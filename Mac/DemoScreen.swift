// --demo: a drawn desktop instead of real capture, and input is drawn on it instead of being posted.
// Lets the whole pipeline run without touching the real Mac or needing any permission.
import AppKit
import ClamshellCore
import CoreMedia
import CoreVideo

final class DemoScreen: FrameSource {
  var onVideo: ((CVPixelBuffer, CMTime) -> Void)?
  var onAudio: ((CMSampleBuffer) -> Void)?
  private var timer: DispatchSourceTimer?
  private var pool: CVPixelBufferPool?
  private var width = 0, height = 0
  private let lock = NSLock()
  private var log: [String] = []
  private var x = 0.5, y = 0.5, frame = 90.0, zoom = 6.0, typed = "Type on the iPhone keyboard… ", down = false, shift = false, command = false
  var appName = "Finder"
  /// Full-screen moving noise: a repeatable worst case for the encoder and the network.
  var stress = false
  var isEditor = false

  static let displays = [DisplayInfo(id: 1, name: "Demo Display", width: 3456, height: 2234, isMain: true)]

  func start(displayID: UInt32, width: Int, height: Int, completion: @escaping (Error?) -> Void) {
    self.width = width; self.height = height
    let attrs: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    ]
    CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
    let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "clamshell.demo", qos: .userInteractive))
    t.schedule(deadline: .now(), repeating: .milliseconds(16))
    t.setEventHandler { [weak self] in self?.render() }
    t.resume()
    timer = t
    completion(nil)
  }

  func stop() { timer?.cancel(); timer = nil }

  func handle(_ e: InputEvent) {
    lock.lock(); defer { lock.unlock() }
    switch e {
    case let .move(dx, dy): x = min(1, max(0, x + Double(dx) / 1728)); y = min(1, max(0, y + Double(dy) / 1117))
    case let .moveTo(nx, ny): x = Double(nx); y = Double(ny)
    case let .button(i, d): down = d; if d { note(i == 1 ? "right click" : "click") }
    case let .scroll(dx, dy, phase, _):
      if isEditor { frame = max(0, min(600, frame - Double(dx != 0 ? dx : dy) / zoom)) }
      if phase == 1 { note("scroll") }
    case let .systemKey(c, d): if d { note("system key \(c)") }
    case let .key(code, d, r):
      if code == KeyCode.shift || code == KeyCode.rightShift { shift = d }
      if code == KeyCode.command || code == KeyCode.rightCommand { command = d }
      guard d else { return }
      note("key \(code)\(command ? " ⌘" : "")\(shift ? " ⇧" : "")\(r ? " repeat" : "")")
      if isEditor { editorKey(code) } else { type(code) }
    case .releaseAll: down = false; shift = false; command = false; note("release all")
    }
  }

  private func note(_ s: String) { log.append(s); if log.count > 9 { log.removeFirst() } }

  private func editorKey(_ code: UInt16) {
    switch code {
    case KeyCode.right: frame = min(600, frame + (shift ? 5 : 1))
    case KeyCode.left: frame = max(0, frame - (shift ? 5 : 1))
    case KeyCode.equal: zoom = min(40, zoom * 1.4)
    case KeyCode.minus: zoom = max(0.6, zoom / 1.4)
    default: break
    }
  }

  private static let chars: [UInt16: String] = {
    var m: [UInt16: String] = [KeyCode.space: " ", KeyCode.comma: ",", KeyCode.period: "."]
    for row in KeyboardLayout.rows { for k in row { if case .key(let c) = k.action, k.style == .letter { m[c] = k.label } } }
    return m
  }()

  private func type(_ code: UInt16) {
    if code == KeyCode.delete { if !typed.isEmpty { typed.removeLast() } }
    else if let c = Self.chars[code] { typed += shift ? c : c.lowercased() }
  }

  private func render() {
    guard let pool else { return }
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
    guard let pb else { return }
    CVPixelBufferLockBaseAddress(pb, [])
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let g = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
      space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
    lock.lock()
    draw(g)
    lock.unlock()
    CVPixelBufferUnlockBaseAddress(pb, [])
    onVideo?(pb, CMTime(value: CMTimeValue(monotonicMicros()), timescale: 1_000_000))
  }

  private func draw(_ g: CGContext) {
    let W = CGFloat(width), H = CGFloat(height), u = W / 1728
    let phase = CGFloat(monotonicSeconds().truncatingRemainder(dividingBy: 8) / 8)
    let colors = [NSColor(calibratedRed: 0.11, green: 0.23, blue: 0.43, alpha: 1).cgColor, NSColor(calibratedRed: 0.24, green: 0.17, blue: 0.42, alpha: 1).cgColor,
      NSColor(calibratedRed: 0.06, green: 0.42, blue: 0.42, alpha: 1).cgColor] as CFArray
    g.drawLinearGradient(CGGradient(colorsSpace: nil, colors: colors, locations: [0, 0.55, 1])!, start: .zero, end: CGPoint(x: W, y: H), options: [])
    if stress {
      let cols = 96, rows = 62, w = W / CGFloat(cols), h = H / CGFloat(rows)
      for y in 0..<rows { for x in 0..<cols {
        g.setFillColor(red: .random(in: 0...1), green: .random(in: 0...1), blue: .random(in: 0...1), alpha: 1)
        g.fill(CGRect(x: CGFloat(x) * w, y: CGFloat(y) * h, width: w, height: h))
      } }
      return
    }
    g.setFillColor(NSColor(white: 1, alpha: 0.12).cgColor)
    g.fill(CGRect(x: phase * W, y: 0, width: 6 * u, height: H)) // moving bar: proves frames are live
    g.setFillColor(NSColor(white: 0.08, alpha: 0.6).cgColor)
    g.fill(CGRect(x: 0, y: H - 34 * u, width: W, height: 34 * u))
    text(g, "\(appName)    File    Edit    View    Window    Help", 20 * u, H - 24 * u, 17 * u, .white, .semibold)
    let clock = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    text(g, clock, W - 130 * u, H - 24 * u, 17 * u, .white, .semibold)
    let window = CGRect(x: 120 * u, y: 90 * u, width: 1150 * u, height: H - 180 * u)
    g.setFillColor(NSColor(white: 0.13, alpha: 0.97).cgColor)
    g.addPath(CGPath(roundedRect: window, cornerWidth: 14 * u, cornerHeight: 14 * u, transform: nil)); g.fillPath()
    if isEditor { drawEditor(g, window, u) } else {
      text(g, "Notes", window.minX + 30 * u, window.maxY - 50 * u, 20 * u, .lightGray, .semibold)
      text(g, typed, window.minX + 30 * u, window.maxY - 100 * u, 34 * u, .white, .regular, width: window.width - 60 * u)
    }
    g.setFillColor(NSColor(white: 0, alpha: 0.5).cgColor)
    let panel = CGRect(x: W - 420 * u, y: H - 300 * u, width: 390 * u, height: 240 * u)
    g.fill(panel)
    for (i, l) in log.enumerated() { text(g, l, panel.minX + 16 * u, panel.maxY - CGFloat(i + 1) * 25 * u, 17 * u, .cyan, .regular) }
    cursor(g, x * Double(W), Double(H) - y * Double(H), u)
  }

  private func drawEditor(_ g: CGContext, _ w: CGRect, _ u: CGFloat) {
    let f = Int(frame.rounded()), tc = String(format: "00:00:%02d:%02d", f / 30, f % 30)
    let hue = CGFloat(f % 120) / 120
    g.setFillColor(NSColor(hue: hue, saturation: 0.55, brightness: 0.4, alpha: 1).cgColor)
    let viewer = CGRect(x: w.midX - 300 * u, y: w.maxY - 440 * u, width: 600 * u, height: 400 * u)
    g.fill(viewer)
    text(g, tc, viewer.minX + 130 * u, viewer.midY, 54 * u, .white, .bold)
    let t = CGRect(x: w.minX + 20 * u, y: w.minY + 30 * u, width: w.width - 40 * u, height: 300 * u)
    g.setFillColor(NSColor(white: 0.1, alpha: 1).cgColor); g.fill(t)
    let view = max(0, frame - Double(t.width / u) / zoom / 2)
    let cuts = [0.0, 75, 160, 240, 330, 420, 540, 600]
    for i in 0..<(cuts.count - 1) {
      let x0 = t.minX + CGFloat((cuts[i] - view) * zoom) * u, x1 = t.minX + CGFloat((cuts[i + 1] - view) * zoom) * u
      g.setFillColor(NSColor(hue: CGFloat(i) * 0.14, saturation: 0.55, brightness: 0.7, alpha: 1).cgColor)
      g.fill(CGRect(x: x0 + 1, y: t.midY, width: x1 - x0 - 2, height: 90 * u).intersection(t))
      g.setFillColor(NSColor(red: 0.2, green: 0.56, blue: 0.33, alpha: 1).cgColor)
      g.fill(CGRect(x: x0 + 1, y: t.midY - 80 * u, width: x1 - x0 - 2, height: 70 * u).intersection(t))
    }
    let px = t.minX + CGFloat((frame - view) * zoom) * u
    g.setFillColor(NSColor.systemRed.cgColor); g.fill(CGRect(x: px - 1.5 * u, y: t.minY, width: 3 * u, height: t.height))
    text(g, String(format: "zoom %.1f px/frame · frame %d", zoom, f), t.minX, t.minY - 24 * u, 16 * u, .lightGray, .regular)
  }

  private func text(_ g: CGContext, _ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ color: NSColor, _ weight: NSFont.Weight, width: CGFloat = 4000) {
    let attr = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
    let framesetter = CTFramesetterCreateWithAttributedString(attr)
    let rect = CGRect(x: x, y: y - size * 4, width: width, height: size * 5.3)
    CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(), CGPath(rect: rect, transform: nil), nil), g)
  }

  private func cursor(_ g: CGContext, _ x: Double, _ y: Double, _ u: CGFloat) {
    let p = CGMutablePath()
    let s = u * (down ? 1.2 : 1.5)
    p.move(to: CGPoint(x: x, y: y))
    for (dx, dy) in [(0, -26), (7, -20), (12, -31), (17, -29), (12, -18), (21, -18)] as [(CGFloat, CGFloat)] {
      p.addLine(to: CGPoint(x: CGFloat(x) + dx * s, y: CGFloat(y) + dy * s))
    }
    p.closeSubpath()
    g.addPath(p); g.setFillColor(NSColor.black.cgColor); g.setStrokeColor(NSColor.white.cgColor); g.setLineWidth(2 * u); g.drawPath(using: .fillStroke)
  }
}
