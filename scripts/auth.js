#!/usr/bin/env node

const {
  AUTH_PATH,
  ensureAuthConfig,
  resetPassword,
  resetSessions,
} = require("../src/auth-store");

async function main() {
  const command = process.argv[2] || "help";

  if (command === "clear") {
    await ensureAuthConfig();
    await resetSessions();
    console.log("已清除所有手机端登录状态。");
    return;
  }

  if (command === "reset") {
    const password = await resetPassword();
    console.log("认证密码已重置，所有手机端登录状态也已清除。");
    console.log(`新认证密码: ${password}`);
    return;
  }

  if (command === "path") {
    console.log(AUTH_PATH);
    return;
  }

  console.log("用法:");
  console.log("  npm run auth:clear  # 清除所有已登录设备");
  console.log("  npm run auth:reset  # 重置认证密码并清除登录状态");
  console.log("  npm run auth:path   # 查看认证文件路径");
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
