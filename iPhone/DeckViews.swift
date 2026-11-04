// Keyboard, trackpad and edit bar. Plain views that hand touches straight to the core engines.
import AudioToolbox
import ClamshellCore
import UIKit

extension UITouch {
  func point(in view: UIView) -> Touch {
    let p = location(in: view)
    return Touch(id: ObjectIdentifier(self).hashValue, x: p.x, y: p.y)
  }
}

final class KeyCapView: UIView {
  let def: KeyDef
  private let main = UILabel(), upper = UILabel(), icon = UIImageView(), word = UILabel(), fnLabel = UILabel(), led = UIView()
  private var theme = Theme.all[0]
  private(set) var isDown = false

  init(_ def: KeyDef) {
    self.def = def
    super.init(frame: .zero)
    isUserInteractionEnabled = false
    layer.cornerCurve = .continuous
    [main, upper, icon, word, fnLabel, led].forEach(addSubview)
    [main, upper, word, fnLabel].forEach { $0.textAlignment = .center; $0.adjustsFontSizeToFitWidth = true; $0.minimumScaleFactor = 0.5 }
    icon.contentMode = .scaleAspectFit
    led.isHidden = true
    if let s = def.symbol { icon.image = UIImage(systemName: s) }
    switch def.style {
    case .letter: main.text = def.label
    case .dual: main.text = def.label; upper.text = def.shifted
    case .wordLeft, .wordRight: word.text = def.label
    case .modifierLeft, .modifierRight: word.text = def.label
    case .function: fnLabel.text = def.label; fnLabel.isHidden = true
    case .touchID, .space, .arrow: break
    }
    if def.style == .touchID { layer.borderWidth = 0 }
  }
  required init?(coder: NSCoder) { fatalError() }

  func apply(_ t: Theme) {
    theme = t
    backgroundColor = isDown ? t.keyDown : t.key
    [main, upper, word, fnLabel].forEach { $0.textColor = t.legend }
    icon.tintColor = t.legend
    layer.cornerRadius = t.keyRadius
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = t.vintage ? 0.22 : 0.55
    layer.shadowRadius = 0.5
    layer.shadowOffset = CGSize(width: 0, height: 1)
    led.backgroundColor = UIColor.systemGreen
    if def.style == .touchID {
      icon.image = UIImage(systemName: "circle")
      icon.tintColor = t.legendDim
    }
  }

  func setDown(_ down: Bool) {
    isDown = down
    CATransaction.begin(); CATransaction.setDisableActions(true)
    backgroundColor = down ? theme.keyDown : theme.key
    transform = down ? CGAffineTransform(scaleX: 0.955, y: 0.955) : .identity
    CATransaction.commit()
  }

  /// Blue ring = armed for the next key; green dot = locked on.
  func setModifier(_ state: ModifierState?) {
    layer.borderWidth = state != nil && state != .locked ? 1.5 : 0
    layer.borderColor = theme.accent.cgColor
    led.isHidden = !(state == .locked || state == .locking)
  }
  func setCaps(_ on: Bool) { led.isHidden = !on }

  func setFnActive(_ on: Bool) {
    guard def.style == .function else { return }
    fnLabel.isHidden = !on
    icon.isHidden = on
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: theme.keyRadius).cgPath
    let b = bounds, unit = superview?.bounds.width ?? 390, showWords = unit >= 560
    let inset: CGFloat = max(3, b.height * 0.11)
    led.frame = CGRect(x: inset, y: inset, width: 4, height: 4)
    led.layer.cornerRadius = 2
    switch def.style {
    case .letter:
      main.font = .systemFont(ofSize: unit * 0.0255, weight: .medium)
      main.frame = b
    case .dual:
      let size = unit * 0.019
      main.font = .systemFont(ofSize: size, weight: .medium); upper.font = .systemFont(ofSize: size * 0.9, weight: .medium)
      upper.frame = CGRect(x: 0, y: b.height * 0.13, width: b.width, height: b.height * 0.36)
      main.frame = CGRect(x: 0, y: b.height * 0.5, width: b.width, height: b.height * 0.38)
    case .wordLeft, .wordRight:
      word.font = .systemFont(ofSize: unit * 0.0155)
      word.textAlignment = def.style == .wordLeft ? .left : .right
      word.frame = b.insetBy(dx: inset + 2, dy: inset).offsetBy(dx: 0, dy: b.height * 0.14)
    case .modifierLeft, .modifierRight:
      word.font = .systemFont(ofSize: unit * 0.0135)
      word.isHidden = !showWords
      if showWords {
        let s = b.height * 0.27
        icon.frame = CGRect(x: def.style == .modifierLeft ? b.width - s - inset : inset, y: inset, width: s, height: s)
        word.textAlignment = def.style == .modifierLeft ? .left : .right
        word.frame = CGRect(x: inset, y: b.height * 0.56, width: b.width - inset * 2, height: b.height * 0.34)
      } else {
        let s = min(b.height, b.width) * 0.46
        icon.frame = CGRect(x: (b.width - s) / 2, y: (b.height - s) / 2, width: s, height: s)
      }
    case .function:
      let s = min(b.height, b.width) * 0.58
      icon.frame = CGRect(x: (b.width - s) / 2, y: (b.height - s) / 2, width: s, height: s)
      fnLabel.font = .systemFont(ofSize: unit * 0.0135); fnLabel.frame = b
    case .arrow:
      let s = min(b.height, b.width) * 0.42
      icon.frame = CGRect(x: (b.width - s) / 2, y: (b.height - s) / 2, width: s, height: s)
    case .touchID:
      let s = min(b.height, b.width) * 0.62
      icon.frame = CGRect(x: (b.width - s) / 2, y: (b.height - s) / 2, width: s, height: s)
    case .space: break
    }
  }
}

