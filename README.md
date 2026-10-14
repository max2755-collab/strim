# onPitch

Native iOS multi-destination RTMP(S) live streaming app — built for the pitch.

Stream your phone camera to YouTube, Twitch, VK Live, or any RTMP ingest by pasting an ingest URL and stream key. Multiple destinations can go live at the same time, with an LFL-style scorebug burned into the feed.

## Requirements

- Xcode 16+
- iOS 17+
- Physical iPhone/iPad recommended (camera + network)

## Setup

```bash
# Generate the Xcode project (XcodeGen)
brew install xcodegen   # if needed
xcodegen generate
open OnPitch.xcodeproj
```

1. Select your Development Team in the app target signing settings.
2. Build & run on a device.
3. Allow Camera and Microphone permissions.

## How to go live

1. On the home screen, set teams, kit colours and the scorebug position.
2. Under **Where to stream**, add a platform: paste the ingest URL and stream key (from YouTube Studio / Twitch Dashboard / VK Live).
3. Switch on the platforms you want (max 3) and pick a quality preset (Economy / Balance / Maximum, or **Fine-tune**).
4. Tap **Open camera** → the on-air button → check the pre-flight panel → **Start stream**.
5. To stop, **press and hold** the on-air button (~1 s) — a tap only shows a hint, so you can't stop by accident.

### Example ingest URLs

| Platform | Typical URL |
|----------|-------------|
| YouTube  | `rtmp://a.rtmp.youtube.com/live2` (or `rtmps://…`) |
| Twitch   | `rtmp://live.twitch.tv/app` |
| VK Live  | URL from the broadcast cabinet |

Stream keys stay in the Keychain; never commit them.
