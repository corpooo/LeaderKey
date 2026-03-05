import Cocoa

class HoldToStickyMonitor {
  var onKeyDown: ((_ firstKeyEvent: NSEvent?) -> Void)?
  var onKeyUp: (() -> Void)?

  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var monitoredKeyCode: Int64 = -1

  private enum HoldState {
    case idle
    case pending  // keyDown received, waiting to determine tap vs hold
    case holding  // confirmed hold, onKeyDown was called
  }

  private var holdState: HoldState = .idle
  private var holdTimer: DispatchWorkItem?
  private var eventsToPassThrough = 0
  private let holdThresholdSeconds: Double = 0.2

  func start(keyCode: Int) {
    stop()

    guard keyCode >= 0 else { return }
    monitoredKeyCode = Int64(keyCode)
    holdState = .idle
    eventsToPassThrough = 0

    let eventMask: CGEventMask =
      (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)

    let callback: CGEventTapCallBack = { proxy, type, event, refcon in
      guard let refcon = refcon else { return Unmanaged.passRetained(event) }
      let monitor = Unmanaged<HoldToStickyMonitor>.fromOpaque(refcon)
        .takeUnretainedValue()
      return monitor.handleEvent(proxy: proxy, type: type, event: event)
    }

    let selfPtr = Unmanaged.passUnretained(self).toOpaque()

    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: eventMask,
        callback: callback,
        userInfo: selfPtr)
    else {
      promptAccessibility()
      return
    }

    eventTap = tap

    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    runLoopSource = source
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
  }

  func stop() {
    holdTimer?.cancel()
    holdTimer = nil
    if let tap = eventTap {
      CGEvent.tapEnable(tap: tap, enable: false)
      if let source = runLoopSource {
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
      }
    }
    eventTap = nil
    runLoopSource = nil
    holdState = .idle
    eventsToPassThrough = 0
    monitoredKeyCode = -1
  }

  private func handleEvent(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent
  ) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout {
      if let tap = eventTap {
        CGEvent.tapEnable(tap: tap, enable: true)
      }
      return Unmanaged.passRetained(event)
    }

    guard type == .keyDown || type == .keyUp else {
      return Unmanaged.passRetained(event)
    }

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

    // Another key pressed while hold key is pending — immediately activate
    // and forward the key event to Leader Key.
    // While holding, continue forwarding subsequent keyDown events and
    // suppress passthrough to the currently focused app.
    if keyCode != monitoredKeyCode {
      if holdState == .pending, type == .keyDown,
        let nsEvent = NSEvent(cgEvent: event)
      {
        holdTimer?.cancel()
        holdTimer = nil
        holdState = .holding
        onKeyDown?(nsEvent)
        return nil
      }
      if holdState == .holding {
        if type == .keyDown, let nsEvent = NSEvent(cgEvent: event) {
          onKeyDown?(nsEvent)
        }
        return nil
      }
      return Unmanaged.passRetained(event)
    }

    // Let reposted events pass through
    if eventsToPassThrough > 0 {
      eventsToPassThrough -= 1
      return Unmanaged.passRetained(event)
    }

    if type == .keyDown {
      if holdState == .idle {
        holdState = .pending
        let timer = DispatchWorkItem { [weak self] in
          guard let self = self, self.holdState == .pending else { return }
          self.holdState = .holding
          self.onKeyDown?(nil)
        }
        holdTimer = timer
        DispatchQueue.main.asyncAfter(
          deadline: .now() + holdThresholdSeconds,
          execute: timer
        )
      }
      // Suppress all keyDown events (including repeats) while pending or holding
      return nil
    }

    if type == .keyUp {
      if holdState == .pending {
        // Quick tap — cancel timer and replay the keystroke
        holdTimer?.cancel()
        holdTimer = nil
        holdState = .idle
        repostKeyPress()
      } else if holdState == .holding {
        // Was holding — deactivate
        holdTimer?.cancel()
        holdTimer = nil
        holdState = .idle
        DispatchQueue.main.async { self.onKeyUp?() }
      }
      return nil
    }

    return Unmanaged.passRetained(event)
  }

  private func repostKeyPress() {
    let keyCode = CGKeyCode(monitoredKeyCode)
    eventsToPassThrough = 2
    if let down = CGEvent(
      keyboardEventSource: nil,
      virtualKey: keyCode,
      keyDown: true
    ) {
      down.post(tap: .cghidEventTap)
    }
    if let up = CGEvent(
      keyboardEventSource: nil,
      virtualKey: keyCode,
      keyDown: false
    ) {
      up.post(tap: .cghidEventTap)
    }
  }

  private func promptAccessibility() {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
    AXIsProcessTrustedWithOptions(options)
  }

  deinit {
    stop()
  }
}
