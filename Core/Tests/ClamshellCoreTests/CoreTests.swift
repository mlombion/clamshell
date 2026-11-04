import XCTest
@testable import ClamshellCore

final class TransportTests: XCTestCase {
  func testSealRoundTripAndTamperAndReplay() {
    let key = randomSessionKey()
    var sealer = DatagramSealer(key: key, direction: .hostToPhone)
    var opener = DatagramOpener(key: key, direction: .hostToPhone)
    let d = sealer.seal(.video, Data("hello".utf8))!
    let r = opener.open(d)
    XCTAssertEqual(r?.channel, .video); XCTAssertEqual(r?.payload, Data("hello".utf8))
    XCTAssertNil(opener.open(d), "replay must be rejected")
    var bad = sealer.seal(.video, Data("x".utf8))!; bad[bad.count - 1] ^= 1
    XCTAssertNil(opener.open(bad), "tampered tag must be rejected")
    var other = DatagramOpener(key: randomSessionKey(), direction: .hostToPhone)
    XCTAssertNil(other.open(sealer.seal(.audio, Data())!), "wrong key must be rejected")
    var wrongWay = DatagramOpener(key: key, direction: .phoneToHost)
    XCTAssertNil(wrongWay.open(sealer.seal(.audio, Data())!), "reflected packets must be rejected")
  }

  func testOutOfOrderDatagramsAccepted() {
    let key = randomSessionKey()
    var s = DatagramSealer(key: key, direction: .phoneToHost), o = DatagramOpener(key: key, direction: .phoneToHost)
    let a = s.seal(.input, Data([1]))!, b = s.seal(.input, Data([2]))!, c = s.seal(.input, Data([3]))!
    XCTAssertEqual(o.open(c)?.payload, Data([3])); XCTAssertEqual(o.open(a)?.payload, Data([1])); XCTAssertEqual(o.open(b)?.payload, Data([2]))
    XCTAssertNil(o.open(a))
  }

  func testHeavyReorderingIsNotAReplay() {
    let key = randomSessionKey()
    var s = DatagramSealer(key: key, direction: .hostToPhone), o = DatagramOpener(key: key, direction: .hostToPhone)
    let all = (0..<6000).map { _ in s.seal(.video, Data([1]))! }
    XCTAssertNotNil(o.open(all[5000]))
    XCTAssertNotNil(o.open(all[4500]), "500 packets late is still fine")
    XCTAssertNil(o.open(all[4500]), "but only once")
    XCTAssertNotNil(o.open(all[5999]))
    XCTAssertNil(o.open(all[0]), "too old to track")
    XCTAssertNil(o.open(all[5999]))
    XCTAssertNotNil(o.open(all[5998]))
    // Slots get reused as the window slides.
    var last = all[5999]
    for _ in 0..<5000 { last = s.seal(.video, Data([2]))!; XCTAssertNotNil(o.open(last)) }
    XCTAssertNil(o.open(last))
  }

  func testRateControllerIgnoresAHiccupButBacksOffOnSustainedLoss() {
    var r = RateController(maximum: 10_000_000)
    XCTAssertNil(r.update(sentPackets: 1000, resentPackets: 5, framesLost: 0, now: 0), "already at maximum")
    XCTAssertNil(r.update(sentPackets: 1000, resentPackets: 100, framesLost: 0, now: 1), "one bad second is a Wi-Fi hiccup")
    XCTAssertNil(r.update(sentPackets: 1000, resentPackets: 0, framesLost: 0, now: 2))
    XCTAssertNil(r.update(sentPackets: 1000, resentPackets: 100, framesLost: 0, now: 3))
    XCTAssertEqual(r.update(sentPackets: 1000, resentPackets: 100, framesLost: 0, now: 4), 8_000_000, "two in a row is real")
    XCTAssertNil(r.update(sentPackets: 1000, resentPackets: 100, framesLost: 0, now: 5), "lets the last cut take effect")
    XCTAssertEqual(r.update(sentPackets: 1000, resentPackets: 100, framesLost: 0, now: 6), 6_400_000)
    XCTAssertEqual(r.update(sentPackets: 1000, resentPackets: 0, framesLost: 1, now: 8), 5_120_000, "an unrecoverable frame counts at once")
  }

