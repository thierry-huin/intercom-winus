# companion-module-winus-intercom

Local Bitfocus Companion module to drive Winus Intercom PTT targets from a
Streamdeck. One button per target with Latch/Momentary gesture detection:

- **Sustained press** (≥ 250 ms while holding) → momentary talk
  (`ptt_start` on hold, `ptt_stop` on release).
- **Two quick taps** (< 250 ms each, gap < 500 ms) → toggle latch
  (second tap of the first pair enters latched `ptt_start`; a later
  double-tap exits back to idle).
- **Single short tap** → no-op.

## Prerequisites

- Bitfocus Companion **3.x** on the PC that drives the Streamdeck.
- **Node.js 18+** (used at build time; Companion already bundles its own
  Node runtime at execution time).
- **ffmpeg** on PATH — used to capture the PC microphone.
- Account on your Winus server with permissions to PTT the targets you
  want. Recommended to create a **dedicated user** (e.g. `streamdeck-booth1`)
  so the session lock on regular users doesn't collide with your phone/web
  session. Admin / superuser / bridge roles bypass the session lock and
  also work.

## Build

```bash
cd companion-module-winus-intercom
npm install
npm run build
```

This produces `dist/main.js` that Companion will load.

## Install as a user-local module

Copy the whole folder (including `dist/`, `companion/`, `package.json`,
`node_modules/`) into Companion's user-modules directory:

- **Linux**:  `~/.config/companion/module-source/winus-intercom/`
- **macOS**:  `~/Library/Application Support/companion/module-source/winus-intercom/`
- **Windows**: `%APPDATA%\companion\module-source\winus-intercom\`

Alternatively, configure Companion's "Developer: modules directory" from
Settings → Developer and point it at the parent directory that contains
this folder. Then restart Companion.

After the restart you should see **Winus Intercom** in
*Connections → Add connection*.

## ffmpeg input arguments (by OS)

The Companion config exposes a raw ffmpeg input string. Defaults to
PulseAudio. Pick the right one for your PC:

| OS      | Value                                              |
|---------|----------------------------------------------------|
| Linux (PulseAudio) | `-f pulse -i default`                  |
| Linux (ALSA)       | `-f alsa -i default`                   |
| macOS              | `-f avfoundation -i ":0"` (0 = default input) |
| Windows (DirectShow)| `-f dshow -i audio="Microphone (Realtek …)"` |

To list the available DirectShow devices on Windows:

```powershell
ffmpeg -list_devices true -f dshow -i dummy
```

## Wiring buttons in Companion

For each target you want to address, create a button with:

- **Press action**: *Intercom: PTT press* → pick target (e.g. `user:3`).
- **Release action**: *Intercom: PTT release* → same target.
- **Feedbacks**:
  - *Target: currently talking* → red background.
  - *Target: latched* → blue background.
  - *Target: online* → green background (only for user targets).

Optionally a second button bound to *Intercom: PTT cancel latch* as a
panic-off for a specific target.

## Troubleshooting

- **Status stays on "Connecting" or "Bad config"**: verify host/port are
  reachable with `curl -k https://HOST:PORT/api/rooms/my-targets`.
- **"User already connected" error**: the Streamdeck user is logged in
  somewhere else; use a dedicated account.
- **No audio transmitted**: check Companion logs for `ffmpeg-stderr`
  entries. Install ffmpeg or fix the input string. On Linux make sure the
  PulseAudio server is running as the same user that runs Companion.
- **Self-signed cert**: the config flag "Accept self-signed certificate"
  disables TLS verification for both the REST login and the WebSocket.

## File layout

```
companion-module-winus-intercom/
├── package.json
├── tsconfig.json
├── companion/manifest.json
├── src/
│   ├── index.ts         # InstanceBase entrypoint (runEntrypoint)
│   ├── config.ts        # Config schema
│   ├── session.ts       # REST login + WS + mediasoup-client + ffmpeg mic
│   ├── ptt-gesture.ts   # Latch/Moment state machine per target
│   ├── actions.ts       # ptt_press / ptt_release / ptt_cancel_latch
│   ├── feedbacks.ts     # talking / latched / online
│   └── variables.ts     # connection_status, counts
└── README.md
```
