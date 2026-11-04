// Touch → Mac input. Touches come in as plain values and time is passed explicitly, so every gesture
// can be replayed in unit tests, including finger counts the Simulator can't produce.
import Foundation

public struct Touch: Equatable, Sendable {
  public var id: Int, x: Double, y: Double
  public init(id: Int, x: Double, y: Double) { self.id = id; self.x = x; self.y = y }
}

public enum GestureFeedback: Equatable, Sendable { case tap, detent, dragStarted, dragEnded, toast(String) }

/// Shared by the trackpad and the screen.
public final class GestureContext {
  public var profile = Profiles.mac
  public var pointerSpeed = 1.0, scrollSpeed = 1.0, naturalScrolling = true
  /// `reliable` puts motion on the ordered channel; used right before a click so it can't land in the wrong place.
  public var send: (InputEvent, _ reliable: Bool) -> Void = { _, _ in }
  public var feedback: (GestureFeedback) -> Void = { _ in }
  public let keyboard: KeyboardEngine
  public let scroller = Scroller()

  public init(keyboard: KeyboardEngine) { self.keyboard = keyboard; scroller.context = self }

  func emit(_ e: InputEvent) { send(e, !e.isMotion) }

  func click(_ button: UInt8) {
    keyboard.markModifiersUsed()
    emit(.button(index: button, down: true))
    emit(.button(index: button, down: false))
    keyboard.releaseLatched()
    feedback(.tap)
  }

  func shortcut(_ keys: [UInt16]) {
    guard let last = keys.last else { return }
    let mods = keys.dropLast()
    mods.forEach { emit(.key(code: $0, down: true, isRepeat: false)) }
    emit(.key(code: last, down: true, isRepeat: false))
    emit(.key(code: last, down: false, isRepeat: false))
    mods.reversed().forEach { emit(.key(code: $0, down: false, isRepeat: false)) }
  }

  func perform(_ tap: FingerAction.Tap) {
    switch tap {
    case .none: break
    case .click: click(0)
    case .rightClick: click(1)
    case .keys(let k): shortcut(k); feedback(.tap)
    }
  }
}

/// Pixel scrolling with macOS scroll and momentum phases: the event stream a real trackpad produces.
public final class Scroller {
  weak var context: GestureContext?
  private var rx = 0.0, ry = 0.0, started = false, axis: Character? = nil, lockX = 0.0, lockY = 0.0
  private var samples: [(t: TimeInterval, dx: Double, dy: Double)] = []
  private var vx = 0.0, vy = 0.0, coasting = false, firstCoast = true, lastTick: TimeInterval = 0

  private var gain: Double {
    guard let c = context else { return 1 }
    return c.profile.scroll.speed * c.scrollSpeed * (c.naturalScrolling ? 1 : -1)
  }

  private func emit(_ dx: Double, _ dy: Double, phase: UInt8, momentum: UInt8) {
    rx += dx; ry += dy
    let ix = rx.rounded(.towardZero), iy = ry.rounded(.towardZero)
    rx -= ix; ry -= iy
    if ix != 0 || iy != 0 || phase != 0 || momentum != 0 {
      context?.emit(.scroll(dx: Int32(ix), dy: Int32(iy), phase: phase, momentum: momentum))
    }
  }

  public func begin() { stopCoasting(); samples = []; started = false; axis = nil; lockX = 0; lockY = 0 }

  public func move(dx inX: Double, dy inY: Double, t: TimeInterval) {
    var dx = inX, dy = inY
    // Axis lock: decide from the first few points, then ignore the other axis. Stops a timeline scroll drifting across tracks.
    if context?.profile.scroll.axisLock == true {
      if axis == nil {
        lockX += dx; lockY += dy
        if hypot(lockX, lockY) < 6 { return }
        axis = abs(lockX) >= abs(lockY) ? "x" : "y"
        dx = lockX; dy = lockY
      }
      if axis == "x" { dy = 0 } else { dx = 0 }
    }
    samples.append((t, dx, dy))
    samples.removeAll { t - $0.t > 0.1 }
    emit(dx * gain, dy * gain, phase: started ? 2 : 1, momentum: 0)
    started = true
  }

