#!/usr/bin/env bash
# ============================================================
#  Uptime Kuma 2.5.12 配置（加固版）
#
#  ⚠ 本文件会被 source，且**刻意不使用 export**
#    —— 避免 WEBDAV_PASS / BACKUP_PASS / NZ_CLIENT_SECRET
#       进入 node 进程的 environ（/proc/<pid>/environ 可读）
#
#  ⚠ 敏感值请写进 600 权限的文件，不要写在这里：
#      echo -n '你的密码' > .webdav.pass && chmod 600 .webdav.pass
#      echo -n '备份口令'   > .backup.pass && chmod 600 .backup.pass
#      echo -n '哪吒密钥'   > .nezha.secret && chmod 600 .nezha.secret
#    密码文件内容就是密码本身（一行，末尾不要换行，脚本会自己去掉）
#
#  ⚠ 本文件不要提交到公开仓库（.gitignore 已忽略敏感文件名）
#  ⚠ 所有变量写成 ${X:-默认值} 形式，便于平台用环境变量覆盖
# ============================================================

# ---------- 基础 ----------
export TZ="${TZ:-Asia/Shanghai}"   # TZ 不是密钥，可以 export
PORT="${PORT:-2114}"               # 改成面板分配给你的端口
NODE_HEAP_MB="${NODE_HEAP_MB:-512}"  # 2.5.x 建议 512；内存 <512MB 时改 384

# ---------- 预构建包 ----------
KUMA_VERSION="${KUMA_VERSION:-2.5.12}"
KUMA_DOWNLOAD_URL="${KUMA_DOWNLOAD_URL:-https://github.com/aniuyaya3/uptime/releases/download/2.5.12/uptime-kuma-2.5.12.tar.gz}"
# 强烈建议填上 workflow 产出的 sha256（该文件内容的第一列），防止包被替换
KUMA_SHA256="${KUMA_SHA256:-7f3b0cb24b2e790c5457bd80f18114843c37880025f0a81d9e91de3332f72cea}"
ALLOW_INSECURE_URL="${ALLOW_INSECURE_URL:-0}"   # 1 = 允许 http（不建议）

# ---------- WebDAV 备份 ----------
WEBDAV_URL="${WEBDAV_URL:-https://your.webdav.example/dav/uptime-kuma/}"
WEBDAV_USER="${WEBDAV_USER:-}"
WEBDAV_USER_FILE="${WEBDAV_USER_FILE:-}"          # 可选：600 文件
WEBDAV_PASS_FILE="${WEBDAV_PASS_FILE:-}"          # 推荐：填 .webdav.pass 的绝对路径
WEBDAV_PASS="${WEBDAV_PASS:-}"                    # 兼容旧写法，强烈不建议

# ---------- 备份策略 ----------
BACKUP_HOUR="${BACKUP_HOUR:-4}"                   # 每天几点备份（0-23）
KEEP_DAYS="${KEEP_DAYS:-5}"                       # 保留几天
BACKUP_EXCLUDE_UPLOAD="${BACKUP_EXCLUDE_UPLOAD:-1}"  # 1 = 不备份 data/upload（恢复后图标会丢）
BACKUP_PASS_FILE="${BACKUP_PASS_FILE:-}"          # 填 .backup.pass 的绝对路径；留空=不加密
BACKUP_PASS="${BACKUP_PASS:-}"                    # 兼容旧写法，强烈不建议
OPENSSL_ITER="${OPENSSL_ITER:-300000}"            # PBKDF2 迭代次数

# ---------- 哪吒监控（可选，NZ_SERVER 留空即禁用） ----------
NZ_SERVER="${NZ_SERVER:-}"                        # 你自己的面板，例如 panel.example.com:443
NZ_UUID="${NZ_UUID:-}"
NZ_CLIENT_SECRET_FILE="${NZ_CLIENT_SECRET_FILE:-}"  # 填 .nezha.secret 的绝对路径
NZ_CLIENT_SECRET="${NZ_CLIENT_SECRET:-}"          # 兼容旧写法
NZ_TLS="${NZ_TLS:-1}"                             # 1/0
NZ_CHECK_INTERVAL="${NZ_CHECK_INTERVAL:-600}"     # 守护进程检查间隔（秒）
NZ_ALLOW_COMMAND_EXECUTE="${NZ_ALLOW_COMMAND_EXECUTE:-0}"  # 0 = 面板不能在本机执行命令
