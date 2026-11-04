# Clamshell

Use a foldable iPhone as a pocket MacBook. Fold the iPhone Duo halfway and the top half shows your Mac live, with a MacBook keyboard and trackpad on the bottom half. Open it flat for a full trackpad, or rotate it for the full screen.

> **This is not a perfect app.** I built it for fun, quickly, to show what's possible to create, and I'm sharing it free with everyone. It has not been stress-tested or security-tested, and I'm not liable for anything that happens if you use it. There's no support and no guarantee. It lets a phone control your Mac, so use it at your own risk.

Inspired by Pocket Mac Lab by @__diditee__. Not affiliated with Apple.

## Two ways to get it

- **Build your own with AI:** paste [PROMPT.md](PROMPT.md) into Claude Code.
- **Build this code:** follow the steps below. It's free, but you do have to build it in Xcode. iPhone apps can't simply be downloaded and run outside the App Store.

## What you need

- A Mac with **Xcode 27.1 or newer**, which is free on the Mac App Store. The project uses the iOS 27.1 fold API, so older versions won't build it.
- An **iPhone** with a cable. It's designed for the iPhone Duo and needs iOS 17 or newer. On other iPhones the fold features won't apply. I've only tested it on an iPhone Duo.
- A free **Apple account**. On a free account the iPhone app stops opening after 7 days, and you run it from Xcode again to renew it. A paid Apple Developer account lasts much longer.

## Install

1. [Download this project as a ZIP](../../archive/refs/heads/main.zip) and unzip it, or clone it.
2. Open `Clamshell.xcodeproj` in Xcode.
3. Add your Apple account under **Xcode → Settings → Apple Accounts**.
4. Open `Config/Signing.xcconfig` and change `com.yourname` to something unique to you. Set `DEVELOPMENT_TEAM` to your team ID, or pick your team under **Signing & Capabilities** for both targets.
5. Choose the **ClamshellHost** scheme with **My Mac** as the destination, then press **Run**.
6. In the Clamshell window on your Mac, click **Allow…** for **Screen Recording** and **Accessibility**. If Screen Recording doesn't turn green, quit and reopen the app.
7. Plug in your iPhone. On a first install, turn on **Settings → Privacy & Security → Developer Mode**.
8. Choose the **Clamshell** scheme with your iPhone as the destination, then press **Run**. If the phone says **Untrusted Developer**, go to **Settings → General → VPN & Device Management** and trust your profile.
9. Point the iPhone camera at the QR code on your Mac and open the link. Tap **Allow** when asked about the local network.

Both devices need to be on the same network. To quit, use the menu bar icon: the app keeps your Mac awake while it's open.

## Security

This app lets a phone control your Mac, so please read this.

- **Treat the QR code like a password.** It holds the secret that lets a phone connect. Don't post it or film it. If it gets out, click **Unpair All Phones** on the Mac.
- Traffic is encrypted with Apple's frameworks, and there are no outside servers. The code has not been independently audited.
- Quit the Mac app when you aren't using it.

## From outside your home network

There's no built-in way to connect from anywhere. In principle a VPN such as [Tailscale](https://tailscale.com) on both devices should work, because the QR code includes its address, but **I haven't tested this**. Expect a noticeable delay over long distances.

## Using it

Gestures follow the app in front on your Mac, or you can pick a profile from the notch menu.

| Fingers | macOS | Premiere Pro | Final Cut · Resolve |
|---|---|---|---|
| 1 | Pointer, tap to click, hold then move to drag | same | same |
| 2 | Scroll with momentum, tap to right-click, pinch for ⌘+/− | Timeline scroll locked to one direction with no coasting, pinch for `=`/`−` | same, pinch for ⌘+/− |
| 3 | Swipe: Spaces, Mission Control, app windows | Jog: one frame per 10 pt with a haptic tick, flick for a big step, up/down for edit points, tap to play/pause | same |
| 4 | same as 3 | Spaces and Mission Control | same |

The editing profiles add a shortcut bar with J K L, In, Out, Cut, Trim and Undo. They assume each app's default shortcuts, and the zoom keys need the timeline panel selected. To change anything, edit `Core/Sources/ClamshellCore/Profiles.swift`.

On the picture itself: tap to click, long-press to right-click, drag to select or move, two fingers to scroll, pinch to zoom your local view.

Modifier keys: hold them, tap to latch for one key, double-tap to lock.

## Performance

A single quick measurement on my own Wi-Fi using a moving noise pattern, from an Apple silicon Mac to an iPhone Duo. Capture to arrival on the phone, before the phone decodes and displays the frame:

| Quality | Bitrate | Median delay | Resent packets |
|---|---|---|---|
| Balanced (1920 wide) | 14 Mb/s | 26 ms | 0.2% |
| Sharp (3456 wide) | 40 Mb/s | 42 ms | 0.8% |

Your numbers will differ.

## How it's built

```
iPhone: Clamshell                            Mac: Clamshell Host
┌───────────────────────────┐                ┌──────────────────────────────┐
│ AVSampleBufferDisplayLayer│◀── UDP, ───────│ ScreenCaptureKit             │
│ AVAudioEngine             │    AES-GCM     │  → VideoToolbox HEVC/H.264   │
│                           │                │  → Opus (AVAudioConverter)   │
│ Keyboard, trackpad,       │── TLS 1.2 ───▶ │ CGEvent input                │
│ gesture engines           │   pre-shared   │                              │
│ UIHingeInteraction (fold) │   key, TCP     │ NSWorkspace (front app)      │
└───────────────────────────┘                └──────────────────────────────┘
```

- `Core/`: shared Swift package with no UI: wire format, encrypted datagrams, frame reassembly, bitrate control, keyboard and gesture logic. Run its tests with `cd Core && swift test`.
- `Mac/`: capture, encoding, input, server, window.
- `iPhone/`: networking, decoding, audio, keyboard and trackpad views, settings.

The pairing QR holds a 256-bit secret that authenticates a TLS-PSK control connection, which delivers a fresh AES-GCM key each session. Missing video packets are requested again once a later packet proves they're gone. If a frame can't be recovered, the phone asks for a new keyframe and never shows a corrupted picture. The bitrate drops only on sustained loss.

**Testing without touching your Mac:** run the Mac app with `--demo --port 47801 --print-pairing --log-stats`. It draws a fake desktop and shows input on it instead of sending it to macOS, and needs no permissions. Add `--stress` for moving noise, `--simulate-loss 10` to drop packets, or `--demo-app com.adobe.PremierePro.26` for a mock timeline.

## License

MIT. See [LICENSE](LICENSE).
