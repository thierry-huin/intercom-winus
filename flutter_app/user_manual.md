# Winus Intercom — User Manual (v3.1)

A push-to-talk intercom that runs on Android, iOS and the web, talking to a self-hosted server. This is a quick guide covering everything from picking your server the first time to fine-tuning the in-app settings.

---

## 1. First launch

When you open the app for the first time you land on the **Server screen**:

- **Server URL** field — type the address of your intercom server, e.g. `https://huin.tv:8443` or `https://winus.overon.es:8443`.
- **Saved servers** — once you have connected to at least one server, this dropdown shows the last 10 you used. Pick one to autofill the URL.
- **🗑 Trash** — removes the currently selected URL from the saved list.
- **Connect** — saves the URL and moves to login.

You only need to do this once; the app remembers the URL across launches.

> **Tip**: if you can't reach the server from inside the same LAN it's hosted on, your router likely intercepts the port. Use a different port for that server or use the LAN IP from inside the network.

---

## 2. Login

Two fields: **Username** and **Password** of an account that exists on the server you just chose.

- The app remembers your token across launches and auto-logs in next time.
- If the server has changed credentials or you log out, re-enter them.
- The settings ⚙ icon at the top of the login screen lets you go back to the Server screen if you mistyped.

After login the app moves to the **Intercom screen**.

---

## 3. The intercom screen

```
┌─────────────────────────────────────────────────────────────┐
│ [Logo] Username      [Mic] [Status chip] [⚙] [Admin] [Logout]│
│  v3.1                                                        │
├─────────────────────────────────────────────────────────────┤
│ (Audio banner — appears when someone is talking to you)     │
│                                                             │
│  Users                                                      │
│   ┌──────────┐ ┌──────────┐ ┌──────────┐                    │
│   │  RING    │ │  RING    │ │  RING    │                    │
│   │  ●  Alice│ │  ●  Bob  │ │  ●  Eve  │                    │
│   │  Hold to │ │  Hold to │ │  Tap to  │                    │
│   │   talk   │ │   talk   │ │   talk   │                    │
│   │  ▬▬▬▬▬   │ │  ▬▬▬▬▬   │ │  ▬▬▬▬▬   │                    │
│   │ MOMENT.  │ │ MOMENT.  │ │  LATCH   │                    │
│   └──────────┘ └──────────┘ └──────────┘                    │
│                                                             │
│  Bridges  (if you have any)                                 │
│  Groups                                                     │
└─────────────────────────────────────────────────────────────┘
```

### 3.1 Top bar

- **Logo + Display name + v3.1** — version is also shown for support purposes.
- **Mic icon** — quick mute / unmute. If you mute while transmitting to one or more targets, the buttons stay red and audio resumes automatically when you unmute.
- **Status chip** — `Connected · 18 ms` (green = WS+media OK, RTT shown when known), `Loading…`, `Connecting…` or `MIC OFF` if muted.
- **Call in progress** chip (orange) — appears while the system has handed audio focus to a phone or VoIP call. See §6.
- **⚙ Settings** — opens the bottom-sheet detailed in §5.
- **Admin** — visible for admin/superuser accounts; opens the user/group/permissions admin panel.
- **Logout** — disconnects and goes back to login.

### 3.2 PTT buttons

Each contact (user, bridge or group you are allowed to talk to) is a button. Color cues:

- **Grey-blue / online** — that user is currently connected.
- **Dark grey / offline** — disconnected; pressing has no effect.
- **Central area turns red** while you're transmitting to that target.
- **Border tinted in user color** — the admin can color-tag users; the tag shows on the border so you spot critical ones at a glance.

Each button has up to four zones (top to bottom):

1. **RING bar** (only admins, only on user buttons) — short tap "rings" the target user (their app shows a modal and plays a ringtone for ~30 s).
2. **PTT zone** (the main one):
   - **Hold-to-talk** in MOMENT. mode — release stops audio.
   - **Tap-to-toggle** in LATCH mode — first tap starts, second tap stops; you can latch to several targets at once.
   - The label and a small dot show the user's online status.
3. **Volume slider** — per-user/group playback volume (0 = mute, 1 = full). Volume of 0 also hides the "Receiving audio" banner from that source. Saved across sessions.
4. **MOMENT. / LATCH toggle** — switches the button's gesture mode. Saved per target.

> If pressing a button has no effect, check that you are listed under "Connected" in the top bar — the button is greyed out until media is fully ready.

### 3.3 Sections

- **Users** — every individual user you can talk to.
- **Bridges** — any "bridge" account in your permissions list (typically a TieLine bridge connecting external audio matrices, like Dante / MADI).
- **Groups** — multi-target buttons; pressing one talks to all current members at once. The number in the header tells you how many users sit in the group.

If a section is empty you'll see a placeholder card explaining that you have no permissions there.

---

## 4. Receiving audio

When somebody talks to you a horizontal banner appears at the top of the list:

> Receiving audio from **Bob**

The banner stays as long as Bob keeps the PTT pressed; it auto-fades when audio stops, returning the screen to its normal state.

The phone vibrates briefly when audio starts, unless the device is in silent mode.

When an admin **rings** you, a full-screen modal pops up with the message and a system ringtone plays until you tap **OK** or 30 s pass.

