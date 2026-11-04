// The MacBook keyboard: layout data and press/latch/repeat behaviour. UI-free so it can be unit tested.
import Foundation

/// macOS virtual key codes (Carbon kVK_*).
public enum KeyCode {
  public static let a: UInt16 = 0x00, s: UInt16 = 0x01, d: UInt16 = 0x02, f: UInt16 = 0x03, h: UInt16 = 0x04, g: UInt16 = 0x05, z: UInt16 = 0x06
  public static let x: UInt16 = 0x07, c: UInt16 = 0x08, v: UInt16 = 0x09, b: UInt16 = 0x0B, q: UInt16 = 0x0C, w: UInt16 = 0x0D, e: UInt16 = 0x0E
  public static let r: UInt16 = 0x0F, y: UInt16 = 0x10, t: UInt16 = 0x11, n1: UInt16 = 0x12, n2: UInt16 = 0x13, n3: UInt16 = 0x14, n4: UInt16 = 0x15
  public static let n6: UInt16 = 0x16, n5: UInt16 = 0x17, equal: UInt16 = 0x18, n9: UInt16 = 0x19, n7: UInt16 = 0x1A, minus: UInt16 = 0x1B, n8: UInt16 = 0x1C
  public static let n0: UInt16 = 0x1D, rightBracket: UInt16 = 0x1E, o: UInt16 = 0x1F, u: UInt16 = 0x20, leftBracket: UInt16 = 0x21, i: UInt16 = 0x22, p: UInt16 = 0x23
  public static let enter: UInt16 = 0x24, l: UInt16 = 0x25, j: UInt16 = 0x26, quote: UInt16 = 0x27, k: UInt16 = 0x28, semicolon: UInt16 = 0x29, backslash: UInt16 = 0x2A
  public static let comma: UInt16 = 0x2B, slash: UInt16 = 0x2C, n: UInt16 = 0x2D, m: UInt16 = 0x2E, period: UInt16 = 0x2F, tab: UInt16 = 0x30, space: UInt16 = 0x31
  public static let grave: UInt16 = 0x32, delete: UInt16 = 0x33, escape: UInt16 = 0x35, rightCommand: UInt16 = 0x36, command: UInt16 = 0x37, shift: UInt16 = 0x38
  public static let capsLock: UInt16 = 0x39, option: UInt16 = 0x3A, control: UInt16 = 0x3B, rightShift: UInt16 = 0x3C, rightOption: UInt16 = 0x3D, fn: UInt16 = 0x3F
  public static let f1: UInt16 = 0x7A, f2: UInt16 = 0x78, f3: UInt16 = 0x63, f4: UInt16 = 0x76, f5: UInt16 = 0x60, f6: UInt16 = 0x61, f7: UInt16 = 0x62, f8: UInt16 = 0x64
  public static let f9: UInt16 = 0x65, f10: UInt16 = 0x6D, f11: UInt16 = 0x67, f12: UInt16 = 0x6F
  public static let left: UInt16 = 0x7B, right: UInt16 = 0x7C, down: UInt16 = 0x7D, up: UInt16 = 0x7E, missionControl: UInt16 = 0xA0
  public static let modifiers: Set<UInt16> = [command, rightCommand, shift, rightShift, option, rightOption, control, fn]
}

/// NX_KEYTYPE_* system keys.
public enum SystemKey {
  public static let volumeUp: UInt8 = 0, volumeDown: UInt8 = 1, brightnessUp: UInt8 = 2, brightnessDown: UInt8 = 3, mute: UInt8 = 7, play: UInt8 = 16, next: UInt8 = 17, previous: UInt8 = 18
}

public enum KeyAction: Hashable, Sendable {
  case key(UInt16)
  case modifier(UInt16)
  case capsLock
  case system(UInt8, fallback: UInt16)
  case combo([UInt16], fallback: UInt16)
  case functionKey(UInt16, fallback: UInt16) // sends the first; with fn held sends the F-key fallback
  case menu
}

