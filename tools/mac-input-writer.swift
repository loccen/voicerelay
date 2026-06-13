import AppKit
import ApplicationServices
import Foundation

enum WriterError: Error, CustomStringConvertible {
  case accessibilityNotTrusted
  case missingFrontmostApp
  case missingFocusedElement(String)
  case unsupportedRole(String)
  case selectedRangeFailed(AXError)
  case missingPasteMenuItem(String)
  case pasteMenuPressFailed(AXError)
  case pasteFailed

  var description: String {
    switch self {
    case .accessibilityNotTrusted:
      return "当前进程没有辅助功能权限"
    case .missingFrontmostApp:
      return "没有找到前台应用"
    case .missingFocusedElement(let appName):
      return "没有找到当前焦点元素，前台应用: \(appName)"
    case .unsupportedRole(let role):
      return "当前焦点不是可编辑文本框: \(role)"
    case .selectedRangeFailed(let error):
      return "设置文本选区失败: \(error.rawValue)"
    case .missingPasteMenuItem(let appName):
      return "没有找到 \(appName) 的 Paste/粘贴 菜单项"
    case .pasteMenuPressFailed(let error):
      return "点击 Paste/粘贴 菜单项失败: \(error.rawValue)"
    case .pasteFailed:
      return "发送粘贴事件失败"
    }
  }
}

struct FocusContext {
  let app: NSRunningApplication
  let appElement: AXUIElement
  let focusedElement: AXUIElement?
}

func readStdin() -> String {
  let data = FileHandle.standardInput.readDataToEndOfFile()
  return String(data: data, encoding: .utf8) ?? ""
}

func isDiagnoseMode() -> Bool {
  return CommandLine.arguments.contains("--diagnose")
}

func mode(_ name: String) -> Bool {
  return CommandLine.arguments.contains(name)
}

func isDaemonMode() -> Bool {
  return mode("--daemon")
}

enum DaemonCommand {
  case sync(String)
  case paste(String)
  case insertPaste(String)
  case submit
}

func decodeDaemonCommand(_ line: String) -> DaemonCommand? {
  if line == "SUBMIT" {
    return .submit
  }

  if let payload = line.stripPrefix("PASTE "),
     let data = Data(base64Encoded: payload),
     let text = String(data: data, encoding: .utf8) {
    return .paste(text)
  }

  if let payload = line.stripPrefix("INSERT_PASTE "),
     let data = Data(base64Encoded: payload),
     let text = String(data: data, encoding: .utf8) {
    return .insertPaste(text)
  }

  if let data = Data(base64Encoded: line), let text = String(data: data, encoding: .utf8) {
    return .sync(text)
  }

  return nil
}

extension String {
  func stripPrefix(_ prefix: String) -> String? {
    guard hasPrefix(prefix) else { return nil }
    return String(dropFirst(prefix.count))
  }
}

func axStringAttribute(_ element: AXUIElement, _ name: String) -> String? {
  var value: CFTypeRef?
  let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
  guard error == .success else { return nil }
  return value as? String
}

func axAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
  var value: CFTypeRef?
  let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
  guard error == .success else { return nil }
  return value
}

func axChildren(_ element: AXUIElement) -> [AXUIElement] {
  guard let value = axAttribute(element, kAXChildrenAttribute) else { return [] }
  return (value as? [AXUIElement]) ?? []
}

func axTitle(_ element: AXUIElement) -> String {
  return axStringAttribute(element, kAXTitleAttribute) ?? ""
}

func axBoolAttribute(_ element: AXUIElement, _ name: String) -> Bool? {
  guard let value = axAttribute(element, name) else { return nil }
  return value as? Bool
}

func axFrame(_ element: AXUIElement) -> CGRect {
  guard let positionRef = axAttribute(element, kAXPositionAttribute),
        let sizeRef = axAttribute(element, kAXSizeAttribute) else {
    return .zero
  }

  var position = CGPoint.zero
  var size = CGSize.zero
  AXValueGetValue(positionRef as! AXValue, .cgPoint, &position)
  AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
  return CGRect(origin: position, size: size)
}

func axAttributeNames(_ element: AXUIElement) -> [String] {
  var names: CFArray?
  let error = AXUIElementCopyAttributeNames(element, &names)
  guard error == .success else { return [] }
  return (names as? [String]) ?? []
}

