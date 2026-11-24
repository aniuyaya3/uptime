#!/usr/bin/env bash
# start.sh — 容器入口（加固版，适配 Uptime Kuma 2.5.12）
#
# 与上游的区别：
#   * umask 077：新建文件默认 600，不再出现 644 的 .agent.yaml
#   * 下载走 -f 到临时文件 + sha256 校验（不再 curl | tar 裸管道）
#   * config.sh 用 if 判断加载（修掉 set -e 撞 && 链导致静默退出）
#   * 备份调度改成「算到下一个整点还差多少秒」，不再整点漂移漏天
#   * exec node 之前 unset 全部密钥，node 的 environ 里没有凭据
#   * 哪吒 disable_command_execute 可配，默认关闭

set -Eeuo pipefail
umask 077

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$APP_DIR/lib.sh"

if [ -f "$APP_DIR/config.sh" ]; then
    # shellcheck source=config.sh
    . "$APP_DIR/config.sh"
    log "配置已加载"
else
    die "缺少 config.sh（复制 config.sh 并填好）"
fi

warn_loose_perms "$APP_DIR/config.sh" "config.sh"

DATA_DIR="$APP_DIR/data"
KUMA_DIR="$APP_DIR/uptime-kuma"
AGENT_BIN="$APP_DIR/nezha-agent"
AGENT_CONF="$APP_DIR/.agent.yaml"
AGENT_PID_FILE="$APP_DIR/.agent.pid"
WATCHDOG_PID_FILE="$APP_DIR/.watchdog.pid"

mkdir -p "$DATA_DIR"
chmod 700 "$DATA_DIR" 2>/dev/null || warn "无法 chmod 700 $DATA_DIR"

# ============================================================
# 进程工具（不依赖 ps，精简容器里通常没有 procps）
# ============================================================
proc_alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

find_proc_by_name() {
    local name="$1" pid
    for d in /proc/[0-9]*; do
        pid="${d##*/}"
        [ -r "$d/cmdline" ] || continue
        if tr '\0' ' ' < "$d/cmdline" 2>/dev/null | grep -q -- "$name"; then
            printf '%s' "$pid"
            return 0
        fi
    done
    return 1
}

# ============================================================
# 清理
# ============================================================
cleanup() {
    local rc=$?
    log "收到退出信号，清理中..."
    for f in "$WATCHDOG_PID_FILE" "$AGENT_PID_FILE"; do
        [ -f "$f" ] || continue
        pid="$(cat "$f" 2>/dev/null || true)"
        if proc_alive "$pid"; then kill "$pid" 2>/dev/null || true; fi
        rm -f "$f"
    done
    exit "$rc"
}
trap cleanup TERM INT

# ============================================================
# 1. 准备 Uptime Kuma
# ============================================================
download_kuma() {
    local url="${KUMA_DOWNLOAD_URL:-}" tmp
    [ -n "$url" ] || die "KUMA_DOWNLOAD_URL 为空"
    case "$url" in
        *'<你的用户名>'*|*'<你的仓库>'*)
            die "请先把 config.sh 里的 KUMA_DOWNLOAD_URL 改成你自己的 release 地址" ;;
    esac
    check_url_scheme "$url" "${ALLOW_INSECURE_URL:-0}"

    tmp="$(mktemp "$APP_DIR/.kuma-download.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" EXIT

    log "下载 Uptime Kuma ${KUMA_VERSION:-} ..."
    case "$url" in
        file://*)
            # 离线安装：把 tar.gz 传到容器里，KUMA_DOWNLOAD_URL=file:///绝对路径
            cp -f "${url#file://}" "$tmp" || die "复制失败：${url#file://}" ;;
        *)
            curl -fsSL --connect-timeout 20 --max-time 900 \
                --retry 3 --retry-delay 5 --retry-connrefused \
                "$url" -o "$tmp" || die "下载失败：$url" ;;
    esac

    if [ -n "${KUMA_SHA256:-}" ]; then
        if printf '%s  %s\n' "$KUMA_SHA256" "$tmp" | sha256sum -c - >/dev/null 2>&1; then
            log "sha256 校验通过"
        else
            die "sha256 校验失败（包被替换或配置写错）"
        fi
    else
        warn "未配置 KUMA_SHA256，跳过完整性校验（不推荐）"
    fi

    rm -rf "$KUMA_DIR"
    mkdir -p "$KUMA_DIR"
    tar -xzf "$tmp" --strip-components=1 -C "$KUMA_DIR" || die "解压失败"
    rm -f "$tmp"
    trap - EXIT

    [ -f "$KUMA_DIR/server/server.js" ] || die "包里没有 server/server.js，不是有效的预构建包"
    [ -d "$KUMA_DIR/node_modules" ] || die "包里没有 node_modules，不是有效的预构建包"
    log "Uptime Kuma 就绪"
}

