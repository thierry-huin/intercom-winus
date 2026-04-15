package tv.huin.intercom.intercom_app

import android.app.PictureInPictureParams
import android.content.Context
import android.content.res.Configuration
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "tv.huin.intercom/pip"
    private val AUDIO_CHANNEL = "tv.huin.intercom/audio"
    private var pipEnabled = true
    private var audioFocusRequest: AudioFocusRequest? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
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
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AUDIO_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "releaseAudioFocus" -> {
                    releaseExclusiveAudioFocus()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Release exclusive audio focus so other VoIP apps (WhatsApp, etc.) can play audio.
     * Sets MODE_NORMAL (frees the communication channel) and requests non-exclusive
     * audio focus with AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK.
     * The microphone stays open — only the audio output exclusivity is released.
     */
    private fun releaseExclusiveAudioFocus() {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager

        // Switch from MODE_IN_COMMUNICATION to MODE_NORMAL
        // This frees the communication audio stream for other apps
        audioManager.mode = AudioManager.MODE_NORMAL

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
        // Ensure auto-enter PiP is set whenever the activity resumes
        updatePipParams()
    }

    override fun onPictureInPictureModeChanged(isInPipMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPipMode, newConfig)
        // Notify Flutter of PiP state change so it can throttle UI updates
        flutterEngine?.dartExecutor?.binaryMessenger?.let { messenger ->
            MethodChannel(messenger, CHANNEL).invokeMethod("pipChanged", isInPipMode)
        }
    }
}
