// The one-time pairing link shown as a QR code on the Mac.
// clamshell://pair?v=1&k=<base64url secret>&n=<mac name>&p=<port>&h=<address,address>
import Foundation

public struct PairingInfo: Equatable, Codable, Sendable {
  public var secret: Data, hostName: String, port: UInt16, addresses: [String]
  public init(secret: Data, hostName: String, port: UInt16, addresses: [String]) {
    self.secret = secret; self.hostName = hostName; self.port = port; self.addresses = addresses
  }

  public var url: URL {
    var c = URLComponents()
    c.scheme = "clamshell"; c.host = "pair"
    c.queryItems = [
      .init(name: "v", value: "1"), .init(name: "k", value: secret.base64URL), .init(name: "n", value: hostName),
      .init(name: "p", value: String(port)), .init(name: "h", value: addresses.joined(separator: ",")),
    ]
    return c.url!
  }

  public init?(url: URL) {
    guard url.scheme == "clamshell", url.host == "pair",
      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
    func q(_ n: String) -> String? { items.first { $0.name == n }?.value }
    guard let k = q("k"), let secret = Data(base64URL: k), secret.count >= 16 else { return nil }
    self.init(secret: secret, hostName: q("n") ?? "Mac", port: q("p").flatMap(UInt16.init) ?? ClamshellProtocol.defaultPort,
      addresses: (q("h") ?? "").split(separator: ",").map(String.init))
  }
}

extension Data {
  public var base64URL: String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
  public init?(base64URL s: String) {
    var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while b.count % 4 != 0 { b += "=" }
    self.init(base64Encoded: b)
  }
}