public struct KeyDef: Hashable, Identifiable, Sendable {
  public enum Style: Hashable, Sendable { case letter, dual, wordLeft, wordRight, modifierLeft, modifierRight, function, space, arrow, touchID }
  public var id: String, label: String, shifted: String?, symbol: String?, width: Double, action: KeyAction, style: Style
  public init(_ id: String, _ label: String, shifted: String? = nil, symbol: String? = nil, width: Double = 1, action: KeyAction, style: Style = .letter) {
    self.id = id; self.label = label; self.shifted = shifted; self.symbol = symbol; self.width = width; self.action = action; self.style = style
  }
}

public enum KeyboardLayout {
  private static func letters(_ s: String, _ codes: [UInt16]) -> [KeyDef] {
    zip(s, codes).map { KeyDef(String($0), String($0), action: .key($1)) }
  }
  private static func dual(_ l: String, _ s: String, _ c: UInt16) -> KeyDef { KeyDef(l, l, shifted: s, action: .key(c), style: .dual) }
  private static func fnKey(_ n: Int, _ symbol: String, _ a: KeyAction) -> KeyDef { KeyDef("F\(n)", "F\(n)", symbol: symbol, action: a, style: .function) }

  /// Rows top to bottom; every row adds up to 14.5 units. The arrow cluster is the last row's tail.
  public static let rows: [[KeyDef]] = [
    [
      KeyDef("esc", "esc", width: 1.5, action: .key(KeyCode.escape), style: .wordLeft),
      fnKey(1, "sun.min", .system(SystemKey.brightnessDown, fallback: KeyCode.f1)),
      fnKey(2, "sun.max", .system(SystemKey.brightnessUp, fallback: KeyCode.f2)),
      fnKey(3, "rectangle.3.group", .functionKey(KeyCode.missionControl, fallback: KeyCode.f3)),
      fnKey(4, "magnifyingglass", .combo([KeyCode.command, KeyCode.space], fallback: KeyCode.f4)),
      fnKey(5, "square.grid.3x3", .combo([KeyCode.fn, KeyCode.a], fallback: KeyCode.f5)),
      fnKey(6, "camera.viewfinder", .combo([KeyCode.command, KeyCode.shift, KeyCode.n5], fallback: KeyCode.f6)),
      fnKey(7, "backward.fill", .system(SystemKey.previous, fallback: KeyCode.f7)),
      fnKey(8, "playpause.fill", .system(SystemKey.play, fallback: KeyCode.f8)),
      fnKey(9, "forward.fill", .system(SystemKey.next, fallback: KeyCode.f9)),
      fnKey(10, "speaker.slash.fill", .system(SystemKey.mute, fallback: KeyCode.f10)),
      fnKey(11, "speaker.wave.1.fill", .system(SystemKey.volumeDown, fallback: KeyCode.f11)),
      fnKey(12, "speaker.wave.3.fill", .system(SystemKey.volumeUp, fallback: KeyCode.f12)),
      KeyDef("touchid", "", action: .menu, style: .touchID),
    ],
    [
      dual("`", "~", KeyCode.grave), dual("1", "!", KeyCode.n1), dual("2", "@", KeyCode.n2), dual("3", "#", KeyCode.n3), dual("4", "$", KeyCode.n4),
      dual("5", "%", KeyCode.n5), dual("6", "^", KeyCode.n6), dual("7", "&", KeyCode.n7), dual("8", "*", KeyCode.n8), dual("9", "(", KeyCode.n9),
      dual("0", ")", KeyCode.n0), dual("-", "_", KeyCode.minus), dual("=", "+", KeyCode.equal),
      KeyDef("delete", "delete", width: 1.5, action: .key(KeyCode.delete), style: .wordRight),
    ],
    [KeyDef("tab", "tab", width: 1.5, action: .key(KeyCode.tab), style: .wordLeft)]
      + letters("QWERTYUIOP", [KeyCode.q, KeyCode.w, KeyCode.e, KeyCode.r, KeyCode.t, KeyCode.y, KeyCode.u, KeyCode.i, KeyCode.o, KeyCode.p])
      + [dual("[", "{", KeyCode.leftBracket), dual("]", "}", KeyCode.rightBracket), dual("\\", "|", KeyCode.backslash)],
    [KeyDef("caps", "caps lock", width: 1.75, action: .capsLock, style: .wordLeft)]
      + letters("ASDFGHJKL", [KeyCode.a, KeyCode.s, KeyCode.d, KeyCode.f, KeyCode.g, KeyCode.h, KeyCode.j, KeyCode.k, KeyCode.l])
      + [dual(";", ":", KeyCode.semicolon), dual("'", "\"", KeyCode.quote), KeyDef("return", "return", width: 1.75, action: .key(KeyCode.enter), style: .wordRight)],
    [KeyDef("shiftL", "shift", symbol: "shift", width: 2.25, action: .modifier(KeyCode.shift), style: .modifierLeft)]
      + letters("ZXCVBNM", [KeyCode.z, KeyCode.x, KeyCode.c, KeyCode.v, KeyCode.b, KeyCode.n, KeyCode.m])
      + [dual(",", "<", KeyCode.comma), dual(".", ">", KeyCode.period), dual("/", "?", KeyCode.slash),
         KeyDef("shiftR", "shift", symbol: "shift", width: 2.25, action: .modifier(KeyCode.rightShift), style: .modifierRight)],
    [
      KeyDef("fn", "fn", symbol: "globe", action: .modifier(KeyCode.fn), style: .modifierLeft),
      KeyDef("ctrl", "control", symbol: "control", action: .modifier(KeyCode.control), style: .modifierLeft),
      KeyDef("optL", "option", symbol: "option", action: .modifier(KeyCode.option), style: .modifierLeft),
      KeyDef("cmdL", "command", symbol: "command", width: 1.25, action: .modifier(KeyCode.command), style: .modifierLeft),
      KeyDef("space", "", width: 5, action: .key(KeyCode.space), style: .space),
      KeyDef("cmdR", "command", symbol: "command", width: 1.25, action: .modifier(KeyCode.rightCommand), style: .modifierRight),
      KeyDef("optR", "option", symbol: "option", action: .modifier(KeyCode.rightOption), style: .modifierRight),
    ],
  ]
  public static let arrowLeft = KeyDef("left", "", symbol: "arrowtriangle.left.fill", action: .key(KeyCode.left), style: .arrow)
  public static let arrowUp = KeyDef("up", "", symbol: "arrowtriangle.up.fill", action: .key(KeyCode.up), style: .arrow)
  public static let arrowDown = KeyDef("down", "", symbol: "arrowtriangle.down.fill", action: .key(KeyCode.down), style: .arrow)
  public static let arrowRight = KeyDef("right", "", symbol: "arrowtriangle.right.fill", action: .key(KeyCode.right), style: .arrow)
}

