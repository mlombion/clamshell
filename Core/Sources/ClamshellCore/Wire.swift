// What travels between the iPhone and the Mac.
//
// TCP + TLS-PSK ("control"): pairing secret authenticates both ends. Carries JSON control messages
//   and order-sensitive input (keys, clicks, scroll phases).
// UDP + AES-GCM ("datagrams"): video, audio, pointer motion, NACKs and pings. The key is random per
//   session and delivered over the control channel.
import Foundation

public enum ClamshellProtocol {
  public static let version = 1
  public static let defaultPort: UInt16 = 47800
  public static let bonjourType = "_clamshell._tcp"
  public static let pskIdentity = "clamshell"
  public static let maxDatagram = 1200
}

public enum Quality: String, Codable, CaseIterable, Sendable {
  case speed, balanced, sharp
  public var title: String { rawValue.capitalized }
  public var maxWidth: Int { switch self { case .speed: 1280; case .balanced: 1920; case .sharp: 3456 } }
  public var bitrate: Int { switch self { case .speed: 6_000_000; case .balanced: 14_000_000; case .sharp: 40_000_000 } }
}

public enum VideoCodec: String, Codable, Sendable { case hevc, h264 }

public struct DisplayInfo: Codable, Equatable, Identifiable, Sendable {
  public var id: UInt32, name: String, width: Int, height: Int, isMain: Bool
  public init(id: UInt32, name: String, width: Int, height: Int, isMain: Bool) {
    self.id = id; self.name = name; self.width = width; self.height = height; self.isMain = isMain
  }
}

public struct StreamInfo: Codable, Equatable, Sendable {
  public var width: Int, height: Int, codec: VideoCodec, displayID: UInt32, quality: Quality, hasAudio: Bool
  public init(width: Int, height: Int, codec: VideoCodec, displayID: UInt32, quality: Quality, hasAudio: Bool) {
    self.width = width; self.height = height; self.codec = codec; self.displayID = displayID; self.quality = quality; self.hasAudio = hasAudio
  }
}

/// What the phone sees, once a second. Only the phone can measure these.
public struct PhoneStats: Codable, Equatable, Sendable {
  public var rttMillis: Double, ageMillis: Double, framesShown: Int, packetsRequested: Int, duplicates: Int, framesLost: Int
  public init(rttMillis: Double, ageMillis: Double, framesShown: Int, packetsRequested: Int, duplicates: Int, framesLost: Int) {
    self.rttMillis = rttMillis; self.ageMillis = ageMillis; self.framesShown = framesShown
    self.packetsRequested = packetsRequested; self.duplicates = duplicates; self.framesLost = framesLost
  }
}

public enum ClientMessage: Codable, Equatable, Sendable {
  case hello(deviceName: String, version: Int, codecs: [VideoCodec])
  case setQuality(Quality)
  case selectDisplay(UInt32)
  case requestKeyframe
  case setAudio(Bool)
  case stats(PhoneStats)
}

public enum HostMessage: Codable, Equatable, Sendable {
  case welcome(hostName: String, sessionKey: Data, udpPort: UInt16)
  case displays([DisplayInfo], active: UInt32)
  case stream(StreamInfo)
  case frontApp(id: String, name: String)
  case problem(String)
}

// MARK: - Input events

public enum InputEvent: Equatable, Sendable {
  case move(dx: Float, dy: Float)
  /// Absolute position, normalized 0…1 on the streamed display.
  case moveTo(x: Float, y: Float)
  case button(index: UInt8, down: Bool)
  /// Pixel scroll carrying macOS scroll phase (1 began, 2 changed, 4 ended) and momentum phase (1 begin, 2 continue, 3 end).
  case scroll(dx: Int32, dy: Int32, phase: UInt8, momentum: UInt8)
  case key(code: UInt16, down: Bool, isRepeat: Bool)
  case systemKey(code: UInt8, down: Bool)
  case releaseAll

  /// Motion is safe to lose, so it travels by datagram; everything else must arrive in order.
  public var isMotion: Bool { switch self { case .move, .moveTo: true; default: false } }

