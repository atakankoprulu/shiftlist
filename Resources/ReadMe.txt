SHIFTLIST
Select files in Finder, tap Shift once: convert, edit, share.

REQUIREMENTS
• Apple silicon or Intel Mac.
• macOS 14 or later. The glass look and the bundled ffmpeg (video/audio tools) need macOS 26.
• On Intel Macs the video and audio tools need ffmpeg from Homebrew (brew install ffmpeg).

INSTALL
1. Drag Shiftlist onto the Applications folder next to it.
2. Open Shiftlist from Applications.
3. If macOS says it "can't verify" the app:
   System Settings › Privacy & Security › scroll down and click "Open Anyway" next to "Shiftlist".
   (A one-time warning, because Shiftlist doesn't come from the App Store and isn't signed by an Apple developer.)

PERMISSIONS (once, on first launch)
• Accessibility: to notice the Shift tap. System Settings › Privacy & Security › Accessibility › turn on Shiftlist.
• Controlling Finder: to see the selected files. Click "Allow" when asked.
• Notifications: to tell you when a job is done.
You're ready when the "Shiftlist is ready" notification appears.

USAGE
Select one or more files in Finder, tap Shift once and let go. The list opens under your cursor.
  ⇧ Shift     Convert   — JPG, PNG, HEIC, PDF, MP4, MP3, DOCX, ZIP…
  ⌃ Control   Tools     — compress, strip metadata, crop, redact, trim, speed, split…
  ⌘ Command   Actions   — AirDrop, pin, copy, move, copy path, Terminal
Esc closes. You can also pick with 1–9. New files are always saved next to the original; the original is never touched.
Settings and "Launch at Login" are in the Shiftlist menu bar icon.
The interface follows your system language (English or Turkish).

NOTES
• Markdown and EPUB conversion need pandoc (Homebrew: brew install pandoc). Without it those options are hidden.
• Word → PDF uses Pages when it's installed (better page layout).
• Pressing Option five times in a row turns on macOS "Mouse Keys" (keyboard letters start moving the pointer).
  If that happens, press Option five times again.

LICENSE
Bundles FFmpeg (https://ffmpeg.org) for video and audio. FFmpeg is licensed under the GPL;
its source code is available at https://ffmpeg.org/download.html.