  func testRateControllerRecoversSlowlyAndKeepsItsLimits() {
    var r = RateController(maximum: 10_000_000)
    _ = r.update(sentPackets: 1000, resentPackets: 0, framesLost: 1, now: 0)
    XCTAssertEqual(r.target, 8_000_000)
    XCTAssertNil(r.update(sentPackets: 1000, resentPackets: 0, framesLost: 0, now: 2))
    XCTAssertNil(r.update(sentPackets: 3, resentPackets: 0, framesLost: 0, now: 3), "an idle screen says nothing")
    XCTAssertNil(r.update(sentPackets: 1000, resentPackets: 0, framesLost: 0, now: 4))
    XCTAssertEqual(r.update(sentPackets: 1000, resentPackets: 0, framesLost: 0, now: 5), 8_800_000)
    var t = 10.0
    for _ in 0..<40 { _ = r.update(sentPackets: 1000, resentPackets: 0, framesLost: 0, now: t); t += 1 }
    XCTAssertEqual(r.target, 10_000_000, "back to the maximum and no further")
    for _ in 0..<40 { _ = r.update(sentPackets: 1000, resentPackets: 900, framesLost: 0, now: t); t += 2 }
    XCTAssertEqual(r.target, 1_500_000, "never below the floor")
  }

  func testInputEventRoundTrip() {
    let all: [InputEvent] = [.move(dx: 1.5, dy: -2), .moveTo(x: 0.25, y: 0.75), .button(index: 1, down: true), .scroll(dx: -5, dy: 9, phase: 2, momentum: 1),
      .key(code: KeyCode.a, down: true, isRepeat: true), .systemKey(code: SystemKey.mute, down: false), .releaseAll]
    for e in all { XCTAssertEqual(InputEvent(e.encoded()), e) }
    XCTAssertNil(InputEvent(Data([99])))
    XCTAssertNil(InputEvent(Data([1, 0])))
  }

  func testControlFramingAcrossChunks() throws {
    let msg = try JSONEncoder().encode(ClientMessage.setQuality(.sharp))
    let bytes = ControlFrame.json(msg).encoded() + ControlFrame.input(.releaseAll).encoded()
    var d = ControlDeframer(); var out: [ControlFrame] = []
    for b in bytes { out += d.feed(Data([b])) }
    XCTAssertEqual(out, [.json(msg), .input(.releaseAll)])
    XCTAssertEqual(try JSONDecoder().decode(ClientMessage.self, from: msg), .setQuality(.sharp))
    var bad = ControlDeframer(); _ = bad.feed(Data([0xFF, 0xFF, 0xFF, 0xFF, 0]))
    XCTAssertTrue(bad.isCorrupt)
  }

  func testPairingLink() {
    let p = PairingInfo(secret: randomSessionKey(), hostName: "Studio MacBook Pro", port: 47800, addresses: ["192.168.1.4", "100.64.0.2"])
    XCTAssertEqual(PairingInfo(url: p.url), p)
    XCTAssertNil(PairingInfo(url: URL(string: "clamshell://pair?k=abc")!), "short secrets are refused")
    XCTAssertNil(PairingInfo(url: URL(string: "https://example.com/pair?k=abc")!))
  }

  func testFramePayload() {
    let p = FramePayload(parameterSets: [Data([1, 2]), Data([3])], units: Data([9, 9, 9]))
    XCTAssertEqual(FramePayload(p.encoded()), p)
    let none = FramePayload(parameterSets: [], units: Data([7]))
    XCTAssertEqual(FramePayload(none.encoded()), none)
  }
}

final class AssemblerTests: XCTestCase {
  private func packets(_ id: UInt32, key: Bool = false, size: Int = VideoPacket.maxChunk * 2 + 10) -> [VideoPacket] {
    VideoPacket.split(frameID: id, isKeyframe: key, captureMicros: 5, data: Data(repeating: UInt8(id & 0xFF), count: size))
  }

  func testSplitIsWithinDatagramLimit() {
    let p = packets(1)
    XCTAssertEqual(p.count, 3)
    XCTAssertLessThanOrEqual(p[0].encoded().count + DatagramSealer.overhead, ClamshellProtocol.maxDatagram)
    XCTAssertEqual(VideoPacket(p[1].encoded()), p[1])
  }

