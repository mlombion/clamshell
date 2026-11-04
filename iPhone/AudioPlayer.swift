// Plays the Mac's system audio with a very small buffer.
import AVFoundation
import ClamshellCore

final class AudioPlayer {
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
  private var converter: AVAudioConverter?
  private var opus: AVAudioFormat?
  private let queue = DispatchQueue(label: "clamshell.audio", qos: .userInteractive)
  private var queued = 0, enabled = false, muted = false, started = false

  init() {
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: pcm)
    var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 960, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
    if let f = AVAudioFormat(streamDescription: &asbd) { opus = f; converter = AVAudioConverter(from: f, to: pcm) }
  }

  func setEnabled(_ on: Bool) { queue.async { [self] in enabled = on; if !on { stop() } } }
  func setMuted(_ m: Bool) { queue.async { [self] in muted = m; player.volume = m ? 0 : 1 } }

  private func start() {
    guard !started else { return }
    try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
    try? AVAudioSession.sharedInstance().setPreferredIOBufferDuration(0.005)
    try? AVAudioSession.sharedInstance().setActive(true)
    try? engine.start()
    player.volume = muted ? 0 : 1
    player.play()
    started = true
  }

  private func stop() {
    guard started else { return }
    player.stop(); engine.stop(); started = false; queued = 0
  }

  func enqueue(_ packet: Data) {
    queue.async { [self] in
      guard enabled, let tag = packet.first else { return }
      let body = packet.dropFirst()
      guard let buffer = tag == AudioFormatTag.opus ? decodeOpus(body) : decodePCM(body) else { return }
      start()
      // More than ~100 ms behind: drop it and catch up. Staying in sync with the picture beats gapless sound.
      guard queued < 6 else { return }
      queued += 1
      player.scheduleBuffer(buffer) { [weak self] in self?.queue.async { self?.queued -= 1 } }
    }
  }

  private func decodeOpus(_ body: Data) -> AVAudioPCMBuffer? {
    guard let converter, let opus, let out = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 960) else { return nil }
    let input = AVAudioCompressedBuffer(format: opus, packetCapacity: 1, maximumPacketSize: body.count)
    body.withUnsafeBytes { input.data.copyMemory(from: $0.baseAddress!, byteCount: body.count) }
    input.byteLength = UInt32(body.count)
    input.packetCount = 1
    input.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(body.count))
    var given = false, error: NSError?
    converter.convert(to: out, error: &error) { _, status in
      if given { status.pointee = .noDataNow; return nil }
      given = true
      status.pointee = .haveData
      return input
    }
    return error == nil && out.frameLength > 0 ? out : nil
  }

  private func decodePCM(_ body: Data) -> AVAudioPCMBuffer? {
    let frames = body.count / 4
    guard frames > 0, let out = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
    out.frameLength = AVAudioFrameCount(frames)
    body.withUnsafeBytes { raw in
      let s = raw.bindMemory(to: Int16.self)
      for i in 0..<frames {
        out.floatChannelData![0][i] = Float(Int16(littleEndian: s[i * 2])) / 32767
        out.floatChannelData![1][i] = Float(Int16(littleEndian: s[i * 2 + 1])) / 32767
      }
    }
    return out
  }
}