if [ ! -f "$KUMA_DIR/server/server.js" ]; then
    download_kuma
fi
[ -d "$KUMA_DIR/node_modules" ] || die "node_modules 缺失，请删除 uptime-kuma/ 重新下载"

# ============================================================
# 2. 哪吒监控 Agent（可选）
# ============================================================
NEZHA_ON=0
NZ_SECRET=""

resolve_nezha() {
    NZ_SECRET=""
    if [ -n "${NZ_CLIENT_SECRET_FILE:-}" ]; then
        [ -f "$NZ_CLIENT_SECRET_FILE" ] || die "NZ_CLIENT_SECRET_FILE 不存在: $NZ_CLIENT_SECRET_FILE"
        NZ_SECRET="$(get_secret "$NZ_CLIENT_SECRET_FILE" "" "NZ_CLIENT_SECRET")"
    elif [ -n "${NZ_CLIENT_SECRET:-}" ]; then
        warn "NZ_CLIENT_SECRET 直接写在 config.sh 里，建议改用 NZ_CLIENT_SECRET_FILE"
        NZ_SECRET="$NZ_CLIENT_SECRET"
    fi
    if [ -n "${NZ_SERVER:-}" ] && [ -n "${NZ_UUID:-}" ] && [ -n "$NZ_SECRET" ]; then
        NEZHA_ON=1
    elif [ -n "${NZ_SERVER:-}${NZ_UUID:-}${NZ_SECRET}" ]; then
        warn "哪吒配置不完整，已跳过"
        if [ -z "${NZ_SERVER:-}" ]; then warn "  缺少 NZ_SERVER"; fi
        if [ -z "${NZ_UUID:-}" ]; then warn "  缺少 NZ_UUID"; fi
        if [ -z "$NZ_SECRET" ]; then warn "  缺少 NZ_CLIENT_SECRET"; fi
    fi
}
resolve_nezha

download_agent() {
    local arch file url ver
    arch="$(uname -m)"
    case "$arch" in
        x86_64)  file="nezha-agent_linux_amd64.zip" ;;
        aarch64) file="nezha-agent_linux_arm64.zip" ;;
        *) warn "不支持的架构 $arch，跳过哪吒"; NEZHA_ON=0; return 0 ;;
    esac
    command -v unzip >/dev/null 2>&1 || { warn "缺少 unzip，跳过哪吒"; NEZHA_ON=0; return 0; }

    ver="${NZ_AGENT_VERSION:-}"
    if [ -z "$ver" ] || [ "$ver" = "latest" ]; then
        ver="$(curl -sIL --connect-timeout 10 --max-time 30 \
            https://github.com/nezhahq/agent/releases/latest 2>/dev/null \
            | grep -i '^location:' | tail -1 | sed 's#.*/tag/##' | tr -d '\r\n ')"
    fi
    [ -n "$ver" ] || { warn "无法确定哪吒 Agent 版本，跳过"; NEZHA_ON=0; return 0; }

    url="https://github.com/nezhahq/agent/releases/download/${ver}/${file}"
    log "下载哪吒 Agent ${ver} ..."
    if curl -fsSL --connect-timeout 20 --max-time 300 --retry 2 "$url" -o "$APP_DIR/$file"; then
        ( cd "$APP_DIR" && unzip -qo "$file" && rm -f "$file" )
        if [ -f "$AGENT_BIN" ]; then
            chmod 700 "$AGENT_BIN"
        fi
    fi
    [ -x "$AGENT_BIN" ] || { warn "哪吒 Agent 下载失败，跳过"; NEZHA_ON=0; }
}

