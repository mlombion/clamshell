// Sealed UDP datagrams and the video packet layer on top of them.
import CryptoKit
import Foundation

public enum Channel: UInt8, Sendable { case video = 0, audio = 1, input = 2, nack = 3, ping = 4, pong = 5, hello = 6 }
public enum Direction: UInt32, Sendable { case hostToPhone = 0, phoneToHost = 1 }

/// Layout: [channel u8][seq u64] ciphertext tag. The header is authenticated; the nonce is direction + seq,
/// so it can never repeat for one key as long as each direction has one sealer.
public struct DatagramSealer {
  private let key: SymmetricKey
  private let direction: Direction
  private var seq: UInt64 = 0
  public static let overhead = 9 + 16

  public init(key: Data, direction: Direction) { self.key = SymmetricKey(data: key); self.direction = direction }

  public mutating func seal(_ channel: Channel, _ payload: Data) -> Data? {
    seq += 1
    var header = ByteWriter(); header.u8(channel.rawValue); header.u64(seq)
    guard let nonce = makeNonce(direction, seq),
      let box = try? AES.GCM.seal(payload, using: key, nonce: nonce, authenticating: header.data) else { return nil }
    return header.data + box.ciphertext + box.tag
  }
}

public struct DatagramOpener {
  private let key: SymmetricKey
  private let direction: Direction
  private var highest: UInt64 = 0
  // One bit per recent sequence number. Wide enough that Wi-Fi reordering at full bitrate is never mistaken for a replay.
  private var seen = [UInt64](repeating: 0, count: Self.windowWords)
  private static let windowWords = 64
  private static let windowBits = UInt64(windowWords * 64)

  public init(key: Data, direction: Direction) { self.key = SymmetricKey(data: key); self.direction = direction }

  public mutating func open(_ datagram: Data) -> (channel: Channel, payload: Data)? {
    guard datagram.count >= DatagramSealer.overhead else { return nil }
    var r = ByteReader(datagram)
    guard let rawChannel = r.u8(), let channel = Channel(rawValue: rawChannel), let seq = r.u64() else { return nil }
    guard !isReplay(seq), let nonce = makeNonce(direction, seq) else { return nil }
    let s = datagram.startIndex
    let header = datagram[s..<(s + 9)]
    let ciphertext = datagram[(s + 9)..<(datagram.endIndex - 16)]
    let tag = datagram[(datagram.endIndex - 16)...]
    guard let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag),
      let plain = try? AES.GCM.open(box, using: key, authenticating: header) else { return nil }
    record(seq)
    return (channel, plain)
  }

  private func slot(_ seq: UInt64) -> (word: Int, mask: UInt64) {
    let bit = seq % Self.windowBits
    return (Int(bit / 64), UInt64(1) << (bit % 64))
  }

  private func isReplay(_ seq: UInt64) -> Bool {
    if seq == 0 { return true }
    if seq > highest { return false }
    if highest - seq >= Self.windowBits { return true }
    let (w, m) = slot(seq)
    return seen[w] & m != 0
  }

  private mutating func record(_ seq: UInt64) {
    if seq > highest {
      if seq - highest >= Self.windowBits {
        seen = [UInt64](repeating: 0, count: Self.windowWords)
      } else {
        var n = highest + 1 // slots being reused now describe newer sequence numbers
        while n < seq { let (w, m) = slot(n); seen[w] &= ~m; n += 1 }
      }
      highest = seq
    }
    let (w, m) = slot(seq)
    seen[w] |= m
  }
}

private func makeNonce(_ d: Direction, _ seq: UInt64) -> AES.GCM.Nonce? {
  var w = ByteWriter(); w.u32(d.rawValue); w.u64(seq)
  return try? AES.GCM.Nonce(data: w.data)
}

public func randomSessionKey() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }

// MARK: - Video packets

public struct VideoPacket: Equatable, Sendable {
  public var frameID: UInt32, index: UInt16, count: UInt16, isKeyframe: Bool, captureMicros: UInt64, chunk: Data
  public static let headerSize = 17
  public static let maxChunk = ClamshellProtocol.maxDatagram - DatagramSealer.overhead - headerSize

  public init(frameID: UInt32, index: UInt16, count: UInt16, isKeyframe: Bool, captureMicros: UInt64, chunk: Data) {
    self.frameID = frameID; self.index = index; self.count = count; self.isKeyframe = isKeyframe; self.captureMicros = captureMicros; self.chunk = chunk
  }

  public func encoded() -> Data {
    var w = ByteWriter()
    w.u32(frameID); w.u16(index); w.u16(count); w.u8(isKeyframe ? 1 : 0); w.u64(captureMicros); w.bytes(chunk)
    return w.data
  }