  func testInOrderDeliveryWithReorderedPackets() {
    var a = FrameAssembler()
    var out: [AssembledFrame] = []
    for p in packets(1, key: true).reversed() { out += a.add(p, now: 0) }
    XCTAssertEqual(out.map(\.frameID), [1])
    XCTAssertEqual(out[0].data.count, VideoPacket.maxChunk * 2 + 10)
    for p in packets(2) { out += a.add(p, now: 0) }
    XCTAssertEqual(out.map(\.frameID), [1, 2])
  }

  func testIgnoresDeltaFramesUntilFirstKeyframe() {
    var a = FrameAssembler()
    XCTAssertTrue(packets(1).flatMap { a.add($0, now: 0) }.isEmpty)
    XCTAssertTrue(a.isWaitingForKeyframe)
    XCTAssertEqual(packets(2, key: true).flatMap { a.add($0, now: 0) }.map(\.frameID), [2])
  }

  func testLostPacketIsNackedThenRecovered() {
    var a = FrameAssembler()
    _ = packets(1, key: true).flatMap { a.add($0, now: 0) }
    let p2 = packets(2)
    _ = a.add(p2[0], now: 1); _ = a.add(p2[2], now: 1)
    XCTAssertTrue(a.service(now: 1.001).isEmpty, "waits briefly for reordering")
    XCTAssertEqual(a.service(now: 1.01), [Nack(frameID: 2, indices: [1])])
    XCTAssertTrue(a.service(now: 1.012).isEmpty, "doesn't spam")
    // later frame arrives first but must wait for frame 2
    XCTAssertTrue(packets(3).flatMap { a.add($0, now: 1.02) }.isEmpty)
    XCTAssertEqual(a.add(p2[1], now: 1.03).map(\.frameID), [2, 3])
  }

  func testWholeFrameLossDetectedFromNextFrame() {
    var a = FrameAssembler()
    _ = packets(1, key: true).flatMap { a.add($0, now: 0) }
    _ = packets(3).flatMap { a.add($0, now: 1) }
    XCTAssertEqual(a.service(now: 1.01), [Nack(frameID: 2, indices: [])])
    XCTAssertEqual(packets(2).flatMap { a.add($0, now: 1.02) }.map(\.frameID), [2, 3])
  }

  func testGivesUpAndRecoversOnKeyframe() {
    var a = FrameAssembler()
    _ = packets(1, key: true).flatMap { a.add($0, now: 0) }
    _ = a.add(packets(2)[0], now: 1)
    _ = a.service(now: 1.21)
    XCTAssertTrue(a.isWaitingForKeyframe)
    XCTAssertTrue(packets(3).flatMap { a.add($0, now: 1.22) }.isEmpty, "no corrupt frames are shown")
    XCTAssertEqual(packets(4, key: true).flatMap { a.add($0, now: 1.3) }.map(\.frameID), [4])
    XCTAssertFalse(a.isWaitingForKeyframe)
    XCTAssertEqual(packets(5).flatMap { a.add($0, now: 1.31) }.map(\.frameID), [5])
  }

  func testKeyframeSkipsPastAMissingFrame() {
    var a = FrameAssembler()
    _ = packets(1, key: true).flatMap { a.add($0, now: 0) }
    XCTAssertEqual(packets(5, key: true).flatMap { a.add($0, now: 1) }.map(\.frameID), [5])
  }

  func testSlowArrivalIsNotCalledLoss() {
    // A frame arriving in order over 25 ms, which is ordinary on Wi-Fi: nothing should be requested.
    var a = FrameAssembler()
    _ = packets(1, key: true).flatMap { a.add($0, now: 0) }
    let p = packets(2, size: VideoPacket.maxChunk * 6)
    var t = 1.0, nacks: [Nack] = []
    for packet in p { _ = a.add(packet, now: t); t += 0.005; nacks += a.service(now: t) }
    XCTAssertEqual(nacks, [], "in-order packets still arriving are not lost")
    XCTAssertEqual(a.duplicates, 0)
  }

