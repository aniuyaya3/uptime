#!/usr/bin/env bash
# scripts/selftest.sh — 不依赖网络的本地自测
#
# 覆盖：打包 → 加密 → sha256 → 恢复 → 解密 → 回填比对
# 用法: bash scripts/selftest.sh

set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

T="$(mktemp -d)"
cleanup() { rm -rf "$T"; }
trap cleanup EXIT

PASS=0
FAIL=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

echo "== 准备测试数据 =="
mkdir -p "$T/data/upload"
head -c 262144 /dev/urandom > "$T/data/kuma.db"
printf 'png-bytes' > "$T/data/upload/icon.png"
printf 'noise\n' > "$T/data/server.log"
ORIG_SUM="$(sha256sum "$T/data/kuma.db" | awk '{print $1}')"
echo "  data 大小: $(du -sh "$T/data" | cut -f1)"

printf 'test-passphrase-123' > "$T/pass"
chmod 600 "$T/pass"

echo "== 备份（本地模式 + 加密）=="
DATA_DIR="$T/data" BACKUP_PASS_FILE="$T/pass" \
    bash "$APP_DIR/scripts/backup.sh" --local-only --out "$T/out"

PKG="$(find "$T/out" -name 'uptime-kuma-*.tar.gz.enc' | head -n1)"
check "生成加密包"            "[ -n \"$PKG\" ]"
check "生成 sha256 校验文件"   "[ -f \"$PKG.sha256\" ]"
check "包权限为 600"          "[ \"\$(stat -c %a \"$PKG\")\" = \"600\" ]"
check "备份目录权限为 700"     "[ \"\$(stat -c %a \"$T/out\")\" = \"700\" ]"

echo "== 加密有效性 =="
check "密文不是 tar.gz（魔数不同）" "! tar -tzf \"$PKG\" >/dev/null 2>&1"
check "密文里搜不到明文文件名"      "! grep -qa 'kuma.db' \"$PKG\""

echo "== 错误口令必须失败 =="
printf 'wrong-pass' > "$T/badpass"; chmod 600 "$T/badpass"
if DATA_DIR="$T/nope" BACKUP_PASS_FILE="$T/badpass" \
    bash "$APP_DIR/scripts/restore.sh" --file "$PKG" >/dev/null 2>&1; then
    bad "错误口令竟然恢复成功"
else
    ok "错误口令被拒绝"
fi

echo "== 恢复（本地文件）=="
DATA_DIR="$T/restored" BACKUP_PASS_FILE="$T/pass" \
    bash "$APP_DIR/scripts/restore.sh" --file "$PKG"

NEW_SUM="$(sha256sum "$T/restored/kuma.db" | awk '{print $1}')"
check "kuma.db 内容一致"        "[ \"$ORIG_SUM\" = \"$NEW_SUM\" ]"
check "data 目录权限为 700"      "[ \"\$(stat -c %a \"$T/restored\")\" = \"700\" ]"
check "kuma.db 权限为 600"      "[ \"\$(stat -c %a \"$T/restored/kuma.db\")\" = \"600\" ]"
check "upload 被排除"           "[ ! -d \"$T/restored/upload\" ]"
check "*.log 被排除"            "[ ! -f \"$T/restored/server.log\" ]"

echo "== 二次恢复不丢旧数据（备份目录留存）=="
DATA_DIR="$T/restored" BACKUP_PASS_FILE="$T/pass" \
    bash "$APP_DIR/scripts/restore.sh" --file "$PKG" >/dev/null
check "生成 data.bak.* 留存目录" "ls -d \"$T\"/restored.bak.* >/dev/null 2>&1"

echo
echo "== 结果: ${PASS} passed, ${FAIL} failed =="
[ "$FAIL" -eq 0 ] || exit 1