func axActionNames(_ element: AXUIElement) -> [String] {
  var names: CFArray?
  let error = AXUIElementCopyActionNames(element, &names)
  guard error == .success else { return [] }
  return (names as? [String]) ?? []
}

func axParameterizedAttributeNames(_ element: AXUIElement) -> [String] {
  var names: CFArray?
  let error = AXUIElementCopyParameterizedAttributeNames(element, &names)
  guard error == .success else { return [] }
  return (names as? [String]) ?? []
}

func axAttributeSettable(_ element: AXUIElement, _ name: String) -> String {
  var settable = DarwinBoolean(false)
  let error = AXUIElementIsAttributeSettable(element, name as CFString, &settable)
  return "\(error.rawValue):\(settable.boolValue)"
}

func editableCandidates(in element: AXUIElement, depth: Int = 0, maxDepth: Int = 16, results: inout [AXUIElement]) {
  if depth > maxDepth { return }

  let role = axStringAttribute(element, kAXRoleAttribute) ?? ""
  if ["AXTextField", "AXTextArea", "AXComboBox"].contains(role) {
    var settable = DarwinBoolean(false)
    let error = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
    if error == .success, settable.boolValue {
      results.append(element)
    }
  }

  for child in axChildren(element) {
    editableCandidates(in: child, depth: depth + 1, maxDepth: maxDepth, results: &results)
  }
}

func fallbackFocusedElement(in appElement: AXUIElement) -> AXUIElement? {
  var candidates: [AXUIElement] = []
  editableCandidates(in: appElement, results: &candidates)

  if let focused = candidates.first(where: { axBoolAttribute($0, kAXFocusedAttribute) == true }) {
    return focused
  }

  return candidates.sorted {
    let left = axFrame($0)
    let right = axFrame($1)
    return left.maxY == right.maxY ? left.maxX > right.maxX : left.maxY > right.maxY
  }.first
}

func focusedContext() throws -> FocusContext {
  guard AXIsProcessTrusted() else {
    throw WriterError.accessibilityNotTrusted
  }

  guard let app = NSWorkspace.shared.frontmostApplication else {
    throw WriterError.missingFrontmostApp
  }

  let appElement = AXUIElementCreateApplication(app.processIdentifier)
  var focused: CFTypeRef?
  let systemElement = AXUIElementCreateSystemWide()
  var error = AXUIElementCopyAttributeValue(
    systemElement,
    kAXFocusedUIElementAttribute as CFString,
    &focused
  )

  if error != .success || focused == nil {
    error = AXUIElementCopyAttributeValue(
      appElement,
      kAXFocusedUIElementAttribute as CFString,
      &focused
    )
  }

  var element = (error == .success ? focused : nil) as! AXUIElement?
  if element == nil {
    element = fallbackFocusedElement(in: appElement)
  }
  if element == nil {
    fputs("frontmost=\(app.localizedName ?? "unknown") bundle=\(app.bundleIdentifier ?? "unknown") pid=\(app.processIdentifier)\n", stderr)
  }
  return FocusContext(app: app, appElement: appElement, focusedElement: element)
}

func selectAll(_ element: AXUIElement) throws {
  let role = axStringAttribute(element, kAXRoleAttribute) ?? "unknown"
  let editableRoles = ["AXTextField", "AXTextArea", "AXComboBox"]

  guard editableRoles.contains(role) else {
    throw WriterError.unsupportedRole(role)
  }

  let existingValue = axStringAttribute(element, kAXValueAttribute) ?? ""
  var range = CFRange(location: 0, length: existingValue.utf16.count)
  guard let rangeValue = AXValueCreate(.cfRange, &range) else {
    throw WriterError.selectedRangeFailed(.failure)
  }

  let error = AXUIElementSetAttributeValue(
    element,
    kAXSelectedTextRangeAttribute as CFString,
    rangeValue
  )

  guard error == .success else {
    throw WriterError.selectedRangeFailed(error)
  }
}

