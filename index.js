// index.js — 仅当平台的启动命令被写死成 `node index.js` 时使用
// 正常情况请把 Startup Command 设为: npm start
const { spawn } = require("child_process");
const path = require("path");

const appDir = __dirname;
const script = path.join(appDir, "start.sh");

const child = spawn("bash", [script], {
  cwd: appDir,
  stdio: "inherit",
  env: { ...process.env, APP_DIR: appDir },
});

const forward = (sig) => () => {
  try {
    child.kill(sig);
  } catch (_) {
    /* 进程已退出 */
  }
};

process.on("SIGTERM", forward("SIGTERM"));
process.on("SIGINT", forward("SIGINT"));

child.on("error", (err) => {
  console.error("[ERROR] 无法启动 start.sh:", err.message);
  process.exit(1);
});

child.on("exit", (code, signal) => {
  process.exit(code === null ? (signal ? 1 : 0) : code);
});
