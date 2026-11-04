// System audio from ScreenCaptureKit → Opus packets (raw PCM if Opus isn't available).
import AVFoundation
import ClamshellCore
import CoreMedia

final class AudioEncoder {
  private let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
  private var converter: AVAudioConverter?
  private var opusFormat: AVAudioFormat?
  private var pending: [AVAudioPCMBuffer] = []
  private var pendingOffset: AVAudioFrameCount = 0
  private var pendingFrames: AVAudioFrameCount = 0
  private let onPacket: (Data) -> Void
  private static let frame: AVAudioFrameCount = 960 // 20 ms

  init(onPacket: @escaping (Data) -> Void) {
    self.onPacket = onPacket
    var asbd = AudioStreamBasicDescription(
      mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: Self.frame,
      mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
    if let f = AVAudioFormat(streamDescription: &asbd), let c = AVAudioConverter(from: pcmFormat, to: f) {
      c.bitRate = 128_000
      opusFormat = f
      converter = c
    }
  }

  var usesOpus: Bool { converter != nil }

  func encode(_ sample: CMSampleBuffer) {
    guard let pcm = Self.pcmBuffer(from: sample, format: pcmFormat) else { return }
    guard let converter, let opusFormat else { sendPCM(pcm); return }
    pending.append(pcm)
    pendingFrames += pcm.frameLength
    while pendingFrames >= Self.frame {
      let out = AVAudioCompressedBuffer(format: opusFormat, packetCapacity: 1, maximumPacketSize: 1100)
      var fed = false
      var error: NSError?
      let status = converter.convert(to: out, error: &error) { [self] _, inputStatus in
        if fed { inputStatus.pointee = .noDataNow; return nil }
        fed = true
        guard let chunk = takeFrame() else { inputStatus.pointee = .noDataNow; return nil }
        inputStatus.pointee = .haveData
        return chunk
      }
      guard status != .error, error == nil else { return }
      if out.byteLength > 0 {
        var data = Data([AudioFormatTag.opus])
        data.append(Data(bytes: out.data, count: Int(out.byteLength)))
        onPacket(data)
      }
    }
  }

  private func takeFrame() -> AVAudioPCMBuffer? {
    guard pendingFrames >= Self.frame, let out = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: Self.frame) else { return nil }
    var filled: AVAudioFrameCount = 0
    while filled < Self.frame, let head = pending.first {
      let n = min(Self.frame - filled, head.frameLength - pendingOffset)
      for ch in 0..<2 {
        memcpy(out.floatChannelData![ch] + Int(filled), head.floatChannelData![ch] + Int(pendingOffset), Int(n) * MemoryLayout<Float>.size)
      }
      filled += n
      pendingOffset += n
      if pendingOffset == head.frameLength { pending.removeFirst(); pendingOffset = 0 }
    }
    pendingFrames -= filled
    out.frameLength = filled
    return out
  }

  private func sendPCM(_ pcm: AVAudioPCMBuffer) {
    var start = 0
    let total = Int(pcm.frameLength), perPacket = 240 // 5 ms; fits one datagram
    while start < total {
      let n = min(perPacket, total - start)
      var data = Data(capacity: 1 + n * 4)
      data.append(AudioFormatTag.pcm16)
      for i in start..<(start + n) {
        for ch in 0..<2 {
          let v = Int16(max(-1, min(1, pcm.floatChannelData![ch][i])) * 32767)
          withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }
      }
      onPacket(data)
      start += n
    }
  }

  static func pcmBuffer(from sample: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
    let frames = CMSampleBufferGetNumSamples(sample)
    guard frames > 0, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
    out.frameLength = AVAudioFrameCount(frames)
    let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: out.mutableAudioBufferList)
    return status == noErr ? out : nil
  }
}
