package tv.huin.intercom

import android.Manifest
import android.app.PictureInPictureParams
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.Build
import android.telephony.PhoneStateListener
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import android.util.Log
import android.view.KeyEvent
import android.util.Rational
import androidx.core.app.ActivityCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val CHANNEL = "tv.huin.intercom/pip"
    private val AUDIO_CHANNEL = "tv.huin.intercom/audio"
    private var pipEnabled = true
    private var audioFocusRequest: AudioFocusRequest? = null
    private var audioChannel: MethodChannel? = null
    private var deviceCallback: AudioDeviceCallback? = null
    private var ringtone: Ringtone? = null

    // Audio-focus monitoring for VoIP/GSM calls. We keep a persistent
    // AudioFocusRequest (separate from the MEDIA one used by
    // releaseExclusiveAudioFocus) whose only job is to detect when another
    // app takes the communication audio focus — typical triggers: incoming
    // phone call, WhatsApp/FaceTime VoIP call, dialer dial-out.
    private var callFocusRequest: AudioFocusRequest? = null
    private var callFocusHeld: Boolean = false
    // API 31+ TelephonyCallback (reinforcement path): some OEMs emit only
    // phone-state events and not a clean AUDIOFOCUS_LOSS, so we subscribe
    // to both to cover all cases.
    @Suppress("DEPRECATION")
    private var phoneStateListener: PhoneStateListener? = null
    private var telephonyCallback: TelephonyCallback? = null
    private var lastPhoneState: Int = TelephonyManager.CALL_STATE_IDLE

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        try {
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "enablePip" -> {
                            pipEnabled = call.argument<Boolean>("enabled") ?: true
                            updatePipParams()
                            result.success(null)
                        }
                        "enterPip" -> {
                            result.success(enterPipMode())
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Throwable) {
                    Log.e("IntercomAudio", "pip channel handler error", e)
                    try { result.error("PIP_ERROR", e.message, null) } catch (_: Throwable) {}
                }
            }
        } catch (e: Throwable) {
            Log.e("IntercomAudio", "pip channel setup error", e)
        }

        try {
            audioChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AUDIO_CHANNEL)
            audioChannel!!.setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "releaseAudioFocus" -> {
                            releaseExclusiveAudioFocus()
                            result.success(null)
                        }
                        "listCommunicationDevices" -> {
                            result.success(listCommunicationDevices())
                        }
                        "setCommunicationDevice" -> {
                            val id = call.argument<Int>("deviceId")
                            result.success(setCommunicationDevice(id))
                        }
                        "clearCommunicationDevice" -> {
                            clearCommunicationDevice()
                            result.success(null)
                        }
                        "ensureBluetoothPermission" -> {
                            result.success(ensureBluetoothPermission())
                        }
                        "playRingtone" -> {
                            playRingtone()
                            result.success(null)
                        }
                        "stopRingtone" -> {
                            stopRingtone()
                            result.success(null)
                        }
                        "requestAudioFocusMonitor" -> {
                            val enable = call.argument<Boolean>("enable") ?: true
                            if (enable) startAudioFocusMonitor() else stopAudioFocusMonitor()
                            result.success(true)
                        }
                        "setSidetoneLevel" -> {
                            // Placeholder — actual sidetone loopback requires a
                            // dedicated native path. Acknowledge so the Dart
                            // side doesn't log errors.
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Throwable) {
                    Log.e("IntercomAudio", "audio channel handler error", e)
                    try { result.error("AUDIO_ERROR", e.message, null) } catch (_: Throwable) {}
                }
            }
        } catch (e: Throwable) {
            Log.e("IntercomAudio", "audio channel setup error", e)
        }

        // NOTE: BT permission request and AudioDeviceCallback registration are
        // intentionally deferred to onResume(). Calling them from
        // configureFlutterEngine (i.e. during onCreate) has shown crashes on
        // some OEMs because the activity window is not yet fully attached.
    }

    private fun registerAudioDeviceCallback() {
        if (deviceCallback != null) return
        try {
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            val cb = object : AudioDeviceCallback() {
                override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) {
                    notifyDevicesChanged()
                }
                override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>?) {
                    notifyDevicesChanged()
                }
            }
            am.registerAudioDeviceCallback(cb, Handler(Looper.getMainLooper()))
            deviceCallback = cb
        } catch (e: Throwable) {
            Log.w("IntercomAudio", "registerAudioDeviceCallback failed: $e")
        }
    }

    private fun notifyDevicesChanged() {
        runOnUiThread {
            try {
                audioChannel?.invokeMethod("devicesChanged", null)
            } catch (e: Exception) {
                Log.w("IntercomAudio", "devicesChanged dispatch error: $e")
            }
        }
    }

    override fun onDestroy() {
        deviceCallback?.let {
            try {
                val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                am.unregisterAudioDeviceCallback(it)
            } catch (_: Exception) {}
        }
        deviceCallback = null
        try { stopAudioFocusMonitor() } catch (_: Exception) {}
        audioChannel = null
        super.onDestroy()
    }

    // ======================== AUDIO FOCUS MONITOR ========================

    /**
     * Request a persistent AudioFocus so we get notified when a phone/VoIP
     * call steals the communication audio session. Also registers a
     * TelephonyCallback as a fallback so we can detect GSM calls whose audio
     * focus behaviour depends on the OEM.
     */
    private fun startAudioFocusMonitor() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (callFocusRequest == null) {
                val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                            .build()
                    )
                    .setAcceptsDelayedFocusGain(true)
                    .setWillPauseWhenDucked(false)
                    .setOnAudioFocusChangeListener { change ->
                        handleFocusChange(change)
                    }
                    .build()
                callFocusRequest = req
                val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                val res = am.requestAudioFocus(req)
                callFocusHeld = res == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
                Log.i("IntercomAudio", "Audio focus monitor started (granted=$callFocusHeld)")
            }
        }
        registerPhoneStateListener()
    }

    private fun stopAudioFocusMonitor() {
        cancelFocusRetry()
        cancelPendingLoss()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            callFocusRequest?.let { req ->
                val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                try { am.abandonAudioFocusRequest(req) } catch (_: Exception) {}
            }
            callFocusRequest = null
            callFocusHeld = false
        }
        unregisterPhoneStateListener()
        Log.i("IntercomAudio", "Audio focus monitor stopped")
    }

    // Handler used to retry audio-focus acquisition after a loss. Android
    // does NOT fire a spontaneous AUDIOFOCUS_GAIN when a VoIP call (WhatsApp,
    // FaceTime, ...) ends — we have to re-request and watch the result.
    private val focusRetryHandler = Handler(Looper.getMainLooper())
    private var focusRetryRunnable: Runnable? = null

    // Pending dispatch of "focus lost". We delay reporting losses to Dart by
    // a few seconds so brief events that also steal focus (our own incoming
    // PTT audio, a ringtone, system beeps, etc.) don't toggle the
    // "Call in progress" chip. If the foco is regained inside the window we
    // simply cancel the pending dispatch.
    private val focusLossDispatchHandler = Handler(Looper.getMainLooper())
    private var pendingLossRunnable: Runnable? = null
    private val FOCUS_LOSS_DEBOUNCE_MS = 3000L

    private fun handleFocusChange(change: Int) {
        when (change) {
            // LOSS / LOSS_TRANSIENT only — these mean another app took the
            // VOICE_COMMUNICATION focus (real call). LOSS_TRANSIENT_CAN_DUCK
            // (notifications, navigation prompts, etc.) is intentionally
            // ignored.
            AudioManager.AUDIOFOCUS_LOSS,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                // Skip pre-GAIN spurious losses: some Android builds fire a
                // LOSS right after requestAudioFocus before the first GAIN.
                if (!callFocusHeld) {
                    Log.i("IntercomAudio", "Audio focus loss before first gain — ignoring (change=$change)")
                    return
                }
                callFocusHeld = false

                // Abandon the VOICE_COMMUNICATION focus request so the
                // interrupting app (WhatsApp, GSM dialer…) has clean access
                // to the communication channel. We keep MODE_IN_COMMUNICATION
                // so WebRTC audio keeps playing (ducked by the system).
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    callFocusRequest?.let { req ->
                        try {
                            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                            am.abandonAudioFocusRequest(req)
                        } catch (_: Exception) {}
                    }
                    callFocusRequest = null
                    Log.i("IntercomAudio", "Abandoned VOICE_COMMUNICATION focus (change=$change)")
                }

                schedulePendingLoss()
                scheduleFocusRetry()
            }
            AudioManager.AUDIOFOCUS_GAIN -> {
                callFocusHeld = true
                cancelFocusRetry()
                cancelPendingLoss()
                dispatchFocusGained()
            }
        }
    }

    /// Schedule the actual focusLost dispatch after a debounce window. If
    /// focus comes back within the window, [cancelPendingLoss] is called and
    /// nothing is reported.
    private fun schedulePendingLoss() {
        cancelPendingLoss()
        val r = Runnable {
            // Re-check that we still don't hold focus before reporting.
            if (!callFocusHeld) {
                Log.i("IntercomAudio", "Focus loss persisted ${FOCUS_LOSS_DEBOUNCE_MS}ms — dispatching")
                dispatchFocusLost()
            }
            pendingLossRunnable = null
        }
        pendingLossRunnable = r
        focusLossDispatchHandler.postDelayed(r, FOCUS_LOSS_DEBOUNCE_MS)
    }

    private fun cancelPendingLoss() {
        pendingLossRunnable?.let { focusLossDispatchHandler.removeCallbacks(it) }
        pendingLossRunnable = null
    }

    /// Periodically try to re-acquire audio focus after a loss. The first
    /// successful (or DELAYED) response means the call/interruption ended
    /// and we can resume the intercom.
    ///
    /// We rebuild the AudioFocusRequest each time because handleFocusChange
    /// abandons the original one so WhatsApp / GSM can connect cleanly.
    /// The initial delay is long (10 s) so the other app has plenty of time
    /// to set up its call; subsequent probes are every 5 s.
    private fun scheduleFocusRetry() {
        cancelFocusRetry()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val r = object : Runnable {
            override fun run() {
                if (callFocusHeld) {
                    focusRetryRunnable = null
                    return
                }
                // Build a fresh request each probe.
                val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                            .build()
                    )
                    .setAcceptsDelayedFocusGain(true)
                    .setWillPauseWhenDucked(false)
                    .setOnAudioFocusChangeListener { change ->
                        handleFocusChange(change)
                    }
                    .build()
                val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                val res = try { am.requestAudioFocus(req) } catch (_: Exception) {
                    AudioManager.AUDIOFOCUS_REQUEST_FAILED
                }
                when (res) {
                    AudioManager.AUDIOFOCUS_REQUEST_GRANTED -> {
                        callFocusRequest = req
                        callFocusHeld = true
                        dispatchFocusGained()
                        focusRetryRunnable = null
                        Log.i("IntercomAudio", "Focus re-acquired (call ended)")
                    }
                    AudioManager.AUDIOFOCUS_REQUEST_DELAYED -> {
                        callFocusRequest = req
                        // The listener will fire AUDIOFOCUS_GAIN later.
                        focusRetryRunnable = null
                    }
                    else -> {
                        // Still busy (call ongoing). Retry in 5 s.
                        focusRetryHandler.postDelayed(this, 5000)
                    }
                }
            }
        }
        focusRetryRunnable = r
        // Long initial delay so WhatsApp/VoIP has time to connect and
        // stabilise before we probe for focus again.
        focusRetryHandler.postDelayed(r, 10_000)
    }

    private fun cancelFocusRetry() {
        focusRetryRunnable?.let { focusRetryHandler.removeCallbacks(it) }
        focusRetryRunnable = null
    }

    private fun dispatchFocusLost() {
        runOnUiThread {
            try { audioChannel?.invokeMethod("audioFocusLost", null) } catch (_: Exception) {}
        }
    }

    private fun dispatchFocusGained() {
        runOnUiThread {
            try { audioChannel?.invokeMethod("audioFocusGained", null) } catch (_: Exception) {}
        }
    }

    @Suppress("DEPRECATION")
    private fun registerPhoneStateListener() {
        // Phone state subscription is optional — it doesn't need READ_PHONE_STATE
        // for CALL_STATE on API 31+, but we guard against older ROMs throwing.
        try {
            val tm = getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val cb = object : TelephonyCallback(), TelephonyCallback.CallStateListener {
                    override fun onCallStateChanged(state: Int) {
                        onPhoneStateChanged(state)
                    }
                }
                tm.registerTelephonyCallback(Executors.newSingleThreadExecutor(), cb)
                telephonyCallback = cb
            } else {
                val listener = object : PhoneStateListener() {
                    override fun onCallStateChanged(state: Int, phoneNumber: String?) {
                        onPhoneStateChanged(state)
                    }
                }
                tm.listen(listener, PhoneStateListener.LISTEN_CALL_STATE)
                phoneStateListener = listener
            }
        } catch (e: Throwable) {
            Log.w("IntercomAudio", "registerPhoneStateListener failed: $e")
        }
    }

    @Suppress("DEPRECATION")
    private fun unregisterPhoneStateListener() {
        try {
            val tm = getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                telephonyCallback?.let { tm.unregisterTelephonyCallback(it) }
            } else {
                phoneStateListener?.let { tm.listen(it, PhoneStateListener.LISTEN_NONE) }
            }
        } catch (_: Exception) {}
        telephonyCallback = null
        phoneStateListener = null
        lastPhoneState = TelephonyManager.CALL_STATE_IDLE
    }

    private fun onPhoneStateChanged(state: Int) {
        if (state == lastPhoneState) return
        lastPhoneState = state
        when (state) {
            TelephonyManager.CALL_STATE_RINGING,
            TelephonyManager.CALL_STATE_OFFHOOK -> dispatchFocusLost()
            TelephonyManager.CALL_STATE_IDLE -> dispatchFocusGained()
        }
    }

    // ======================== RINGTONE ========================

    /**
     * Play the system default ringtone in a loop until stopRingtone is called.
     * Uses Ringtone (not MediaPlayer) so we pick up user preferences and
     * route through the music stream (respects volume control).
     */
    private fun playRingtone() {
        try {
            stopRingtone() // ensure idempotent
            val uri: Uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
            val rt = RingtoneManager.getRingtone(applicationContext, uri) ?: return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                rt.isLooping = true
            }
            rt.audioAttributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            rt.play()
            ringtone = rt
            Log.i("IntercomAudio", "Ringtone started")
        } catch (e: Exception) {
            Log.w("IntercomAudio", "playRingtone error: $e")
        }
    }

    private fun stopRingtone() {
        try {
            ringtone?.stop()
        } catch (_: Exception) {}
        ringtone = null
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 4242) {
            // BLUETOOTH_CONNECT dialog resolved: device visibility may have
            // just expanded/collapsed, so ask Flutter to re-enumerate.
            notifyDevicesChanged()
        }
    }

    private fun ensureBluetoothPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        return try {
            val granted = ActivityCompat.checkSelfPermission(
                this, Manifest.permission.BLUETOOTH_CONNECT
            ) == PackageManager.PERMISSION_GRANTED
            if (!granted) {
                ActivityCompat.requestPermissions(
                    this, arrayOf(Manifest.permission.BLUETOOTH_CONNECT), 4242
                )
            }
            granted
        } catch (e: Throwable) {
            Log.w("IntercomAudio", "ensureBluetoothPermission failed: $e")
            false
        }
    }

    // ======================== AUDIO ROUTING ========================

    /**
     * Return the list of devices usable for communication audio routing
     * (earpiece, speaker, wired headset, Bluetooth SCO, USB headset, hearing aid, ...).
     * On API < 31 we return a synthetic list (speaker / earpiece / bluetooth).
     */
    private fun listCommunicationDevices(): List<Map<String, Any?>> {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val out = mutableListOf<Map<String, Any?>>()
        val seen = mutableSetOf<Int>()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Pass 1: canonical communication devices (earpiece, speaker, HFP BT, wired, USB, ...)
            for (d in am.availableCommunicationDevices) {
                if (!seen.add(d.id)) continue
                val label = friendlyLabel(d)
                val caps = capabilities(d.type)
                out.add(mapOf(
                    "deviceId" to d.id,
                    "label" to label,
                    "type" to d.type,
                    "communication" to true,
                    "isInput" to caps.first,
                    "isOutput" to caps.second,
                ))
                Log.i("IntercomAudio", "Comm device: id=${d.id} type=${d.type} name=$label in=${caps.first} out=${caps.second}")
            }
            // Synthetic "Phone mic" entry so the microphone dropdown is never
            // empty and the user can fall back to the built-in mic even while
            // an external BT headset (Jabra) is connected. Selecting it calls
            // clearCommunicationDevice() which resets to the system default
            // route (builtin mic paired with earpiece/speaker).
            out.add(mapOf(
                "deviceId" to -10,
                "label" to "Phone mic",
                "type" to AudioDeviceInfo.TYPE_BUILTIN_MIC,
                "communication" to true,
                "isInput" to true,
                "isOutput" to false,
            ))
            // Pass 2: also surface A2DP/BLE/... output devices so a second BT
            // headset (e.g. Bose A2DP) shows up in the UI even if it's not
            // currently the active communication route.
            for (d in am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)) {
                if (!seen.add(d.id)) continue
                // Skip internal/duplicate nodes
                if (d.type == AudioDeviceInfo.TYPE_TELEPHONY ||
                    d.type == AudioDeviceInfo.TYPE_REMOTE_SUBMIX) continue
                val label = friendlyLabel(d)
                val caps = capabilities(d.type)
                // Non-comm devices are output-only by definition (they're
                // coming from GET_DEVICES_OUTPUTS), never expose them as inputs.
                out.add(mapOf(
                    "deviceId" to d.id,
                    "label" to label,
                    "type" to d.type,
                    "communication" to false,
                    "isInput" to false,
                    "isOutput" to caps.second,
                ))
                Log.i("IntercomAudio", "Output-only device: id=${d.id} type=${d.type} name=$label")
            }
        } else {
            // Legacy fallback: synthetic negative IDs decoded in setCommunicationDevice.
            out.add(mapOf(
                "deviceId" to -1, "label" to "Earpiece",
                "type" to AudioDeviceInfo.TYPE_BUILTIN_EARPIECE,
                "communication" to true, "isInput" to false, "isOutput" to true,
            ))
            out.add(mapOf(
                "deviceId" to -2, "label" to "Speakerphone",
                "type" to AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
                "communication" to true, "isInput" to false, "isOutput" to true,
            ))
            @Suppress("DEPRECATION")
            if (am.isBluetoothScoAvailableOffCall) {
                out.add(mapOf(
                    "deviceId" to -3, "label" to "Bluetooth",
                    "type" to AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
                    "communication" to true, "isInput" to true, "isOutput" to true,
                ))
            }
        }
        return out
    }

    /// Produce a user-friendly label. For built-in hardware the OEM-provided
    /// productName collides (e.g. Samsung reports "SM-S928B" for BOTH the
    /// earpiece and the speaker), which makes the dropdown unreadable, so we
    /// force the canonical type name for those cases.
    private fun friendlyLabel(d: AudioDeviceInfo): String {
        return when (d.type) {
            AudioDeviceInfo.TYPE_BUILTIN_EARPIECE,
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
            AudioDeviceInfo.TYPE_BUILTIN_MIC,
            AudioDeviceInfo.TYPE_TELEPHONY,
            AudioDeviceInfo.TYPE_REMOTE_SUBMIX -> audioTypeLabel(d.type)
            else -> (d.productName?.toString()?.takeIf { it.isNotBlank() })
                ?: audioTypeLabel(d.type)
        }
    }

    /// Return (isInput, isOutput) for a given AudioDeviceInfo type. Used to
    /// keep the microphone and speaker dropdowns from cross-contaminating.
    private fun capabilities(type: Int): Pair<Boolean, Boolean> = when (type) {
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE   -> false to true
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER    -> false to true
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES   -> false to true
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP     -> false to true
        AudioDeviceInfo.TYPE_BLE_SPEAKER        -> false to true
        AudioDeviceInfo.TYPE_HDMI               -> false to true
        AudioDeviceInfo.TYPE_DOCK               -> false to true
        AudioDeviceInfo.TYPE_BUILTIN_MIC        -> true to false
        AudioDeviceInfo.TYPE_WIRED_HEADSET      -> true to true
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO      -> true to true
        AudioDeviceInfo.TYPE_USB_HEADSET        -> true to true
        AudioDeviceInfo.TYPE_USB_DEVICE         -> true to true
        AudioDeviceInfo.TYPE_USB_ACCESSORY      -> true to true
        AudioDeviceInfo.TYPE_HEARING_AID        -> true to true
        AudioDeviceInfo.TYPE_BLE_HEADSET        -> true to true
        else                                    -> true to true
    }

    /**
     * Route both capture (mic) and playback for communication audio to the
     * given device. Handles API 31+ via setCommunicationDevice, and falls back
     * to setSpeakerphoneOn / startBluetoothSco on older Android versions.
     */
    private fun setCommunicationDevice(deviceId: Int?): Boolean {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        // Routing via setCommunicationDevice / SCO requires communication mode.
        am.mode = AudioManager.MODE_IN_COMMUNICATION

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (deviceId == null) {
                am.clearCommunicationDevice()
                return true
            }
            // Synthetic "Phone mic" entry — reset to system default route
            // (builtin mic paired with earpiece/speaker). The UI's cross-sync
            // then picks up the new output in the speaker dropdown.
            if (deviceId == -10) {
                am.clearCommunicationDevice()
                Log.i("IntercomAudio", "Route -> default (Phone mic)")
                return true
            }
            // First try a real communication device.
            val commDevice = am.availableCommunicationDevices.firstOrNull { it.id == deviceId }
            if (commDevice != null) {
                val ok = am.setCommunicationDevice(commDevice)
                Log.i("IntercomAudio", "setCommunicationDevice(${commDevice.productName}/${commDevice.type}) -> $ok")
                return ok
            }
            // Device is a raw output (A2DP speaker/headphones like Bose, BLE, ...).
            // Map it to the closest communication profile available.
            val anyOutput = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                .firstOrNull { it.id == deviceId }
            if (anyOutput != null) {
                Log.i("IntercomAudio", "Routing to non-comm output id=${anyOutput.id} type=${anyOutput.type}")
                val fallback = when (anyOutput.type) {
                    AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
                    AudioDeviceInfo.TYPE_BLE_HEADSET,
                    AudioDeviceInfo.TYPE_BLE_SPEAKER ->
                        am.availableCommunicationDevices.firstOrNull {
                            it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                            it.type == AudioDeviceInfo.TYPE_BLE_HEADSET
                        }
                    AudioDeviceInfo.TYPE_WIRED_HEADPHONES ->
                        am.availableCommunicationDevices.firstOrNull {
                            it.type == AudioDeviceInfo.TYPE_WIRED_HEADSET ||
                            it.type == AudioDeviceInfo.TYPE_WIRED_HEADPHONES
                        }
                    else -> am.availableCommunicationDevices.firstOrNull {
                        it.type == anyOutput.type
                    }
                }
                if (fallback != null) {
                    val ok = am.setCommunicationDevice(fallback)
                    Log.i("IntercomAudio", "Fallback setCommunicationDevice(${fallback.productName}/${fallback.type}) -> $ok")
                    return ok
                }
                Log.w("IntercomAudio", "No communication fallback for output ${anyOutput.type}")
                return false
            }
            Log.w("IntercomAudio", "Device id=$deviceId not found in any output list")
            return false
        }

        // Legacy API < 31
        @Suppress("DEPRECATION")
        when (deviceId) {
            -1, null -> { // Earpiece (also used when deviceId is null)
                am.stopBluetoothSco()
                am.isBluetoothScoOn = false
                am.isSpeakerphoneOn = false
            }
            -2 -> { // Speakerphone
                am.stopBluetoothSco()
                am.isBluetoothScoOn = false
                am.isSpeakerphoneOn = true
            }
            -3 -> { // Bluetooth SCO
                am.isSpeakerphoneOn = false
                am.startBluetoothSco()
                am.isBluetoothScoOn = true
            }
            else -> return false
        }
        return true
    }

    private fun clearCommunicationDevice() {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            am.clearCommunicationDevice()
        } else {
            @Suppress("DEPRECATION")
            run {
                am.stopBluetoothSco()
                am.isBluetoothScoOn = false
                am.isSpeakerphoneOn = false
            }
        }
    }

    private fun audioTypeLabel(type: Int): String = when (type) {
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "Earpiece"
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "Speakerphone"
        AudioDeviceInfo.TYPE_WIRED_HEADSET -> "Wired Headset"
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "Wired Headphones"
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "Bluetooth"
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "Bluetooth A2DP"
        AudioDeviceInfo.TYPE_USB_HEADSET -> "USB Headset"
        AudioDeviceInfo.TYPE_USB_DEVICE -> "USB Device"
        AudioDeviceInfo.TYPE_USB_ACCESSORY -> "USB Accessory"
        AudioDeviceInfo.TYPE_HEARING_AID -> "Hearing Aid"
        AudioDeviceInfo.TYPE_BLE_HEADSET -> "BLE Headset"
        AudioDeviceInfo.TYPE_BLE_SPEAKER -> "BLE Speaker"
        AudioDeviceInfo.TYPE_DOCK -> "Dock"
        AudioDeviceInfo.TYPE_HDMI -> "HDMI"
        else -> "Audio Device"
    }

    /**
     * Release exclusive audio focus so other VoIP apps (WhatsApp, etc.) can play audio.
     * Requests non-exclusive audio focus with AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK but
     * stays in MODE_IN_COMMUNICATION so that setCommunicationDevice routing keeps
     * working (switching to MODE_NORMAL breaks SCO / speaker routing for the live
     * WebRTC tracks).
     * The microphone stays open — only the audio output exclusivity is released.
     */
    private fun releaseExclusiveAudioFocus() {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager

        // NOTE: we intentionally keep MODE_IN_COMMUNICATION here. Setting
        // MODE_NORMAL interferes with setCommunicationDevice routing, which
        // would break Jabra/SCO/speakerphone switches while a call is active.

        // Abandon any existing exclusive audio focus
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audioFocusRequest?.let { audioManager.abandonAudioFocusRequest(it) }

            // Request non-exclusive focus: other apps can duck but still play
            val focusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build()
                )
                .setAcceptsDelayedFocusGain(true)
                .setOnAudioFocusChangeListener { /* no-op: we don't need to react */ }
                .build()
            audioManager.requestAudioFocus(focusRequest)
            audioFocusRequest = focusRequest
        }
    }

    // ======================== HEADSET BUTTON ========================

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (keyCode == KeyEvent.KEYCODE_HEADSETHOOK ||
            keyCode == KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE) {
            runOnUiThread {
                try {
                    audioChannel?.invokeMethod("headsetButtonPressed", null)
                    Log.i("IntercomAudio", "Headset button pressed (keyCode=$keyCode)")
                } catch (_: Exception) {}
            }
            return true // consume the event
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (pipEnabled) {
            enterPipMode()
        }
    }

    private fun buildPipParams(): PictureInPictureParams? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return null
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(Rational(1, 1))
        // Android 12+: auto-enter PiP when app goes to background
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(pipEnabled)
            builder.setSeamlessResizeEnabled(false)
        }
        return builder.build()
    }

    private fun updatePipParams() {
        val params = buildPipParams() ?: return
        try {
            setPictureInPictureParams(params)
        } catch (_: Exception) {}
    }

    private fun enterPipMode(): Boolean {
        val params = buildPipParams() ?: return false
        try {
            enterPictureInPictureMode(params)
            return true
        } catch (e: Exception) {
            return false
        }
    }

    override fun onResume() {
        super.onResume()
        try {
            updatePipParams()
        } catch (e: Throwable) {
            Log.w("IntercomAudio", "updatePipParams failed: $e")
        }
        // Lazily request BT permission and register the audio device callback
        // AFTER the activity is fully attached to its window. Doing this in
        // configureFlutterEngine (during onCreate) can crash on some OEMs.
        // Small post-delay so the window is 100% settled before we touch
        // AudioManager / request permissions — defensive against OEM quirks.
        window?.decorView?.post {
            try { ensureBluetoothPermission() } catch (e: Throwable) {
                Log.w("IntercomAudio", "ensureBluetoothPermission(onResume) failed: $e")
            }
            try { registerAudioDeviceCallback() } catch (e: Throwable) {
                Log.w("IntercomAudio", "registerAudioDeviceCallback(onResume) failed: $e")
            }
        }
    }

    override fun onPictureInPictureModeChanged(isInPipMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPipMode, newConfig)
        // Notify Flutter of PiP state change so it can throttle UI updates
        flutterEngine?.dartExecutor?.binaryMessenger?.let { messenger ->
            MethodChannel(messenger, CHANNEL).invokeMethod("pipChanged", isInPipMode)
        }
    }
}