  public func end(t: TimeInterval) {
    guard started else { return }
    emit(0, 0, phase: 4, momentum: 0)
    started = false
    guard context?.profile.scroll.momentum == true, samples.count >= 2, let last = samples.last, t - last.t < 0.06, let first = samples.first else { return }
    let span = max(0.016, last.t - first.t)
    vx = samples.reduce(0) { $0 + $1.dx } / span
    vy = samples.reduce(0) { $0 + $1.dy } / span
    guard hypot(vx, vy) > 90 else { return } // points per second
    coasting = true; firstCoast = true; lastTick = t
  }

  public func tick(now: TimeInterval) {
    guard coasting else { return }
    let dt = max(0, min(now - lastTick, 0.1))
    lastTick = now
    let decay = pow(0.95, dt * 60)
    vx *= decay; vy *= decay
    if hypot(vx, vy) < 21 { stopCoasting(); return }
    emit(vx * dt * gain, vy * dt * gain, phase: 0, momentum: firstCoast ? 1 : 2)
    firstCoast = false
  }

  public func stopCoasting() {
    guard coasting else { return }
    coasting = false
    emit(0, 0, phase: 0, momentum: 3)
  }
}

private struct Centroid {
  var x: Double, y: Double, spread: Double
  init(_ points: [Int: Touch]) {
    let v = Array(points.values), n = Double(max(v.count, 1))
    let cx = v.reduce(0) { $0 + $1.x } / n, cy = v.reduce(0) { $0 + $1.y } / n
    x = cx; y = cy
    spread = v.reduce(0) { $0 + hypot($1.x - cx, $1.y - cy) } / n
  }
}

/// Speed in points per second over the last ~60 ms.
private struct VelocityTracker {
  private var s: [(x: Double, y: Double, t: TimeInterval)] = []
  mutating func add(x: Double, y: Double, t: TimeInterval) -> Double {
    s.append((x, y, t))
    while s.count > 2, t - s[0].t > 0.06 { s.removeFirst() }
    let span = t - s[0].t
    return span < 0.008 ? 0 : hypot(x - s[0].x, y - s[0].y) / span
  }
}

/// 3–4 finger motion: a one-shot Spaces swipe, or the editing jog wheel.
private final class MultiFingerMover {
  private let context: GestureContext, action: FingerAction
  private var ax = 0.0, ay = 0.0, axis: Character?, fired = false, lastDetent: TimeInterval = 0

  init(context: GestureContext, fingers: Int) { self.context = context; action = context.profile.action(for: fingers) }

  func move(dx: Double, dy: Double, t: TimeInterval, speed: Double) {
    ax += dx; ay += dy
    switch action.move {
    case .swipe:
      guard !fired, hypot(ax, ay) >= 55 else { return }
      fired = true
      let (key, label): (UInt16, String)
      if abs(ax) > abs(ay) { (key, label) = ax < 0 ? (KeyCode.right, "Next Space") : (KeyCode.left, "Previous Space") }
      else { (key, label) = ay < 0 ? (KeyCode.up, "Mission Control") : (KeyCode.down, "App windows") }
      context.shortcut([KeyCode.control, key])
      context.feedback(.tap); context.feedback(.toast(label))
    case .jog:
      // Sideways: one frame per step with a detent, like a jog wheel. A flick moves to the big step. Up/down: edit points.
      if axis == nil, hypot(ax, ay) > 8 { axis = abs(ax) >= abs(ay) ? "x" : "y" }
      if axis == "x" {
        ay = 0
        let big = speed > 900, step = context.profile.jogStep * (big ? 4 : 1)
        while abs(ax) >= step {
          let forward = ax > 0
          ax -= (forward ? 1 : -1) * step
          context.shortcut((big ? context.profile.bigJogModifiers : []) + [forward ? KeyCode.right : KeyCode.left])
          if t - lastDetent > 0.028 { context.feedback(.detent); lastDetent = t }
        }
      } else if axis == "y" {
        ax = 0
        while abs(ay) >= 40 {
          let down = ay > 0
          ay -= (down ? 1 : -1) * 40
          context.shortcut([down ? KeyCode.down : KeyCode.up])
          context.feedback(.tap); context.feedback(.toast(down ? "Next edit" : "Previous edit"))
        }
      }
    default: break
    }
  }
}

