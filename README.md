# VoiceRelay

安卓手机打开你配置的公网地址后，用任意输入法在文本框里输入或语音输入；Mac 端会把手机文本框内容全文同步到当前聚焦的文本框。

手机页面的“发送”按钮位于文本输入区下方。文本框会从一行高度开始随内容变高，达到屏幕可用高度后在文本框内部滚动，按钮会留在可点击区域。点击后会先把手机文本框全文同步到 Mac 当前输入框，然后触发一次 Enter 提交。

## 启动

日常使用推荐菜单栏 App：

```bash
npm run build:menu
npm run menu:install
```

如果要让菜单栏 App 打开你的公网页面，并启动对应的 Cloudflare 隧道配置，可以在构建时传入本机配置：

```bash
PUBLIC_URL=https://your-domain.example/ \
CLOUDFLARED_CONFIG="$HOME/.cloudflared/config.yml" \
npm run menu:install
```

退出后可以用下面任意一种方式重新打开：

```bash
npm run menu:open
open /Applications/VoiceRelayMenu.app
```

也可以在 Finder 里打开 `/Applications/VoiceRelayMenu.app`。

菜单栏 App 默认只常驻菜单栏，不自动开启本地服务或 Cloudflare 隧道。带开关语义的菜单项右侧会显示 Switch；需要使用跨屏输入时，打开“跨屏输入服务”和“Cloudflare 隧道”；不用时关闭任意一个。

前台调试服务：

```bash
npm start
```

前台调试时也可以指定访问地址：

```bash
PUBLIC_URL=https://your-domain.example/ npm start
```

旧的 LaunchAgent 后台模式仍可用于调试；日常使用不建议和菜单栏 App 同时开启：

```bash
npm run daemon:install
```

停止并移除后台服务：

```bash
npm run daemon:uninstall
```

启动后访问你配置的公网地址，例如 `https://your-domain.example/`。手机第一次打开时输入认证密码，之后会长期保持登录。

当前认证密码会写在本地日志 `.voicerelay.log` 的最后一次 `新认证密码` 记录里。如果不确定当前密码，直接运行 `npm run auth:reset` 生成新的。

## 菜单栏 App

菜单栏提供这些操作：

- 跨屏输入服务开关
- Cloudflare 隧道开关
- 打开手机端页面
- 复制认证密码
- 重置认证密码
- 清除手机登录态
- 开机自启菜单栏 App
- App 启动时自动开启服务/隧道
- 打开日志目录
- 清理残留服务进程

## 认证

```bash
npm run auth:clear
```

这会清除所有手机端登录状态，下一次打开页面需要重新输入认证密码。

```bash
npm run auth:reset
```

这会重置认证密码，并同时清除所有手机端登录状态。

## Mac 权限

首次使用需要在 macOS 的“隐私与安全性 -> 辅助功能”里允许运行该服务的进程。同步默认通过原生辅助写入器直接设置当前聚焦文本框的 `AXValue`，不使用剪贴板、不发送 `Command+A`，也不走粘贴。

Codex 的输入框已探测为 `AXTextArea`，实时同步默认通过 `AXValue` 写入。由于 Codex 对 `AXValue` 写入会把换行折叠为空格，点击“发送”且文本包含换行时，会先通过辅助功能选中当前输入框全文，再只发送一次 `Command+V` 粘贴替换，随后 Enter 提交；不会打开应用菜单，也不会发送 `Command+A`。

如果系统设置里已经开启 VoiceRelayMenu，但菜单栏 App 仍提示没有辅助功能权限，通常是因为本地重新构建后 macOS 仍保留旧二进制的授权记录。处理方式：

1. 打开“隐私与安全性 -> 辅助功能”。
2. 移除旧的 VoiceRelayMenu 项。
3. 重新添加 `/Applications/VoiceRelayMenu.app`。
4. 退出并重新打开菜单栏 App。

## 安卓添加到桌面

1. 用安卓 Chrome 打开你配置的公网地址，例如 `https://your-domain.example/`。
2. 点右上角三个点菜单。
3. 选择“安装应用”或“添加到主屏幕”。不同 Chrome 版本的菜单文字可能不同。
4. 点“安装”或“添加”确认。

安装后从桌面图标打开即可。第一次打开需要输入认证密码，之后长期保持登录。

如果手机端已经安装过旧版 PWA，重新打开后仍看不到“发送”按钮，可以在 Chrome 中刷新页面，或清除该站点数据后重新登录。

## Cloudflare Tunnel

本项目默认本地服务地址是 `http://127.0.0.1:5454`。如果要公网访问，请把 Cloudflare Tunnel 映射到本地端口 `5454`，再用 `PUBLIC_URL` 指定你的公网地址。

## 安全说明

公网入口默认需要认证。不要把认证密码发给不可信的人。

## License

MIT