func replaceSelectedText(_ element: AXUIElement, with text: String) throws {
  let role = axStringAttribute(element, kAXRoleAttribute) ?? "unknown"
  let editableRoles = ["AXTextField", "AXTextArea", "AXComboBox"]

  guard editableRoles.contains(role) else {
    throw WriterError.unsupportedRole(role)
  }

  let existingValue = axStringAttribute(element, kAXValueAttribute) ?? ""
  var range = CFRange(location: 0, length: existingValue.utf16.count)
  guard let rangeValue = AXValueCreate(.cfRange, &range) else {
    throw WriterError.selectedRangeFailed(.failure)
  }

  let rangeError = AXUIElementSetAttributeValue(
    element,
    kAXSelectedTextRangeAttribute as CFString,
    rangeValue
  )
  guard rangeError == .success else {
    throw WriterError.selectedRangeFailed(rangeError)
  }

  let textError = AXUIElementSetAttributeValue(
    element,
    kAXSelectedTextAttribute as CFString,
    text as CFString
  )
  guard textError == .success else {
    throw WriterError.selectedRangeFailed(textError)
  }
}

func setAXValue(_ element: AXUIElement, to text: String) throws {
  let error = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
  guard error == .success else {
    throw WriterError.selectedRangeFailed(error)
  }
}

func replaceRangeWithText(_ element: AXUIElement, text: String) throws {
  let existingValue = axStringAttribute(element, kAXValueAttribute) ?? ""
  var range = CFRange(location: 0, length: existingValue.utf16.count)
  guard let rangeValue = AXValueCreate(.cfRange, &range) else {
    throw WriterError.selectedRangeFailed(.failure)
  }

  let payload = [
    "range": rangeValue,
    "text": text as CFString,
  ] as CFDictionary

  var result: CFTypeRef?
  let error = AXUIElementCopyParameterizedAttributeValue(
    element,
    "AXReplaceRangeWithText" as CFString,
    payload,
    &result
  )

  guard error == .success else {
    throw WriterError.selectedRangeFailed(error)
  }
}

func replaceClipboard(with text: String) -> [NSPasteboard.PasteboardType: Data] {
  let pasteboard = NSPasteboard.general
  var previous: [NSPasteboard.PasteboardType: Data] = [:]

  for type in pasteboard.types ?? [] {
    if let data = pasteboard.data(forType: type) {
      previous[type] = data
    }
  }

  pasteboard.clearContents()
  pasteboard.setString(text, forType: .string)
  return previous
}

func restoreClipboard(_ previous: [NSPasteboard.PasteboardType: Data]) {
  let pasteboard = NSPasteboard.general
  pasteboard.clearContents()

  for (type, data) in previous {
    pasteboard.setData(data, forType: type)
  }
}

func paste() throws {
  let source = CGEventSource(stateID: .hidSystemState)
  let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)

  guard let keyDown, let keyUp else {
    throw WriterError.pasteFailed
  }

  keyDown.flags = .maskCommand
  keyUp.flags = .maskCommand
  keyDown.post(tap: .cghidEventTap)
  keyUp.post(tap: .cghidEventTap)
}

func replaceAllWithAccessibilitySelectionAndClipboard(_ element: AXUIElement, text: String) throws {
  let previousClipboard = replaceClipboard(with: text)
  do {
    try selectAll(element)
    Thread.sleep(forTimeInterval: 0.06)
    try paste()
    Thread.sleep(forTimeInterval: 0.12)
    restoreClipboard(previousClipboard)
  } catch {
    restoreClipboard(previousClipboard)
    throw error
  }
}

func pasteTextAtCursor(_ text: String) throws {
  let previousClipboard = replaceClipboard(with: text)
  do {
    try paste()
    Thread.sleep(forTimeInterval: 0.12)
    restoreClipboard(previousClipboard)
  } catch {
    restoreClipboard(previousClipboard)
    throw error
  }
}

func pressEnter() throws {
  let source = CGEventSource(stateID: .hidSystemState)
  let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true)
  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)

  guard let keyDown, let keyUp else {
    throw WriterError.pasteFailed
  }

  keyDown.post(tap: .cghidEventTap)
  keyUp.post(tap: .cghidEventTap)
}

func findMenuItem(in element: AXUIElement, titles: Set<String>, maxDepth: Int = 8) -> AXUIElement? {
  if maxDepth < 0 { return nil }

  let title = axTitle(element)
  if titles.contains(title) {
    return element
  }

  for child in axChildren(element) {
    if let found = findMenuItem(in: child, titles: titles, maxDepth: maxDepth - 1) {
      return found
    }
  }

  return nil
}

