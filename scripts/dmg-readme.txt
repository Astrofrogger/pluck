Installing Pluck
================

1. Drag Pluck onto the Applications folder.

2. The first time you open it, macOS will say it can't verify the developer
   (Pluck isn't signed with an Apple Developer ID). To allow it:
   - Open Pluck once and dismiss the warning.
   - Go to System Settings → Privacy & Security, scroll down, and click
     "Open Anyway" next to Pluck.
   You only need to do this once. Later updates install from inside the app.

3. Pluck needs ffmpeg to merge video and convert audio. If the app shows an
   ffmpeg warning, install Homebrew (https://brew.sh) and run:

       brew install ffmpeg

yt-dlp is downloaded and kept up to date by Pluck automatically.