final class KeyboardView: UIView {
  let engine: KeyboardEngine
  var onPress: () -> Void = {}
  private var rows: [[KeyCapView]] = []
  private var arrowCaps: [KeyCapView] = []
  private var capsCap: KeyCapView?
  private var active: [ObjectIdentifier: KeyCapView] = [:]
  static let aspect: CGFloat = 14.5 / 5.62

  init(engine: KeyboardEngine) {
    self.engine = engine
    super.init(frame: .zero)
    isMultipleTouchEnabled = true
    for row in KeyboardLayout.rows {
      let caps = row.map { KeyCapView($0) }
      caps.forEach(addSubview)
      rows.append(caps)
    }
    arrowCaps = [KeyboardLayout.arrowLeft, KeyboardLayout.arrowUp, KeyboardLayout.arrowDown, KeyboardLayout.arrowRight].map { KeyCapView($0) }
    arrowCaps.forEach(addSubview)
    capsCap = rows.flatMap { $0 }.first { $0.def.id == "caps" }
    engine.onModifiersChanged = { [weak self] in self?.refreshModifiers() }
  }
  required init?(coder: NSCoder) { fatalError() }

  func apply(_ t: Theme) { (rows.flatMap { $0 } + arrowCaps).forEach { $0.apply(t) }; setNeedsLayout() }

  private func refreshModifiers() {
    DispatchQueue.main.async { [self] in
      for cap in rows.flatMap({ $0 }) {
        if case .modifier(let c) = cap.def.action { cap.setModifier(engine.state(of: c)) }
        cap.setFnActive(engine.isFnActive)
      }
      capsCap?.setCaps(engine.capsOn)
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let W = bounds.width, H = bounds.height, gap = max(2.5, W * 0.0062)
    let totalRowUnits: CGFloat = 5.62, rowUnit = (H - gap * 5) / totalRowUnits
    let unit = (W - gap * 13) / 14.5
    var y: CGFloat = 0
    for (r, caps) in rows.enumerated() {
      let h = r == 0 ? rowUnit * 0.62 : rowUnit
      let extra = (W - caps.reduce(0) { $0 + unit * $1.def.width } - gap * CGFloat(caps.count - 1) - (r == 5 ? unit * 3 + gap : 0)) / CGFloat(caps.count)
      var x: CGFloat = 0
      for cap in caps {
        let w = unit * cap.def.width + extra
        cap.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        cap.center = CGPoint(x: x + w / 2, y: y + h / 2)
        x += w + gap
      }
      if r == 5 {
        let aw = (W - x - gap * 2) / 3, half = (h - gap * 0.6) / 2
        place(arrowCaps[0], x, y + h - half, aw, half)
        place(arrowCaps[1], x + aw + gap, y, aw, half)
        place(arrowCaps[2], x + aw + gap, y + h - half, aw, half)
        place(arrowCaps[3], x + (aw + gap) * 2, y + h - half, aw, half)
      }
      y += h + gap
    }
  }

  private func place(_ v: UIView, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
    v.bounds = CGRect(x: 0, y: 0, width: w, height: h)
    v.center = CGPoint(x: x + w / 2, y: y + h / 2)
  }

  private func cap(at p: CGPoint) -> KeyCapView? {
    (rows.flatMap { $0 } + arrowCaps).first { $0.frame.insetBy(dx: -2, dy: -2).contains(p) }
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    for t in touches {
      guard let c = cap(at: t.location(in: self)) else { continue }
      active[ObjectIdentifier(t)] = c
      c.setDown(true)
      onPress()
      engine.press(c.def, now: t.timestamp)
    }
  }
  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
  private func finish(_ touches: Set<UITouch>) {
    for t in touches {
      guard let c = active.removeValue(forKey: ObjectIdentifier(t)) else { continue }
      c.setDown(false)
      engine.release(c.def, now: t.timestamp)
    }
  }
}

/// A surface that sends every touch to a gesture engine. Used for the trackpad and the picture.
final class TouchSurface: UIView {
  var began: ([Touch], TimeInterval) -> Void = { _, _ in }
  var moved: ([Touch], TimeInterval) -> Void = { _, _ in }
  var ended: ([Touch], TimeInterval) -> Void = { _, _ in }

