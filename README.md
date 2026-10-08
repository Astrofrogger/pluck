# Pluck

A native macOS front-end for [yt-dlp](https://github.com/yt-dlp/yt-dlp), built in SwiftUI with Liquid Glass.

- Paste a link (it auto-fills from the clipboard when you switch to the app), or drag one onto the window
- **Video:** Best, 4K, 1440p, 1080p, 720p, 480p or 360p. Codec is H.264 (plays everywhere) or AV1/VP9, container is MP4, MKV or WebM, with an optional 60 fps preference
- **Audio:** original, M4A, MP3, Opus, FLAC or WAV, at Best VBR or 320/256/192/128 kbps
- **Spotify:** track, album and playlist links. Spotify audio is DRM-protected, so Pluck finds the matching song on YouTube Music and tags the file with Spotify's title, artist, album and a square cover
- Up to 3 downloads at a time (adjustable); the rest wait in a queue
- Live progress, speed and ETA, with thumbnails and durations
- Dock badge, plus notifications when a download finishes in the background
- **Settings (⌘,):**
  - Save folder, or "always ask where to save"
  - Format defaults
  - Embed metadata, cover art and subtitles
  - SponsorBlock and playlist downloads
  - Browser cookies from Safari, Chrome, Firefox, Zen, Brave, Edge, Vivaldi, Opera or Chromium
- **Updates yt-dlp automatically:** keeps its own copy of the official release in `~/Library/Application Support/Pluck/bin`, checks daily, verifies the SHA-256 checksum, and offers optional nightly builds
- ⇧⌘D downloads whatever link is on the clipboard

## Install
Download **[Pluck.dmg](https://github.com/Astrofrogger/pluck/releases/latest/download/Pluck.dmg)**, open it, and drag Pluck into Applications. The first time you open it, go to System Settings → Privacy & Security and click **Open Anyway**, because the app isn't signed with an Apple Developer ID. After that, Pluck checks GitHub for its own updates and installs them when you click **Install & Relaunch**.

## Requirements
macOS 26+ and `brew install ffmpeg`. yt-dlp is downloaded automatically, or you can use your own (`brew install yt-dlp`) by turning off auto-update.

## Release
```bash
./scripts/release.sh 1.1.0 "What changed"
```
This bumps the version, builds the app, uploads `Pluck.dmg`, `Pluck.zip` and `Pluck.zip.sha256` to a GitHub release, and tags it. Running copies of Pluck pick up the new version within a day, or straight away with Pluck → Check for Updates….

## Build
```bash
./scripts/build-app.sh            # → build/Pluck.app
./scripts/build-app.sh --install  # also copies it to /Applications
```
