// The Mac's network side: one paired phone at a time.
import ClamshellCore
import Foundation
import Network

final class HostServer {
  let queue = DispatchQueue(label: "clamshell.net", qos: .userInteractive)
  var onHello: ((_ deviceName: String, _ codecs: [VideoCodec]) -> Void)?
  var onMessage: ((ClientMessage) -> Void)?
  var onInput: ((InputEvent) -> Void)?
  var onDatagramsReady: (() -> Void)?
  var onSessionEnded: (() -> Void)?
  var onListenerProblem: ((String) -> Void)?

  private let secret: Data, port: UInt16, serviceName: String?
  private var controlListener: NWListener?, datagramListener: NWListener?

  private final class Session {
    let control: NWConnection
    var udp: NWConnection?
    var sealer: DatagramSealer, opener: DatagramOpener
    var nextFrame: UInt32 = 1
    var retransmit = RetransmitBuffer(capacity: 32)
    init(control: NWConnection, key: Data) {
      self.control = control
      sealer = DatagramSealer(key: key, direction: .hostToPhone)
      opener = DatagramOpener(key: key, direction: .phoneToHost)
    }
  }
  private var session: Session?

  private let simulatedLoss: Double

  // Read from the UI once a second.
  private(set) var bytesSent: UInt64 = 0, framesSent: UInt64 = 0, packetsResent: UInt64 = 0, packetsSent: UInt64 = 0

  init(secret: Data, port: UInt16, serviceName: String?, simulatedLoss: Double = 0) {
    self.secret = secret; self.port = port; self.serviceName = serviceName; self.simulatedLoss = simulatedLoss
  }

  func start() {
    guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
    do {
      let control = try NWListener(using: Transport.controlParameters(secret: secret), on: nwPort)
      if let serviceName { control.service = NWListener.Service(name: serviceName, type: ClamshellProtocol.bonjourType) }
      control.newConnectionHandler = { [weak self] c in self?.acceptControl(c) }
      control.stateUpdateHandler = { [weak self] s in if case .failed(let e) = s { self?.onListenerProblem?("Couldn't listen on port \(self?.port ?? 0): \(e)") } }
      control.start(queue: queue)
      controlListener = control

      let udp = try NWListener(using: Transport.datagramParameters(), on: nwPort)
      udp.newConnectionHandler = { [weak self] c in self?.acceptDatagrams(c) }
      udp.stateUpdateHandler = { [weak self] s in if case .failed(let e) = s { self?.onListenerProblem?("Couldn't open UDP port \(self?.port ?? 0): \(e)") } }
      udp.start(queue: queue)
      datagramListener = udp
    } catch {
      onListenerProblem?("Couldn't start: \(error)")
    }
  }

  func disconnectPhone() { queue.async { [self] in session?.control.cancel() } }

  // MARK: control channel

  private func acceptControl(_ c: NWConnection) {
    var deframer = ControlDeframer()
    c.stateUpdateHandler = { [weak self, weak c] state in
      guard let self, let c else { return }
      switch state {
      case .failed, .cancelled: self.ended(c)
      default: break
      }
    }
    c.start(queue: queue)
    func read() {
      c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
        guard let self else { return }
        if let data {
          let frames = deframer.feed(data)
          if deframer.isCorrupt { c.cancel(); return }
          for f in frames { self.handle(f, from: c) }
        }
        if done || error != nil { c.cancel(); return }
        read()
      }
    }
    read()
  }

  private func handle(_ frame: ControlFrame, from c: NWConnection) {
    switch frame {
    case .input(let e):
      if session?.control === c { onInput?(e) }
    case .json(let d):
      guard let m = try? JSONDecoder().decode(ClientMessage.self, from: d) else { return }
      if case let .hello(name, version, codecs) = m {
        guard version == ClamshellProtocol.version else { c.cancel(); return }
        let previous = session
        let key = randomSessionKey()
        session = Session(control: c, key: key)
        previous?.control.cancel()
        previous?.udp?.cancel()
        send(.welcome(hostName: Host.current().localizedName ?? "Mac", sessionKey: key, udpPort: port))
        onHello?(name, codecs)
      } else if session?.control === c {
        onMessage?(m)
      }
    }
  }

  private func ended(_ c: NWConnection) {
    guard session?.control === c else { return }
    session?.udp?.cancel()
    session = nil
    onSessionEnded?()
  }

  func send(_ m: HostMessage) {
    queue.async { [self] in
      guard let s = session, let d = try? JSONEncoder().encode(m) else { return }
      s.control.send(content: ControlFrame.json(d).encoded(), completion: .idempotent)
    }
  }

  // MARK: datagrams

  private func acceptDatagrams(_ c: NWConnection) {
    c.start(queue: queue)
    func read() {
      c.receiveMessage { [weak self] data, _, _, error in
        guard let self else { return }
        if let data, !self.handle(datagram: data, from: c) { c.cancel(); return }
        if error == nil { read() }
      }
    }
    read()
  }

  /// False when the datagram doesn't authenticate and the sender isn't our current phone.
  private func handle(datagram: Data, from c: NWConnection) -> Bool {
    guard let s = session, let (channel, payload) = s.opener.open(datagram) else { return session?.udp === c }
    // The address that last proved it holds the key is where the stream goes, so a phone can change networks.
    let isNewPath = s.udp !== c
    if isNewPath { s.udp = c }
    switch channel {
    case .hello:
      sendDatagram(.pong, Self.pongPayload(payload), s)
      if isNewPath { onDatagramsReady?() }
    case .ping: sendDatagram(.pong, Self.pongPayload(payload), s)
    case .input: if let e = InputEvent(payload) { onInput?(e) }
    case .nack:
      if let n = Nack(payload) {
        let packets = s.retransmit.packets(for: n)
        packetsResent += UInt64(packets.count)
        for p in packets { sendDatagram(.video, p.encoded(), s) }
      }
    default: break
    }
    return true
  }

  /// Echoes the phone's clock and adds ours, so the phone can work out round trip and clock offset.
  private static func pongPayload(_ ping: Data) -> Data {
    var w = ByteWriter(); w.bytes(ping.prefix(8)); w.u64(monotonicMicros())
    return w.data
  }

  private func sendDatagram(_ ch: Channel, _ payload: Data, _ s: Session) {
    guard let udp = s.udp, let sealed = s.sealer.seal(ch, payload) else { return }
    if simulatedLoss > 0, ch == .video, Double.random(in: 0..<1) < simulatedLoss { return } // test mode only
    bytesSent += UInt64(sealed.count)
    udp.send(content: sealed, completion: .idempotent)
  }

  func sendVideo(payload: Data, isKeyframe: Bool, captureMicros: UInt64) {
    queue.async { [self] in
      guard let s = session, let udp = s.udp else { return }
      let packets = VideoPacket.split(frameID: s.nextFrame, isKeyframe: isKeyframe, captureMicros: captureMicros, data: payload)
      s.nextFrame &+= 1
      s.retransmit.remember(packets)
      framesSent += 1
      packetsSent += UInt64(packets.count)
      udp.batch { for p in packets { sendDatagram(.video, p.encoded(), s) } }
    }
  }

  func sendAudio(_ packet: Data) {
    queue.async { [self] in if let s = session { sendDatagram(.audio, packet, s) } }
  }
}
