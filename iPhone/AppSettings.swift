import ClamshellCore
import Foundation
import Security
import UIKit

enum UIDeviceName { static var current: String { UIDevice.current.name } }

final class AppSettings: ObservableObject {
  private let d = UserDefaults.standard
  @Published var theme: String { didSet { d.set(theme, forKey: "theme") } }
  /// "auto" or a ProfileID.
  @Published var profile: String { didSet { d.set(profile, forKey: "profile") } }
  @Published var pointerSpeed: Double { didSet { d.set(pointerSpeed, forKey: "pointerSpeed") } }
  @Published var scrollSpeed: Double { didSet { d.set(scrollSpeed, forKey: "scrollSpeed") } }
  @Published var natural: Bool { didSet { d.set(natural, forKey: "natural") } }
  @Published var haptics: Bool { didSet { d.set(haptics, forKey: "haptics") } }
  @Published var keyClicks: Bool { didSet { d.set(keyClicks, forKey: "keyClicks") } }
  @Published var sound: Bool { didSet { d.set(sound, forKey: "sound") } }
  @Published var quality: Quality { didSet { d.set(quality.rawValue, forKey: "quality") } }
  /// In landscape: touch where you want to click, or use the whole screen as a trackpad.
  @Published var landscapeTrackpad: Bool { didSet { d.set(landscapeTrackpad, forKey: "landscapeTrackpad") } }
  /// Open the phone flat and the keyboard gives way to a full trackpad.
  @Published var trackpadWhenFlat: Bool { didSet { d.set(trackpadWhenFlat, forKey: "trackpadWhenFlat") } }

  init() {
    d.register(defaults: ["theme": "space", "profile": "auto", "pointerSpeed": 1.0, "scrollSpeed": 1.0, "natural": true, "haptics": true, "keyClicks": false, "sound": true, "quality": Quality.balanced.rawValue, "landscapeTrackpad": false, "trackpadWhenFlat": true])
    theme = d.string(forKey: "theme") ?? "space"
    profile = d.string(forKey: "profile") ?? "auto"
    pointerSpeed = d.double(forKey: "pointerSpeed")
    scrollSpeed = d.double(forKey: "scrollSpeed")
    natural = d.bool(forKey: "natural")
    haptics = d.bool(forKey: "haptics")
    keyClicks = d.bool(forKey: "keyClicks")
    sound = d.bool(forKey: "sound")
    quality = Quality(rawValue: d.string(forKey: "quality") ?? "") ?? .balanced
    landscapeTrackpad = d.bool(forKey: "landscapeTrackpad")
    trackpadWhenFlat = d.bool(forKey: "trackpadWhenFlat")
  }
}

/// The pairing secret lives in the iPhone's Keychain, on this device only.
enum PairingKeychain {
  private static let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "Clamshell pairing", kSecAttrAccount: "mac"]

  static func load() -> PairingInfo? {
    var q = query
    q[kSecReturnData] = true
    var r: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess, let d = r as? Data else { return nil }
    return try? JSONDecoder().decode(PairingInfo.self, from: d)
  }

  static func save(_ p: PairingInfo) {
    guard let d = try? JSONEncoder().encode(p) else { return }
    SecItemDelete(query as CFDictionary)
    var q = query
    q[kSecValueData] = d
    q[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    SecItemAdd(q as CFDictionary, nil)
  }

  static func clear() { SecItemDelete(query as CFDictionary) }
}
