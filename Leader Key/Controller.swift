import Cocoa
import Combine
import Defaults
import SwiftUI

enum KeyHelpers: UInt16 {
  case enter = 36
  case tab = 48
  case space = 49
  case backspace = 51
  case escape = 53
  case upArrow = 126
  case downArrow = 125
  case leftArrow = 123
  case rightArrow = 124
}

class Controller {
  var userState: UserState
  var userConfig: UserConfig
  var isInHoldToStickyMode = false

  var window: MainWindow!
  var cheatsheetWindow: NSWindow!
  private var cheatsheetTimer: Timer?

  private var cancellables = Set<AnyCancellable>()

  init(userState: UserState, userConfig: UserConfig) {
    self.userState = userState
    self.userConfig = userConfig

    Task {
      for await value in Defaults.updates(.theme) {
        let windowClass = Theme.classFor(value)
        self.window = await windowClass.init(controller: self)
      }
    }

    Events.sink { event in
      switch event {
      case .didReload:
        // This should all be handled by the themes
        self.userState.isShowingRefreshState = true
        self.show()
        // Delay for 4 * 300ms to wait for animation to be noticeable
        delay(Int(Pulsate.singleDurationS * 1000) * 3) {
          self.hide()
          self.userState.isShowingRefreshState = false
        }
      default: break
      }
    }.store(in: &cancellables)

    self.cheatsheetWindow = Cheatsheet.createWindow(for: userState)
  }

  func show() {
    Events.send(.willActivate)

    let screen = Defaults[.screen].getNSScreen() ?? NSScreen()
    window.show(on: screen) {
      Events.send(.didActivate)
    }

    if !window.hasCheatsheet || userState.isShowingRefreshState {
      return
    }

    switch Defaults[.autoOpenCheatsheet] {
    case .always:
      showCheatsheet()
    case .delay:
      scheduleCheatsheet()
    default: break
    }
  }

  func hide(afterClose: (() -> Void)? = nil) {
    Events.send(.willDeactivate)
    let shouldClearState = !isInHoldToStickyMode

    window.hide {
      if shouldClearState {
        self.clear()
      }
      afterClose?()
      Events.send(.didDeactivate)
    }

    cheatsheetWindow?.orderOut(nil)
    cheatsheetTimer?.invalidate()
  }

  func keyDown(with event: NSEvent) {
    // Reset the delay timer
    if Defaults[.autoOpenCheatsheet] == .delay {
      scheduleCheatsheet()
    }

    if event.modifierFlags.contains(.command) {
      switch event.charactersIgnoringModifiers {
      case ",":
        NSApp.sendAction(
          #selector(AppDelegate.settingsMenuItemActionHandler(_:)), to: nil,
          from: nil)
        hide()
        return
      case "w":
        hide()
        return
      case "q":
        NSApp.terminate(nil)
        return
      default:
        break
      }
    }

    switch event.keyCode {
    case KeyHelpers.backspace.rawValue:
      clear()
      delay(1) {
        self.positionCheatsheetWindow()
      }
    case KeyHelpers.escape.rawValue:
      window.resignKey()
    default:
      guard let char = charForEvent(event) else { return }
      handleKey(char, withModifiers: event.modifierFlags)
    }
  }

  func handleKey(
    _ key: String,
    withModifiers modifiers: NSEvent.ModifierFlags? = nil,
    execute: Bool = true
  ) {
    if key == "?" {
      showCheatsheet()
      return
    }

    let group = userState.currentGroup ?? userConfig.root
    let hit = findMatch(for: key, in: group)

    if handleHit(hit, withModifiers: modifiers, execute: execute) {
      // Direct match in current group
    } else if Defaults[.keyFallthroughEnabled],
      !userState.navigationPath.isEmpty,
      let fallthroughMatch = findFallthroughMatch(for: key)
    {
      // Reset navigation to ancestor level
      if fallthroughMatch.ancestorIndex < 0 {
        userState.navigationPath = []
      } else {
        userState.navigationPath = Array(
          userState.navigationPath.prefix(fallthroughMatch.ancestorIndex + 1)
        )
      }
      _ = handleHit(fallthroughMatch.hit, withModifiers: modifiers, execute: execute)
    } else {
      window?.notFound()
    }

    delay(1) {
      self.positionCheatsheetWindow()
    }
  }

  private func findMatch(for key: String, in group: Group) -> ActionOrGroup? {
    return group.actions.first { item in
      switch item {
      case .group(let g):
        let groupKey = KeyMaps.glyph(for: g.key ?? "") ?? g.key ?? ""
        let inputKey = KeyMaps.glyph(for: key) ?? key
        return groupKey == inputKey
      case .action(let a):
        let actionKey = KeyMaps.glyph(for: a.key ?? "") ?? a.key ?? ""
        let inputKey = KeyMaps.glyph(for: key) ?? key
        return actionKey == inputKey
      }
    }
  }

