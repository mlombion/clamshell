// Ties capture, encoding, networking and input together, and is what the window displays.
import AppKit
import ClamshellCore
import Combine
import CoreMedia
import CoreImage.CIFilterBuiltins
import IOKit.pwr_mgt
import Network
import Security

@MainActor
final class HostModel: ObservableObject {
  @Published var phoneName: String?
  @Published var displays: [DisplayInfo] = []
  @Published var activeDisplay: UInt32 = 0
  @Published var hasScreenAccess = false
  @Published var hasInputAccess = false
  @Published var problem: String?
  @Published var stats = "—"
  @Published var addresses: [String] = []
  @Published var pairingImage: NSImage?
  @Published var demoApp = "com.apple.finder" { didSet { if isDemo, server != nil { applyDemoApp() } } }

  let isDemo: Bool
  private let port: UInt16
  private var secret: Data
  private var server: HostServer!
  private var source: FrameSource
  private let demo: DemoScreen?
  private let injector = InputInjector()
  private let inputQueue = DispatchQueue(label: "clamshell.input", qos: .userInteractive)
  private let pipeline = Pipeline()
  private var quality = Quality.balanced, codec = VideoCodec.hevc, audioOn = true, frontApp: (id: String, name: String) = ("", "")
  private var rate = RateController(maximum: Quality.balanced.bitrate), usesAdaptiveBitrate = true, forcedQuality: Quality?, framesLostPending = 0
  private var lastSent: UInt64 = 0, lastResent: UInt64 = 0, phoneStats: PhoneStats?
  private var observers: [NSObjectProtocol] = [], timer: Timer?, sleepAssertion: IOPMAssertionID = 0, lastBytes: UInt64 = 0, lastFrames: UInt64 = 0

  init() {
    let args = ProcessInfo.processInfo.arguments
    isDemo = args.contains("--demo")
    if let i = args.firstIndex(of: "--port"), i + 1 < args.count, let p = UInt16(args[i + 1]) { port = p } else { port = ClamshellProtocol.defaultPort }
    if isDemo {
      let d = DemoScreen(); demo = d; source = d
      d.stress = args.contains("--stress")
      // --keep-pairing: a paired phone reconnects to the demo by itself, so a test needs no re-pairing.
      secret = args.contains("--keep-pairing") ? PairingStore.loadOrCreate() : Self.demoSecret()
    } else {
      demo = nil; source = ScreenCapture()
      secret = PairingStore.loadOrCreate()
    }
    if let i = args.firstIndex(of: "--demo-app"), i + 1 < args.count { demoApp = args[i + 1] }
    (source as? ScreenCapture)?.onStopped = { [weak self] error in
      Task { @MainActor in self?.problem = "Screen capture stopped: \(error.localizedDescription)" }
    }
    start()
  }

  private static func demoSecret() -> Data {
    if let s = UserDefaults.standard.data(forKey: "demoSecret") { return s }
    let s = Transport.newSecret()
    UserDefaults.standard.set(s, forKey: "demoSecret")
    return s
  }

