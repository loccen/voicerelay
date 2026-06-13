# VoiceRelay

VoiceRelay 是一个轻量的跨设备输入工具：在手机上输入或语音输入文字，然后实时同步到 Mac 当前聚焦的文本框。

它最初是为一个很具体的场景做的：Mac 放在家里或远端，通过远程桌面、浏览器远控、云电脑工具连接时，远程工具往往不能稳定转发麦克风，导致 Mac 端没法直接使用语音输入。相比折腾远程音频输入，把手机当作输入端会更简单：手机天然有麦克风、有熟悉的输入法，也更适合语音输入。

VoiceRelay 只做一件事：让手机输入框里的内容同步到 Mac 当前输入焦点。它不是完整输入法，也不做剪贴板管理、文件传输、设备协同套件这些重功能。目标是轻、直接、打开就能用。

## 适合什么场景

- Mac 在家里、办公室或其他远端位置，你正在远程连接它
- 远程控制工具不能使用本地麦克风，无法在 Mac 上直接语音输入
- 想用手机输入法或手机语音输入来给 Mac 当前应用输入文字
- 只需要一个轻量输入桥，不想安装复杂的跨屏输入法或设备协同工具
- 需要通过公网访问输入页面，比如 Cloudflare Tunnel、自有域名或内网穿透

## 功能

- 手机网页输入，Mac 当前焦点文本框实时同步
- 支持实时模式和发送模式
- 支持全文同步，手机端修改内容后 Mac 端跟随更新
- 支持多行文本发送
- 点击发送后，先写入当前文本，再触发一次 Enter
- 发送成功后自动清空手机端输入框
- 手机端保留本地发送历史，点击历史项可回填输入框
- 手机端显示本次输入统计和历史累计统计，并估算节省时间
- 手机端是 PWA，可添加到 Android / iOS 主屏幕
- macOS 菜单栏 App 可控制本地服务和 Cloudflare Tunnel
- 公网入口带本地认证密码保护

## 平台支持

Mac 端：

- macOS
- Node.js 18+
- Swift 编译工具链
- 需要开启“辅助功能”权限

手机端：

- Android Chrome / Edge 等现代浏览器
- iPhone / iPad Safari
- 其他支持现代 Web 能力的移动浏览器

## 工作方式

VoiceRelay 由三部分组成：

1. 手机端 PWA 页面  
   用于输入文本、语音输入、点击发送。

2. Mac 本地服务  
   默认监听 `127.0.0.1:5454`，接收手机端同步请求。

3. macOS 辅助写入器  
   通过 macOS Accessibility API 写入当前焦点文本框。

如果需要公网访问，可以使用 Cloudflare Tunnel 或其他内网穿透工具，把公网域名映射到本地 `5454` 端口。

## 快速开始

克隆项目：

```bash
git clone https://github.com/loccen/voicerelay.git
cd voicerelay
```

构建并安装菜单栏 App：

```bash
npm run menu:install
```

安装后打开 `/Applications/VoiceRelayMenu.app`，在菜单栏里开启：

- 跨屏输入服务
- Cloudflare 隧道

如果暂时不需要公网访问，只在本机调试，可以只启动跨屏输入服务，然后访问：

```text
http://127.0.0.1:5454/
```

## 配置公网地址

VoiceRelay 本地服务默认地址是：

```text
http://127.0.0.1:5454
```

使用 Cloudflare Tunnel 时，把你的公网域名映射到这个本地地址。示例 ingress 目标：

```yaml
service: http://127.0.0.1:5454
```

构建菜单栏 App 时，可以把公网地址和 Cloudflare 配置路径写入 App：

```bash
PUBLIC_URL=https://your-domain.example/ \
CLOUDFLARED_CONFIG="$HOME/.cloudflared/config.yml" \
npm run menu:install
```

之后菜单栏里的“打开手机端页面”会打开 `PUBLIC_URL`，Cloudflare 隧道开关会使用指定的配置文件。

## macOS 权限

首次使用需要授权辅助功能权限：

