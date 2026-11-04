// The iPhone's network side: find the Mac, prove we hold the pairing secret, then receive the stream.
import ClamshellCore
import Foundation
import Network
import VideoToolbox

@MainActor
final class PhoneSession: ObservableObject {
  enum State: Equatable { case unpaired, connecting, opening, live, rejected }
  @Published private(set) var state = State.unpaired
  @Published private(set) var hostName = ""
  @Published private(set) var displays: [DisplayInfo] = []
  @Published private(set) var activeDisplay: UInt32 = 0
  @Published private(set) var frontApp: (id: String, name: String) = ("", "")
  @Published private(set) var stream: StreamInfo?
  @Published private(set) var problem: String?
  @Published private(set) var stats = "—"

  private(set) var pairing: PairingInfo?
  let link = NetworkLink()
  var surface: VideoSurface? { didSet { link.surface = surface } }
  let audio = AudioPlayer()

  init() {
    link.audio = audio
    link.onEvent = { [weak self] e in Task { @MainActor in self?.handle(e) } }
  }

  func use(_ p: PairingInfo) {
    pairing = p
    hostName = p.hostName
    resume()
  }

  func resume() {
    guard let pairing else { state = .unpaired; return }
    state = .connecting
    link.connect(pairing)
  }

  func suspend() {
    link.send(.releaseAll, reliable: true)
    link.disconnect()
    surface?.reset()
    if pairing != nil { state = .connecting } else { state = .unpaired }
  }

  func forget() {
    suspend()
    pairing = nil
    state = .unpaired
  }

  func send(_ m: ClientMessage) { link.send(m) }

  private func handle(_ e: NetworkLink.Event) {
    switch e {
    case .connecting: if state != .rejected { state = .connecting }
    case .rejected: state = .rejected
    case .welcome(let host): hostName = host; state = .opening; problem = nil
    case .message(let m):
      switch m {
      case .welcome: break
      case .displays(let d, let active): displays = d; activeDisplay = active
      case .stream(let s): stream = s; problem = nil
      case .frontApp(let id, let name): frontApp = (id, name)
      case .problem(let p): problem = p
      }
    case .firstFrame: state = .live
    case .stats(let s): stats = s
    }
  }
}

/// Everything off the main thread: touches and video must never wait for UI work.
final class NetworkLink {
  enum Event { case connecting, rejected, welcome(String), message(HostMessage), firstFrame, stats(String) }
  var onEvent: (Event) -> Void = { _ in }
  var surface: VideoSurface?
  var audio: AudioPlayer?

  private let queue = DispatchQueue(label: "clamshell.link", qos: .userInteractive)
  private var attempts: [NWConnection] = []
  private var browser: NWBrowser?
  private var control: NWConnection?
  private var udp: NWConnection?
  private var deframer = ControlDeframer()
  private var sealer: DatagramSealer?, opener: DatagramOpener?
  private var assembler = FrameAssembler()
  private var pairing: PairingInfo?
  private var generation = 0
  private var service: DispatchSourceTimer?, retry: DispatchWorkItem?
  private var udpConfirmed = false, lastHello: TimeInterval = 0, lastPing: TimeInterval = 0, lastKeyRequest: TimeInterval = 0
  private var hadFrame = false

  // Clock offset and stats
  private var bestRTT = UInt64.max, clockOffset: Int64 = 0, lastRTT: UInt64 = 0, bestRTTAt: TimeInterval = 0
  private var bytes = 0, frames = 0, statsAt: TimeInterval = 0, ageSum: Double = 0, nacks = 0, lastDuplicates = 0, lastFramesLost = 0

  func connect(_ p: PairingInfo) {
    queue.async { [self] in
      generation += 1
      teardown()
      pairing = p
      attemptAll()
    }
  }

  func disconnect() {
    queue.async { [self] in
      generation += 1
      pairing = nil
      teardown()
    }
  }

  private func teardown() {
    retry?.cancel(); retry = nil
    service?.cancel(); service = nil
    browser?.cancel(); browser = nil
    attempts.forEach { $0.cancel() }; attempts = []
    control?.cancel(); control = nil
    udp?.cancel(); udp = nil
    deframer = ControlDeframer()
    sealer = nil; opener = nil
    assembler = FrameAssembler()
    lastDuplicates = 0; lastFramesLost = 0
    udpConfirmed = false; hadFrame = false
    bestRTT = .max
  }

  // MARK: finding the Mac