  public init?(_ d: Data) {
    var r = ByteReader(d)
    guard let f = r.u32(), let i = r.u16(), let c = r.u16(), let k = r.u8(), let t = r.u64(), c > 0, i < c else { return nil }
    self.init(frameID: f, index: i, count: c, isKeyframe: k & 1 == 1, captureMicros: t, chunk: r.remaining)
  }

  /// Splits one encoded frame into datagram-sized packets.
  public static func split(frameID: UInt32, isKeyframe: Bool, captureMicros: UInt64, data: Data) -> [VideoPacket] {
    let n = max(1, (data.count + maxChunk - 1) / maxChunk)
    return (0..<n).map { i in
      let start = data.startIndex + i * maxChunk
      let end = min(start + maxChunk, data.endIndex)
      return VideoPacket(frameID: frameID, index: UInt16(i), count: UInt16(n), isKeyframe: isKeyframe, captureMicros: captureMicros, chunk: Data(data[start..<end]))
    }
  }
}

public struct AssembledFrame: Equatable, Sendable {
  public var frameID: UInt32, isKeyframe: Bool, captureMicros: UInt64, data: Data
}

/// "Please resend": empty `indices` means the whole frame never showed up.
public struct Nack: Equatable, Sendable {
  public var frameID: UInt32, indices: [UInt16]
  public init(frameID: UInt32, indices: [UInt16]) { self.frameID = frameID; self.indices = indices }
  public func encoded() -> Data {
    var w = ByteWriter(); w.u32(frameID); w.u16(UInt16(indices.count)); indices.forEach { w.u16($0) }
    return w.data
  }
  public init?(_ d: Data) {
    var r = ByteReader(d)
    guard let f = r.u32(), let n = r.u16() else { return nil }
    var idx: [UInt16] = []
    for _ in 0..<n { guard let i = r.u16() else { return nil }; idx.append(i) }
    self.init(frameID: f, indices: idx)
  }
}

/// Rebuilds frames from packets and hands them out strictly in order, because each frame depends on
/// the one before it. A packet only counts as missing when there's evidence: a later packet of the frame
/// has arrived, a later frame has, or the frame has gone quiet. Age alone proves nothing, since a frame
/// can legitimately take longer than a round trip to arrive. If a retransmit doesn't come in time it gives
/// up, asks for a new keyframe and waits for one, rather than showing a corrupted picture.
public struct FrameAssembler {
  private struct Partial {
    var parts: [Data?]; var received = 0; var isKeyframe: Bool; var captureMicros: UInt64
    var lastArrival: TimeInterval; var lastNack: TimeInterval = -.infinity; var highest = -1; var gapSince: TimeInterval?
    var isComplete: Bool { received == parts.count }
    var hasGap: Bool { highest >= 0 && parts[0...highest].contains { $0 == nil } }
  }
  private struct Absent { var firstSeen: TimeInterval; var lastNack: TimeInterval = -.infinity }

  private var partials: [UInt32: Partial] = [:]
  private var absent: [UInt32: Absent] = [:]
  private var next: UInt32? = nil // next frame to deliver; nil = waiting for a keyframe
  private var newest: UInt32 = 0
  public var gapDelay: TimeInterval = 0.005    // allows for slight reordering
  public var quietDelay: TimeInterval = 0.030  // a frame stopped arriving: its tail was lost
  public var nackInterval: TimeInterval = 0.040
  public var giveUpAfter: TimeInterval = 0.200 // with no progress at all
  public private(set) var duplicates = 0, framesLost = 0

  public init() {}
  public var isWaitingForKeyframe: Bool { next == nil }
  /// A keyframe is on its way, so asking for another would only add to the flood.
  public func isKeyframeArriving(now: TimeInterval) -> Bool {
    partials.values.contains { $0.isKeyframe && now - $0.lastArrival < giveUpAfter }
  }

  public mutating func add(_ p: VideoPacket, now: TimeInterval) -> [AssembledFrame] {
    if let n = next, p.frameID < n { duplicates += 1; return [] } // a resend we no longer need
    var f = partials[p.frameID] ?? Partial(parts: Array(repeating: nil, count: Int(p.count)), isKeyframe: p.isKeyframe, captureMicros: p.captureMicros, lastArrival: now)
    guard Int(p.index) < f.parts.count, f.parts.count == Int(p.count) else { return [] }
    guard f.parts[Int(p.index)] == nil else { duplicates += 1; return [] }
    f.parts[Int(p.index)] = p.chunk
    f.received += 1
    f.lastArrival = now
    f.highest = max(f.highest, Int(p.index))
    if f.hasGap { f.gapSince = f.gapSince ?? now } else { f.gapSince = nil }
    partials[p.frameID] = f
    absent[p.frameID] = nil

    // Frames we've jumped past without seeing a single packet.
    if let n = next, p.frameID > newest {
      var id = max(n, newest &+ 1)
      while id < p.frameID { if partials[id] == nil && absent[id] == nil { absent[id] = Absent(firstSeen: now) }; id &+= 1 }
    }
    newest = max(newest, p.frameID)
    return drain()
  }