---

## 5. Settings (the ⚙ panel)

Opening Settings shows a bottom-sheet with the following controls. Every value is persisted, so once tweaked it stays that way across launches.

### 5.1 Microphone

A dropdown listing every recording device the OS exposes (built-in mic, Bluetooth headset mic, USB audio interface, hearing aids, AirPods…). Picking one switches both mic and speaker in lockstep on Android/iOS because mobile audio routing is atomic.

### 5.2 Speaker

Same idea, for playback. Use this to send audio to AirPods, the earpiece, the loudspeaker, a wired headset, etc.

### 5.3 Columns (slider 2 – 4)

Number of buttons per row in the Users / Bridges / Groups sections. 2 → big buttons (good for in-the-pocket ops), 4 → many small buttons (good for tablets / desk). Default 3.

### 5.4 Hide offline users (switch)

When ON, users / bridges / groups whose members are all offline disappear from the list. They reappear automatically when somebody connects, no refresh needed. Default OFF.

### 5.5 Sidetone (slider 0 % – 100 %)

Plays your own microphone back into your ear while you're talking, so you can hear yourself when wearing closed headsets. Default OFF (0 %).

> Note: in v3.1 the slider persists the value but the actual loopback path is not yet implemented natively. It will start working transparently when the platform code lands.

### 5.6 Call ducking (chips: 0 dB / -3 dB / -6 dB / -12 dB / Mute)

How much to attenuate **incoming** intercom audio while you have a phone or VoIP call active (GSM, WhatsApp, FaceTime…).

- **0 dB** — no ducking, you hear the intercom and the call at full volume (chaos).
- **-3 dB** (default) — gentle attenuation, you can still follow the intercom in the background.
- **-12 dB** — clearly quieter, the call dominates.
- **Mute** — the intercom is silent while the call lasts.

Default **-3 dB**.

---

## 6. Behaviour during phone / VoIP calls

This is the biggest change in v3.1: incoming calls always win the microphone.

1. The OS notifies the app that audio focus is leaving.
2. The intercom **releases the microphone** (stops mic capture), so the call app can capture it cleanly.
3. The intercom **ducks** the incoming consumers according to your Call ducking setting.
4. The orange **Call in progress** chip appears in the top bar.
5. Active PTT sessions (latched targets) are kept alive server-side — your buttons stay red.
6. When you hang up, after a 1 s grace period the intercom **reacquires the mic** and audio flows again to the same targets, no taps required.

This applies equally to GSM calls and to VoIP apps like WhatsApp, FaceTime, Telegram, Signal, etc.

> **Why?** With the intercom holding the microphone, WhatsApp couldn't capture audio. Now the caller hears you so you can ask them to hold for a second.

---

## 7. Admin extras (admin / superuser only)

The **Admin** button opens a separate screen where you can:

- Create / edit / delete users.
- Set a user's role (`user` / `admin` / `superuser` / `bridge`).
- Color-tag users so they're easier to recognise on the PTT grid.
- Define **groups** and group permissions.
- Define which users can talk to which (permissions matrix).

Bridge accounts (`role=bridge`) are special: they are designed for the TieLine bridge program, can only authenticate with `client_type=bridge`, and don't count for "session lock" rules.

The **Ring** bar at the top of every user button is also admin-only — useful to grab somebody's attention when they're not listening.

---

## 8. Common operations

### Switch between two servers

1. **Logout** from the top bar.
2. From the Login screen tap **⚙** to go to the Server screen.
3. Either pick the other URL from the **Saved servers** dropdown or type a new one.
4. Login again with the credentials of that server.

Each server has its own user database — credentials don't transfer.

### Make somebody a bit quieter without losing them

Drag their per-button volume slider down. The setting is per-user and survives reconnects. Set to 0 to mute that user entirely.

### Talk to several targets at once

Tap **MOMENT.** to switch the buttons you want into **LATCH**, then tap each one. They stay red until you tap them again.

### Mute the mic temporarily

Tap the **Mic** icon in the top bar. The intercom keeps the mic open but no audio is sent. Tap again to resume. If you had latched targets they keep talking; just toggling mute doesn't drop them.

### Recover from a connection drop

The app reconnects on its own as soon as the network is back. Latched buttons are kept and audio resumes automatically.

---

## 9. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Login fails with **401** | Wrong server / wrong credentials for that server | Check the URL is the right one and that the user exists on that server |
| Login fails with **429** | Too many failed attempts (5 in 5 min → 15 min lockout) | Wait, or try from another network |
| Buttons are all greyed out | Media not ready yet, or microphone permission denied | Wait a few seconds; if stuck, go to OS settings and grant Microphone permission to the app |
| You see "Receiving audio from X" but nothing plays | Per-user volume is 0, or output device routed somewhere unexpected | Open the user's button volume bar; check Settings → Speaker |
| WhatsApp call comes in but nobody can hear you | Older app version — upgrade to v3.1+ which releases the mic for the call |
| App keeps disconnecting from server | Network instability; the app auto-retries every few seconds | Use Wi-Fi when you can; check that the server URL is reachable from your network |
| Server URL was mistyped and the app keeps trying | Logout → ⚙ → Server, fix the URL or pick another from history |