func menuItem(in context: FocusContext, titles: Set<String>) throws -> AXUIElement {
  let appName = context.app.localizedName ?? "前台应用"
  guard let menuBarRef = axAttribute(context.appElement, kAXMenuBarAttribute) else {
    throw WriterError.missingPasteMenuItem(appName)
  }

  let menuBar = (menuBarRef as! AXUIElement)
  let editTitles: Set<String> = ["Edit", "编辑"]

  guard let editMenu = findMenuItem(in: menuBar, titles: editTitles) else {
    throw WriterError.missingPasteMenuItem(appName)
  }

  _ = AXUIElementPerformAction(editMenu, kAXPressAction as CFString)
  Thread.sleep(forTimeInterval: 0.06)

  guard let item = findMenuItem(in: editMenu, titles: titles) ?? findMenuItem(in: menuBar, titles: titles) else {
    throw WriterError.missingPasteMenuItem(appName)
  }

  return item
}

func pressMenuItem(in context: FocusContext, titles: Set<String>) throws {
  let item = try menuItem(in: context, titles: titles)
  let error = AXUIElementPerformAction(item, kAXPressAction as CFString)
  guard error == .success else {
    throw WriterError.pasteMenuPressFailed(error)
  }
}

do {
  if isDaemonMode() {
    var lastFocused: AXUIElement?

    while let line = readLine() {
      guard let command = decodeDaemonCommand(line) else {
        print("ERR invalid-command")
        fflush(stdout)
        continue
      }

      do {
        switch command {
        case .sync(let text):
          let context = try focusedContext()
          if let focused = context.focusedElement {
            lastFocused = focused
          }

          guard let target = lastFocused else {
            throw WriterError.missingFocusedElement(context.app.localizedName ?? "unknown")
          }

          do {
            try setAXValue(target, to: text)
          } catch {
            let refreshed = try focusedContext()
            guard let freshTarget = refreshed.focusedElement else {
              lastFocused = nil
              throw error
            }
            lastFocused = freshTarget
            try setAXValue(freshTarget, to: text)
          }
        case .paste(let text):
          let context = try focusedContext()
          if let focused = context.focusedElement {
            lastFocused = focused
          }

          guard let target = lastFocused else {
            throw WriterError.missingFocusedElement(context.app.localizedName ?? "unknown")
          }

          do {
            try replaceAllWithAccessibilitySelectionAndClipboard(target, text: text)
          } catch {
            let refreshed = try focusedContext()
            guard let freshTarget = refreshed.focusedElement else {
              lastFocused = nil
              throw error
            }
            lastFocused = freshTarget
            try replaceAllWithAccessibilitySelectionAndClipboard(freshTarget, text: text)
          }
        case .insertPaste(let text):
          try pasteTextAtCursor(text)
        case .submit:
          try pressEnter()
        }
        print("OK")
        fflush(stdout)
      } catch {
        print("ERR \(error)")
        fflush(stdout)
      }
    }

    exit(0)
  }

  let context = try focusedContext()
  if isDiagnoseMode() {
    let role = context.focusedElement.flatMap { axStringAttribute($0, kAXRoleAttribute) } ?? "missing"
    let value = context.focusedElement.flatMap { axStringAttribute($0, kAXValueAttribute) } ?? ""
    let menuBar = axAttribute(context.appElement, kAXMenuBarAttribute).map { $0 as! AXUIElement }
    let editMenu = menuBar.flatMap { findMenuItem(in: $0, titles: ["Edit", "编辑"]) }
    let pasteItem = editMenu.flatMap { findMenuItem(in: $0, titles: ["Paste", "粘贴"]) }
    let selectAllItem = editMenu.flatMap { findMenuItem(in: $0, titles: ["Select All", "全选"]) }
    print("app=\(context.app.localizedName ?? "unknown")")
    print("bundleIdentifier=\(context.app.bundleIdentifier ?? "unknown")")
    print("focusedRole=\(role)")
    print("focusedValueLength=\(value.utf16.count)")
    print("hasEditMenu=\(editMenu != nil)")
    print("hasSelectAllItem=\(selectAllItem != nil)")
    print("hasPasteItem=\(pasteItem != nil)")
    if let focused = context.focusedElement {
      let attrs = axAttributeNames(focused).sorted().joined(separator: ",")
      let actions = axActionNames(focused).sorted().joined(separator: ",")
      let paramAttrs = axParameterizedAttributeNames(focused).sorted().joined(separator: ",")
      print("attrs=\(attrs)")
      print("actions=\(actions)")
      print("paramAttrs=\(paramAttrs)")
      for attr in [
        kAXValueAttribute,
        kAXSelectedTextAttribute,
        kAXSelectedTextRangeAttribute,
        kAXVisibleCharacterRangeAttribute,
        kAXNumberOfCharactersAttribute,
      ] {
        print("settable:\(attr)=\(axAttributeSettable(focused, attr))")
      }
    }
    exit(0)
  }

  let text = readStdin()
  if mode("--probe-selected-text") {
    guard let focused = context.focusedElement else {
      throw WriterError.missingFocusedElement(context.app.localizedName ?? "unknown")
    }

    let original = axStringAttribute(focused, kAXValueAttribute) ?? ""
    let probe = "VR-PROBE-\(Int(Date().timeIntervalSince1970))"
    try replaceSelectedText(focused, with: probe)
    Thread.sleep(forTimeInterval: 0.2)
    let afterProbe = axStringAttribute(focused, kAXValueAttribute) ?? ""
    try replaceSelectedText(focused, with: original)
    print("method=selectedText")
    print("probeWritten=\(afterProbe == probe)")
    print("afterProbeLength=\(afterProbe.utf16.count)")
    print("restoredLength=\(original.utf16.count)")
    exit(afterProbe == probe ? 0 : 2)
  }

  if mode("--probe-axvalue") {
    guard let focused = context.focusedElement else {
      throw WriterError.missingFocusedElement(context.app.localizedName ?? "unknown")
    }

    let original = axStringAttribute(focused, kAXValueAttribute) ?? ""
    let probe = "VR-PROBE-\(Int(Date().timeIntervalSince1970))"
    try setAXValue(focused, to: probe)
    Thread.sleep(forTimeInterval: 0.2)
    let afterProbe = axStringAttribute(focused, kAXValueAttribute) ?? ""
    try setAXValue(focused, to: original)
    print("method=axValue")
    print("probeWritten=\(afterProbe == probe)")
    print("afterProbeLength=\(afterProbe.utf16.count)")
    print("restoredLength=\(original.utf16.count)")
    exit(afterProbe == probe ? 0 : 2)
  }

  if mode("--probe-replace-range") {
    guard let focused = context.focusedElement else {
      throw WriterError.missingFocusedElement(context.app.localizedName ?? "unknown")
    }

    let original = axStringAttribute(focused, kAXValueAttribute) ?? ""
    let probe = "VR-PROBE-A\nVR-PROBE-B"
    try replaceRangeWithText(focused, text: probe)
    Thread.sleep(forTimeInterval: 0.2)
    let afterProbe = axStringAttribute(focused, kAXValueAttribute) ?? ""
    try setAXValue(focused, to: original)
    print("method=replaceRange")
    print("probeWritten=\(afterProbe == probe)")
    print("newlinePreserved=\(afterProbe.contains("\n"))")
    print("afterProbe=[\(afterProbe)]")
    exit(afterProbe == probe ? 0 : 2)
  }

  if mode("--selected-text") {
    guard let focused = context.focusedElement else {
      throw WriterError.missingFocusedElement(context.app.localizedName ?? "unknown")
    }
    try replaceSelectedText(focused, with: text)
    exit(0)
  }

  if mode("--axvalue") {
    guard let focused = context.focusedElement else {
      throw WriterError.missingFocusedElement(context.app.localizedName ?? "unknown")
    }
    try setAXValue(focused, to: text)
    exit(0)
  }

  if mode("--replace-range") {
    guard let focused = context.focusedElement else {
      throw WriterError.missingFocusedElement(context.app.localizedName ?? "unknown")
    }
    try replaceRangeWithText(focused, text: text)
    exit(0)
  }

  let previousClipboard = replaceClipboard(with: text)
  do {
    try pressMenuItem(in: context, titles: ["Select All", "全选"])
    Thread.sleep(forTimeInterval: 0.06)
    try pressMenuItem(in: context, titles: ["Paste", "粘贴"])
  } catch {
    if let focused = context.focusedElement {
      FileHandle.standardError.write("菜单写入失败，改用辅助功能选区后粘贴: \(error)\n".data(using: .utf8)!)
      try selectAll(focused)
      try pressMenuItem(in: context, titles: ["Paste", "粘贴"])
    } else {
      throw error
    }
  }
  Thread.sleep(forTimeInterval: 0.25)
  restoreClipboard(previousClipboard)
} catch {
  FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
  exit(1)
}
