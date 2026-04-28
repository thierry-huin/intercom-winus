# Privacy Policy – Winus Intercom

Last updated: April 28, 2026

Winus Intercom is a professional IP intercom system. We process the
following data only to operate the service:

- **Microphone audio** captured only while you press push-to-talk and
  transmitted in real time via WebRTC to authorized peers. Audio is
  never recorded or stored on any server.
- **Login credentials** stored locally on the device for automatic
  reconnection.
- **Network address / session token** used by the server to authenticate
  the WebRTC session.

We do NOT collect location, contacts, messages, photos, video, browsing
history, or advertising data. We do NOT share data with third parties
and do NOT integrate advertising or analytics SDKs.

### Permissions

- `RECORD_AUDIO`, `FOREGROUND_SERVICE_MICROPHONE`: capture & transmit
  voice during PTT.
- `INTERNET`, `ACCESS_NETWORK_STATE`: connect to the intercom server.
- `BLUETOOTH`, `BLUETOOTH_CONNECT`: route audio to selected Bluetooth
  headset.
- `MODIFY_AUDIO_SETTINGS`: configure the system audio mode.
- `WAKE_LOCK`, `FOREGROUND_SERVICE`, `POST_NOTIFICATIONS`: keep the
  intercom session alive in the background.
- `VIBRATE`: notify on incoming audio or admin ring.
- `CAMERA`: declared by the underlying WebRTC library but **the app does
  NOT access the camera, does NOT capture or transmit video, and does
  NOT prompt for camera permission**. Only the audio subsystem of WebRTC
  is used.

### Data retention

Data is processed in real time. No audio is recorded. Local credentials
can be cleared by logging out. Account records live on the
organization's private server, controlled by its administrator.

### Children

The app is not intended for children under 13.

### Contact

Thierry Huin – Winus Intercom
📧 thierry@huin.tv
