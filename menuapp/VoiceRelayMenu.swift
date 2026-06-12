import AppKit
import Foundation

final class BlueSwitch: NSButton {
  private var renderedIsOn = false

  init() {
    super.init(frame: NSRect(x: 0, y: 0, width: 54, height: 30))
    setButtonType(.toggle)
    title = ""
    isBordered = false
    wantsLayer = true
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: 54, height: 30)
  }

  func setOn(_ isOn: Bool) {
    renderedIsOn = isOn
    state = isOn ? .on : .off
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    renderedIsOn = state == .on
    let track = bounds.insetBy(dx: 2, dy: 3)
    let radius = track.height / 2
    let trackPath = NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius)
    let offTrack = NSColor(calibratedWhite: 0.84, alpha: 1)
    let offBorder = NSColor(calibratedWhite: 0.72, alpha: 1)
    (renderedIsOn ? NSColor.systemBlue : offTrack).setFill()
    trackPath.fill()

    if !renderedIsOn {
      offBorder.setStroke()
      trackPath.lineWidth = 1
      trackPath.stroke()
    }

    let knobSize = track.height - 4
    let knobX = renderedIsOn ? track.maxX - knobSize - 2 : track.minX + 2
    let knobRect = NSRect(x: knobX, y: track.minY + 2, width: knobSize, height: knobSize)
    if !renderedIsOn {
      NSColor(calibratedWhite: 0.66, alpha: 0.22).setFill()
      NSBezierPath(ovalIn: knobRect.offsetBy(dx: 0, dy: -1)).fill()
    }
    NSColor.white.setFill()
    NSBezierPath(ovalIn: knobRect).fill()
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let menu = NSMenu()
  private var serviceProcess: Process?
  private var tunnelProcess: Process?
  private var refreshTimer: Timer?

  private let root = AppDelegate.infoString("VoiceRelayProjectRoot", fallback: FileManager.default.currentDirectoryPath)
  private let node = AppDelegate.infoString("VoiceRelayNodePath", fallback: "/usr/bin/env")
  private let cloudflared = AppDelegate.infoString("VoiceRelayCloudflaredPath", fallback: "/usr/bin/env")
  private let cloudflaredConfig = AppDelegate.infoString(
    "VoiceRelayCloudflaredConfig",
    fallback: "\(NSHomeDirectory())/.cloudflared/config.yml"
  )
  private let publicURL = AppDelegate.infoString("VoiceRelayPublicURL", fallback: "http://127.0.0.1:5454/")
  private let launchAgentLabel = "com.loccen.voicerelay.menu"

  private var serviceItem = NSMenuItem()
  private var tunnelItem = NSMenuItem()
  private var autoLaunchItem = NSMenuItem()
  private var autoServiceItem = NSMenuItem()
  private var autoTunnelItem = NSMenuItem()
  private var statusItemText = NSMenuItem()
  private var serviceSwitch = BlueSwitch()
  private var tunnelSwitch = BlueSwitch()
  private var autoLaunchSwitch = BlueSwitch()
  private var autoServiceSwitch = BlueSwitch()
  private var autoTunnelSwitch = BlueSwitch()

  func applicationDidFinishLaunching(_ notification: Notification) {
    configureStatusItem()
    buildMenu()
    loadAutoStarts()
    refreshState()

    refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      self?.refreshState()
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    stopProcess(&serviceProcess)
    stopProcess(&tunnelProcess)
  }

  private func configureStatusItem() {
    if let button = statusItem.button {
      let image = NSImage(named: "StatusIconTemplate") ?? NSImage(systemSymbolName: "keyboard", accessibilityDescription: "跨屏输入")
      image?.isTemplate = true
      image?.size = NSSize(width: 18, height: 18)
      button.image = image
    }
    statusItem.menu = menu
  }

  private func buildMenu() {
    statusItemText = NSMenuItem(title: "状态：未启动", action: nil, keyEquivalent: "")
    menu.addItem(statusItemText)
    menu.addItem(.separator())

    serviceItem = makeSwitchItem(title: "跨屏输入服务", switchControl: serviceSwitch, action: #selector(toggleService))
    menu.addItem(serviceItem)

    tunnelItem = makeSwitchItem(title: "Cloudflare 隧道", switchControl: tunnelSwitch, action: #selector(toggleTunnel))
    menu.addItem(tunnelItem)

    menu.addItem(.separator())

    let openPageItem = NSMenuItem(title: "打开手机端页面", action: #selector(openPage), keyEquivalent: "")
    openPageItem.target = self
    menu.addItem(openPageItem)

    let copyPasswordItem = NSMenuItem(title: "复制认证密码", action: #selector(copyPassword), keyEquivalent: "")
    copyPasswordItem.target = self
    menu.addItem(copyPasswordItem)

    let resetPasswordItem = NSMenuItem(title: "重置认证密码", action: #selector(resetPassword), keyEquivalent: "")
    resetPasswordItem.target = self
    menu.addItem(resetPasswordItem)

    let clearSessionsItem = NSMenuItem(title: "清除手机登录态", action: #selector(clearSessions), keyEquivalent: "")
    clearSessionsItem.target = self
    menu.addItem(clearSessionsItem)

    let accessibilityItem = NSMenuItem(title: "打开辅助功能权限设置", action: #selector(openAccessibilitySettings), keyEquivalent: "")
    accessibilityItem.target = self
    menu.addItem(accessibilityItem)

    menu.addItem(.separator())

    autoLaunchItem = makeSwitchItem(title: "开机自启菜单栏 App", switchControl: autoLaunchSwitch, action: #selector(toggleAutoLaunch))
    menu.addItem(autoLaunchItem)

    autoServiceItem = makeSwitchItem(title: "App 启动时开启跨屏输入服务", switchControl: autoServiceSwitch, action: #selector(toggleAutoService))
    menu.addItem(autoServiceItem)

    autoTunnelItem = makeSwitchItem(title: "App 启动时开启 Cloudflare 隧道", switchControl: autoTunnelSwitch, action: #selector(toggleAutoTunnel))
    menu.addItem(autoTunnelItem)

    menu.addItem(.separator())

    let logItem = NSMenuItem(title: "打开日志目录", action: #selector(openLogs), keyEquivalent: "")
    logItem.target = self
    menu.addItem(logItem)

    let cleanupItem = NSMenuItem(title: "清理残留服务进程", action: #selector(cleanupOrphans), keyEquivalent: "")
    cleanupItem.target = self
    menu.addItem(cleanupItem)

    let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
    quitItem.target = self
    menu.addItem(quitItem)
  }

  private func loadAutoStarts() {
    if defaultsBool("autoService") || CommandLine.arguments.contains("--start-service") {
      startService()
    }
    if defaultsBool("autoTunnel") || CommandLine.arguments.contains("--start-tunnel") {
      startTunnel()
    }
  }

  private func makeSwitchItem(title: String, switchControl: BlueSwitch, action: Selector) -> NSMenuItem {
    let item = NSMenuItem()
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 34))

    let label = NSTextField(labelWithString: title)
    label.font = NSFont.menuFont(ofSize: 0)
    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = false

    switchControl.target = self
    switchControl.action = action
    switchControl.translatesAutoresizingMaskIntoConstraints = false

    view.addSubview(label)
    view.addSubview(switchControl)

    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
      label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      label.trailingAnchor.constraint(lessThanOrEqualTo: switchControl.leadingAnchor, constant: -12),

      switchControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
      switchControl.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])

    item.view = view
    return item
  }

  @objc private func toggleService() {
    isRunning(serviceProcess) ? stopProcess(&serviceProcess) : startService()
    refreshState()
  }

  @objc private func toggleTunnel() {
    isRunning(tunnelProcess) ? stopProcess(&tunnelProcess) : startTunnel()
    refreshState()
  }

  @objc private func openPage() {
    guard let url = URL(string: publicURL) else {
      notify("手机端页面地址无效：\(publicURL)")
      return
    }
    NSWorkspace.shared.open(url)
  }

  @objc private func copyPassword() {
    do {
      let password = try currentPassword()
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(password, forType: .string)
      notify("认证密码已复制")
    } catch {
      notify("复制失败：\(error.localizedDescription)")
    }
  }

  @objc private func resetPassword() {
    do {
      let output = try runCommand(node, args: nodeArguments(["scripts/auth.js", "reset"]), cwd: root)
      let password = output
        .split(separator: "\n")
        .last { $0.contains("新认证密码:") }?
        .replacingOccurrences(of: "新认证密码: ", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)

      if let password, !password.isEmpty {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(password, forType: .string)
        notify("新认证密码已复制")
      } else {
        notify("认证密码已重置")
      }
    } catch {
      notify("重置失败：\(error.localizedDescription)")
    }
  }

  @objc private func clearSessions() {
    do {
      _ = try runCommand(node, args: nodeArguments(["scripts/auth.js", "clear"]), cwd: root)
      notify("已清除手机登录态")
    } catch {
      notify("清除失败：\(error.localizedDescription)")
    }
  }

  @objc private func openAccessibilitySettings() {
    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    NSWorkspace.shared.open(url)
  }

  @objc private func toggleAutoLaunch() {
    if isAutoLaunchEnabled() {
      disableAutoLaunch()
    } else {
      enableAutoLaunch()
    }
    refreshState()
  }

  @objc private func toggleAutoService() {
    setDefaultsBool("autoService", !defaultsBool("autoService"))
    refreshState()
  }

  @objc private func toggleAutoTunnel() {
    setDefaultsBool("autoTunnel", !defaultsBool("autoTunnel"))
    refreshState()
  }

  @objc private func openLogs() {
    NSWorkspace.shared.open(URL(fileURLWithPath: root))
  }

  @objc private func cleanupOrphans() {
    cleanupExternalProcesses()
    notify("已清理残留服务进程")
    refreshState()
  }

  @objc private func quit() {
    NSApplication.shared.terminate(nil)
  }

  private func startService() {
    guard !isRunning(serviceProcess) else { return }
    if !AXIsProcessTrusted() {
      notify("VoiceRelay 菜单栏 App 的“辅助功能”权限未生效。若系统设置里已经开启，请先移除旧的 VoiceRelayMenu 项，再重新添加当前 dist/VoiceRelayMenu.app，然后重新开启跨屏输入服务。")
      openAccessibilitySettings()
      return
    }
    cleanupExternalServiceProcesses()
    serviceProcess = makeProcess(
      executable: node,
      arguments: nodeArguments(["src/server.js"]),
      stdout: "\(root)/.voicerelay.log",
      stderr: "\(root)/.voicerelay.err.log"
    )
    launch(&serviceProcess, name: "跨屏输入服务")
  }

  private func startTunnel() {
    guard !isRunning(tunnelProcess) else { return }
    cleanupExternalTunnelProcesses()
    tunnelProcess = makeProcess(
      executable: cloudflared,
      arguments: cloudflaredArguments(),
      stdout: "\(root)/.cloudflared-voicerelay.log",
      stderr: "\(root)/.cloudflared-voicerelay.err.log"
    )
    launch(&tunnelProcess, name: "Cloudflare 隧道")
  }

  private func makeProcess(executable: String, arguments: [String], stdout: String, stderr: String) -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: root)
    var environment = ProcessInfo.processInfo.environment
    environment["MAC_INPUT_WRITER_PATH"] = "\(appBundlePath())/Contents/MacOS/mac-input-writer"
    process.environment = environment

    FileManager.default.createFile(atPath: stdout, contents: nil)
    FileManager.default.createFile(atPath: stderr, contents: nil)
    process.standardOutput = try? FileHandle(forWritingTo: URL(fileURLWithPath: stdout))
    process.standardError = try? FileHandle(forWritingTo: URL(fileURLWithPath: stderr))

    return process
  }

  private func launch(_ process: inout Process?, name: String) {
    do {
      try process?.run()
    } catch {
      notify("\(name)启动失败：\(error.localizedDescription)")
      process = nil
    }
  }

  private func stopProcess(_ process: inout Process?) {
    guard let running = process else { return }
    if running.isRunning {
      running.terminate()
      DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
        if running.isRunning {
          running.interrupt()
        }
      }
    }
    process = nil
  }

  private func isRunning(_ process: Process?) -> Bool {
    return process?.isRunning == true
  }

  private func refreshState() {
    let serviceRunning = isRunning(serviceProcess)
    let tunnelRunning = isRunning(tunnelProcess)

    serviceItem.title = "跨屏输入服务"
    tunnelItem.title = "Cloudflare 隧道"
    serviceSwitch.setOn(serviceRunning)
    tunnelSwitch.setOn(tunnelRunning)

    autoLaunchSwitch.setOn(isAutoLaunchEnabled())
    autoServiceSwitch.setOn(defaultsBool("autoService"))
    autoTunnelSwitch.setOn(defaultsBool("autoTunnel"))

    let serviceText = serviceRunning ? "服务开" : "服务关"
    let tunnelText = tunnelRunning ? "隧道开" : "隧道关"
    statusItemText.title = "状态：\(serviceText)，\(tunnelText)"

    statusItem.button?.contentTintColor = nil
  }

  private func cleanupExternalProcesses() {
    let currentPID = ProcessInfo.processInfo.processIdentifier
    let shell = """
    pgrep -f 'node src/server.js' | while read pid; do
      [ "$pid" = "\(currentPID)" ] || kill "$pid" 2>/dev/null || true
    done
    pgrep -f \(shellSingleQuoted("cloudflared tunnel --config \(cloudflaredConfig) run")) | while read pid; do
      kill "$pid" 2>/dev/null || true
    done
    """
    _ = try? runCommand("/bin/zsh", args: ["-c", shell], cwd: root)
  }

  private func cleanupExternalServiceProcesses() {
    let shell = """
    pgrep -f 'node src/server.js' | while read pid; do
      kill "$pid" 2>/dev/null || true
    done
    """
    _ = try? runCommand("/bin/zsh", args: ["-c", shell], cwd: root)
  }

  private func cleanupExternalTunnelProcesses() {
    let shell = """
    pgrep -f \(shellSingleQuoted("cloudflared tunnel --config \(cloudflaredConfig) run")) | while read pid; do
      kill "$pid" 2>/dev/null || true
    done
    """
    _ = try? runCommand("/bin/zsh", args: ["-c", shell], cwd: root)
  }

  private func currentPassword() throws -> String {
    let log = try String(contentsOfFile: "\(root)/.voicerelay.log", encoding: .utf8)
    let lines = log.components(separatedBy: .newlines).reversed()
    for line in lines {
      if line.hasPrefix("新认证密码: ") {
        return String(line.dropFirst("新认证密码: ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
      }
      if line.hasPrefix("首次认证密码: ") {
        return String(line.dropFirst("首次认证密码: ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
    throw NSError(domain: "VoiceRelayMenu", code: 1, userInfo: [NSLocalizedDescriptionKey: "日志中没有认证密码，请先重置认证密码"])
  }

  private func runCommand(_ executable: String, args: [String], cwd: String) throws -> String {
    let process = Process()
    let pipe = Pipe()
    let errorPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = args
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)
    process.standardOutput = pipe
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()

    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let errors = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if process.terminationStatus != 0 {
      throw NSError(domain: "VoiceRelayMenu", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errors.isEmpty ? output : errors])
    }
    return output
  }

  private func enableAutoLaunch() {
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>\(launchAgentLabel)</string>
      <key>ProgramArguments</key>
      <array>
        <string>\(appBundlePath())/Contents/MacOS/VoiceRelayMenu</string>
      </array>
      <key>RunAtLoad</key>
      <true/>
      <key>StandardOutPath</key>
      <string>\(root)/.voicerelay-menu.log</string>
      <key>StandardErrorPath</key>
      <string>\(root)/.voicerelay-menu.err.log</string>
    </dict>
    </plist>
    """

    do {
      let launchAgents = "\(NSHomeDirectory())/Library/LaunchAgents"
      try FileManager.default.createDirectory(atPath: launchAgents, withIntermediateDirectories: true)
      let path = "\(launchAgents)/\(launchAgentLabel).plist"
      try plist.write(toFile: path, atomically: true, encoding: .utf8)
      _ = try? runCommand("/bin/launchctl", args: ["bootout", "gui/\(getuid())/\(launchAgentLabel)"], cwd: root)
      _ = try runCommand("/bin/launchctl", args: ["bootstrap", "gui/\(getuid())", path], cwd: root)
      notify("已开启开机自启")
    } catch {
      notify("设置开机自启失败：\(error.localizedDescription)")
    }
  }

  private func disableAutoLaunch() {
    let path = "\(NSHomeDirectory())/Library/LaunchAgents/\(launchAgentLabel).plist"
    _ = try? runCommand("/bin/launchctl", args: ["bootout", "gui/\(getuid())/\(launchAgentLabel)"], cwd: root)
    try? FileManager.default.removeItem(atPath: path)
    notify("已关闭开机自启")
  }

  private func isAutoLaunchEnabled() -> Bool {
    return FileManager.default.fileExists(atPath: "\(NSHomeDirectory())/Library/LaunchAgents/\(launchAgentLabel).plist")
  }

  private func appBundlePath() -> String {
    return Bundle.main.bundlePath
  }

  private func cloudflaredArguments() -> [String] {
    if cloudflared == "/usr/bin/env" {
      return ["cloudflared", "tunnel", "--config", cloudflaredConfig, "run"]
    }
    return ["tunnel", "--config", cloudflaredConfig, "run"]
  }

  private func nodeArguments(_ arguments: [String]) -> [String] {
    if node == "/usr/bin/env" {
      return ["node"] + arguments
    }
    return arguments
  }

  private func shellSingleQuoted(_ value: String) -> String {
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private static func infoString(_ key: String, fallback: String) -> String {
    let value = Bundle.main.object(forInfoDictionaryKey: key) as? String
    return value?.isEmpty == false ? value! : fallback
  }

  private func defaultsBool(_ key: String) -> Bool {
    return UserDefaults.standard.bool(forKey: key)
  }

  private func setDefaultsBool(_ key: String, _ value: Bool) {
    UserDefaults.standard.set(value, forKey: key)
  }

  private func notify(_ message: String) {
    let alert = NSAlert()
    alert.messageText = message
    alert.addButton(withTitle: "好")
    alert.runModal()
  }
}
