// Bitrate control on the Mac.
import Foundation

/// Adjusts the encoder to the connection. Reacts only to real trouble: Wi-Fi has momentary hiccups that
/// retransmits already handle, and cutting the bitrate for those costs more picture than it saves.
public struct RateController {
  public private(set) var target: Int
  public let maximum: Int, minimum: Int
  private var lossyWindows = 0, calmWindows = 0, holdUntil: TimeInterval = 0

  public init(maximum: Int) { self.maximum = maximum; minimum = min(1_500_000, maximum); target = maximum }

  /// Call about once a second. `framesLost` is frames that couldn't be recovered at all. Returns the new bitrate when it should change.
  public mutating func update(sentPackets: Int, resentPackets: Int, framesLost: Int, now: TimeInterval) -> Int? {
    let lossy = sentPackets >= 50 && Double(resentPackets) / Double(sentPackets) > 0.05
    lossyWindows = lossy ? lossyWindows + 1 : 0
    if framesLost > 0 || lossyWindows >= 2 {
      calmWindows = 0
      guard now >= holdUntil else { return nil } // give the last cut time to take effect
      holdUntil = now + 1.5
      return set(Int(Double(target) * 0.8))
    }
    // Idle windows say nothing about the connection.
    guard !lossy, sentPackets >= 50, target < maximum else { return nil }
    calmWindows += 1
    guard calmWindows >= 3 else { return nil }
    calmWindows = 0
    return set(Int(Double(target) * 1.1))
  }

  private mutating func set(_ value: Int) -> Int? {
    let v = min(maximum, max(minimum, value))
    guard v != target else { return nil }
    target = v
    return v
  }
}
