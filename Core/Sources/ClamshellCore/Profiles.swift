// Gesture profiles: what each finger count does, per kind of work. The one place to retune gestures.
import Foundation

public struct FingerAction: Sendable {
  public enum Move: Sendable { case none, pointer, scroll, swipe, jog }
  public enum Tap: Sendable { case none, click, rightClick, keys([UInt16]) }
  public var move: Move, tap: Tap, holdToDrag: Bool, pinchIn: [UInt16]?, pinchOut: [UInt16]?
  public init(move: Move = .none, tap: Tap = .none, holdToDrag: Bool = false, pinchIn: [UInt16]? = nil, pinchOut: [UInt16]? = nil) {
    self.move = move; self.tap = tap; self.holdToDrag = holdToDrag; self.pinchIn = pinchIn; self.pinchOut = pinchOut
  }
}

public struct ScrollTuning: Sendable {
  public var speed: Double, momentum: Bool, axisLock: Bool
  public init(speed: Double, momentum: Bool, axisLock: Bool) { self.speed = speed; self.momentum = momentum; self.axisLock = axisLock }
}

public struct EditBarItem: Identifiable, Sendable {
  public var id: String { label }
  public var label: String, caption: String, keys: [UInt16], startsGroup: Bool
  public init(_ label: String, _ caption: String, _ keys: [UInt16], startsGroup: Bool = false) {
    self.label = label; self.caption = caption; self.keys = keys; self.startsGroup = startsGroup
  }
}

public enum ProfileID: String, CaseIterable, Codable, Sendable { case mac, premiere, video }

public struct GestureProfile: Sendable {
  public var id: ProfileID, name: String, short: String
  public var fingers: [Int: FingerAction], scroll: ScrollTuning
  public var jogStep: Double, bigJogModifiers: [UInt16]
  public var bar: [EditBarItem], descriptions: [(String, String)]

  public func action(for fingers: Int) -> FingerAction { self.fingers[min(fingers, 4)] ?? FingerAction() }
}

public enum Profiles {
  private static let oneFinger = FingerAction(move: .pointer, tap: .click, holdToDrag: true)
  private static let spaces = FingerAction(move: .swipe)
  private static let jog = FingerAction(move: .jog, tap: .keys([KeyCode.space]))
  private static func twoFingers(zoomIn: [UInt16], zoomOut: [UInt16]) -> FingerAction {
    FingerAction(move: .scroll, tap: .rightClick, pinchIn: zoomIn, pinchOut: zoomOut)
  }
  private static let transport = [
    EditBarItem("J", "◀◀", [KeyCode.j]), EditBarItem("K", "stop", [KeyCode.k]), EditBarItem("L", "▶▶", [KeyCode.l]),
    EditBarItem("I", "in", [KeyCode.i], startsGroup: true), EditBarItem("O", "out", [KeyCode.o]),
  ]
  private static let undo = EditBarItem("⌘Z", "undo", [KeyCode.command, KeyCode.z], startsGroup: true)
  private static let pointerText = "Move the pointer · tap to click · hold, then move to drag"

  public static let mac = GestureProfile(
    id: .mac, name: "macOS", short: "macOS",
    fingers: [1: oneFinger, 2: twoFingers(zoomIn: [KeyCode.command, KeyCode.equal], zoomOut: [KeyCode.command, KeyCode.minus]), 3: spaces, 4: spaces],
    scroll: ScrollTuning(speed: 1.9, momentum: true, axisLock: false), jogStep: 10, bigJogModifiers: [KeyCode.shift], bar: [],
    descriptions: [
      ("1 finger", pointerText),
      ("2 fingers", "Scroll with momentum · tap to right-click · pinch to zoom (⌘+ / ⌘−)"),
      ("3–4 fingers", "Swipe for Spaces ← →, Mission Control ↑, app windows ↓"),
    ])

  public static let premiere = GestureProfile(
    id: .premiere, name: "Premiere Pro", short: "Premiere",
    fingers: [1: oneFinger, 2: twoFingers(zoomIn: [KeyCode.equal], zoomOut: [KeyCode.minus]), 3: jog, 4: spaces],
    scroll: ScrollTuning(speed: 1.5, momentum: false, axisLock: true), jogStep: 10, bigJogModifiers: [KeyCode.shift],
    bar: transport + [
      EditBarItem("⌘K", "cut", [KeyCode.command, KeyCode.k], startsGroup: true), EditBarItem("Q", "trim ◀", [KeyCode.q]), EditBarItem("W", "trim ▶", [KeyCode.w]), undo,
    ],
    descriptions: [
      ("1 finger", "Move the pointer · tap to click · hold, then move to drag clips"),
      ("2 fingers", "Scroll the timeline, locked to one direction with no coasting · tap to right-click · pinch to zoom the timeline (= / −)"),
      ("3 fingers", "Jog wheel: slide sideways one frame per tick, flick for 5 frames · slide up/down for previous/next edit · tap to play/pause"),
      ("4 fingers", "Swipe for Spaces and Mission Control"),
    ])

  public static let video = GestureProfile(
    id: .video, name: "Final Cut Pro · DaVinci Resolve", short: "FCP · Resolve",
    fingers: [1: oneFinger, 2: twoFingers(zoomIn: [KeyCode.command, KeyCode.equal], zoomOut: [KeyCode.command, KeyCode.minus]), 3: jog, 4: spaces],
    scroll: ScrollTuning(speed: 1.5, momentum: false, axisLock: true), jogStep: 10, bigJogModifiers: [KeyCode.shift],
    bar: transport + [EditBarItem("⌘B", "blade", [KeyCode.command, KeyCode.b], startsGroup: true), undo],
    descriptions: [
      ("1 finger", "Move the pointer · tap to click · hold, then move to drag clips"),
      ("2 fingers", "Scroll the timeline, locked to one direction with no coasting · tap to right-click · pinch to zoom (⌘+ / ⌘−)"),
      ("3 fingers", "Jog wheel: slide sideways one frame per tick, flick for a big step · slide up/down for previous/next edit · tap to play/pause"),
      ("4 fingers", "Swipe for Spaces and Mission Control"),
    ])

  public static func profile(_ id: ProfileID) -> GestureProfile {
    switch id { case .mac: mac; case .premiere: premiere; case .video: video }
  }

  /// Auto mode: the profile for the Mac's frontmost app.
  public static func id(forBundleID bundle: String) -> ProfileID {
    if bundle.hasPrefix("com.adobe.PremierePro") { return .premiere }
    if bundle.hasPrefix("com.apple.FinalCut") || bundle.hasPrefix("com.blackmagic-design.DaVinciResolve") { return .video }
    return .mac
  }
}