  /// Tries the Bonjour name and every known address at once; the first that completes the TLS handshake wins.
  private func attemptAll() {
    guard let p = pairing else { return }
    onEvent(.connecting)
    let g = generation
    for a in p.addresses { attempt(.hostPort(host: NWEndpoint.Host(a), port: NWEndpoint.Port(rawValue: p.port)!), p) }
    let b = NWBrowser(for: .bonjour(type: ClamshellProtocol.bonjourType, domain: nil), using: NWParameters())
    b.browseResultsChangedHandler = { [weak self] results, _ in
      guard let self, self.generation == g, self.control == nil else { return }
      for r in results { if case .service(let name, _, _, _) = r.endpoint, name == p.hostName { self.attempt(r.endpoint, p) } }
    }
    b.start(queue: queue)
    browser = b
    scheduleRetry(after: 5)
  }

  private func scheduleRetry(after s: TimeInterval) {
    retry?.cancel()
    let g = generation
    let w = DispatchWorkItem { [weak self] in
      guard let self, self.generation == g, self.control == nil else { return }
      self.attempts.forEach { $0.cancel() }; self.attempts = []
      self.browser?.cancel(); self.browser = nil
      self.attemptAll()
    }
    retry = w
    queue.asyncAfter(deadline: .now() + s, execute: w)
  }

  private func attempt(_ endpoint: NWEndpoint, _ p: PairingInfo) {
    let c = NWConnection(to: endpoint, using: Transport.controlParameters(secret: p.secret))
    let g = generation
    c.stateUpdateHandler = { [weak self, weak c] s in
      guard let self, let c, self.generation == g else { return }
      switch s {
      case .ready: self.won(c)
      case .failed(let e), .waiting(let e):
        if case .tls = e, self.control == nil { self.onEvent(.rejected) }
        if self.control === c { self.lost() }
      case .cancelled: if self.control === c { self.lost() }
      default: break
      }
    }
    attempts.append(c)
    c.start(queue: queue)
  }