write_agent_conf() {
    # 600 权限；disable_command_execute 由 NZ_ALLOW_COMMAND_EXECUTE 控制
    local tls cmd_exec
    case "${NZ_TLS:-1}" in 1|true|TRUE|yes) tls=true ;; *) tls=false ;; esac
    case "${NZ_ALLOW_COMMAND_EXECUTE:-0}" in 1|true|TRUE|yes) cmd_exec=false ;; *) cmd_exec=true ;; esac

    ( umask 077
      cat > "$AGENT_CONF" <<EOF
client_secret: ${NZ_SECRET}
debug: false
disable_auto_update: true
disable_command_execute: ${cmd_exec}
disable_force_update: true
disable_nat: false
disable_send_query: false
gpu: false
insecure_tls: false
ip_report_period: 1800
report_delay: 4
server: ${NZ_SERVER}
skip_connection_count: false
skip_procs_count: false
temperature: false
tls: ${tls}
use_gitee_to_upgrade: false
use_ipv6_country_code: false
uuid: ${NZ_UUID}
EOF
    )
    chmod 600 "$AGENT_CONF"
}

start_agent() {
    proc_alive "$(cat "$AGENT_PID_FILE" 2>/dev/null || true)" && return 0
    [ -x "$AGENT_BIN" ] && [ -f "$AGENT_CONF" ] || return 1
    nohup "$AGENT_BIN" -c "$AGENT_CONF" >/dev/null 2>&1 &
    printf '%s' "$!" > "$AGENT_PID_FILE"
    sleep 3
    if proc_alive "$(cat "$AGENT_PID_FILE")"; then
        log "哪吒 Agent 已启动 (PID $(cat "$AGENT_PID_FILE"))"
        return 0
    fi
    rm -f "$AGENT_PID_FILE"
    warn "哪吒 Agent 启动失败"
    return 1
}

if [ "$NEZHA_ON" = "1" ]; then
    [ -x "$AGENT_BIN" ] || download_agent
    if [ "$NEZHA_ON" = "1" ] && [ -x "$AGENT_BIN" ]; then
        write_agent_conf
        start_agent || true
    fi
fi

# 守护进程：Agent 挂了就拉起来（带退避）
if [ "$NEZHA_ON" = "1" ] && [ -f "$AGENT_CONF" ]; then
    (
        interval="${NZ_CHECK_INTERVAL:-600}"
        case "$interval" in ''|*[!0-9]*) interval=600 ;; esac
        [ "$interval" -lt 30 ] && interval=30
        sleep 10
        while :; do
            sleep "$interval"
            if ! proc_alive "$(cat "$AGENT_PID_FILE" 2>/dev/null || true)"; then
                log "哪吒 Agent 不在，尝试重启"
                start_agent || sleep 300
            fi
        done
    ) &
    printf '%s' "$!" > "$WATCHDOG_PID_FILE"
    log "哪吒守护进程已启动（每 ${NZ_CHECK_INTERVAL:-600}s 检查）"
fi

# ============================================================
# 3. 备份调度（算到下一个整点，不漏天）
# ============================================================
if [ -n "${WEBDAV_URL:-}" ]; then
    (
        hour="${BACKUP_HOUR:-4}"
        case "$hour" in ''|*[!0-9]*) hour=4 ;; esac
        [ "$hour" -gt 23 ] && hour=4
        sleep 30
        while :; do
            now="$(date +%s)"
            target="$(date -d "today ${hour}:00:00" +%s 2>/dev/null || printf '0')"
            if [ "$target" -le "$now" ]; then
                target="$(date -d "tomorrow ${hour}:00:00" +%s)"
            fi
            sleep_for=$(( target - now ))
            log "下次备份：$(date -d "@${target}" '+%Y-%m-%d %H:%M')（${sleep_for}s 后）"
            sleep "$sleep_for"
            bash "$APP_DIR/scripts/backup.sh" || warn "备份失败，明天重试"
            sleep 120
        done
    ) &
    log "备份调度已启动（每天 ${BACKUP_HOUR:-4}:00）"
fi

# ============================================================
# 4. 启动 Uptime Kuma
# ============================================================
export DATA_DIR
export UPTIME_KUMA_PORT="${PORT:-3001}"
export NODE_OPTIONS="--max-old-space-size=${NODE_HEAP_MB:-512}"

# 关键：exec 之后 node 继承 environ，所以先把凭据全部摘掉
unset WEBDAV_PASS WEBDAV_USER BACKUP_PASS NZ_CLIENT_SECRET NZ_SECRET 2>/dev/null || true

log "启动 Uptime Kuma — 端口 ${UPTIME_KUMA_PORT}，数据 ${DATA_DIR}"
cd "$KUMA_DIR"
exec node server/server.js