/// Pinch: one zoom shortcut per ~15% change in finger spread.
private struct Pincher {
  var reference: Double
  mutating func update(spread: Double, action: FingerAction, context: GestureContext) {
    guard reference > 0 else { return }
    if spread / reference > 1.15, let keys = action.pinchIn { reference = spread; context.shortcut(keys); context.feedback(.tap) }
    else if spread / reference < 1 / 1.15, let keys = action.pinchOut { reference = spread; context.shortcut(keys); context.feedback(.tap) }
  }
}

// MARK: - Trackpad

public final class TrackpadEngine {
  private enum Mode { case point, undecidedTwo, scroll, pinch, multi, none }
  private struct Gesture {
    var t0: TimeInterval, sx: Double, sy: Double, count = 1, maxCount = 1, moved = false, lastT: TimeInterval, mode = Mode.point
    var anchor = (x: 0.0, y: 0.0, spread: 0.0), last = (x: 0.0, y: 0.0)
    var mover: MultiFingerMover?, pincher: Pincher?, velocity = VelocityTracker()
  }
  private let context: GestureContext
  private var points: [Int: Touch] = [:]
  private var g: Gesture?
  private var holdDeadline: TimeInterval?
  public private(set) var isDragging = false
  public static let holdToDrag: TimeInterval = 0.32

  public init(context: GestureContext) { self.context = context }
  public var isActive: Bool { g != nil }

  public func began(_ touches: [Touch], t: TimeInterval) {
    context.scroller.stopCoasting()
    for touch in touches { points[touch.id] = touch }
    if g == nil, let first = touches.first {
      g = Gesture(t0: t, sx: first.x, sy: first.y, lastT: t)
      if context.profile.action(for: 1).holdToDrag { holdDeadline = t + Self.holdToDrag }
    }
    guard g != nil, points.count > 1 else { return }
    holdDeadline = nil
    g!.maxCount = max(g!.maxCount, points.count)
    if points.count > g!.count { regroup(t) }
  }

  /// A finger was added: upgrade the gesture to the higher count.
  private func regroup(_ t: TimeInterval) {
    let c = Centroid(points), n = points.count
    g!.count = n
    g!.anchor = (c.x, c.y, c.spread); g!.last = (c.x, c.y)
    g!.pincher = nil; g!.velocity = VelocityTracker()
    _ = g!.velocity.add(x: c.x, y: c.y, t: t)
    g!.mode = n == 2 ? .undecidedTwo : .multi
    g!.mover = n >= 3 ? MultiFingerMover(context: context, fingers: n) : nil
    context.scroller.begin()
  }

  public func moved(_ touches: [Touch], t: TimeInterval) {
    guard g != nil else { return }
    var singleDelta: (Double, Double)?
    for touch in touches {
      guard let old = points[touch.id] else { continue }
      singleDelta = (touch.x - old.x, touch.y - old.y)
      points[touch.id] = touch
      if points.count == 1, !g!.moved, hypot(touch.x - g!.sx, touch.y - g!.sy) > 6 {
        g!.moved = true
        if !isDragging { holdDeadline = nil }
      }
    }
    if g!.mode == .point {
      guard points.count == 1, let (dx, dy) = singleDelta else { return }
      let dt = max(0.001, t - g!.lastT)
      g!.lastT = t
      let v = hypot(dx, dy) / dt / 1000 // points per ms
      let gain = context.pointerSpeed * (1.6 + 3.2 * min(v, 1.6))
      context.emit(.move(dx: Float(dx * gain), dy: Float(dy * gain)))
      return
    }

    let c = Centroid(points)
    let cdx = c.x - g!.last.x, cdy = c.y - g!.last.y
    let speed = g!.velocity.add(x: c.x, y: c.y, t: t)
    g!.last = (c.x, c.y)
    let travel = hypot(c.x - g!.anchor.x, c.y - g!.anchor.y)
    let pinchRatio = g!.anchor.spread > 0 ? abs(c.spread / g!.anchor.spread - 1) : 0
    if travel > 6 || pinchRatio > 0.1 { g!.moved = true }

    if g!.mode == .undecidedTwo, points.count == 2 {
      let action = context.profile.action(for: 2)
      if action.pinchIn != nil, pinchRatio > 0.1 {
        g!.mode = .pinch
        g!.pincher = Pincher(reference: g!.anchor.spread)
      } else if travel > 6 {
        g!.mode = action.move == .scroll ? .scroll : .none
      }
    }
    switch g!.mode {
    case .scroll where points.count >= 2: context.scroller.move(dx: cdx, dy: cdy, t: t)
    case .pinch where points.count >= 2: g!.pincher?.update(spread: c.spread, action: context.profile.action(for: 2), context: context)
    case .multi: g!.mover?.move(dx: cdx, dy: cdy, t: t, speed: speed)
    default: break
    }
  }