  private func start() {
    let args = ProcessInfo.processInfo.arguments
    usesAdaptiveBitrate = !args.contains("--no-adaptive")
    var loss = 0.0
    if isDemo, let i = args.firstIndex(of: "--simulate-loss"), i + 1 < args.count { loss = (Double(args[i + 1]) ?? 0) / 100 }
    if let i = args.firstIndex(of: "--force-quality"), i + 1 < args.count, let q = Quality(rawValue: args[i + 1]) { forcedQuality = q; quality = q }
    server = HostServer(secret: secret, port: port, serviceName: isDemo ? nil : Host.current().localizedName, simulatedLoss: loss)
    server.onListenerProblem = { [weak self] p in Task { @MainActor in self?.problem = p } }
    server.onHello = { [weak self] name, codecs in Task { @MainActor in self?.phoneConnected(name, codecs) } }
    server.onDatagramsReady = { [weak self] in Task { @MainActor in self?.startStreaming() } }
    server.onSessionEnded = { [weak self] in Task { @MainActor in self?.phoneDisconnected() } }
    server.onMessage = { [weak self] m in Task { @MainActor in self?.handle(m) } }
    let injector = injector, inputQueue = inputQueue, demo = demo
    server.onInput = { e in
      if let demo { demo.handle(e); return }
      inputQueue.async { injector.handle(e) }
    }
    server.start()

    IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
      "Clamshell keeps this Mac reachable from your iPhone" as CFString, &sleepAssertion)
    observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
      let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      Task { @MainActor in self?.reportFrontApp(app) }
    })
    if isDemo { applyDemoApp() } else { reportFrontApp(NSWorkspace.shared.frontmostApplication) }
    refresh()
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    if ProcessInfo.processInfo.arguments.contains("--print-pairing") { print("PAIRING \(pairing.url.absoluteString)"); fflush(stdout) }
  }

  // MARK: status

  private var pairing: PairingInfo { PairingInfo(secret: secret, hostName: Host.current().localizedName ?? "Mac", port: port, addresses: addresses) }

  private func refresh() {
    hasScreenAccess = isDemo || CGPreflightScreenCaptureAccess()
    hasInputAccess = isDemo || InputInjector.isTrusted
    let list = isDemo ? DemoScreen.displays : Displays.all()
    if list != displays { displays = list; server.send(.displays(list, active: activeDisplay)) }
    if activeDisplay == 0 || !list.contains(where: { $0.id == activeDisplay }) { activeDisplay = list.first { $0.isMain }?.id ?? list.first?.id ?? 0; injector.display = activeDisplay }
    let found = NetworkAddresses.current()
    if found != addresses || pairingImage == nil { addresses = found; pairingImage = QRCode.image(pairing.url.absoluteString) }

    let b = server.bytesSent, f = server.framesSent
    adaptBitrate()
    if phoneName != nil {
      let mbps = Double(b &- lastBytes) * 8 / 1_000_000
      let (w, h) = pipeline.size
      stats = String(format: "%d fps · %.1f Mb/s · %d×%d %@ · encode %.1f ms", Int(f &- lastFrames), mbps, w, h, codec == .hevc ? "HEVC" : "H.264", pipeline.encodeMillis)
      if let p = phoneStats { stats += String(format: " · %.0f ms round trip · %.0f ms capture→phone", p.rttMillis, p.ageMillis) }
      if ProcessInfo.processInfo.arguments.contains("--log-stats") {
        var line = "STATS \(stats) resent \(server.packetsResent) target \(rate.target / 1000) kb/s"
        if let p = phoneStats { line += " PHONE shown \(p.framesShown) requested \(p.packetsRequested) dup \(p.duplicates) lost \(p.framesLost)" }
        print(line); fflush(stdout)
      }
    } else { stats = "—" }
    lastBytes = b; lastFrames = f
  }

  func requestScreenAccess() { CGRequestScreenCaptureAccess(); openSettings("Privacy_ScreenCapture") }
  func requestInputAccess() { InputInjector.requestTrust(); openSettings("Privacy_Accessibility") }
  private func openSettings(_ pane: String) {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
  }

  /// New secret: every paired phone has to scan again.
  func unpairAll() {
    guard !isDemo else { return }
    secret = PairingStore.replace()
    server.disconnectPhone()
    observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; observers = []
    timer?.invalidate()
    pairingImage = nil
    start()
  }

  func select(display id: UInt32) {
    activeDisplay = id
    injector.display = id
    server.send(.displays(displays, active: id))
    if phoneName != nil { startStreaming() }
  }

  // MARK: phone lifecycle

  private func phoneConnected(_ name: String, _ codecs: [VideoCodec]) {
    phoneName = name
    codec = codecs.contains(.hevc) ? .hevc : .h264
    problem = nil
    if !isDemo && !hasInputAccess { server.send(.problem("Allow Accessibility for Clamshell Host on your Mac to control it.")) }
    server.send(.displays(displays, active: activeDisplay))
    server.send(.frontApp(id: frontApp.id, name: frontApp.name))
    // Keep the display lit while someone is using it remotely; capture needs that.
    if displayAssertion == 0 {
      IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
        "Clamshell is streaming this screen" as CFString, &displayAssertion)
    }
  }
  private var displayAssertion: IOPMAssertionID = 0

  private func phoneDisconnected() {
    phoneName = nil
    pipeline.stop()
    source.stop()
    inputQueue.async { [injector] in injector.releaseAll() }
    if displayAssertion != 0 { IOPMAssertionRelease(displayAssertion); displayAssertion = 0 }
  }

  private func handle(_ m: ClientMessage) {
    switch m {
    case .hello: break
    case .setQuality(let q): quality = forcedQuality ?? q; startStreaming()
    case .selectDisplay(let id): select(display: id)
    case .requestKeyframe: pipeline.encoder?.requestKeyframe()
    case .setAudio(let on): audioOn = on; pipeline.audioEnabled = on
    case .stats(let s): phoneStats = s; framesLostPending += s.framesLost
    }
  }

  private func adaptBitrate() {
    let sent = server.packetsSent, resent = server.packetsResent
    defer { lastSent = sent; lastResent = resent; framesLostPending = 0 }
    guard usesAdaptiveBitrate, phoneName != nil else { return }
    if let bitrate = rate.update(sentPackets: Int(sent &- lastSent), resentPackets: Int(resent &- lastResent), framesLost: framesLostPending, now: monotonicSeconds()) {
      pipeline.encoder?.setBitrate(bitrate)
    }
  }

  private func startStreaming() {
    let info = displays.first { $0.id == activeDisplay } ?? displays.first
    guard let info else { return }
    if !isDemo && !hasScreenAccess {
      let msg = "Allow Screen Recording for Clamshell Host on your Mac."
      problem = msg; server.send(.problem(msg))
      CGRequestScreenCaptureAccess()
      return
    }
    let (w, h) = Displays.streamSize(displayWidth: info.width, displayHeight: info.height, maxWidth: quality.maxWidth)
    let server = server!
    source.stop()
    rate = RateController(maximum: quality.bitrate)
    pipeline.configure(width: w, height: h, codec: codec, bitrate: quality.bitrate, server: server, audioEnabled: audioOn)
    source.onVideo = { [pipeline] px, _ in pipeline.encode(px) }
    source.onAudio = { [pipeline] s in pipeline.encodeAudio(s) }
    let codec = codec, quality = quality, displayID = info.id, isDemo = isDemo
    source.start(displayID: info.id, width: w, height: h) { [weak self] error in
      if let error {
        let msg = "Screen capture failed: \(error.localizedDescription)"
        Task { @MainActor in self?.problem = msg }
        server.send(.problem(msg))
      } else {
        server.send(.stream(StreamInfo(width: w, height: h, codec: codec, displayID: displayID, quality: quality, hasAudio: !isDemo)))
        Task { @MainActor in self?.problem = nil }
      }
    }
  }

  private func reportFrontApp(_ app: NSRunningApplication?) {
    guard let app, let id = app.bundleIdentifier, !isDemo else { return }
    frontApp = (id, app.localizedName ?? id)
    server.send(.frontApp(id: id, name: frontApp.name))
  }

  private func applyDemoApp() {
    let name = ["com.apple.finder": "Finder", "com.adobe.PremierePro.26": "Premiere Pro", "com.apple.FinalCut": "Final Cut Pro"][demoApp] ?? demoApp
    demo?.appName = name
    demo?.isEditor = demoApp != "com.apple.finder"
    frontApp = (demoApp, name)
    server.send(.frontApp(id: demoApp, name: name))
  }
}

