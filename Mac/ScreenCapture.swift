// ScreenCaptureKit capture of one display, video and system audio.
import AppKit
import ClamshellCore
import CoreMedia
import ScreenCaptureKit

protocol FrameSource: AnyObject {
  var onVideo: ((CVPixelBuffer, CMTime) -> Void)? { get set }
  var onAudio: ((CMSampleBuffer) -> Void)? { get set }
  func start(displayID: UInt32, width: Int, height: Int, completion: @escaping (Error?) -> Void)
  func stop()
}

enum Displays {
  static func all() -> [DisplayInfo] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return ids.map { id in
      let (w, h) = pixelSize(id)
      let name = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }?.localizedName
      return DisplayInfo(id: id, name: name ?? "Display \(id)", width: w, height: h, isMain: CGDisplayIsMain(id) != 0)
    }
  }

  static func pixelSize(_ id: CGDirectDisplayID) -> (Int, Int) {
    if let mode = CGDisplayCopyDisplayMode(id) { return (mode.pixelWidth, mode.pixelHeight) }
    return (CGDisplayPixelsWide(id), CGDisplayPixelsHigh(id))
  }

  /// Fits the display inside the quality's width; both sides even, as encoders require.
  static func streamSize(displayWidth w: Int, displayHeight h: Int, maxWidth: Int) -> (Int, Int) {
    let scale = min(1, Double(maxWidth) / Double(max(w, 1)))
    return (Int((Double(w) * scale / 2).rounded()) * 2, Int((Double(h) * scale / 2).rounded()) * 2)
  }
}

final class ScreenCapture: NSObject, FrameSource, SCStreamOutput, SCStreamDelegate {
  var onVideo: ((CVPixelBuffer, CMTime) -> Void)?
  var onAudio: ((CMSampleBuffer) -> Void)?
  var onStopped: ((Error) -> Void)?
  private var stream: SCStream?
  private let videoQueue = DispatchQueue(label: "clamshell.capture.video", qos: .userInteractive)
  private let audioQueue = DispatchQueue(label: "clamshell.capture.audio", qos: .userInteractive)

  func start(displayID: UInt32, width: Int, height: Int, completion: @escaping (Error?) -> Void) {
    stop()
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
      guard let self else { return }
      guard let content, let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
        completion(error ?? NSError(domain: "Clamshell", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display to capture"]))
        return
      }
      let config = SCStreamConfiguration()
      config.width = width
      config.height = height
      config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
      config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
      config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
      config.colorSpaceName = CGColorSpace.sRGB
      config.queueDepth = 5
      config.showsCursor = true
      config.capturesAudio = true
      config.sampleRate = 48000
      config.channelCount = 2
      config.excludesCurrentProcessAudio = true

      let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
      do {
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.videoQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.audioQueue)
      } catch { completion(error); return }
      self.stream = stream
      stream.startCapture { completion($0) }
    }
  }

  func stop() {
    stream?.stopCapture(completionHandler: nil)
    stream = nil
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
    guard sample.isValid else { return }
    switch type {
    case .screen:
      // ScreenCaptureKit also reports idle and blank frames; only complete ones carry a picture.
      guard let atts = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
        let raw = atts.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
        let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
      onVideo?(pixels, CMSampleBufferGetPresentationTimeStamp(sample))
    case .audio: onAudio?(sample)
    default: break
    }
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) { onStopped?(error) }
}