  public func ended(_ touches: [Touch], t: TimeInterval) {
    for touch in touches { points[touch.id] = nil }
    guard g != nil else { return }
    if !points.isEmpty {
      // A finger lifted mid-gesture: keep the gesture, re-anchor so nothing jumps.
      let c = Centroid(points)
      g!.last = (c.x, c.y)
      if g!.mode == .scroll, points.count < 2 { context.scroller.end(t: t) }
      return
    }
    holdDeadline = nil
    let quick = !g!.moved && t - g!.t0 < 0.3
    if isDragging {
      isDragging = false
      context.emit(.button(index: 0, down: false))
      context.keyboard.releaseLatched()
      context.feedback(.dragEnded)
    } else if quick {
      context.perform(context.profile.action(for: g!.maxCount).tap)
    }
    if g!.mode == .scroll { context.scroller.end(t: t) }
    g = nil
  }

  public func tick(now: TimeInterval) {
    guard let deadline = holdDeadline, now >= deadline else { return }
    holdDeadline = nil
    guard g != nil, !g!.moved, points.count == 1 else { return }
    isDragging = true
    context.keyboard.markModifiersUsed()
    context.emit(.button(index: 0, down: true))
    context.feedback(.dragStarted)
  }
}

// MARK: - Direct touch on the picture

public struct ViewTransform: Equatable, Sendable {
  public var scale = 1.0, x = 0.0, y = 0.0
  public init() {}
}

public final class DirectTouchEngine {
  private enum Mode { case tap, drag, done, undecidedTwo, zoom, scroll, multi, ignore }
  private struct Gesture {
    var mode: Mode, t0: TimeInterval, sx = 0.0, sy = 0.0, count = 1, moved = false
    var anchor = (x: 0.0, y: 0.0, spread: 0.0), last = (x: 0.0, y: 0.0)
    var startView = ViewTransform(), content = (x: 0.0, y: 0.0), mover: MultiFingerMover?, velocity = VelocityTracker()
  }
  private let context: GestureContext
  private var points: [Int: Touch] = [:]
  private var g: Gesture?
  private var longPressDeadline: TimeInterval?
  public static let longPress: TimeInterval = 0.52

  /// Local zoom of the picture on the phone; pinching the screen is never sent to the Mac.
  public private(set) var view = ViewTransform()
  public var onViewChanged: (ViewTransform) -> Void = { _ in }
  public var viewportSize = (width: 1.0, height: 1.0)
  /// Viewport point → 0…1 on the Mac's display, nil outside the picture. Provided by the video view.
  public var mapToDisplay: (Double, Double) -> (Float, Float)? = { _, _ in nil }

  public init(context: GestureContext) { self.context = context }

  public func resetView() { view = ViewTransform(); onViewChanged(view) }

