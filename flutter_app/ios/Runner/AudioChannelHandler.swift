import Flutter
import AVFoundation
import AudioToolbox
import MediaPlayer
import UIKit
import UserNotifications

/// Handles the `tv.huin.intercom/audio` method channel on iOS. Provides
/// earpiece / speakerphone / Bluetooth / wired routing through AVAudioSession,
/// mirroring the Android AudioManager.setCommunicationDevice semantics.
class AudioChannelHandler: NSObject {
    static let shared = AudioChannelHandler()

    private var channel: FlutterMethodChannel?
    /// Synthetic integer id -> real AVAudioSessionPortDescription.
    /// Synthetic ids allow us to reuse the Android-style int deviceId protocol.
    private var portIdMap: [Int: AVAudioSessionPortDescription] = [:]
    private var nextId: Int = 100

    // Ringtone
    private var ringPlayer: AVAudioPlayer?
    private var ringTimer: Timer?
    private var ringSoundId: SystemSoundID = 0
    private var ringBgTaskId: UIBackgroundTaskIdentifier = .invalid
    private static let ringNotifId = "tv.huin.intercom.ring"

    // Well-known synthetic ids shared with Android semantics.
    private let kIdEarpiece = -1
    private let kIdSpeakerphone = -2
    private let kIdBuiltInMic = -10

    // Audio focus monitor state — tracks whether the native side has been
    // asked to watch for interruptions so we subscribe only once.
    private var focusMonitorActive = false

    func register(with messenger: FlutterBinaryMessenger) {
        let ch = FlutterMethodChannel(name: "tv.huin.intercom/audio", binaryMessenger: messenger)
        ch.setMethodCallHandler { [weak self] call, result in
            self?.handle(call: call, result: result)
        }
        channel = ch

        // Re-emit devicesChanged when iOS reports a route change (BT/wired
        // plug/unplug, Siri/Control Center toggle, ...).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )

        // Audio session interruptions (phone calls, FaceTime, WhatsApp, etc.)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )

        // Headset button (play/pause on BT headsets / EarPods).
        // MPRemoteCommandCenter captures the hardware button even when
        // no MPNowPlayingSession is active.
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async {
                self?.channel?.invokeMethod("headsetButtonPressed", arguments: nil)
                NSLog("[IntercomAudio] Headset button pressed (togglePlayPause)")
            }
            return .success
        }
        // Activate a minimal audio session so the remote command center
        // stays responsive even when no WebRTC track is playing yet.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .defaultToSpeaker, .mixWithOthers])
        try? session.setActive(true)