  override init(frame: CGRect) { super.init(frame: frame); isMultipleTouchEnabled = true; layer.cornerCurve = .continuous }
  required init?(coder: NSCoder) { fatalError() }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { began(touches.map { $0.point(in: self) }, event?.timestamp ?? CACurrentMediaTime()) }
  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { moved(touches.map { $0.point(in: self) }, event?.timestamp ?? CACurrentMediaTime()) }
  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { ended(touches.map { $0.point(in: self) }, event?.timestamp ?? CACurrentMediaTime()) }
  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { touchesEnded(touches, with: event) }
}

/// Holds its keys down for as long as the finger stays, so shuttle combos (hold K, tap L) work.
final class EditBarButton: UIView {
  let item: EditBarItem
  var onDown: (EditBarItem) -> Void = { _ in }, onUp: (EditBarItem) -> Void = { _ in }
  private let top = UILabel(), bottom = UILabel()
  private var theme = Theme.all[0]

  init(_ item: EditBarItem) {
    self.item = item
    super.init(frame: .zero)
    top.text = item.label; bottom.text = item.caption
    [top, bottom].forEach { $0.textAlignment = .center; $0.adjustsFontSizeToFitWidth = true; $0.minimumScaleFactor = 0.6; addSubview($0) }
    layer.cornerCurve = .continuous
  }
  required init?(coder: NSCoder) { fatalError() }

  func apply(_ t: Theme) {
    theme = t
    backgroundColor = t.key
    top.textColor = t.legend; bottom.textColor = t.legendDim
    layer.cornerRadius = t.keyRadius
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let h = bounds.height
    top.font = .systemFont(ofSize: h * 0.34, weight: .semibold); bottom.font = .systemFont(ofSize: h * 0.22)
    top.frame = CGRect(x: 2, y: h * 0.1, width: bounds.width - 4, height: h * 0.48)
    bottom.frame = CGRect(x: 2, y: h * 0.58, width: bounds.width - 4, height: h * 0.32)
  }

  private func set(_ down: Bool) { backgroundColor = down ? theme.keyDown : theme.key; transform = down ? CGAffineTransform(scaleX: 0.95, y: 0.95) : .identity }
  override func touchesBegan(_ t: Set<UITouch>, with e: UIEvent?) { set(true); onDown(item) }
  override func touchesEnded(_ t: Set<UITouch>, with e: UIEvent?) { set(false); onUp(item) }
  override func touchesCancelled(_ t: Set<UITouch>, with e: UIEvent?) { set(false); onUp(item) }
}

/// Dotted speaker grille on the vintage decks.
final class GrilleView: UIView {
  var color = UIColor.gray { didSet { setNeedsDisplay() } }
  var rounded = true { didSet { setNeedsDisplay() } }
  override init(frame: CGRect) { super.init(frame: frame); isOpaque = false; isUserInteractionEnabled = false; contentMode = .redraw }
  required init?(coder: NSCoder) { fatalError() }
  override func draw(_ rect: CGRect) {
    let g = UIGraphicsGetCurrentContext()
    color.setFill()
    let step: CGFloat = 6, c = CGPoint(x: bounds.midX, y: bounds.midY), r = min(bounds.width, bounds.height) / 2
    var y = bounds.minY
    while y <= bounds.maxY {
      var x = bounds.minX
      while x <= bounds.maxX {
        if !rounded || hypot(x - c.x, y - c.y) <= r { g?.fillEllipse(in: CGRect(x: x - 1.3, y: y - 1.3, width: 2.6, height: 2.6)) }
        x += step
      }
      y += step
    }
  }
}