  public func began(_ touches: [Touch], t: TimeInterval) {
    context.scroller.stopCoasting()
    for touch in touches { points[touch.id] = touch }
    if g == nil, points.count == 1, let first = touches.first {
      guard let at = mapToDisplay(first.x, first.y) else { g = Gesture(mode: .ignore, t0: t); return }
      g = Gesture(mode: .tap, t0: t, sx: first.x, sy: first.y)
      context.send(.moveTo(x: at.0, y: at.1), true)
      longPressDeadline = t + Self.longPress
      return
    }
    if g == nil { g = Gesture(mode: .ignore, t0: t) }
    longPressDeadline = nil
    if g!.mode == .drag { context.emit(.button(index: 0, down: false)) }
    let c = Centroid(points), t0 = g!.t0
    if points.count == 2 {
      var n = Gesture(mode: .undecidedTwo, t0: t0)
      n.anchor = (c.x, c.y, c.spread); n.last = (c.x, c.y); n.startView = view
      n.content = ((c.x - view.x) / view.scale, (c.y - view.y) / view.scale)
      g = n
      context.scroller.begin()
    } else {
      // Three or more fingers on the screen behave like on the trackpad (jog / Spaces).
      if g!.mode == .scroll { context.scroller.end(t: t) }
      var n = Gesture(mode: .multi, t0: t0, count: points.count)
      n.anchor = (c.x, c.y, c.spread); n.last = (c.x, c.y)
      n.mover = MultiFingerMover(context: context, fingers: points.count)
      _ = n.velocity.add(x: c.x, y: c.y, t: t)
      g = n
    }
  }

  public func moved(_ touches: [Touch], t: TimeInterval) {
    guard g != nil else { return }
    for touch in touches where points[touch.id] != nil { points[touch.id] = touch }
    switch g!.mode {
    case .tap, .drag:
      guard points.count == 1, let p = points.values.first else { return }
      if g!.mode == .tap, hypot(p.x - g!.sx, p.y - g!.sy) > 9 {
        longPressDeadline = nil
        g!.mode = .drag
        context.keyboard.markModifiersUsed()
        context.emit(.button(index: 0, down: true))
      }
      if g!.mode == .drag, let at = mapToDisplay(p.x, p.y) { context.emit(.moveTo(x: at.0, y: at.1)) }
    case .multi:
      let c = Centroid(points)
      let speed = g!.velocity.add(x: c.x, y: c.y, t: t)
      let dx = c.x - g!.last.x, dy = c.y - g!.last.y
      g!.last = (c.x, c.y)
      if hypot(c.x - g!.anchor.x, c.y - g!.anchor.y) > 6 { g!.moved = true }
      g!.mover?.move(dx: dx, dy: dy, t: t, speed: speed)
    case .undecidedTwo, .zoom, .scroll:
      guard points.count == 2 else { return }
      let c = Centroid(points)
      if g!.mode == .undecidedTwo {
        if g!.anchor.spread > 0, abs(c.spread / g!.anchor.spread - 1) > 0.12 { g!.mode = .zoom }
        else if hypot(c.x - g!.anchor.x, c.y - g!.anchor.y) > 6 { g!.mode = .scroll }
      }
      if g!.mode == .zoom { zoom(to: c) }
      else if g!.mode == .scroll { context.scroller.move(dx: c.x - g!.last.x, dy: c.y - g!.last.y, t: t) }
      g!.last = (c.x, c.y)
    default: break
    }
  }

  private func zoom(to c: Centroid) {
    let s = min(5, max(1, g!.startView.scale * c.spread / g!.anchor.spread))
    view.scale = s
    view.x = min(0, max(viewportSize.width * (1 - s), c.x - g!.content.x * s))
    view.y = min(0, max(viewportSize.height * (1 - s), c.y - g!.content.y * s))
    if s < 1.04 { view = ViewTransform() }
    onViewChanged(view)
  }

  public func ended(_ touches: [Touch], t: TimeInterval) {
    for touch in touches { points[touch.id] = nil }
    guard g != nil else { return }
    if !points.isEmpty { let c = Centroid(points); g!.last = (c.x, c.y); return }
    longPressDeadline = nil
    let dur = t - g!.t0
    switch g!.mode {
    case .tap: context.click(0)
    case .drag:
      if let p = touches.last, let at = mapToDisplay(p.x, p.y) { context.send(.moveTo(x: at.0, y: at.1), true) }
      context.emit(.button(index: 0, down: false))
      context.keyboard.releaseLatched()
    case .undecidedTwo where dur < 0.3: context.click(1)
    case .scroll: context.scroller.end(t: t)
    case .multi where !g!.moved && dur < 0.3: context.perform(context.profile.action(for: g!.count).tap)
    default: break
    }
    g = nil
  }

  public func tick(now: TimeInterval) {
    guard let d = longPressDeadline, now >= d else { return }
    longPressDeadline = nil
    if g?.mode == .tap { g?.mode = .done; context.click(1) }
  }
}
