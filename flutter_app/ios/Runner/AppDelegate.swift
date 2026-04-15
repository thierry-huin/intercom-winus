import Flutter
import UIKit
import AVKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var _pipManager: AnyObject? // Stored as AnyObject to avoid @available on stored property

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Configure audio session for background playback
    let audioSession = AVAudioSession.sharedInstance()
    try? audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothA2DP, .defaultToSpeaker, .mixWithOthers])
    try? audioSession.setActive(true)

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Initialize PiP after Flutter engine is ready (requires iOS 15+)
    if #available(iOS 15.0, *) {
      if let window = UIApplication.shared.connectedScenes
          .compactMap({ $0 as? UIWindowScene })
          .first?.windows.first {
        _pipManager = IntercomPiPManager(window: window)
      }
    }
  }
}

// MARK: - PiP Manager
/// Keeps the app alive in PiP mode using a minimal video layer,
/// similar to how VoIP apps maintain background connectivity.
@available(iOS 15.0, *)
class IntercomPiPManager: NSObject, AVPictureInPictureControllerDelegate {
  private var pipController: AVPictureInPictureController?
  private var displayLayer: AVSampleBufferDisplayLayer?
  private var pipView: UIView?
  private var displayLink: CADisplayLink?
  private weak var window: UIWindow?
  private var isActive = false

  init(window: UIWindow) {
    self.window = window
    super.init()

    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      print("[PiP] Not supported on this device")
      return
    }

    setupPiP(in: window)

    // Auto-enter PiP when app goes to background
    NotificationCenter.default.addObserver(
      self, selector: #selector(appWillResignActive),
      name: UIApplication.willResignActiveNotification, object: nil
    )
    NotificationCenter.default.addObserver(
      self, selector: #selector(appDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification, object: nil
    )
  }

  private func setupPiP(in window: UIWindow) {
    let layer = AVSampleBufferDisplayLayer()
    layer.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
    layer.videoGravity = .resizeAspect

    let view = UIView(frame: CGRect(x: -10, y: -10, width: 2, height: 2))
    view.layer.addSublayer(layer)
    window.addSubview(view)
    window.sendSubviewToBack(view)

    self.displayLayer = layer
    self.pipView = view

    // Create PiP controller from the display layer
    let contentSource = AVPictureInPictureController.ContentSource(
      sampleBufferDisplayLayer: layer,
      playbackDelegate: self
    )
    let controller = AVPictureInPictureController(contentSource: contentSource)
    controller.delegate = self
    controller.canStartPictureInPictureAutomaticallyFromInline = true
    self.pipController = controller

    // Start feeding frames so PiP has content
    startFrameGeneration()

    print("[PiP] Initialized")
  }

  private func startFrameGeneration() {
    displayLink = CADisplayLink(target: self, selector: #selector(generateFrame))
    displayLink?.preferredFramesPerSecond = 1 // Minimal — just to keep PiP alive
    displayLink?.add(to: .main, forMode: .common)
  }

  @objc private func generateFrame() {
    guard let layer = displayLayer else { return }

    // Create a minimal 2x2 black pixel buffer
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
    guard let buffer = pixelBuffer else { return }

    let timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 1),
      presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
      decodeTimeStamp: .invalid
    )

    var formatDesc: CMFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &formatDesc)
    guard let desc = formatDesc else { return }

    var sampleBuffer: CMSampleBuffer?
    var timingVar = timing
    CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: buffer,
      formatDescription: desc,
      sampleTiming: &timingVar,
      sampleBufferOut: &sampleBuffer
    )

    if let sample = sampleBuffer {
      layer.enqueue(sample)
    }
  }

  @objc private func appWillResignActive() {
    guard let controller = pipController, !controller.isPictureInPictureActive else { return }
    // Brief delay to avoid conflicts with system animations
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      controller.startPictureInPicture()
      self.isActive = true
      print("[PiP] Started (app going to background)")
    }
  }

  @objc private func appDidBecomeActive() {
    guard let controller = pipController, controller.isPictureInPictureActive else { return }
    controller.stopPictureInPicture()
    isActive = false
    print("[PiP] Stopped (app in foreground)")
  }

  // MARK: - AVPictureInPictureControllerDelegate

  func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
    print("[PiP] Will start")
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
    print("[PiP] Did stop")
    isActive = false
  }

  func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
    print("[PiP] Failed to start: \(error.localizedDescription)")
  }

  deinit {
    displayLink?.invalidate()
    NotificationCenter.default.removeObserver(self)
  }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate
@available(iOS 15.0, *)
extension IntercomPiPManager: AVPictureInPictureSampleBufferPlaybackDelegate {
  func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
    // No-op: we're always "playing"
  }

  func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
    return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
  }

  func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
    return false // Always playing
  }

  func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
    // No-op
  }

  func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
    completionHandler()
  }
}