  func testLostTailIsRequestedOnceTheFrameGoesQuiet() {
    var a = FrameAssembler()
    _ = packets(1, key: true).flatMap { a.add($0, now: 0) }
    let p = packets(2)
    _ = a.add(p[0], now: 1)
    XCTAssertTrue(a.service(now: 1.02).isEmpty, "could still be on its way")
    XCTAssertEqual(a.service(now: 1.031), [Nack(frameID: 2, indices: [1, 2])])
  }

  func testLaterFrameProvesAnEarlierTailWasLost() {
    var a = FrameAssembler()
    _ = packets(1, key: true).flatMap { a.add($0, now: 0) }
    _ = a.add(packets(2)[0], now: 1)
    _ = a.add(packets(3)[0], now: 1.001)
    XCTAssertEqual(a.service(now: 1.002).first, Nack(frameID: 2, indices: [1, 2]))
  }

  func testDuplicatesAreCountedAndHarmless() {
    var a = FrameAssembler()
    let p = packets(1, key: true)
    _ = a.add(p[0], now: 0); _ = a.add(p[0], now: 0)
    XCTAssertEqual(a.duplicates, 1)
    _ = a.add(p[1], now: 0)
    XCTAssertEqual(a.add(p[2], now: 0).map(\.frameID), [1])
    _ = a.add(p[2], now: 0)
    XCTAssertEqual(a.duplicates, 2)
  }

  func testSlowKeyframeIsNotAbandonedOrReRequested() {
    var a = FrameAssembler()
    let p = packets(1, key: true, size: VideoPacket.maxChunk * 40)
    var t = 1.0
    for packet in p.dropLast() {
      _ = a.add(packet, now: t); t += 0.02 // takes 780 ms in all, but keeps making progress
      _ = a.service(now: t)
      XCTAssertTrue(a.isKeyframeArriving(now: t))
    }
    XCTAssertEqual(a.add(p.last!, now: t).map(\.frameID), [1])
    XCTAssertFalse(a.isWaitingForKeyframe)
  }

  func testLostPacketsInTheFirstKeyframeAreRecovered() {
    // The bug: while waiting for a keyframe nothing was ever requested, so any loss meant a black screen forever.
    var a = FrameAssembler()
    let p = packets(1, key: true)
    _ = a.add(p[0], now: 0); _ = a.add(p[2], now: 0)
    XCTAssertTrue(a.isWaitingForKeyframe)
    XCTAssertEqual(a.service(now: 0.01), [Nack(frameID: 1, indices: [1])])
    XCTAssertEqual(a.add(p[1], now: 0.02).map(\.frameID), [1])
    XCTAssertFalse(a.isWaitingForKeyframe)
  }

  func testDeltaFramesAreNotRequestedWhileWaitingForAKeyframe() {
    var a = FrameAssembler()
    let p = packets(1)
    _ = a.add(p[0], now: 0); _ = a.add(p[2], now: 0)
    XCTAssertTrue(a.service(now: 0.1).isEmpty, "useless without a keyframe")
  }

  func testAStalledKeyframeLetsTheNextRequestThrough() {
    var a = FrameAssembler()
    _ = a.add(packets(1, key: true)[0], now: 0)
    XCTAssertTrue(a.isKeyframeArriving(now: 0.1))
    XCTAssertFalse(a.isKeyframeArriving(now: 0.3), "gone quiet: time to ask again")
  }

  func testRetransmitBuffer() {
    var b = RetransmitBuffer(capacity: 2)
    b.remember(packets(1)); b.remember(packets(2)); b.remember(packets(3))
    XCTAssertTrue(b.packets(for: Nack(frameID: 1, indices: [])).isEmpty, "evicted")
    XCTAssertEqual(b.packets(for: Nack(frameID: 2, indices: [])).count, 3)
    XCTAssertEqual(b.packets(for: Nack(frameID: 3, indices: [1, 9])).map(\.index), [1])
  }
}