  private mutating func drain() -> [AssembledFrame] {
    var out: [AssembledFrame] = []
    // A complete keyframe resets the chain: skip anything still missing before it.
    if let key = partials.filter({ $0.value.isComplete && $0.value.isKeyframe && (next == nil || $0.key >= next!) }).keys.max() {
      if next == nil || key > next! { next = key }
    }
    while let n = next, let f = partials[n], f.isComplete {
      out.append(AssembledFrame(frameID: n, isKeyframe: f.isKeyframe, captureMicros: f.captureMicros, data: f.parts.reduce(into: Data()) { $0.append($1!) }))
      partials[n] = nil
      next = n &+ 1
    }
    if let n = next {
      partials = partials.filter { $0.key >= n }
      absent = absent.filter { $0.key >= n }
    }
    return out
  }

  /// Call often (every few ms). Returns resend requests, and falls back to waiting for a keyframe when a frame is unrecoverable.
  public mutating func service(now: TimeInterval) -> [Nack] {
    // While waiting for a keyframe only keyframes matter, and they're worth rescuing: one is hundreds of
    // packets, so on a lossy link it would almost never arrive whole by itself.
    let waiting = next == nil
    if waiting { partials = partials.filter { now - $0.value.lastArrival < 1 } }
    var nacks: [Nack] = []
    for id in partials.keys.sorted() {
      guard var f = partials[id], !f.isComplete, !waiting || f.isKeyframe else { continue }
      if now - f.lastArrival > giveUpAfter {
        if waiting { continue } // the phone's keyframe request covers this
        giveUp(); return []
      }
      guard now - f.lastNack >= nackInterval else { continue }
      let quiet = now - f.lastArrival >= quietDelay || id < newest
      let gapAged = f.gapSince.map { now - $0 >= gapDelay } ?? false
      guard quiet || gapAged else { continue }
      // Quiet: everything missing is overdue. Otherwise only what's below the newest packet we've seen.
      let upTo = quiet ? f.parts.count - 1 : f.highest
      let missing = (0...upTo).filter { f.parts[$0] == nil }.map { UInt16($0) }
      guard !missing.isEmpty else { continue }
      f.lastNack = now
      partials[id] = f
      nacks.append(Nack(frameID: id, indices: missing))
    }
    for id in absent.keys.sorted() {
      guard var a = absent[id] else { continue }
      if now - a.firstSeen > giveUpAfter { giveUp(); return [] }
      if now - a.firstSeen >= gapDelay, now - a.lastNack >= nackInterval {
        a.lastNack = now
        absent[id] = a
        nacks.append(Nack(frameID: id, indices: []))
      }
    }
    return nacks
  }

  private mutating func giveUp() {
    next = nil
    framesLost += 1
    absent = [:]
    partials = partials.filter { $0.value.isKeyframe }
  }
}

/// Host side: remembers recent packets so NACKs can be answered.
public struct RetransmitBuffer {
  private var frames: [UInt32: [VideoPacket]] = [:]
  private var order: [UInt32] = []
  private let capacity: Int
  public init(capacity: Int = 32) { self.capacity = capacity }

  public mutating func remember(_ packets: [VideoPacket]) {
    guard let id = packets.first?.frameID else { return }
    frames[id] = packets
    order.append(id)
    while order.count > capacity { frames[order.removeFirst()] = nil }
  }

  public func packets(for nack: Nack) -> [VideoPacket] {
    guard let f = frames[nack.frameID] else { return [] }
    return nack.indices.isEmpty ? f : nack.indices.compactMap { Int($0) < f.count ? f[Int($0)] : nil }
  }
}

// MARK: - Encoded frame payload: optional parameter sets, then length-prefixed NAL units as VideoToolbox emits them

public struct FramePayload: Equatable, Sendable {
  public var parameterSets: [Data], units: Data
  public init(parameterSets: [Data], units: Data) { self.parameterSets = parameterSets; self.units = units }

  public func encoded() -> Data {
    var w = ByteWriter()
    w.u8(UInt8(parameterSets.count))
    for p in parameterSets { w.u16(UInt16(p.count)); w.bytes(p) }
    w.bytes(units)
    return w.data
  }

  public init?(_ d: Data) {
    var r = ByteReader(d)
    guard let n = r.u8() else { return nil }
    var sets: [Data] = []
    var offset = 1
    for _ in 0..<n {
      guard let len = r.u16() else { return nil }
      offset += 2
      let s = d.startIndex + offset
      guard s + Int(len) <= d.endIndex else { return nil }
      sets.append(Data(d[s..<(s + Int(len))]))
      offset += Int(len)
      r = ByteReader(Data(d[(s + Int(len))...]))
    }
    self.init(parameterSets: sets, units: Data(d[(d.startIndex + offset)...]))
  }
}
