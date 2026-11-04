import UIKit

struct Theme: Identifiable {
  var id: String, name: String, subtitle: String, vintage: Bool
  var outer, lid, bezel, deckTop, deckBottom, deckEdge, well, key, keyDown, legend, legendDim, pad, padDown, button, grille, accent: UIColor
  var rim: CGFloat, bezelWidth: CGFloat, bezelTop: CGFloat, screenRadius: CGFloat, frame: CGFloat, frameColor: UIColor, keyRadius: CGFloat, padRadius: CGFloat
  var singleButton = false

  private static func c(_ hex: UInt32) -> UIColor {
    UIColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
  }

  static let all: [Theme] = [
    Theme(id: "space", name: "Space Black", subtitle: "Pro · 2026", vintage: false, outer: c(0x0B0B0C), lid: c(0x050506), bezel: c(0x050506), deckTop: c(0x36383C), deckBottom: c(0x2B2D31), deckEdge: c(0x494B50),
      well: c(0x151618), key: c(0x0C0C0E), keyDown: c(0x2C2D31), legend: c(0xD9DADD), legendDim: c(0x8F9298), pad: c(0x3B3D42), padDown: c(0x46484E), button: c(0x3B3D42), grille: c(0x222222), accent: c(0x0A84FF),
      rim: 0, bezelWidth: 4, bezelTop: 12, screenRadius: 9, frame: 0, frameColor: .clear, keyRadius: 5, padRadius: 12),
    Theme(id: "silver", name: "Silver", subtitle: "Pro · 2026", vintage: false, outer: c(0x8D8F93), lid: c(0x050506), bezel: c(0x050506), deckTop: c(0xE6E7E9), deckBottom: c(0xD3D4D7), deckEdge: c(0xF4F4F5),
      well: c(0xB9BBBF), key: c(0x131416), keyDown: c(0x2E2F33), legend: c(0xEDEDEF), legendDim: c(0x9A9CA1), pad: c(0xCBCCD0), padDown: c(0xBFC0C4), button: c(0xCBCCD0), grille: c(0xAAAAAA), accent: c(0x0A84FF),
      rim: 0, bezelWidth: 4, bezelTop: 12, screenRadius: 9, frame: 0, frameColor: .clear, keyRadius: 5, padRadius: 12),
    Theme(id: "ivory", name: "Ivory", subtitle: "Putty portable · 1998", vintage: true, outer: c(0x3A362E), lid: c(0xE3DBC4), bezel: c(0xD8CFB5), deckTop: c(0xECE5D1), deckBottom: c(0xDCD3BB), deckEdge: c(0xF5F0E2),
      well: c(0xCDC3A8), key: c(0xF7F2E6), keyDown: c(0xDDD5BF), legend: c(0x5E584A), legendDim: c(0x8F8771), pad: c(0x6F6C66), padDown: c(0x5F5C56), button: c(0xE7DFCA), grille: c(0xA89F86), accent: c(0xB5722E),
      rim: 6, bezelWidth: 12, bezelTop: 14, screenRadius: 3, frame: 3, frameColor: c(0xA39A82), keyRadius: 3, padRadius: 5),
    Theme(id: "tide", name: "Tide", subtitle: "Candy clamshell · 1999", vintage: true, outer: c(0x06302F), lid: c(0x17A6A0), bezel: c(0xF3F5F4), deckTop: c(0xF7F9F8), deckBottom: c(0xE7ECEA), deckEdge: c(0x17A6A0),
      well: c(0xDBE3E1), key: c(0xFFFFFF), keyDown: c(0xE2E9E7), legend: c(0x2F3E3C), legendDim: c(0x7B8987), pad: c(0x17A6A0), padDown: c(0x12908B), button: c(0xF4F1E6), grille: c(0x17A6A0), accent: c(0x17A6A0),
      rim: 7, bezelWidth: 11, bezelTop: 14, screenRadius: 8, frame: 2, frameColor: c(0x17A6A0), keyRadius: 4, padRadius: 14, singleButton: true),
    Theme(id: "ember", name: "Ember", subtitle: "Candy clamshell · 1999", vintage: true, outer: c(0x3A1606), lid: c(0xEF6A2C), bezel: c(0xF6F3EF), deckTop: c(0xFAF7F4), deckBottom: c(0xEDE6DF), deckEdge: c(0xEF6A2C),
      well: c(0xE7DDD4), key: c(0xFFFFFF), keyDown: c(0xEFE6DD), legend: c(0x47362C), legendDim: c(0x8F7D70), pad: c(0xEF6A2C), padDown: c(0xD65A20), button: c(0xF6F1E8), grille: c(0xEF6A2C), accent: c(0xEF6A2C),
      rim: 7, bezelWidth: 11, bezelTop: 14, screenRadius: 8, frame: 2, frameColor: c(0xEF6A2C), keyRadius: 4, padRadius: 14, singleButton: true),
  ]

  static func named(_ id: String) -> Theme { all.first { $0.id == id } ?? all[0] }
}