  @discardableResult
  private func handleHit(
    _ hit: ActionOrGroup?,
    withModifiers modifiers: NSEvent.ModifierFlags?,
    execute: Bool
  ) -> Bool {
    switch hit {
    case .action(let action):
      if execute {
        let isStickyMode =
          isInHoldToStickyMode || (modifiers.map { isInStickyMode($0) } ?? false)
        let shouldKeepFocus = isStickyMode
        if shouldKeepFocus {
          runAction(action, keepFocus: true)
        } else {
          hide {
            self.runAction(action)
          }
        }
      }
      return true
    case .group(let group):
      if execute, let mods = modifiers, shouldRunGroupSequenceWithModifiers(mods) {
        hide {
          self.runGroup(group)
        }
      } else {
        userState.display = group.key
        userState.navigateToGroup(group)
      }
      return true
    case .none:
      return false
    }
  }

  private func findFallthroughMatch(for key: String) -> (hit: ActionOrGroup, ancestorIndex: Int)? {
    let path = userState.navigationPath
    // Walk up from parent to root (skip current group at path.count-1)
    for i in stride(from: path.count - 2, through: 0, by: -1) {
      if let match = findMatch(for: key, in: path[i]) {
        return (match, i)
      }
    }
    // Check root
    if let match = findMatch(for: key, in: userConfig.root) {
      return (match, -1)
    }
    return nil
  }

  private func shouldRunGroupSequence(_ event: NSEvent) -> Bool {
    return shouldRunGroupSequenceWithModifiers(event.modifierFlags)
  }

  private func shouldRunGroupSequenceWithModifiers(_ modifierFlags: NSEvent.ModifierFlags) -> Bool {
    let config = Defaults[.modifierKeyConfiguration]

    switch config {
    case .controlGroupOptionSticky:
      return modifierFlags.contains(.control)
    case .optionGroupControlSticky:
      return modifierFlags.contains(.option)
    }
  }

  private func isInStickyMode(_ modifierFlags: NSEvent.ModifierFlags) -> Bool {
    let config = Defaults[.modifierKeyConfiguration]

    switch config {
    case .controlGroupOptionSticky:
      return modifierFlags.contains(.option)
    case .optionGroupControlSticky:
      return modifierFlags.contains(.control)
    }
  }

  internal func charForEvent(_ event: NSEvent) -> String? {
    let forceEnglish = Defaults[.forceEnglishKeyboardLayout]

    // 1. If the user forces English, or if the key is non-printable,
    //    fall back to the hard-coded map.
    if forceEnglish {
      return englishGlyph(for: event)
    }

    // 2. For special keys like Enter, always use the mapped glyph
    if let entry = KeyMaps.entry(for: event.keyCode) {
      // For Enter, Space, Tab, arrows, etc. - use the glyph representation
      if event.keyCode == KeyHelpers.enter.rawValue || event.keyCode == KeyHelpers.space.rawValue
        || event.keyCode == KeyHelpers.tab.rawValue
        || event.keyCode == KeyHelpers.leftArrow.rawValue
        || event.keyCode == KeyHelpers.rightArrow.rawValue
        || event.keyCode == KeyHelpers.upArrow.rawValue
        || event.keyCode == KeyHelpers.downArrow.rawValue
      {
        return entry.glyph
      }
    }

    // 3. Use the system-translated character for regular keys.
    if let printable = event.charactersIgnoringModifiers,
      !printable.isEmpty,
      printable.unicodeScalars.first?.isASCII ?? false
    {
      return printable  // already contains correct case
    }

    // 4. For arrows, ␣, ⌫ … use map as last resort.
    return englishGlyph(for: event)
  }

  private func englishGlyph(for event: NSEvent) -> String? {
    guard let entry = KeyMaps.entry(for: event.keyCode) else {
      return event.charactersIgnoringModifiers
    }
    if entry.glyph.first?.isLetter == true && !entry.isReserved {
      return event.modifierFlags.contains(.shift)
        ? entry.glyph.uppercased()
        : entry.glyph
    }
    return entry.glyph
  }

  private func positionCheatsheetWindow() {
    guard let mainWindow = window, let cheatsheet = cheatsheetWindow else {
      return
    }

    cheatsheet.setFrameOrigin(
      mainWindow.cheatsheetOrigin(cheatsheetSize: cheatsheet.frame.size))
  }

  private func showCheatsheet() {
    if !window.hasCheatsheet {
      return
    }
    positionCheatsheetWindow()
    cheatsheetWindow?.orderFront(nil)
  }

  private func scheduleCheatsheet() {
    cheatsheetTimer?.invalidate()

    cheatsheetTimer = Timer.scheduledTimer(
      withTimeInterval: Double(Defaults[.cheatsheetDelayMS]) / 1000.0, repeats: false
    ) { [weak self] _ in
      self?.showCheatsheet()
    }
  }

  private func runGroup(_ group: Group) {
    for groupOrAction in group.actions {
      switch groupOrAction {
      case .group(let group):
        runGroup(group)
      case .action(let action):
        runAction(action)
      }
    }
  }