public enum ModifierState: Equatable, Sendable { case held, latched, locking, locked, releasing }

/// Modifiers: hold like a real key, tap to latch for the next key, double-tap to lock. Keys auto-repeat.
public final class KeyboardEngine {
  public var send: (InputEvent) -> Void = { _ in }
  public var onModifiersChanged: () -> Void = {}
  public var onMenu: () -> Void = {}
  public private(set) var capsOn = false

  private struct Mod { var state: ModifierState; var used = false; var at: TimeInterval }
  private var mods: [UInt16: Mod] = [:]
  private enum Pressed { case key(UInt16), modifier(UInt16), system(UInt8), combo(key: UInt16, mods: [UInt16]), none, menu }
  private var pressed: [String: Pressed] = [:]
  private var repeats: [UInt16: TimeInterval] = [:]
  private static let noRepeat: Set<UInt16> = [KeyCode.escape, KeyCode.enter, KeyCode.tab]

  public init() {}
  public var isFnActive: Bool { mods[KeyCode.fn] != nil }
  public func state(of code: UInt16) -> ModifierState? { mods[code]?.state }

  public func press(_ def: KeyDef, now: TimeInterval) {
    let fn = isFnActive
    switch def.action {
    case .menu: pressed[def.id] = .menu
    case .modifier(let c): pressed[def.id] = .modifier(c); modifierDown(c, now: now)
    case .capsLock:
      capsOn.toggle()
      send(.key(code: KeyCode.capsLock, down: true, isRepeat: false))
      send(.key(code: KeyCode.capsLock, down: false, isRepeat: false))
      pressed[def.id] = Pressed.none
      onModifiersChanged()
    case .system(let s, let fallback):
      if fn { pressKey(def.id, fallback, now: now, canRepeat: false) } else { send(.systemKey(code: s, down: true)); pressed[def.id] = .system(s) }
    case .functionKey(let k, let fallback):
      pressKey(def.id, fn ? fallback : k, now: now, canRepeat: false)
    case .combo(let keys, let fallback):
      if fn { pressKey(def.id, fallback, now: now, canRepeat: false); return }
      let extra = keys.dropLast().filter { mods[$0] == nil }
      extra.forEach { send(.key(code: $0, down: true, isRepeat: false)) }
      send(.key(code: keys.last!, down: true, isRepeat: false))
      pressed[def.id] = .combo(key: keys.last!, mods: Array(extra))
    case .key(let k):
      pressKey(def.id, k, now: now, canRepeat: !Self.noRepeat.contains(k))
    }
  }

