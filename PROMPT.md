# The prompt

Paste this into Claude Code in an empty folder, on a Mac with Xcode installed. Results will differ from my build, because AI output varies from run to run. If something breaks, describe it and let Claude Code fix it.

```text
Build me a native app pair that turns my iPhone Duo into a remote MacBook. Use Apple frameworks
only: no browser, no WebRTC, no third-party dependencies, no outside servers.

WHAT IT DOES
- Tabletop mode (portrait): the Mac's screen live on the top half, above the fold. On the bottom
  half, a MacBook keyboard and a trackpad.
- Open the phone flat and the keyboard gives way to a full trackpad. Use UIHingeInteraction
  (iOS 27.1) to read the fold, behind an availability check, with a manual override.
- Full screen (landscape): the Mac's screen fills the display. Tap where you want to click, or use
  the whole screen as a trackpad. Pinching zooms the local view only. The keyboard can be shown on demand.
- A notch at the top of the lid opens a native menu: live stats, gesture profile, quality, which
  Mac display to show, sound, themes.
- Themes: Space Black and Silver, plus vintage looks with speaker grilles and real click buttons.

MAC APP
- ScreenCaptureKit for video and system audio. VideoToolbox HEVC with H.264 as the fallback:
  low-latency rate control, real time, no frame reordering, keyframes only on request.
- macOS sends no frames while the screen is still, so re-encode the last frame a few times after
  it goes still, otherwise text stays blurry.
- CGEvent for input: relative and absolute pointer, drag, double-click counts, pixel scrolling with
  real scroll and momentum phases, modifier flags, media keys. Never leave a key or button stuck on disconnect.
- A window with a large pairing QR code, permission status with buttons for Screen Recording and
  Accessibility, a display picker, and live stats. Also a menu bar item.
- Report the frontmost app to the phone. Keep the Mac awake while running.

PHONE APP
- UIKit for the touch surfaces and SwiftUI for settings and pairing. AVSampleBufferDisplayLayer for
  video, showing each frame immediately. Real haptics. Keep the pairing secret in the Keychain.
- Pair by QR code using a clamshell:// link, with an in-app scanner and a paste fallback. Find the Mac
  with Bonjour and known addresses at the same time, and reconnect by itself.

CONNECTION
- TCP with TLS 1.2 pre-shared key (the pairing secret) for control messages, keys, clicks and scroll phases.
- UDP sealed with CryptoKit AES-GCM for video, audio and pointer motion. A random key per session,
  sent over TLS. A nonce from direction + sequence number, a wide replay window (several thousand
  packets), 1200-byte datagrams.
- Test TLS, DTLS and QUIC with a pre-shared key on loopback first, then use what actually works. For me,
  only TLS 1.2 worked.
- Frames must be delivered strictly in order. Missing packets are requested again; if a frame can't be
  recovered, request a keyframe and show nothing corrupted. Adapt the bitrate only on sustained loss.

MISTAKES TO AVOID (I hit all of these)
- Don't request a resend because a frame is N ms old. Packets still in flight look lost, and that caused
  28% false resends for me. Only treat a packet as missing if a later packet or frame has arrived, or the
  frame has gone quiet.
- Keep recovering keyframes while waiting for a keyframe. Otherwise any loss means a black screen forever.
- Don't re-request a keyframe that's still arriving.
- Don't add packet pacing without measuring it. It doubled my delay and I removed it.

GESTURES
Keep a single table of per-app profiles mapping finger count to action, and pick one automatically from
the Mac's frontmost app:
- macOS: 1 finger pointer, tap click, hold then drag. 2 fingers scroll with momentum, tap right-click,
  pinch ⌘+/⌘−. 3 or 4 fingers swipe for Spaces and Mission Control.
- Premiere Pro: 2 fingers scroll locked to one axis with no momentum, pinch =/−. 3 fingers is a jog wheel:
  one frame per 10 points with a haptic tick, a flick for 5 frames, up/down for edit points, tap for
  play/pause. 4 fingers for Spaces. Add a shortcut bar: J K L, In, Out, Cut, Trim, Undo. Keys stay down
  while the finger does.
- Final Cut and Resolve: the same, with their own zoom and blade shortcuts.
Keyboard modifiers: hold them, tap to latch for one key, double-tap to lock. Keys auto-repeat.

HOW TO WORK
- Put everything without a UI (protocol, encryption, frame reassembly, keyboard, gestures) in a local Swift
  package with unit tests. Touches and time should be plain values, so gestures the Simulator can't produce
  can still be tested.
- Add a --demo mode to the Mac app that draws a fake desktop and shows input on it instead of touching my
  real Mac, so everything can be tested without permissions. Include a noise stress pattern and simulated
  packet loss.
- Test on the iPhone Duo simulator, then ask me to install on my real phone. Measure before and after every
  performance change, and report honestly what has and hasn't been tested.
- Tell me each step I have to do myself, such as permissions and signing.
```
