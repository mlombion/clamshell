// VideoToolbox hardware encoding tuned for latency: no B-frames, one frame in, one frame out.
import ClamshellCore
import CoreMedia
import Foundation
import VideoToolbox

final class VideoEncoder {
  struct Output { let payload: Data; let isKeyframe: Bool; let captureMicros: UInt64; let encodeMillis: Double }

  private var session: VTCompressionSession?
  private let codec: VideoCodec
  private let onOutput: (Output) -> Void
  private var forceKey = true
  private let lock = NSLock()
  let isLowLatency: Bool

  init?(width: Int, height: Int, codec: VideoCodec, bitrate: Int, onOutput: @escaping (Output) -> Void) {
    self.codec = codec
    self.onOutput = onOutput
    let type = codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
    var created: VTCompressionSession?
    // Low-latency rate control when the hardware offers it; plain real-time mode otherwise.
    let lowLatency: [CFString: Any] = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true]
    var status = VTCompressionSessionCreate(
      allocator: nil, width: Int32(width), height: Int32(height), codecType: type, encoderSpecification: lowLatency as CFDictionary,
      imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &created)
    isLowLatency = status == noErr
    if status != noErr {
      status = VTCompressionSessionCreate(
        allocator: nil, width: Int32(width), height: Int32(height), codecType: type, encoderSpecification: nil,
        imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &created)
    }
    guard status == noErr, let s = created else { return nil }
    session = s

    let set = { (key: CFString, value: CFTypeRef) in _ = VTSessionSetProperty(s, key: key, value: value) }
    set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
    set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
    set(kVTCompressionPropertyKey_ExpectedFrameRate, 60 as CFNumber)
    set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 3600 as CFNumber) // keyframes on request only
    set(kVTCompressionPropertyKey_ProfileLevel, codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
    set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
    set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
    set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
    setBitrate(bitrate)
    VTCompressionSessionPrepareToEncodeFrames(s)
  }

  deinit { invalidate() }

  func invalidate() {
    lock.lock(); defer { lock.unlock() }
    if let s = session { VTCompressionSessionInvalidate(s) }
    session = nil
  }

  func setBitrate(_ bitrate: Int) {
    guard let s = session else { return }
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
    // Allow short bursts for scene changes, but cap them so a burst can't flood the network.
    let limits = [Double(bitrate) * 1.5 / 8, 1.0] as CFArray
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
  }

  func requestKeyframe() { lock.lock(); forceKey = true; lock.unlock() }

  func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, captureMicros: UInt64) {
    lock.lock()
    let s = session
    let key = forceKey
    forceKey = false
    lock.unlock()
    guard let s else { return }
    let props = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
    let started = monotonicSeconds()
    VTCompressionSessionEncodeFrame(s, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid, frameProperties: props, infoFlagsOut: nil) {
      [weak self] status, _, sample in
      guard status == noErr, let sample, let self else { return }
      self.deliver(sample, captureMicros: captureMicros, encodeMillis: (monotonicSeconds() - started) * 1000)
    }
  }

  private func deliver(_ sample: CMSampleBuffer, captureMicros: UInt64, encodeMillis: Double) {
    guard let block = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample) else { return }
    var isKey = true
    if let atts = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
      let notSync = atts.first?[kCMSampleAttachmentKey_NotSync] as? Bool { isKey = !notSync }

    var length = 0
    var pointer: UnsafeMutablePointer<CChar>?
    guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr, let pointer else { return }
    let units = Data(bytes: pointer, count: length)
    let payload = FramePayload(parameterSets: isKey ? parameterSets(format) : [], units: units)
    onOutput(Output(payload: payload.encoded(), isKeyframe: isKey, captureMicros: captureMicros, encodeMillis: encodeMillis))
  }

  private func parameterSets(_ format: CMFormatDescription) -> [Data] {
    var count = 0
    var sets: [Data] = []
    func get(_ i: Int) -> Data? {
      var p: UnsafePointer<UInt8>?, size = 0
      let status = codec == .hevc
        ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &p, parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &p, parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
      guard status == noErr, let p else { return nil }
      return Data(bytes: p, count: size)
    }
    if let first = get(0) { sets.append(first) }
    for i in 1..<max(count, 1) { if let s = get(i) { sets.append(s) } }
    return sets
  }
}