/// Capture → encode → send. Runs off the main thread.
final class Pipeline {
  private let lock = NSLock()
  private(set) var encoder: VideoEncoder?
  private var audio: AudioEncoder?
  private var lastPixels: CVPixelBuffer?, lastFrameAt: TimeInterval = 0, repeats = 0
  private var refiner: DispatchSourceTimer?
  private let queue = DispatchQueue(label: "clamshell.pipeline", qos: .userInteractive)
  var audioEnabled = true
  private(set) var size = (0, 0)
  private(set) var encodeMillis = 0.0
  private static let idleRepeats = 8

  func configure(width: Int, height: Int, codec: VideoCodec, bitrate: Int, server: HostServer, audioEnabled: Bool) {
    stop()
    lock.lock(); defer { lock.unlock() }
    size = (width, height)
    self.audioEnabled = audioEnabled
    encoder = VideoEncoder(width: width, height: height, codec: codec, bitrate: bitrate) { [weak self] out in
      self?.encodeMillis = out.encodeMillis
      server.sendVideo(payload: out.payload, isKeyframe: out.isKeyframe, captureMicros: out.captureMicros)
    }
    audio = AudioEncoder { server.sendAudio($0) }
    // macOS only sends frames when the screen changes. Re-encoding the last frame a few times after it
    // goes still lets the encoder sharpen text instead of leaving motion blur on screen.
    let t = DispatchSource.makeTimerSource(queue: queue)
    t.schedule(deadline: .now() + 0.1, repeating: .milliseconds(50))
    t.setEventHandler { [weak self] in self?.refine() }
    t.resume()
    refiner = t
  }