final class KeyboardTests: XCTestCase {
  private let engine = KeyboardEngine()
  private var log: [InputEvent] = []
  override func setUp() { log = []; engine.send = { [unowned self] in log.append($0) } }
  private func def(_ id: String) -> KeyDef { (KeyboardLayout.rows.flatMap { $0 } + [KeyboardLayout.arrowLeft]).first { $0.id == id }! }
  private func tap(_ id: String, _ t: TimeInterval) { engine.press(def(id), now: t); engine.release(def(id), now: t + 0.05) }
  private func k(_ c: UInt16, _ d: Bool) -> InputEvent { .key(code: c, down: d, isRepeat: false) }

  func testEveryRowAddsUpToTheSameWidth() {
    let widths = KeyboardLayout.rows.map { $0.reduce(0) { $0 + $1.width } }
    XCTAssertEqual(widths, [14.5, 14.5, 14.5, 14.5, 14.5, 11.5], "last row leaves 3 units for the arrow cluster")
  }

  func testTapLatchesModifierForOneKey() {
    tap("shiftL", 0)
    XCTAssertEqual(log, [k(KeyCode.shift, true)])
    XCTAssertEqual(engine.state(of: KeyCode.shift), .latched)
    tap("A", 1)
    XCTAssertEqual(log, [k(KeyCode.shift, true), k(KeyCode.a, true), k(KeyCode.a, false), k(KeyCode.shift, false)])
    XCTAssertNil(engine.state(of: KeyCode.shift))
  }

  func testHoldingModifierWhileTypingReleasesWithIt() {
    engine.press(def("cmdL"), now: 0)
    tap("C", 0.1); tap("V", 0.2)
    XCTAssertEqual(engine.state(of: KeyCode.command), .held, "stays down across keys")
    engine.release(def("cmdL"), now: 0.3)
    XCTAssertEqual(log.last, k(KeyCode.command, false))
    XCTAssertEqual(log.filter { $0 == k(KeyCode.command, true) }.count, 1)
  }

  func testDoubleTapLocksAndTapUnlocks() {
    tap("cmdL", 0); tap("cmdL", 0.2)
    XCTAssertEqual(engine.state(of: KeyCode.command), .locked)
    tap("A", 1); tap("B", 2)
    XCTAssertEqual(engine.state(of: KeyCode.command), .locked)
    tap("cmdL", 3)
    XCTAssertNil(engine.state(of: KeyCode.command))
    XCTAssertEqual(log.last, k(KeyCode.command, false))
  }

  func testAutoRepeat() {
    engine.press(def("A"), now: 0)
    engine.tick(now: 0.2); XCTAssertEqual(log.count, 1)
    engine.tick(now: 0.43); XCTAssertEqual(log.last, .key(code: KeyCode.a, down: true, isRepeat: true))
    engine.release(def("A"), now: 0.5)
    let n = log.count; engine.tick(now: 2); XCTAssertEqual(log.count, n)
  }

  func testFunctionRowAndFn() {
    tap("F12", 0)
    XCTAssertEqual(log, [.systemKey(code: SystemKey.volumeUp, down: true), .systemKey(code: SystemKey.volumeUp, down: false)])
    log = []
    engine.press(def("fn"), now: 1); tap("F12", 1.1); engine.release(def("fn"), now: 1.2)
    XCTAssertEqual(log, [k(KeyCode.fn, true), k(KeyCode.f12, true), k(KeyCode.f12, false), k(KeyCode.fn, false)])
  }

  func testComboKey() {
    tap("F4", 0)
    XCTAssertEqual(log, [k(KeyCode.command, true), k(KeyCode.space, true), k(KeyCode.space, false), k(KeyCode.command, false)])
  }
}

final class GestureTests: XCTestCase {
  private var keyboard: KeyboardEngine!, context: GestureContext!, pad: TrackpadEngine!
  private var log: [InputEvent] = [], reliableLog: [(InputEvent, Bool)] = [], feedback: [GestureFeedback] = []

  override func setUp() {
    keyboard = KeyboardEngine(); context = GestureContext(keyboard: keyboard); pad = TrackpadEngine(context: context)
    log = []; reliableLog = []; feedback = []
    keyboard.send = { [unowned self] in log.append($0) }
    context.send = { [unowned self] e, r in log.append(e); reliableLog.append((e, r)) }
    context.feedback = { [unowned self] in feedback.append($0) }
  }
  private func k(_ c: UInt16, _ d: Bool) -> InputEvent { .key(code: c, down: d, isRepeat: false) }
  private var keyDowns: [UInt16] { log.compactMap { if case let .key(c, true, _) = $0 { c } else { nil } } }
  private var scrolls: [InputEvent] { log.filter { if case .scroll = $0 { true } else { false } } }

