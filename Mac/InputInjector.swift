// Posts real macOS input events. Needs Accessibility permission.
import AppKit
import ApplicationServices
import ClamshellCore
import CoreGraphics

final class InputInjector {
  /// Absolute touches map onto this display.
  var display = CGMainDisplayID()
  private let source = CGEventSource(stateID: .hidSystemState)
  private var flags: CGEventFlags = []
  private var buttons = [false, false]
  private var heldKeys = Set<CGKeyCode>()
  private var modifierDown = [CGKeyCode: Bool]()
  // Tracked locally so fast relative moves never lose deltas; re-syncs when someone uses the real mouse.
  private var position = CGPoint.zero
  private var lastPost: TimeInterval = 0
  private var lastDown: TimeInterval = 0
  private var lastDownPosition = CGPoint.zero
  private var clickCount: Int64 = 1
  private var boundsCache = CGRect.null
  private var boundsAt: TimeInterval = -10

  static var isTrusted: Bool { AXIsProcessTrusted() }
  static func requestTrust() {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
  }

  private let modifierFlags: [CGKeyCode: CGEventFlags] = [
    0x37: .maskCommand, 0x36: .maskCommand, 0x38: .maskShift, 0x3C: .maskShift,
    0x3A: .maskAlternate, 0x3D: .maskAlternate, 0x3B: .maskControl, 0x3E: .maskControl,
    0x3F: .maskSecondaryFn, 0x39: .maskAlphaShift,
  ]

  func handle(_ event: InputEvent) {
    switch event {
    case let .move(dx, dy):
      syncPosition()
      movePointer(to: CGPoint(x: position.x + CGFloat(dx), y: position.y + CGFloat(dy)), dx: Double(dx), dy: Double(dy))
    case let .moveTo(x, y):
      let b = CGDisplayBounds(display)
      let target = CGPoint(x: b.minX + CGFloat(x) * b.width, y: b.minY + CGFloat(y) * b.height)
      syncPosition()
      movePointer(to: target, dx: target.x - position.x, dy: target.y - position.y)
    case let .button(index, down): mouseButton(Int(index), down: down)
    case let .scroll(dx, dy, phase, momentum): scroll(dx: dx, dy: dy, phase: Int64(phase), momentum: Int64(momentum))
    case let .key(code, down, isRepeat): key(CGKeyCode(code), down: down, isRepeat: isRepeat)
    case let .systemKey(code, down): systemKey(Int(code), down: down)
    case .releaseAll: releaseAll()
    }
  }

  private func now() -> TimeInterval { monotonicSeconds() }
  private func syncPosition() { if now() - lastPost > 0.25 { position = CGEvent(source: nil)?.location ?? position } }
  private func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap); lastPost = now() }

  private func desktopBounds() -> CGRect {
    if now() - boundsAt > 2 {
      var count: UInt32 = 0
      CGGetActiveDisplayList(0, nil, &count)
      var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
      CGGetActiveDisplayList(count, &ids, &count)
      boundsCache = ids.reduce(CGRect.null) { $0.union(CGDisplayBounds($1)) }
      boundsAt = now()
    }
    return boundsCache
  }

  private func movePointer(to p: CGPoint, dx: Double, dy: Double) {
    let b = desktopBounds()
    position = CGPoint(x: min(max(p.x, b.minX), b.maxX - 1), y: min(max(p.y, b.minY), b.maxY - 1))
    let type: CGEventType = buttons[0] ? .leftMouseDragged : buttons[1] ? .rightMouseDragged : .mouseMoved
    let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: position, mouseButton: buttons[1] && !buttons[0] ? .right : .left)
    e?.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
    e?.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
    e?.flags = flags
    post(e)
  }

  private func mouseButton(_ b: Int, down: Bool) {
    guard b == 0 || b == 1, buttons[b] != down else { return }
    syncPosition()
    if b == 0 && down {
      let t = now()
      let near = hypot(position.x - lastDownPosition.x, position.y - lastDownPosition.y) < 6
      clickCount = (t - lastDown < NSEvent.doubleClickInterval && near) ? clickCount + 1 : 1
      lastDown = t
      lastDownPosition = position
    }
    buttons[b] = down
    let type: CGEventType = b == 0 ? (down ? .leftMouseDown : .leftMouseUp) : (down ? .rightMouseDown : .rightMouseUp)
    let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: position, mouseButton: b == 0 ? .left : .right)
    e?.setIntegerValueField(.mouseEventClickState, value: b == 0 ? clickCount : 1)
    e?.flags = flags
    post(e)
  }

  private func scroll(dx: Int32, dy: Int32, phase: Int64, momentum: Int64) {
    let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
    e?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    if phase != 0 { e?.setIntegerValueField(CGEventField(rawValue: 99)!, value: phase) }
    if momentum != 0 { e?.setIntegerValueField(CGEventField(rawValue: 123)!, value: momentum) }
    e?.flags = flags
    post(e)
  }

  // Real Apple keyboards tag these keys with extra flags; some apps check for them.
  private func implicitFlags(_ code: CGKeyCode) -> CGEventFlags {
    switch code {
    case 0x7B...0x7E: return [.maskNumericPad, .maskSecondaryFn]
    case 0x60...0x79: return [.maskSecondaryFn]
    default: return []
    }
  }

  private func key(_ code: CGKeyCode, down: Bool, isRepeat: Bool) {
    if let f = modifierFlags[code] {
      if code == 0x39 {
        guard down else { return }
        if flags.contains(f) { flags.remove(f) } else { flags.insert(f) }
      } else {
        modifierDown[code] = down
        let held = modifierFlags.contains { $0.value == f && modifierDown[$0.key] == true }
        if held { flags.insert(f) } else { flags.remove(f) }
      }
      let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
      e?.type = .flagsChanged
      e?.flags = flags
      post(e)
      return
    }
    if down { heldKeys.insert(code) } else { heldKeys.remove(code) }
    let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
    e?.flags = flags.union(implicitFlags(code))
    if isRepeat { e?.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
    post(e)
  }

  private func systemKey(_ nx: Int, down: Bool) {
    let state = down ? 0xA : 0xB
    let ev = NSEvent.otherEvent(
      with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
      timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: (nx << 16) | (state << 8), data2: -1)
    ev?.cgEvent?.post(tap: .cghidEventTap)
  }

  /// Never leave a key or button stuck down.
  func releaseAll() {
    for b in 0..<2 where buttons[b] { mouseButton(b, down: false) }
    for k in Array(heldKeys) { key(k, down: false, isRepeat: false) }
    for (k, d) in modifierDown where d { key(k, down: false, isRepeat: false) }
    flags = flags.intersection(.maskAlphaShift)
  }
}
