#!/usr/bin/env bash
# scripts/backup.sh — 备份（加固版）
#
# 与上游的区别：
#   * 不再用 curl -u（密码会出现在 /proc/<pid>/cmdline）→ 改用 600 的 curl 配置文件
#   * 不再用 zip -P（ZipCrypto 已被攻破）→ tar.gz + openssl AES-256-CBC/PBKDF2
#   * 临时目录 mktemp -d（700）+ EXIT 清理，不再把完整 kuma.db 放在 755 的 /tmp
#   * 上传带重试；旧备份清理失败不影响本次备份成功
#
# 用法:
#   bash scripts/backup.sh                  # 打包 + 上传 + 清理旧备份
#   bash scripts/backup.sh --local-only     # 只打包到 backups/（不上传，用于验证）
#   bash scripts/backup.sh --local-only --out /path/to/dir

set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib.sh
. "$APP_DIR/lib.sh"
[ -f "$APP_DIR/config.sh" ] || die "缺少 config.sh"
# shellcheck source=../config.sh
. "$APP_DIR/config.sh"

LOCAL_ONLY=0
OUT_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --local-only) LOCAL_ONLY=1 ;;
        --out) OUT_DIR="${2:-}"; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) die "未知参数: $1" ;;
    esac
    shift
done

DATA_DIR="${DATA_DIR:-$APP_DIR/data}"
[ -d "$DATA_DIR" ] || die "数据目录不存在: $DATA_DIR"

WEBDAV_URL="${WEBDAV_URL:-}"
WUSER=""; WPASS=""
if [ "$LOCAL_ONLY" = "0" ]; then
    [ -n "$WEBDAV_URL" ] || die "WEBDAV_URL 未配置"
    check_url_scheme "$WEBDAV_URL" "${ALLOW_INSECURE_URL:-0}"
    # 配了 *_FILE 却文件不存在 = 配置错误，必须失败（不能静默降级）
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
    [ -n "$WUSER" ] || die "WebDAV 用户名缺失（WEBDAV_USER / WEBDAV_USER_FILE）"
    [ -n "$WPASS" ] || die "WebDAV 密码缺失（WEBDAV_PASS_FILE）"
fi

TMP="$(mktemp -d)"          # 默认 700
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

log "准备数据 ..."
mkdir -p "$TMP/payload"
cp -a "$DATA_DIR" "$TMP/payload/data"

if [ "${BACKUP_EXCLUDE_UPLOAD:-1}" = "1" ]; then
    rm -rf "$TMP/payload/data/upload"
    log "已排除 data/upload（BACKUP_EXCLUDE_UPLOAD=1）"
fi
find "$TMP/payload/data" -maxdepth 1 -name '*.log' -delete 2>/dev/null || true

log "打包 ..."
tar -czf "$TMP/data.tar.gz" -C "$TMP/payload" data

STAMP="$(date +%Y%m%d-%H%M%S)"
BASE="uptime-kuma-${STAMP}.tar.gz"

# 加密口令：配了文件就必须存在；都没配才允许明文（并告警）
PASS=""
if [ -n "${BACKUP_PASS_FILE:-}" ]; then
    [ -f "$BACKUP_PASS_FILE" ] || die "BACKUP_PASS_FILE 不存在: $BACKUP_PASS_FILE"
    PASS="$(get_secret "$BACKUP_PASS_FILE" "" "BACKUP_PASS")"
elif [ -n "${BACKUP_PASS:-}" ]; then
    warn "BACKUP_PASS 直接写在 config.sh 里，建议改用 BACKUP_PASS_FILE"
    PASS="$BACKUP_PASS"
fi

if [ -n "$PASS" ]; then
    printf '%s' "$PASS" > "$TMP/pass"
    chmod 600 "$TMP/pass"
    NAME="${BASE}.enc"
    openssl enc -aes-256-cbc -salt -pbkdf2 -iter "${OPENSSL_ITER:-300000}" \
        -pass "file:$TMP/pass" -in "$TMP/data.tar.gz" -out "$TMP/$NAME" \
        || die "加密失败"
    rm -f "$TMP/pass" "$TMP/data.tar.gz"
    log "已加密（AES-256-CBC / PBKDF2 ${OPENSSL_ITER:-300000} 轮）"
else
    NAME="$BASE"
    mv "$TMP/data.tar.gz" "$TMP/$NAME"
    warn "未配置 BACKUP_PASS：备份是明文，云端可读到完整 kuma.db（含通知 token、密码哈希、监控凭据）"
fi

( cd "$TMP" && sha256sum "$NAME" > "$NAME.sha256" )
log "产物: $NAME ($(du -h "$TMP/$NAME" | cut -f1))"

if [ "$LOCAL_ONLY" = "1" ]; then
    OUT_DIR="${OUT_DIR:-$APP_DIR/backups}"
    mkdir -p "$OUT_DIR"
    chmod 700 "$OUT_DIR" 2>/dev/null || true
    cp -f "$TMP/$NAME" "$TMP/$NAME.sha256" "$OUT_DIR/"
    chmod 600 "$OUT_DIR/$NAME" "$OUT_DIR/$NAME.sha256"
    log "已生成: $OUT_DIR/$NAME"
    exit 0
fi

AUTH="$TMP/.curlauth"
write_curl_auth "$AUTH" "$WUSER" "$WPASS"

REMOTE="${WEBDAV_URL%/}"
log "上传 ..."
code="$(webdav_put "$TMP/$NAME" "$REMOTE/$NAME" "$AUTH")"
is_2xx "$code" || die "上传失败 HTTP $code"
log "上传成功（HTTP $code）"

code="$(webdav_put "$TMP/$NAME.sha256" "$REMOTE/$NAME.sha256" "$AUTH")"
is_2xx "$code" || warn "校验文件上传失败 HTTP $code（不影响本次备份）"

# ---------- 清理旧备份（失败不致命） ----------
KEEP="${KEEP_DAYS:-5}"
case "$KEEP" in ''|*[!0-9]*) KEEP=5 ;; esac
[ "$KEEP" -ge 1 ] || KEEP=1
CUTOFF="$(date -d "-${KEEP} days" +%Y%m%d)" || { warn "无法计算保留期，跳过清理"; exit 0; }

log "清理 ${KEEP} 天前的备份（早于 ${CUTOFF}）..."
LIST="$(webdav_propfind "$WEBDAV_URL" "$AUTH")"
printf '%s' "$LIST" \
    | grep -oE 'uptime-kuma-[0-9]{8}-[0-9]{6}\.tar\.gz(\.enc)?' \
    | sort -u \
    | while read -r f; do
        d="${f#uptime-kuma-}"
        d="${d%%-*}"
        case "$d" in ''|*[!0-9]*) continue ;; esac
        [ "$d" -lt "$CUTOFF" ] || continue
        for target in "$f" "$f.sha256"; do
            c="$(webdav_delete "$REMOTE/$target" "$AUTH")"
            is_2xx "$c" && log "已删除 $target" || warn "删除 $target 失败 HTTP $c"
        done
      done

log "备份完成: $NAME"
