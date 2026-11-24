# Uptime Kuma 2.5.12 on Lunes.host（加固版）

基于 `oyz8/action` 的 `lunes.host-Uptime` 思路重写：**不依赖 Docker、小内存、WebDAV 持久化**，
适配 Uptime Kuma **2.5.12**，并修掉了原版在凭据处理上的几处结构性泄漏。

## 和上游的区别

| 项 | 上游 | 这里 |
|---|---|---|
| 凭据传递 | `export` 全部变量 → 进入 node 进程 environ | 不 export；`exec node` 前 `unset` |
| curl 认证 | `curl -u user:pass`（`ps` 可见） | 600 权限的 curl 配置文件 + `-K` |
| 备份加密 | `zip -P`（ZipCrypto，已被攻破） | `tar.gz` + `openssl AES-256-CBC / PBKDF2 30 万轮` |
| 临时目录 | `/tmp/backup-$$`（755，含完整 kuma.db） | `mktemp -d`（700）+ EXIT 清理 |
| 哪吒配置 | `.agent.yaml` 644 + `disable_command_execute: false` | 600 + 默认 `true`（禁命令执行） |
| 包校验 | `curl \| tar`，无校验 | 下载到临时文件 + sha256 + `server/server.js` 存在性检查 |
| 备份调度 | `sleep 3600` 后比整点（会漏天） | 算到下一个整点还差多少秒 |
| 内存 | 固定 256MB | `NODE_HEAP_MB`，默认 512 |
| Node 版本 | 2.0.2 / workflow 用 node 18 | 2.5.12 要求 `>= 20.4.0`，统一 node 20 |

## 目录

```
config.sh              # 配置（600；敏感值只放路径）
start.sh               # 容器入口
lib.sh                 # 公共函数（日志/密钥/curl/WebDAV）
index.js               # 平台写死 node index.js 时用
scripts/backup.sh      # 备份：打包 → 加密 → 上传 → 清理旧包
scripts/restore.sh     # 恢复：校验 → 解密 → 可回滚地落盘
scripts/selftest.sh    # 不联网自测（13 项）
.github/workflows/     # 自建 2.5.12 预构建包的 amd64 / arm64 构建
dist/                  # 已构建好的 2.5.12 包（见下）
```

## 快速开始

1. **上传** 除 `dist/` 外的所有文件到容器根目录。
2. **权限**：
   ```bash
   chmod 755 start.sh lib.sh scripts/*.sh
   chmod 600 config.sh
   ```
3. **写密码文件**（内容就是密码本身，末尾别带换行）：
   ```bash
   printf '%s' '你的WebDAV密码' > .webdav.pass && chmod 600 .webdav.pass
   printf '%s' '备份口令'        > .backup.pass && chmod 600 .backup.pass
   # 用哪吒才需要：
   printf '%s' '面板密钥'        > .nezha.secret && chmod 600 .nezha.secret
   ```
4. **改 `config.sh`**：`PORT`、`WEBDAV_URL`、`WEBDAV_USER`、
   `WEBDAV_PASS_FILE=/绝对路径/.webdav.pass`、`BACKUP_PASS_FILE=/绝对路径/.backup.pass`。
5. **预构建包**（默认已指向官方 Release，一般不用改）：
   - 默认：`KUMA_DOWNLOAD_URL` 已填
     `https://github.com/aniuyaya3/uptime/releases/download/2.5.12/uptime-kuma-2.5.12.tar.gz`，
     `KUMA_SHA256` 已填好，启动时自动校验；
   - 离线：把 `dist/uptime-kuma-2.5.12.tar.gz` 传进容器，改
     `KUMA_DOWNLOAD_URL="file:///绝对路径/uptime-kuma-2.5.12.tar.gz"`；
   - 自建：用 `.github/workflows/Uptime_amd64.yml` 现场构建，换成自己的地址 + `KUMA_SHA256`。
6. **Startup Command** 设为 `npm start`，启动。

首次访问会先出现 **Setup Database**（选 SQLite）→ 再设管理员账号。
**这一步之前别把端口暴露到公网**，2.5.x 未初始化时任何人都能抢占。

## 已构建的产物

已发布：<https://github.com/aniuyaya3/uptime/releases/tag/2.5.12>

```
https://github.com/aniuyaya3/uptime/releases/download/2.5.12/uptime-kuma-2.5.12.tar.gz
https://github.com/aniuyaya3/uptime/releases/download/2.5.12/uptime-kuma-2.5.12.tar.gz.sha256
sha256 = 7f3b0cb24b2e790c5457bd80f18114843c37880025f0a81d9e91de3332f72cea
```

本地也留了一份：`dist/uptime-kuma-2.5.12.tar.gz`（39MB，不进 git）

- 顶层目录 `uptime-kuma/`（配合 `--strip-components=1`）
- 含 `dist/`（前端）、`server/`、`src/`、`db/`、`extra/`、生产依赖
- 已在 node 22 和 node 20 下分别启动验证：`Uptime Kuma Version: 2.5.12`，监听正常
- sqlite3 是 N-API 绑定（`napi-v6-linux-x64`），跨 node 20/22 通用

## 安全模型（明确边界）

做对的部分：

- 密钥不进命令行、不进 node 的 environ、不落 644 文件
- 备份默认 AES-256-CBC + PBKDF2；口令缺失会告警
- 临时目录 700，退出即删
- 强制 https（`ALLOW_INSECURE_URL=1` 才能放开）
- 下载校验 sha256；不校验会显式告警

仍然存在的限制（如实说明）：

1. **`openssl enc` 没有 MAC**：能防窃听、防篡改（有 sha256 sidecar），但**不是**认证加密。
   对手若能同时改包和 `.sha256`，校验就失效。要更强就用 `age`/`gpg`。
2. **`.agent.yaml` 在运行期必须存在**（守护进程重启 Agent 要读它），所以是 600 而不是删除。
   容器被入侵时它可读。
3. **`exec node` 后 bash 的 EXIT trap 不执行**——这是上游的坑，本版不再依赖它：
   敏感变量在 exec 前就 unset 了，文件权限在创建时就设好了。
4. `BACKUP_EXCLUDE_UPLOAD=1`（默认）不备份 `data/upload`，恢复后通知图标会丢；
   要完整备份就设 0，代价是包体积。
5. 备份口令与 WebDAV 密码**别复用**。

## 自测

```bash
bash scripts/selftest.sh
```

覆盖：打包 → 加密 → sha256 → 错误口令被拒 → 恢复 → 内容比对 → 权限 → 排除规则 → 旧数据留存。

## 排错

| 现象 | 原因 |
|---|---|
| `node_modules 缺失` | 包不是预构建包，或下载被 CDN 截断 |
| 启动即退出，无日志 | `config.sh` 里 `WEBDAV_PASS_FILE` 指向的文件不存在（本版会直接报错，不静默降级） |
| `sqlite3` 加载失败 | 用了 arm64 包跑在 amd64 上（或反之） |
| 备份上传 401 | WebDAV 用了应用密码/独立密码，不是账号密码 |
| 备份从没跑过 | `BACKUP_HOUR` 非数字，或容器时区与预期不符（脚本用 `TZ`） |