  /// Starts fingers around (100,100), moves them with `at`, lifts them.
  private func gesture(fingers: Int, steps: Int, stepTime: TimeInterval = 0.016, start: TimeInterval = 10, at: (Touch, Int) -> (Double, Double)) {
    let touches = (0..<fingers).map { Touch(id: $0, x: 100 + Double($0) * 30, y: 100) }
    pad.began(touches, t: start)
    var t = start
    for s in 0..<steps {
      t += stepTime
      pad.moved(touches.map { let (x, y) = at($0, s + 1); return Touch(id: $0.id, x: x, y: y) }, t: t)
    }
    t += 0.01
    pad.ended(touches, t: t)
  }

  func testOneFingerMovesAndAccelerates() {
    gesture(fingers: 1, steps: 5) { t, s in (t.x + Double(s), t.y) }
    guard case let .move(slow, _)? = log.first else { return XCTFail() }
    XCTAssertGreaterThan(slow, 1.5)
    setUp()
    gesture(fingers: 1, steps: 5) { t, s in (t.x + Double(s) * 30, t.y) }
    guard case let .move(fast, _)? = log.last else { return XCTFail() }
    XCTAssertGreaterThan(fast, slow * 10)
    XCTAssertTrue(reliableLog.allSatisfy { !$0.1 }, "motion is fire-and-forget")
  }

  func testTapsByFingerCount() {
    gesture(fingers: 1, steps: 0) { t, _ in (t.x, t.y) }
    XCTAssertEqual(log, [.button(index: 0, down: true), .button(index: 0, down: false)])
    log = []
    gesture(fingers: 2, steps: 0) { t, _ in (t.x, t.y) }
    XCTAssertEqual(log, [.button(index: 1, down: true), .button(index: 1, down: false)])
  }

  func testHoldThenMoveDrags() {
    let f = Touch(id: 0, x: 50, y: 50)
    pad.began([f], t: 0)
    pad.tick(now: 0.2); XCTAssertTrue(log.isEmpty)
    pad.tick(now: 0.33); XCTAssertEqual(log, [.button(index: 0, down: true)]); XCTAssertEqual(feedback, [.dragStarted])
    pad.moved([Touch(id: 0, x: 80, y: 50)], t: 0.4)
    pad.ended([f], t: 0.5)
    XCTAssertEqual(log.last, .button(index: 0, down: false))
    XCTAssertEqual(log.filter { $0 == .button(index: 0, down: true) }.count, 1)
  }

  func testMacTwoFingerScrollHasPhasesAndMomentum() {
    context.profile = Profiles.mac
    gesture(fingers: 2, steps: 20) { t, s in (t.x, t.y - Double(s) * 8) }
    guard case let .scroll(_, dy, phase, _)? = scrolls.first else { return XCTFail() }
    XCTAssertEqual(phase, 1); XCTAssertLessThan(dy, 0, "natural scrolling: finger up = negative")
    XCTAssertTrue(scrolls.contains { if case .scroll(_, _, 4, 0) = $0 { true } else { false } }, "ended phase")
    let before = scrolls.count
    var t = 10.5; for _ in 0..<400 { context.scroller.tick(now: t); t += 0.016 }
    XCTAssertGreaterThan(scrolls.count, before + 5, "keeps coasting")
    guard case let .scroll(_, _, 0, m)? = scrolls.last else { return XCTFail() }
    XCTAssertEqual(m, 3, "momentum ends")
  }

  func testPremiereScrollIsAxisLockedWithNoCoasting() {
    context.profile = Profiles.premiere
    gesture(fingers: 2, steps: 20) { t, s in (t.x + Double(s) * 3, t.y + Double(s) * 0.6) }
    XCTAssertFalse(scrolls.isEmpty)
    XCTAssertTrue(scrolls.allSatisfy { if case let .scroll(_, dy, _, _) = $0 { dy == 0 } else { false } }, "vertical drift is removed")
    let n = scrolls.count
    var t = 10.5; for _ in 0..<50 { context.scroller.tick(now: t); t += 0.016 }
    XCTAssertEqual(scrolls.count, n, "no momentum on a timeline")
  }