  func stop() {
    lock.lock(); defer { lock.unlock() }
    refiner?.cancel(); refiner = nil
    encoder?.invalidate(); encoder = nil
    audio = nil; lastPixels = nil
    size = (0, 0)
  }

  func encode(_ px: CVPixelBuffer) {
    lock.lock()
    lastPixels = px; lastFrameAt = monotonicSeconds(); repeats = 0
    let e = encoder
    lock.unlock()
    push(px, e)
  }

  private func refine() {
    lock.lock()
    guard let px = lastPixels, monotonicSeconds() - lastFrameAt > 0.12, repeats < Self.idleRepeats else { lock.unlock(); return }
    repeats += 1
    let e = encoder
    lock.unlock()
    push(px, e)
  }

  private func push(_ px: CVPixelBuffer, _ e: VideoEncoder?) {
    let now = monotonicMicros()
    e?.encode(px, pts: CMTime(value: CMTimeValue(now), timescale: 1_000_000), captureMicros: now)
  }

  func encodeAudio(_ s: CMSampleBuffer) {
    guard audioEnabled else { return }
    lock.lock(); let a = audio; lock.unlock()
    a?.encode(s)
  }
}

enum NetworkAddresses {
  /// IPv4 addresses a phone could reach, Tailscale first because it works from anywhere.
  static func current() -> [String] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return [] }
    defer { freeifaddrs(head) }
    var out: [String] = []
    var p = head
    while let i = p {
      defer { p = i.pointee.ifa_next }
      guard let sa = i.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), i.pointee.ifa_flags & UInt32(IFF_UP) != 0, i.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
      let ip = String(cString: host)
      if !ip.hasPrefix("169.254.") && !out.contains(ip) { out.append(ip) }
    }
    func isTailscale(_ ip: String) -> Bool {
      let parts = ip.split(separator: ".").compactMap { Int($0) }
      return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }
    return out.filter(isTailscale) + out.filter { !isTailscale($0) }
  }
}

enum QRCode {
  static func image(_ text: String) -> NSImage? {
    let f = CIFilter.qrCodeGenerator()
    f.message = Data(text.utf8)
    f.correctionLevel = "M"
    guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
      let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
  }
}

enum PairingStore {
  private static let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "Clamshell pairing secret", kSecAttrAccount: "default"]

  static func loadOrCreate() -> Data {
    var q = query
    q[kSecReturnData] = true
    var result: CFTypeRef?
    if SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let d = result as? Data, d.count >= 16 { return d }
    return replace()
  }

  static func replace() -> Data {
    SecItemDelete(query as CFDictionary)
    let s = Transport.newSecret()
    var q = query
    q[kSecValueData] = s
    SecItemAdd(q as CFDictionary, nil)
    return s
  }
}
