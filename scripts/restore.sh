#!/usr/bin/env bash
# scripts/restore.sh — 恢复（加固版）
#
# 与上游的区别：
#   * 临时目录 mktemp -d（700）+ EXIT 清理
#   * 有 .sha256 就校验，损坏的包不会往 data/ 里灌
#   * 覆盖前先检测 Kuma 是否在跑（在跑就拒绝，除非 --force）
#   * 覆盖不是就地 cp，而是「旧目录改名留存 + 新数据搬入」，失败可回滚
#
# 用法:
#   bash scripts/restore.sh                 # 从 WebDAV 取最新一份
#   bash scripts/restore.sh --file x.tar.gz.enc   # 从本地文件恢复
#   bash scripts/restore.sh --force         # Kuma 正在运行时强制恢复（危险）

set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib.sh
. "$APP_DIR/lib.sh"
[ -f "$APP_DIR/config.sh" ] || die "缺少 config.sh"
# shellcheck source=../config.sh
. "$APP_DIR/config.sh"

SRC=""
FORCE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --file) SRC="${2:-}"; shift ;;
        --force) FORCE=1 ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        *) die "未知参数: $1" ;;
    esac
    shift
done

DATA_DIR="${DATA_DIR:-$APP_DIR/data}"
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ---------- 安全检查：Kuma 在跑就别动 data ----------
# 判据（收紧过）：必须是 **node 进程**，且 argv 里的 server/server.js
# 按该进程的 cwd 解析后，正好等于本目录的 uptime-kuma/server/server.js。
#
# 旧实现只 grep /proc/*/cmdline 里的 'server/server.js' 字符串，导致任何
# 命令行里带这串的进程（编辑器、tail、grep、CI 命令）都被当成 Kuma 在跑，
# 恢复被无故拒绝。现在多要求两点：argv[0] 是 node/nodejs、路径解析后命中本目录。
kuma_running() {
    local target d pid cwd arg real
    target="$(readlink -f "$APP_DIR/uptime-kuma/server/server.js" 2>/dev/null || true)"
    [ -n "$target" ] || return 1

    for d in /proc/[0-9]*; do
        pid="${d##*/}"
        [ "$pid" = "$$" ] && continue
        [ -r "$d/cmdline" ] || continue

        # argv[0] 必须是 node / nodejs，否则不可能是 Kuma
        arg=""
        IFS= read -r -d '' arg < "$d/cmdline" 2>/dev/null || true
        case "${arg##*/}" in
            node|nodejs) ;;
            *) continue ;;
        esac

        cwd="$(readlink -f "$d/cwd" 2>/dev/null || true)"

        while IFS= read -r -d '' arg; do
            case "$arg" in
                *server/server.js)
                    case "$arg" in
                        /*) real="$arg" ;;
                        *)  real="$cwd/$arg" ;;
                    esac
                    if [ "$(readlink -f "$real" 2>/dev/null || true)" = "$target" ]; then
                        return 0
                    fi
                    ;;
            esac
        done < "$d/cmdline" 2>/dev/null || true
    done
    return 1
}
if kuma_running; then
    if [ "$FORCE" = "1" ]; then
        warn "Uptime Kuma 正在运行，--force 已生效（覆盖正在写入的 sqlite 有风险）"
    else
        die "Uptime Kuma 正在运行。请先停止服务再恢复（或加 --force）"
    fi
fi

# ---------- 取包 ----------
LOCAL_MODE=0
if [ -n "$SRC" ]; then
    LOCAL_MODE=1
    [ -f "$SRC" ] || die "文件不存在: $SRC"
    cp -f "$SRC" "$TMP/pkg"
    NAME="$(basename "$SRC")"
    if [ -f "$SRC.sha256" ]; then
        cp -f "$SRC.sha256" "$TMP/pkg.sha256"
    fi
else
    [ -n "${WEBDAV_URL:-}" ] || die "WEBDAV_URL 未配置，且未指定 --file"
    check_url_scheme "$WEBDAV_URL" "${ALLOW_INSECURE_URL:-0}"
    WUSER=""; WPASS=""
    if [ -n "${WEBDAV_USER_FILE:-}" ]; then
        [ -f "$WEBDAV_USER_FILE" ] || die "WEBDAV_USER_FILE 不存在: $WEBDAV_USER_FILE"
        WUSER="$(get_secret "$WEBDAV_USER_FILE" "" "WEBDAV_USER")"
    elif [ -n "${WEBDAV_USER:-}" ]; then
        WUSER="$WEBDAV_USER"
    fi
    if [ -n "${WEBDAV_PASS_FILE:-}" ]; then
        [ -f "$WEBDAV_PASS_FILE" ] || die "WEBDAV_PASS_FILE 不存在: $WEBDAV_PASS_FILE"
        WPASS="$(get_secret "$WEBDAV_PASS_FILE" "" "WEBDAV_PASS")"
    elif [ -n "${WEBDAV_PASS:-}" ]; then
        warn "WEBDAV_PASS 直接写在 config.sh 里，建议改用 WEBDAV_PASS_FILE"
        WPASS="$WEBDAV_PASS"
    fi
    [ -n "$WUSER" ] && [ -n "$WPASS" ] || die "WebDAV 凭据缺失"
    AUTH="$TMP/.curlauth"
    write_curl_auth "$AUTH" "$WUSER" "$WPASS"

    log "查找最新备份 ..."
    LIST="$(webdav_propfind "$WEBDAV_URL" "$AUTH")"
    NAME="$(printf '%s' "$LIST" \
        | grep -oE 'uptime-kuma-[0-9]{8}-[0-9]{6}\.tar\.gz(\.enc)?' \
        | sort -u | sort -r | head -n1)"
    [ -n "$NAME" ] || die "远端没有找到备份文件"

    REMOTE="${WEBDAV_URL%/}"
    log "下载 $NAME ..."
    code="$(webdav_get "$REMOTE/$NAME" "$TMP/pkg" "$AUTH")"
    is_2xx "$code" || die "下载失败 HTTP $code"

    code="$(webdav_get "$REMOTE/$NAME.sha256" "$TMP/pkg.sha256" "$AUTH")"
    is_2xx "$code" && log "已取得校验文件" || warn "无校验文件，跳过完整性校验"
fi

# ---------- 校验 ----------
if [ -f "$TMP/pkg.sha256" ]; then
    expected="$(awk '{print $1}' "$TMP/pkg.sha256" | head -n1)"
    actual="$(sha256sum "$TMP/pkg" | awk '{print $1}')"
    if [ -n "$expected" ] && [ "$expected" != "$actual" ]; then
        die "sha256 不匹配（包损坏或被篡改）: 期望 $expected 实际 $actual"
    fi
    log "sha256 校验通过"
fi

# ---------- 解密 ----------
WORK="$TMP/pkg"
case "$NAME" in
    *.enc)
        PASS=""
        if [ -n "${BACKUP_PASS_FILE:-}" ]; then
            [ -f "$BACKUP_PASS_FILE" ] || die "BACKUP_PASS_FILE 不存在: $BACKUP_PASS_FILE"
            PASS="$(get_secret "$BACKUP_PASS_FILE" "" "BACKUP_PASS")"
        elif [ -n "${BACKUP_PASS:-}" ]; then
            warn "BACKUP_PASS 直接写在 config.sh 里，建议改用 BACKUP_PASS_FILE"
            PASS="$BACKUP_PASS"
        fi
        [ -n "$PASS" ] || die "备份已加密，但没找到 BACKUP_PASS_FILE"
        printf '%s' "$PASS" > "$TMP/pass"
        chmod 600 "$TMP/pass"
        openssl enc -d -aes-256-cbc -pbkdf2 -iter "${OPENSSL_ITER:-300000}" \
            -pass "file:$TMP/pass" -in "$TMP/pkg" -out "$TMP/pkg.tar.gz" \
            || die "解密失败（密码不对，或 openssl 不支持 -iter）"
        rm -f "$TMP/pass"
        WORK="$TMP/pkg.tar.gz"
        log "解密完成"
        ;;
esac

# ---------- 解包 ----------
mkdir -p "$TMP/x"
tar -xzf "$WORK" -C "$TMP/x" || die "解压失败"
[ -d "$TMP/x/data" ] || die "包内没有 data/ 目录，不是有效备份"

# ---------- 落地（可回滚） ----------
STAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$DATA_DIR"
chmod 700 "$DATA_DIR" 2>/dev/null || true

if [ -n "$(ls -A "$DATA_DIR" 2>/dev/null || true)" ]; then
    BAK="${DATA_DIR}.bak.${STAMP}"
    log "保留旧数据: $BAK"
    mv "$DATA_DIR" "$BAK" || die "无法移动旧数据目录"
    mkdir -p "$DATA_DIR"
    chmod 700 "$DATA_DIR"
fi

if ! cp -a "$TMP/x/data/." "$DATA_DIR/"; then
    warn "恢复失败，尝试回滚"
    rm -rf "$DATA_DIR"
    [ -d "${DATA_DIR}.bak.${STAMP}" ] && mv "${DATA_DIR}.bak.${STAMP}" "$DATA_DIR"
    die "恢复失败，已回滚"
fi
chmod 700 "$DATA_DIR" 2>/dev/null || true
chmod 600 "$DATA_DIR"/*.db 2>/dev/null || true

log "恢复完成: $NAME"
if [ -d "${DATA_DIR}.bak.${STAMP}" ]; then
    log "旧数据保留在 ${DATA_DIR}.bak.${STAMP}，确认无误后可删除"
fi
exit 0