  private func pressKey(_ id: String, _ code: UInt16, now: TimeInterval, canRepeat: Bool) {
    markModifiersUsed()
    send(.key(code: code, down: true, isRepeat: false))
    pressed[id] = .key(code)
    if canRepeat { repeats[code] = now + 0.42 }
  }

  public func release(_ def: KeyDef, now: TimeInterval) {
    guard let p = pressed.removeValue(forKey: def.id) else { return }
    switch p {
    case .none: break
    case .menu: onMenu()
    case .modifier(let c): modifierUp(c, now: now)
    case .system(let s): send(.systemKey(code: s, down: false))
    case .combo(let k, let extra):
      send(.key(code: k, down: false, isRepeat: false))
      extra.reversed().forEach { send(.key(code: $0, down: false, isRepeat: false)) }
    case .key(let k):
      repeats[k] = nil
      send(.key(code: k, down: false, isRepeat: false))
      releaseLatched()
    }
  }

  /// Fires auto-repeat. Call every frame.
  public func tick(now: TimeInterval) {
    for (code, at) in repeats where now >= at {
      send(.key(code: code, down: true, isRepeat: true))
      repeats[code] = now + 0.042
    }
  }

  public func markModifiersUsed() { for k in mods.keys where mods[k]?.state == .held { mods[k]?.used = true } }

  public func releaseLatched() {
    let latched = mods.filter { $0.value.state == .latched }.keys
    guard !latched.isEmpty else { return }
    latched.forEach(releaseModifier)
    onModifiersChanged()
  }

  /// Everything up: the phone was backgrounded or disconnected.
  public func reset() {
    mods.removeAll(); pressed.removeAll(); repeats.removeAll()
    onModifiersChanged()
  }

  private func modifierDown(_ c: UInt16, now: TimeInterval) {
    if let m = mods[c] {
      mods[c]?.state = (m.state == .latched && now - m.at < 0.35) ? .locking : .releasing
    } else {
      send(.key(code: c, down: true, isRepeat: false))
      mods[c] = Mod(state: .held, at: now)
    }
    onModifiersChanged()
  }

  private func modifierUp(_ c: UInt16, now: TimeInterval) {
    guard let m = mods[c] else { return }
    switch m.state {
    case .held:
      if !m.used && now - m.at < 0.4 { mods[c]?.state = .latched; mods[c]?.at = now } else { releaseModifier(c) }
    case .locking: mods[c]?.state = .locked
    case .releasing: releaseModifier(c)
    default: break
    }
    onModifiersChanged()
  }

  private func releaseModifier(_ c: UInt16) {
    send(.key(code: c, down: false, isRepeat: false))
    mods[c] = nil
  }
}