  func testPinchFiresZoomKeys() {
    context.profile = Profiles.premiere
    gesture(fingers: 2, steps: 20) { t, s in (t.id == 0 ? t.x - Double(s) * 1.5 : t.x + Double(s) * 1.5, t.y) }
    XCTAssertEqual(Set(keyDowns), [KeyCode.equal])
    XCTAssertGreaterThanOrEqual(keyDowns.count, 3)
    XCTAssertTrue(scrolls.isEmpty, "a pinch is not a scroll")
    log = []
    context.profile = Profiles.mac
    gesture(fingers: 2, steps: 20) { t, s in (t.id == 0 ? t.x + Double(s) * 0.6 : t.x - Double(s) * 0.6, t.y) }
    XCTAssertTrue(keyDowns.contains(KeyCode.minus)); XCTAssertTrue(keyDowns.contains(KeyCode.command))
  }

  func testPremiereThreeFingerJogOneFramePerStep() {
    context.profile = Profiles.premiere
    gesture(fingers: 3, steps: 25) { t, s in (t.x + Double(s) * 2, t.y) }
    XCTAssertEqual(keyDowns, Array(repeating: KeyCode.right, count: 5), "50 pt = 5 frames")
    XCTAssertTrue(feedback.contains(.detent))
  }

  func testPremiereFlickUsesBigSteps() {
    context.profile = Profiles.premiere
    gesture(fingers: 3, steps: 8) { t, s in (t.x - Double(s) * 25, t.y) }
    XCTAssertTrue(keyDowns.contains(KeyCode.shift)); XCTAssertTrue(keyDowns.contains(KeyCode.left))
    XCTAssertFalse(keyDowns.contains(KeyCode.right))
    XCTAssertLessThan(keyDowns.filter { $0 == KeyCode.left }.count, 12, "200 pt in big steps, not 20 single frames")
  }

  func testPremiereThreeFingerVerticalJumpsEdits() {
    context.profile = Profiles.premiere
    gesture(fingers: 3, steps: 15) { t, s in (t.x, t.y + Double(s) * 3) }
    XCTAssertEqual(keyDowns, [KeyCode.down])
    XCTAssertTrue(feedback.contains(.toast("Next edit")))
  }

  func testThreeFingerTapPlaysInPremiereButNotOnMac() {
    context.profile = Profiles.premiere
    gesture(fingers: 3, steps: 0) { t, _ in (t.x, t.y) }
    XCTAssertEqual(log, [k(KeyCode.space, true), k(KeyCode.space, false)])
    log = []
    context.profile = Profiles.mac
    gesture(fingers: 3, steps: 0) { t, _ in (t.x, t.y) }
    XCTAssertTrue(log.isEmpty)
  }

  func testSpacesSwipeFiresOnce() {
    for (id, f) in [(ProfileID.mac, 3), (.mac, 4), (.premiere, 4)] {
      log = []; feedback = []
      context.profile = Profiles.profile(id)
      gesture(fingers: f, steps: 20) { t, s in (t.x - Double(s) * 8, t.y) }
      XCTAssertEqual(log, [k(KeyCode.control, true), k(KeyCode.right, true), k(KeyCode.right, false), k(KeyCode.control, false)], "\(id) \(f) fingers")
      XCTAssertTrue(feedback.contains(.toast("Next Space")))
    }
  }

  func testAddingAFingerDoesNotJumpThePointer() {
    pad.began([Touch(id: 0, x: 0, y: 0)], t: 0)
    pad.moved([Touch(id: 0, x: 10, y: 0)], t: 0.01)
    log = []
    pad.began([Touch(id: 1, x: 300, y: 300)], t: 0.02)
    context.profile = Profiles.mac
    pad.moved([Touch(id: 0, x: 10.5, y: 0), Touch(id: 1, x: 300.5, y: 300)], t: 0.03)
    XCTAssertTrue(log.isEmpty, "under the 6 pt threshold nothing fires: \(log)")
  }

