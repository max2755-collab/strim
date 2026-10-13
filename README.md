# Strim

Native iOS multi-destination RTMP(S) live streaming app.

Stream your phone camera to YouTube, Twitch, VK Live, or any RTMP ingest by pasting an ingest URL and stream key. Multiple destinations can go live at the same time.

## Requirements

- Xcode 16+
- iOS 16+
- Physical iPhone/iPad recommended (camera + network)

## Setup

```bash
# Generate the Xcode project (XcodeGen)
brew install xcodegen   # if needed
xcodegen generate
open Strim.xcodeproj
```

1. Select your Development Team in the Strim target signing settings.
2. Build & run on a device.
3. Allow Camera and Microphone permissions.

## How to go live

1. Open **Destinations** → add a destination.
2. Paste the platform ingest URL and stream key (from YouTube Studio / Twitch Dashboard / VK Live).
3. Enable the destinations you want (max 3).
4. Adjust resolution / bitrate in **Settings** if needed (default 720p @ 2500 kbps).
5. On **Live**, tap the red button to start. Tap again to stop.

### Example ingest URLs

| Platform | Typical URL |
|----------|-------------|
| YouTube  | `rtmp://a.rtmp.youtube.com/live2` (or `rtmps://…`) |
| Twitch   | `rtmp://live.twitch.tv/app` |
| VK Live  | URL from the broadcast cabinet |
| Custom   | Any `rtmp://` or `rtmps://` server |

The app appends your stream key as the final path segment: `url/streamKey`.

## Architecture

- **SwiftUI** UI
- **HaishinKit** + **RTMPHaishinKit** for capture, H.264/AAC encode, and RTMP publish
- One `MediaMixer` fans out to N RTMP sessions
- Stream keys stored in **Keychain**; destination metadata in UserDefaults

## Notes

- Streaming runs in the foreground only (MVP).
- Prefer Wi‑Fi; multi-stream at 1080p is heavy on CPU and uplink.
- Prefer `rtmps://` when the platform supports it.