  private func won(_ c: NWConnection) {
    guard control == nil else { c.cancel(); return }
    retry?.cancel()
    control = c
    attempts.filter { $0 !== c }.forEach { $0.cancel() }
    attempts = []
    browser?.cancel(); browser = nil
    readControl(c)
    let codecs: [VideoCodec] = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) ? [.hevc, .h264] : [.h264]
    send(.hello(deviceName: UIDeviceName.current, version: ClamshellProtocol.version, codecs: codecs))
  }

  /// The Mac went away: start looking again.
  private func lost() {
    let p = pairing
    teardown()
    pairing = p
    guard p != nil else { return }
    onEvent(.connecting)
    scheduleRetry(after: 1)
  }

  // MARK: control channel

  private func readControl(_ c: NWConnection) {
    c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
      guard let self, self.control === c else { return }
      if let data {
        for f in self.deframer.feed(data) {
          if case .json(let d) = f, let m = try? JSONDecoder().decode(HostMessage.self, from: d) { self.handle(m, on: c) }
        }
      }
      if done || error != nil { self.lost(); return }
      self.readControl(c)
    }
  }

  private func handle(_ m: HostMessage, on c: NWConnection) {
    if case let .welcome(host, key, port) = m {
      sealer = DatagramSealer(key: key, direction: .phoneToHost)
      opener = DatagramOpener(key: key, direction: .hostToPhone)
      onEvent(.welcome(host))
      openDatagrams(on: c, port: port)
    }
    if case .stream(let s) = m {
      // New encoder on the Mac: new parameter sets, and frame numbering stays with the session.
      surface?.reset()
      assembler = FrameAssembler()
      lastDuplicates = 0; lastFramesLost = 0
      lastKeyRequest = 0
      audio?.setEnabled(s.hasAudio)
      hadFrame = false
    }
    onEvent(.message(m))
  }

  func send(_ m: ClientMessage) {
    guard let d = try? JSONEncoder().encode(m) else { return }
    queue.async { [self] in control?.send(content: ControlFrame.json(d).encoded(), completion: .idempotent) }
  }

  func send(_ e: InputEvent, reliable: Bool) {
    queue.async { [self] in
      if !reliable, udpConfirmed, let sealed = sealer?.seal(.input, e.encoded()) {
        udp?.send(content: sealed, completion: .idempotent)
      } else {
        control?.send(content: ControlFrame.input(e).encoded(), completion: .idempotent)
      }
    }
  }

  // MARK: datagrams

  private func openDatagrams(on c: NWConnection, port: UInt16) {
    guard let nwPort = NWEndpoint.Port(rawValue: port), case .hostPort(let host, _)? = c.currentPath?.remoteEndpoint else { return }
    let u = NWConnection(host: host, port: nwPort, using: Transport.datagramParameters())
    udp = u
    u.start(queue: queue)
    readDatagrams(u)
    let t = DispatchSource.makeTimerSource(queue: queue)
    t.schedule(deadline: .now(), repeating: .milliseconds(4))
    t.setEventHandler { [weak self] in self?.tick() }
    t.resume()
    service = t
  }

  private func readDatagrams(_ u: NWConnection) {
    u.receiveMessage { [weak self] data, _, _, error in
      guard let self, self.udp === u else { return }
      if let data { self.handle(datagram: data) }
      if error == nil { self.readDatagrams(u) } else { self.queue.asyncAfter(deadline: .now() + 0.2) { if self.udp === u { self.readDatagrams(u) } } }
    }
  }

  private func handle(datagram: Data) {
    guard let (channel, payload) = opener?.open(datagram) else { return }
    let now = monotonicSeconds()
    switch channel {
    case .video:
      bytes += datagram.count
      guard let p = VideoPacket(payload) else { return }
      for frame in assembler.add(p, now: now) { deliver(frame) }
    case .audio: audio?.enqueue(payload)
    case .pong:
      udpConfirmed = true
      var r = ByteReader(payload)
      guard let sent = r.u64(), let hostTime = r.u64() else { return }
      let local = monotonicMicros()
      lastRTT = local &- sent
      // The fastest round trips give the truest clock offset between the two machines.
      if lastRTT < bestRTT || now - bestRTTAt > 10 {
        bestRTT = lastRTT; bestRTTAt = now
        clockOffset = Int64(hostTime) - Int64(sent + lastRTT / 2)
      }
    default: break
    }
  }

  private func deliver(_ frame: AssembledFrame) {
    guard let surface else { return }
    let needsReset = surface.enqueue(frame)
    if needsReset { requestKeyframe(now: monotonicSeconds()); return }
    frames += 1
    ageSum += Double(Int64(monotonicMicros()) + clockOffset - Int64(frame.captureMicros)) / 1000
    if !hadFrame { hadFrame = true; onEvent(.firstFrame) }
  }

  private func requestKeyframe(now: TimeInterval) {
    guard now - lastKeyRequest > 0.25 else { return }
    lastKeyRequest = now
    send(.requestKeyframe)
  }

  private func tick() {
    guard let u = udp else { return }
    let now = monotonicSeconds()
    if !udpConfirmed, now - lastHello > 0.2 {
      lastHello = now
      var w = ByteWriter(); w.u64(monotonicMicros())
      if let sealed = sealer?.seal(.hello, w.data) { u.send(content: sealed, completion: .idempotent) }
    }
    if udpConfirmed, now - lastPing > 0.5 {
      lastPing = now
      var w = ByteWriter(); w.u64(monotonicMicros())
      if let sealed = sealer?.seal(.ping, w.data) { u.send(content: sealed, completion: .idempotent) }
    }
    for n in assembler.service(now: now) {
      nacks += max(n.indices.count, 1)
      if let sealed = sealer?.seal(.nack, n.encoded()) { u.send(content: sealed, completion: .idempotent) }
    }
    if assembler.isWaitingForKeyframe, udpConfirmed, !assembler.isKeyframeArriving(now: now) { requestKeyframe(now: now) }
    if now - statsAt >= 1 {
      let age = frames > 0 ? ageSum / Double(frames) : 0
      onEvent(.stats(String(format: "%.0f ms network · %.0f ms capture→phone · %d fps · %.1f Mb/s%@", Double(lastRTT) / 1000, age, frames, Double(bytes) * 8 / 1_000_000, nacks > 0 ? " · \(nacks) resent" : "")))
      send(.stats(PhoneStats(rttMillis: Double(lastRTT) / 1000, ageMillis: age, framesShown: frames, packetsRequested: nacks,
        duplicates: assembler.duplicates - lastDuplicates, framesLost: assembler.framesLost - lastFramesLost)))
      lastDuplicates = assembler.duplicates; lastFramesLost = assembler.framesLost
      frames = 0; bytes = 0; ageSum = 0; nacks = 0; statsAt = now
    }
  }
}
