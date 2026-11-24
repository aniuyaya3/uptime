#!/usr/bin/env bash
# lib.sh — 公共函数，被 start.sh / scripts/*.sh source
#
# 三条硬规则（对应上游版本的三处泄漏）：
#   1. 密钥不进命令行参数 —— 不用 curl -u、不用 zip -P、不用 openssl -pass pass:
#   2. 临时文件一律 600、临时目录一律 700，并在 EXIT 时清理
#   3. 敏感值优先从 600 权限的文件读取；config.sh 里只放路径
#
# 本文件不 export 任何密钥。

LC_ALL=C
export LC_ALL

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] [WARN] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die()  { printf '[%s] [ERROR] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; exit 1; }

# ---------- 权限 ----------
# Linux: stat -c；BSD/macOS: stat -f
file_mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || printf '?'
}

# 权限过宽只告警、不自动改（避免在只读挂载上直接失败）
warn_loose_perms() {
    local f="$1" label="${2:-$1}" mode
    [ -e "$f" ] || return 0
    mode="$(file_mode "$f")"
    case "$mode" in
        600|400|700|500|'?') ;;
        *) warn "$label 权限为 $mode，建议: chmod 600 \"$f\"" ;;
    esac
}

# ---------- 密钥读取 ----------
# get_secret <文件路径|""> <直接值|""> <名称>
# 文件优先；都没有则返回 1。输出不带换行。
get_secret() {
    local file="$1" inline="$2" name="${3:-secret}"
    if [ -n "$file" ]; then
        [ -f "$file" ] || die "$name：密钥文件不存在 ($file)"
        warn_loose_perms "$file" "$name 密钥文件"
        tr -d '\r\n' < "$file"
        return 0
    fi
    if [ -n "$inline" ]; then
        warn "$name 直接写在 config.sh 里，建议改用 *_FILE（600 权限文件）"
        printf '%s' "$inline"
        return 0
    fi
    return 1
}

# ---------- curl 认证文件 ----------
# 把 user:pass 写进 600 的 curl 配置文件，用 -K 读取。
# 相比 curl -u，进程列表里看不到密码。
#   write_curl_auth <输出文件> <user> <pass>
write_curl_auth() {
    local out="$1" user="$2" pass="$3"
    user="${user//\\/\\\\}"; user="${user//\"/\\\"}"
    pass="${pass//\\/\\\\}"; pass="${pass//\"/\\\"}"
    ( umask 077; printf 'user = "%s:%s"\n' "$user" "$pass" > "$out" )
    chmod 600 "$out"
}

# ---------- WebDAV ----------
# 只允许 https，除非显式放行；file:// 仅用于本地离线安装
check_url_scheme() {
    local url="$1" allow="${2:-0}"
    case "$url" in
        https://*) return 0 ;;
        file://*)  return 0 ;;
        http://*)
            [ "$allow" = "1" ] || die "拒绝明文 http 传输（如确需，设 ALLOW_INSECURE_URL=1）"
            warn "正在使用明文 http 传输凭据与备份"
            ;;
        *) die "URL 格式不支持: $url" ;;
    esac
}

# webdav_put <本地文件> <远端URL> <auth文件>  -> 打印 HTTP 状态码
webdav_put() {
    curl -K "$3" -sS -o /dev/null -w '%{http_code}' \
        --connect-timeout 20 --max-time 600 \
        --retry 3 --retry-delay 5 --retry-connrefused \
        -T "$1" "$2" 2>/dev/null || printf '000'
}

# webdav_get <远端URL> <输出文件> <auth文件> -> 打印 HTTP 状态码
webdav_get() {
    curl -K "$3" -sS -o "$2" -w '%{http_code}' \
        --connect-timeout 20 --max-time 600 \
        --retry 3 --retry-delay 5 --retry-connrefused \
        "$1" 2>/dev/null || printf '000'
}

# webdav_propfind <目录URL> <auth文件>
webdav_propfind() {
    curl -K "$2" -sS --connect-timeout 20 --max-time 120 \
        -X PROPFIND -H 'Depth: 1' "$1" 2>/dev/null || true
}

# webdav_delete <远端URL> <auth文件> -> 打印 HTTP 状态码
webdav_delete() {
    curl -K "$2" -sS -o /dev/null -w '%{http_code}' \
        --connect-timeout 20 --max-time 120 \
        --retry 2 --retry-delay 3 \
        -X DELETE "$1" 2>/dev/null || printf '000'
}

is_2xx() { case "$1" in 2??) return 0 ;; *) return 1 ;; esac; }