  private func runAction(_ action: Action, keepFocus: Bool = false) {
    let openConfig =
      keepFocus
      ? DontActivateConfiguration.shared.configuration
      : NSWorkspace.OpenConfiguration()
    openConfig.activates = !keepFocus

    switch action.type {
    case .application:
      let appOpenConfig = openConfig
      appOpenConfig.activates = true
      openApplication(action, configuration: appOpenConfig, keepFocus: keepFocus)
    case .url:
      openURL(action, keepFocus: keepFocus)
    case .command:
      CommandRunner.run(action.value)
    case .folder:
      let path: String = (action.value as NSString).expandingTildeInPath
      NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    default:
      print("\(action.type) unknown")
    }

    if keepFocus && action.type != .application && window?.isVisible == true {
      window.makeKeyAndOrderFront(nil)
    }
  }

  private func openApplication(
    _ action: Action,
    configuration: NSWorkspace.OpenConfiguration,
    keepFocus: Bool
  ) {
    guard let appURL = applicationURL(for: action.value) else {
      showAlert(
        title: "Invalid application",
        message:
          "Could not resolve application from value: \(action.value). Use an app path, app name, or bundle identifier."
      )
      return
    }

    if openApplicationUsingOpenCommand(appURL, keepFocus: keepFocus) {
      guard !keepFocus else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        let targetApp = self.runningApplication(for: appURL)
        _ = targetApp?.activate(options: [.activateIgnoringOtherApps])
      }
      return
    }

    NSWorkspace.shared.openApplication(
      at: appURL,
      configuration: configuration
    ) { [weak self] launchedApp, error in
      guard let self else { return }

      if let error {
        DispatchQueue.main.async {
          self.showAlert(
            title: "Failed to open application",
            message: "\(error.localizedDescription)\n\nApplication: \(action.value)"
          )
        }
        return
      }

      guard !keepFocus else { return }
      DispatchQueue.main.async {
        let targetApp = launchedApp ?? self.runningApplication(for: appURL)
        _ = targetApp?.activate(options: [.activateIgnoringOtherApps])
      }
    }
  }

  private func openApplicationUsingOpenCommand(_ appURL: URL, keepFocus: Bool) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [appURL.path]

    let stderrPipe = Pipe()
    process.standardError = stderrPipe

    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus == 0
    } catch {
      return false
    }
  }

  private func applicationURL(for value: String) -> URL? {
    let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedValue.isEmpty else { return nil }

    let expandedPath = (trimmedValue as NSString).expandingTildeInPath
    if FileManager.default.fileExists(atPath: expandedPath) {
      return URL(fileURLWithPath: expandedPath)
    }

    if let fileURL = URL(string: trimmedValue),
      fileURL.isFileURL,
      FileManager.default.fileExists(atPath: fileURL.path)
    {
      return fileURL
    }

    if let appByBundleIdentifier = NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: trimmedValue)
    {
      return appByBundleIdentifier
    }

    let appName = trimmedValue.hasSuffix(".app") ? trimmedValue : "\(trimmedValue).app"
    let searchPaths = [
      "/Applications",
      "/System/Applications",
      ("~/Applications" as NSString).expandingTildeInPath,
    ]
    for basePath in searchPaths {
      let candidatePath = (basePath as NSString).appendingPathComponent(appName)
      if FileManager.default.fileExists(atPath: candidatePath) {
        return URL(fileURLWithPath: candidatePath)
      }
    }

    return nil
  }

  private func runningApplication(for appURL: URL) -> NSRunningApplication? {
    guard let bundleIdentifier = Bundle(url: appURL)?.bundleIdentifier else {
      return nil
    }
    return NSRunningApplication.runningApplications(
      withBundleIdentifier: bundleIdentifier
    ).first
  }

  private func clear() {
    userState.clear()
  }

  private func openURL(_ action: Action, keepFocus: Bool = false) {
    guard let url = URL(string: action.value) else {
      showAlert(
        title: "Invalid URL", message: "Failed to parse URL: \(action.value)")
      return
    }

    guard let scheme = url.scheme else {
      showAlert(
        title: "Invalid URL",
        message:
          "URL is missing protocol (e.g. https://, raycast://): \(action.value)"
      )
      return
    }

    if keepFocus || scheme != "http" && scheme != "https" {
      NSWorkspace.shared.open(
        url,
        configuration: DontActivateConfiguration.shared.configuration)
    } else {
      NSWorkspace.shared.open(
        url,
        configuration: NSWorkspace.OpenConfiguration())
    }
  }

  private func showAlert(title: String, message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }
}

class DontActivateConfiguration {
  let configuration = NSWorkspace.OpenConfiguration()

  static var shared = DontActivateConfiguration()

  init() {
    configuration.activates = false
  }
}

extension Screen {
  func getNSScreen() -> NSScreen? {
    switch self {
    case .primary:
      return NSScreen.screens.first
    case .mouse:
      return NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
    case .activeWindow:
      return NSScreen.main
    }
  }
}