1. 打开系统设置
2. 进入“隐私与安全性”
3. 打开“辅助功能”
4. 添加并允许 `/Applications/VoiceRelayMenu.app`
5. 重新启动菜单栏 App 或重新开启跨屏输入服务

没有这个权限时，VoiceRelay 无法写入当前焦点输入框。

## 手机端使用

打开你配置的公网地址，例如：

```text
https://your-domain.example/
```

第一次打开时输入认证密码。登录后即可使用手机输入法或系统语音输入。

手机端有两个输入模式：

- 实时模式：输入内容会实时同步到 Mac 当前焦点文本框，适合浏览器、聊天软件、普通 GUI 输入框。
- 发送模式：输入内容只留在手机页面里，不会实时写入 Mac；点击“发送”后才粘贴到 Mac 当前焦点并触发 Enter，适合终端、TUI、Codex CLI、VSCode Terminal、Termius 等场景。

点击“发送”时，VoiceRelay 会：

1. 把手机端当前文本写入 Mac 当前焦点位置
2. 触发一次 Enter
3. 如果发送成功，记录累计字数并清空手机端输入框

点击发送时，当前文本会先保存到手机端发送历史。即使后续因为焦点、权限或目标应用行为导致 Mac 端没有收到内容，也可以从发送按钮下方的历史列表点回输入框。

手机端会显示两组统计：

- 本次输入：当前字数和活动输入耗时。输入暂停时停止计时，恢复输入后继续累计
- 历史累计：累计发送字数和估算节省时间

节省时间默认按 `60 字/分钟` 的普通中文手打速度估算，并扣除手机端本次实际输入耗时。你可以在菜单栏 App 里修改自己的打字速度，也可以打开菜单里的“打字速度测试”去 `https://dazi.kukuw.com/` 测试后回填。

历史和统计会同时保存在手机浏览器本地和 Mac 本地服务的 `.voicerelay-data.json` 中，所以清除手机缓存后仍可从服务端恢复。菜单栏 App 也会显示本次输入和历史累计统计。

## 添加到主屏幕

Android Chrome：

1. 打开 VoiceRelay 页面
2. 点击右上角菜单
3. 选择“安装应用”或“添加到主屏幕”

iPhone / iPad Safari：

1. 打开 VoiceRelay 页面
2. 点击分享按钮
3. 选择“添加到主屏幕”

安装后可以像普通 App 一样从桌面图标打开。

## 认证

VoiceRelay 会在本地生成认证密码。公网入口必须登录后才能写入 Mac。

重置认证密码：

```bash
npm run auth:reset
```

清除所有手机登录态：

```bash
npm run auth:clear
```

查看认证文件路径：

```bash
npm run auth:path
```

认证文件、日志和构建产物默认不会被提交到 Git。

## 开发

前台启动服务：

```bash
npm start
```

构建辅助写入器：

```bash
npm run build:helper
```

构建菜单栏 App：

```bash
npm run build:menu
```

旧的 LaunchAgent 后台模式仍可用于调试；日常使用不建议和菜单栏 App 同时开启：

```bash
npm run daemon:install
```

停止并移除后台服务：

```bash
npm run daemon:uninstall
```

## 常见问题

### 手机页面红框是什么意思？

红框表示最近一次同步或发送失败。常见原因包括：Mac 本地服务没有启动、Cloudflare Tunnel 没有启动、手机登录状态失效、辅助功能权限未生效，或 Mac 当前焦点不是可编辑文本框。

### 终端或 TUI 里应该用哪个模式？

使用发送模式。终端和 TUI 通常不会把当前输入缓冲区作为标准文本框暴露给 macOS，所以实时全文同步不一定可靠。发送模式只在点击“发送”时通过粘贴写入当前焦点，更适合这类应用。

### 为什么需要辅助功能权限？

VoiceRelay 需要把文字写入 Mac 当前聚焦的文本框。这个动作需要通过 macOS Accessibility API 完成，因此系统会要求授权。

### 会上传我的输入内容吗？

VoiceRelay 默认只在你的手机浏览器、你的公网入口和 Mac 本地服务之间传递输入内容。项目本身不接入第三方文本服务。公网使用时，请保护好认证密码和隧道入口。

## License

MIT