        // Ask the user for notification permission up-front so the ring
        // banner has a chance to appear when the app is backgrounded.
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, error in
            if let error {
                NSLog("[IntercomAudio] Notif authorization error: \(error.localizedDescription)")
            } else {
                NSLog("[IntercomAudio] Notif authorization granted=\(granted)")
            }
        }
    }

    @objc private func onRouteChange(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.channel?.invokeMethod("devicesChanged", arguments: nil)
        }
    }

    /// Bridge AVAudioSession interruptions (phone calls, FaceTime, VoIP apps
    /// that use CallKit) into Dart-level events so the intercom can release
    /// the microphone and duck its incoming audio while the call is active.
    @objc private func onInterruption(_ note: Notification) {
        guard focusMonitorActive else { return }
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            // The session stays active (.mixWithOthers allows ducked
            // playback alongside the interrupting call). We only notify
            // Dart so it can duck the intercom volume and mute the mic.
            NSLog("[IntercomAudio] Interruption began (session stays active for ducking)")
            DispatchQueue.main.async { [weak self] in
                self?.channel?.invokeMethod("audioFocusLost", arguments: nil)
            }
        case .ended:
            // Re-ensure the session is active and notify Dart to restore
            // full volume and re-acquire the mic.
            let session = AVAudioSession.sharedInstance()
            try? session.setActive(true)
            NSLog("[IntercomAudio] Interruption ended — session reactivated")
            DispatchQueue.main.async { [weak self] in
                self?.channel?.invokeMethod("audioFocusGained", arguments: nil)
            }
        @unknown default:
            break
        }
    }

    // MARK: - Channel dispatch

    private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "releaseAudioFocus":
            // iOS manages audio focus via the system; no-op here.
            result(nil)
        case "listCommunicationDevices":
            result(listDevices())
        case "setCommunicationDevice":
            let args = call.arguments as? [String: Any]
            let id = args?["deviceId"] as? Int
            result(setDevice(id: id))
        case "clearCommunicationDevice":
            clearDevice()
            result(nil)
        case "ensureBluetoothPermission":
            // iOS doesn't require a separate permission for AVAudioSession-
            // managed Bluetooth audio routing.
            result(true)
        case "playRingtone":
            playRingtone()
            result(nil)
        case "stopRingtone":
            stopRingtone()
            result(nil)
        case "requestAudioFocusMonitor":
            let args = call.arguments as? [String: Any]
            let enable = (args?["enable"] as? Bool) ?? true
            focusMonitorActive = enable
            NSLog("[IntercomAudio] Audio focus monitor enable=\(enable)")
            result(true)
        case "setSidetoneLevel":
            // Placeholder. Actual loopback needs a dedicated AVAudio graph
            // which is out of scope for this release; the Dart side already
            // persists the chosen level and retries on future builds.
            result(true)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Enumeration

    private func listDevices() -> [[String: Any]] {
        ensureCategory()
        var out: [[String: Any]] = []

        // Built-in earpiece (output-only route). The paired mic is reflected
        // separately as "Phone mic" below.
        out.append([
            "deviceId": kIdEarpiece,
            "label": "Earpiece",
            "type": typeCode(.builtInReceiver),
            "communication": true,
            "isInput": false,
            "isOutput": true,
        ])
        // Built-in loudspeaker (output-only).
        out.append([
            "deviceId": kIdSpeakerphone,
            "label": "Speakerphone",
            "type": typeCode(.builtInSpeaker),
            "communication": true,
            "isInput": false,
            "isOutput": true,
        ])
        // Built-in microphone (input-only). Selecting it clears any external
        // preferred input and keeps the current output route.
        out.append([
            "deviceId": kIdBuiltInMic,
            "label": "Phone mic",
            "type": 15, // TYPE_BUILTIN_MIC
            "communication": true,
            "isInput": true,
            "isOutput": false,
        ])

        // Rebuild synthetic ids for external ports on every enumeration.
        portIdMap.removeAll()
        nextId = 100

        let session = AVAudioSession.sharedInstance()
        for port in session.availableInputs ?? [] {
            // Skip the built-in mic; we already added a synthetic entry for it.
            if port.portType == .builtInMic { continue }
            let id = nextId
            nextId += 1
            portIdMap[id] = port
            let caps = capabilities(port.portType)
            out.append([
                "deviceId": id,
                "label": port.portName,
                "type": typeCode(port.portType),
                "communication": isCommunicationPort(port.portType),
                "isInput": caps.input,
                "isOutput": caps.output,
            ])
        }
        // Surface the currently-routed external outputs (wired headphones,
        // Bluetooth A2DP, BLE) even though they aren't in availableInputs.
        for desc in session.currentRoute.outputs {
            switch desc.portType {
            case .headphones, .bluetoothA2DP, .bluetoothLE, .carAudio:
                let id = nextId
                nextId += 1
                portIdMap[id] = desc
                out.append([
                    "deviceId": id,
                    "label": desc.portName,
                    "type": typeCode(desc.portType),
                    "communication": isCommunicationPort(desc.portType),
                    "isInput": false,
                    "isOutput": true,
                ])
            default: break
            }
        }
        return out
    }

    private func capabilities(_ t: AVAudioSession.Port) -> (input: Bool, output: Bool) {
        switch t {
        case .builtInReceiver, .builtInSpeaker, .headphones,
             .bluetoothA2DP, .bluetoothLE, .carAudio, .airPlay, .HDMI:
            return (false, true)
        case .builtInMic:
            return (true, false)
        case .headsetMic, .bluetoothHFP, .usbAudio:
            return (true, true)
        default:
            return (true, true)
        }
    }

    // MARK: - Routing

    private func setDevice(id: Int?) -> Bool {
        ensureCategory()
        let session = AVAudioSession.sharedInstance()
        do {
            switch id {
            case nil, kIdEarpiece:
                try session.setPreferredInput(nil)
                try session.overrideOutputAudioPort(.none)
                NSLog("[IntercomAudio] Route -> Earpiece")
                return true
            case kIdSpeakerphone:
                try session.setPreferredInput(nil)
                try session.overrideOutputAudioPort(.speaker)
                NSLog("[IntercomAudio] Route -> Speakerphone")
                return true
            case kIdBuiltInMic:
                // Input-only selection: clear preferred input, keep current output.
                try session.setPreferredInput(nil)
                NSLog("[IntercomAudio] Input -> Built-in mic")
                return true
            default:
                guard let i = id, let port = portIdMap[i] else {
                    NSLog("[IntercomAudio] Unknown deviceId: \(String(describing: id))")
                    return false
                }
                try session.setPreferredInput(port)
                try session.overrideOutputAudioPort(.none)
                NSLog("[IntercomAudio] Route -> \(port.portName) (\(port.portType.rawValue))")
                return true
            }
        } catch {
            NSLog("[IntercomAudio] setDevice error: \(error.localizedDescription)")
            return false
        }
    }

    private func clearDevice() {
        let session = AVAudioSession.sharedInstance()
        try? session.setPreferredInput(nil)
        try? session.overrideOutputAudioPort(.none)
    }

    // MARK: - Ringtone

    /// Play a looping ringtone. Prefers a bundled `ringtone.caf/.m4a/.wav/.mp3`
    /// via AVAudioPlayer; falls back to a generated phone-style ring WAV in
    /// memory (also looped via AVAudioPlayer so it survives when the app is
    /// in background thanks to UIBackgroundModes=audio).
    ///
    /// Additionally posts a time-sensitive local notification so the user
    /// sees a banner on the lock screen and can tap to bring the app back
    /// to the foreground (iOS does not allow self-activation).
    private func playRingtone() {
        stopRingtone()

        // Take a background-task assertion so the repeating logic has some
        // runtime even if the app is mid-suspension when the ring arrives.
        beginRingBackgroundTask()

        // Make sure the audio session is active; playback in background
        // requires this to be set BEFORE the app is suspended.
        activateSessionForRinging()

        // 1) Prefer a bundled asset if the user shipped one.
        let candidates: [(String, String)] = [
            ("ringtone", "caf"), ("ringtone", "m4a"),
            ("ringtone", "wav"), ("ringtone", "mp3"),
        ]
        for (name, ext) in candidates {
            if let url = Bundle.main.url(forResource: name, withExtension: ext),
               let p = try? AVAudioPlayer(contentsOf: url) {
                p.numberOfLoops = -1
                p.volume = 1.0
                p.prepareToPlay()
                if p.play() {
                    ringPlayer = p
                    postIncomingRingNotification()
                    NSLog("[IntercomAudio] Ringtone started (asset \(name).\(ext))")
                    return
                }
            }
        }

        // 2) Generated fallback: a traditional dual-tone (440+480 Hz) ring
        //    pattern encoded as PCM16 WAV in memory, looped forever.
        if let data = Self.makeRingWavData(),
           let p = try? AVAudioPlayer(data: data) {
            p.numberOfLoops = -1
            p.volume = 1.0
            p.prepareToPlay()
            if p.play() {
                ringPlayer = p
                postIncomingRingNotification()
                NSLog("[IntercomAudio] Ringtone started (generated WAV, looped)")
                return
            }
        }

        // 3) Last-resort fallback: system sound + repeating timer. This will
        //    only really fire in foreground; the posted notification covers
        //    the background case.
        let soundId: SystemSoundID = 1005
        ringSoundId = soundId
        ringTimer?.invalidate()
        ringTimer = Timer.scheduledTimer(withTimeInterval: 1.8, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            AudioServicesPlaySystemSound(self.ringSoundId)
        }
        AudioServicesPlaySystemSound(soundId)
        postIncomingRingNotification()
        NSLog("[IntercomAudio] Ringtone started (system sound, no loop support)")
    }

    private func stopRingtone() {
        ringPlayer?.stop()
        ringPlayer = nil
        ringTimer?.invalidate()
        ringTimer = nil
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.ringNotifId])
        center.removeDeliveredNotifications(withIdentifiers: [Self.ringNotifId])
        endRingBackgroundTask()
    }

    private func activateSessionForRinging() {
        let session = AVAudioSession.sharedInstance()
        do {
            // Keep whatever category the session has (usually .playAndRecord
            // from ensureCategory above); just make sure it's active.
            try session.setActive(true, options: [])
        } catch {
            NSLog("[IntercomAudio] activateSessionForRinging: \(error.localizedDescription)")
        }
    }

    private func postIncomingRingNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Winus Intercom"
        content.body = "Someone wants your attention — tap to open"
        content.sound = .default
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
        }
        let request = UNNotificationRequest(
            identifier: Self.ringNotifId,
            content: content,
            trigger: nil // deliver immediately
        )
        UNUserNotificationCenter.current().add(request) { err in
            if let err {
                NSLog("[IntercomAudio] post ring notif failed: \(err.localizedDescription)")
            }
        }
    }

    private func beginRingBackgroundTask() {
        if ringBgTaskId != .invalid { return }
        ringBgTaskId = UIApplication.shared.beginBackgroundTask(withName: "ring") { [weak self] in
            self?.endRingBackgroundTask()
        }
    }

    private func endRingBackgroundTask() {
        if ringBgTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(ringBgTaskId)
            ringBgTaskId = .invalid
        }
    }

    // MARK: - Ringtone WAV generation (pure Swift, no assets needed)

    /// Build ~4 s of PCM16 mono 44.1 kHz WAV bytes in memory, containing a
    /// classic "brrring … brrring" pattern (two 1 s dual-tone bursts followed
    /// by silence). AVAudioPlayer will loop this forever with numberOfLoops=-1.
    private static func makeRingWavData() -> Data? {
        let sampleRate: Double = 44_100
        let totalSec: Double = 4.0
        let totalSamples = Int(sampleRate * totalSec)
        var samples = [Int16](repeating: 0, count: totalSamples)

        // Two ring bursts within the 4 s pattern.
        let bursts: [(Double, Double)] = [(0.0, 1.0), (1.3, 2.3)]
        let freq1: Double = 440
        let freq2: Double = 480
        let maxAmp: Double = 9000 // keep sum(sin)*amp within Int16 range

        for (startSec, endSec) in bursts {
            let startIdx = Int(startSec * sampleRate)
            let endIdx = Int(endSec * sampleRate)
            let burstLen = Double(endIdx - startIdx) / sampleRate
            for i in startIdx..<min(endIdx, totalSamples) {
                let localSec = Double(i - startIdx) / sampleRate
                // 20 ms linear fade-in/out to avoid clicks.
                let env: Double
                if localSec < 0.02 {
                    env = localSec / 0.02
                } else if localSec > burstLen - 0.02 {
                    env = max(0, (burstLen - localSec) / 0.02)
                } else {
                    env = 1.0
                }
                let wave = sin(2 * .pi * freq1 * localSec) + sin(2 * .pi * freq2 * localSec)
                let v = wave * env * maxAmp
                samples[i] = Int16(clamping: Int(v))
            }
        }

        let dataSize = samples.count * MemoryLayout<Int16>.size
        var wav = Data()
        wav.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataSize), to: &wav)
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16), to: &wav)    // fmt chunk size
        append(UInt16(1), to: &wav)     // PCM
        append(UInt16(1), to: &wav)     // mono
        append(UInt32(sampleRate), to: &wav)
        append(UInt32(sampleRate * 2), to: &wav) // byte rate (sampleRate*blockAlign)
        append(UInt16(2), to: &wav)     // block align
        append(UInt16(16), to: &wav)    // bits per sample
        wav.append(contentsOf: Array("data".utf8))
        append(UInt32(dataSize), to: &wav)
        samples.withUnsafeBufferPointer { buf in
            let raw = UnsafeRawBufferPointer(buf)
            if let ptr = raw.baseAddress {
                wav.append(ptr.assumingMemoryBound(to: UInt8.self), count: raw.count)
            }
        }
        return wav
    }

    private static func append(_ v: UInt32, to data: inout Data) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func append(_ v: UInt16, to data: inout Data) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    // MARK: - Helpers

    /// Make sure the audio session is configured so availableInputs includes
    /// Bluetooth HFP headsets. We explicitly keep speakerphone OFF by default
    /// so `overrideOutputAudioPort(.none)` actually sends audio to the earpiece.
    private func ensureCategory() {
        let session = AVAudioSession.sharedInstance()
        let options: AVAudioSession.CategoryOptions = [
            .allowBluetooth,        // enables BT HFP (mic + mono playback)
            .allowBluetoothA2DP,    // enables BT A2DP fall-back (output only)
            .mixWithOthers,
        ]
        do {
            if session.category != .playAndRecord
                || session.mode != .voiceChat
                || session.categoryOptions != options {
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
            }
            if !session.isOtherAudioPlaying {
                try session.setActive(true, options: [])
            }
        } catch {
            NSLog("[IntercomAudio] ensureCategory error: \(error.localizedDescription)")
        }
    }

    /// True for ports that can carry bidirectional voice (mic + spkr).
    private func isCommunicationPort(_ t: AVAudioSession.Port) -> Bool {
        switch t {
        case .bluetoothA2DP, .bluetoothLE:
            return false
        default:
            return true
        }
    }

    /// Map iOS port types to Android AudioDeviceInfo type ints so the Flutter
    /// layer can treat them uniformly.
    private func typeCode(_ t: AVAudioSession.Port) -> Int {
        switch t {
        case .builtInReceiver:   return 1   // TYPE_BUILTIN_EARPIECE
        case .builtInSpeaker:    return 2   // TYPE_BUILTIN_SPEAKER
        case .headsetMic:        return 3   // TYPE_WIRED_HEADSET
        case .headphones:        return 4   // TYPE_WIRED_HEADPHONES
        case .bluetoothHFP:      return 7   // TYPE_BLUETOOTH_SCO
        case .bluetoothA2DP:     return 8   // TYPE_BLUETOOTH_A2DP
        case .usbAudio:          return 22  // TYPE_USB_HEADSET
        case .bluetoothLE:       return 26  // TYPE_BLE_HEADSET
        case .carAudio:          return 0
        default:                 return 0
        }
    }
}