  public func encoded() -> Data {
    var w = ByteWriter()
    switch self {
    case let .move(dx, dy): w.u8(1); w.f32(dx); w.f32(dy)
    case let .moveTo(x, y): w.u8(2); w.f32(x); w.f32(y)
    case let .button(i, d): w.u8(3); w.u8(i); w.u8(d ? 1 : 0)
    case let .scroll(dx, dy, p, m): w.u8(4); w.i32(dx); w.i32(dy); w.u8(p); w.u8(m)
    case let .key(c, d, r): w.u8(5); w.u16(c); w.u8(d ? 1 : 0); w.u8(r ? 1 : 0)
    case let .systemKey(c, d): w.u8(6); w.u8(c); w.u8(d ? 1 : 0)
    case .releaseAll: w.u8(7)
    }
    return w.data
  }

  public init?(_ data: Data) {
    var r = ByteReader(data)
    guard let tag = r.u8() else { return nil }
    switch tag {
    case 1: guard let a = r.f32(), let b = r.f32(), a.isFinite, b.isFinite else { return nil }; self = .move(dx: a, dy: b)
    case 2: guard let a = r.f32(), let b = r.f32(), a.isFinite, b.isFinite else { return nil }; self = .moveTo(x: a, y: b)
    case 3: guard let i = r.u8(), let d = r.u8() else { return nil }; self = .button(index: i, down: d == 1)
    case 4: guard let a = r.i32(), let b = r.i32(), let p = r.u8(), let m = r.u8() else { return nil }; self = .scroll(dx: a, dy: b, phase: p, momentum: m)
    case 5: guard let c = r.u16(), let d = r.u8(), let e = r.u8() else { return nil }; self = .key(code: c, down: d == 1, isRepeat: e == 1)
    case 6: guard let c = r.u8(), let d = r.u8() else { return nil }; self = .systemKey(code: c, down: d == 1)
    case 7: self = .releaseAll
    default: return nil
    }
  }
}

// MARK: - TCP framing: [u32 length][u8 kind][payload]

public enum ControlFrame: Equatable, Sendable {
  case json(Data), input(InputEvent)

  public func encoded() -> Data {
    var body = Data()
    switch self {
    case .json(let d): body.append(1); body.append(d)
    case .input(let e): body.append(2); body.append(e.encoded())
    }
    var w = ByteWriter(); w.u32(UInt32(body.count))
    return w.data + body
  }
}

public struct ControlDeframer {
  private var buffer = Data()
  public static let maxFrame = 1 << 20
  public private(set) var isCorrupt = false
  public init() {}

  public mutating func feed(_ data: Data) -> [ControlFrame] {
    buffer.append(data)
    var out: [ControlFrame] = []
    while buffer.count >= 4 && !isCorrupt {
      let s = buffer.startIndex
      let len = Int(buffer[s]) << 24 | Int(buffer[s + 1]) << 16 | Int(buffer[s + 2]) << 8 | Int(buffer[s + 3])
      guard len >= 1, len <= Self.maxFrame else { isCorrupt = true; break }
      guard buffer.count >= 4 + len else { break }
      let kind = buffer[s + 4]
      let payload = Data(buffer[(s + 5)..<(s + 4 + len)])
      buffer = Data(buffer[(s + 4 + len)...])
      switch kind {
      case 1: out.append(.json(payload))
      case 2: if let e = InputEvent(payload) { out.append(.input(e)) }
      default: break
      }
    }
    return out
  }
}

// MARK: - Bytes

public struct ByteWriter {
  public private(set) var data = Data()
  public init() {}
  public mutating func u8(_ v: UInt8) { data.append(v) }
  public mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
  public mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
  public mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
  public mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
  public mutating func f32(_ v: Float) { u32(v.bitPattern) }
  public mutating func bytes(_ d: Data) { data.append(d) }
}

public struct ByteReader {
  private let data: Data
  private var i: Data.Index
  public init(_ d: Data) { data = d; i = d.startIndex }
  public var remaining: Data { Data(data[i...]) }
  private mutating func take<T: FixedWidthInteger>(_: T.Type) -> T? {
    let n = MemoryLayout<T>.size
    guard data.distance(from: i, to: data.endIndex) >= n else { return nil }
    var v: T = 0
    for b in data[i..<(i + n)] { v = (v << 8) | T(b) }
    i += n
    return v
  }
  public mutating func u8() -> UInt8? { take(UInt8.self) }
  public mutating func u16() -> UInt16? { take(UInt16.self) }
  public mutating func u32() -> UInt32? { take(UInt32.self) }
  public mutating func u64() -> UInt64? { take(UInt64.self) }
  public mutating func i32() -> Int32? { u32().map { Int32(bitPattern: $0) } }
  public mutating func f32() -> Float? { u32().map { Float(bitPattern: $0) } }
}
