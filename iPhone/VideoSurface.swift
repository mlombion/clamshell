// Decodes and shows the stream. AVSampleBufferDisplayLayer uses the hardware decoder directly.
import AVFoundation
import ClamshellCore
import UIKit

final class VideoSurface: UIView {
  override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
  private var videoLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
  private let lock = NSLock()
  private var format: CMFormatDescription?
  var codec = VideoCodec.hevc

  override init(frame: CGRect) {
    super.init(frame: frame)
    videoLayer.videoGravity = .resizeAspect
    videoLayer.backgroundColor = UIColor.black.cgColor
    isUserInteractionEnabled = false
  }
  required init?(coder: NSCoder) { fatalError() }

  func reset() {
    lock.lock(); format = nil; lock.unlock()
    videoLayer.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil)
  }

  /// Returns true when the decoder needs a new keyframe.
  func enqueue(_ frame: AssembledFrame) -> Bool {
    guard let payload = FramePayload(frame.data) else { return true }
    lock.lock(); defer { lock.unlock() }
    if !payload.parameterSets.isEmpty { format = makeFormat(payload.parameterSets) ?? format }
    guard let format, let sample = makeSample(payload.units, format: format) else { return true }
    let renderer = videoLayer.sampleBufferRenderer
    if renderer.status == .failed {
      renderer.flush()
      return true
    }
    renderer.enqueue(sample)
    return false
  }

  private func makeFormat(_ sets: [Data]) -> CMFormatDescription? {
    let copies = sets.map { d -> UnsafeMutablePointer<UInt8> in
      let p = UnsafeMutablePointer<UInt8>.allocate(capacity: d.count)
      d.copyBytes(to: p, count: d.count)
      return p
    }
    defer { copies.forEach { $0.deallocate() } }
    let pointers = copies.map { UnsafePointer($0) }
    let sizes = sets.map(\.count)
    var out: CMFormatDescription?
    // The Mac sends HEVC with three parameter sets (VPS, SPS, PPS) and H.264 with two.
    let status = sets.count >= 3
      ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &out)
      : CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &out)
    return status == noErr ? out : nil
  }

  private func makeSample(_ units: Data, format: CMFormatDescription) -> CMSampleBuffer? {
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: units.count, blockAllocator: nil, customBlockSource: nil,
      offsetToData: 0, dataLength: units.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr, let block else { return nil }
    let ok = units.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: units.count) }
    guard ok == noErr else { return nil }
    var sample: CMSampleBuffer?
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
    var size = units.count
    guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
      sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return nil }
    // Show each frame as soon as it's decoded rather than scheduling it against a timeline.
    if let atts = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(atts) > 0 {
      let dict = unsafeBitCast(CFArrayGetValueAtIndex(atts, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    return sample
  }
}