  func testTappingWithLatchedCommandSendsCommandClick() {
    keyboard.press(KeyboardLayout.rows[5][3], now: 0); keyboard.release(KeyboardLayout.rows[5][3], now: 0.05)
    gesture(fingers: 1, steps: 0) { t, _ in (t.x, t.y) }
    XCTAssertEqual(log, [k(KeyCode.command, true), .button(index: 0, down: true), .button(index: 0, down: false), k(KeyCode.command, false)])
  }

  func testAutoProfileSelection() {
    XCTAssertEqual(Profiles.id(forBundleID: "com.adobe.PremierePro.26"), .premiere)
    XCTAssertEqual(Profiles.id(forBundleID: "com.apple.FinalCut"), .video)
    XCTAssertEqual(Profiles.id(forBundleID: "com.blackmagic-design.DaVinciResolve"), .video)
    XCTAssertEqual(Profiles.id(forBundleID: "com.apple.finder"), .mac)
  }

  // MARK: direct touch

  private func direct() -> DirectTouchEngine {
    let d = DirectTouchEngine(context: context)
    d.viewportSize = (400, 300)
    d.mapToDisplay = { x, y in (0...400).contains(x) && (0...300).contains(y) ? (Float(x / 400), Float(y / 300)) : nil }
    return d
  }

  func testDirectTapMovesReliablyThenClicks() {
    let d = direct(), f = Touch(id: 0, x: 200, y: 150)
    d.began([f], t: 0); d.ended([f], t: 0.05)
    XCTAssertEqual(log, [.moveTo(x: 0.5, y: 0.5), .button(index: 0, down: true), .button(index: 0, down: false)])
    XCTAssertTrue(reliableLog.allSatisfy { $0.1 }, "the position must not be overtaken by the click")
  }

  func testDirectLongPressRightClicksOnce() {
    let d = direct(), f = Touch(id: 0, x: 10, y: 10)
    d.began([f], t: 0); d.tick(now: 0.53); d.ended([f], t: 0.6)
    XCTAssertEqual(log.dropFirst().map { $0 }, [.button(index: 1, down: true), .button(index: 1, down: false)])
  }

  func testDirectDragPinchAndOutsideTaps() {
    let d = direct()
    d.began([Touch(id: 0, x: 10, y: 10)], t: 0)
    d.moved([Touch(id: 0, x: 100, y: 10)], t: 0.1)
    d.ended([Touch(id: 0, x: 200, y: 10)], t: 0.2)
    XCTAssertTrue(log.contains(.button(index: 0, down: true))); XCTAssertEqual(log.last, .button(index: 0, down: false))
    log = []
    var views: [ViewTransform] = []
    d.onViewChanged = { views.append($0) }
    d.began([Touch(id: 0, x: 180, y: 150)], t: 1); log = []
    d.began([Touch(id: 1, x: 220, y: 150)], t: 1.01)
    d.moved([Touch(id: 0, x: 100, y: 150), Touch(id: 1, x: 300, y: 150)], t: 1.1)
    d.ended([Touch(id: 0, x: 100, y: 150), Touch(id: 1, x: 300, y: 150)], t: 1.2)
    XCTAssertEqual(views.last?.scale ?? 0, 5, accuracy: 0.01)
    XCTAssertTrue(log.isEmpty, "zooming the picture sends nothing to the Mac")
    let ignored = direct(); log = []
    ignored.began([Touch(id: 0, x: 900, y: 900)], t: 0); ignored.ended([Touch(id: 0, x: 900, y: 900)], t: 0.05)
    XCTAssertTrue(log.isEmpty, "letterbox taps do nothing")
  }

  func testDirectThreeFingerTapPlaysInPremiere() {
    context.profile = Profiles.premiere
    let d = direct(), ts = (0..<3).map { Touch(id: $0, x: 100 + Double($0) * 40, y: 100) }
    d.began([ts[0]], t: 0); d.began([ts[1], ts[2]], t: 0.01); log = []
    d.ended(ts, t: 0.05)
    XCTAssertEqual(log, [k(KeyCode.space, true), k(KeyCode.space, false)])
  }
}
