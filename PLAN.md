# Plan: iPhone Screen + Camera Recorder for Mac

A native Mac app that shows your iPhone's screen in a beautiful window (like Bezel),
records it together with your Mac's camera and microphone (like the demo videos on
Twitter), and exports polished videos (borrowing Screen Studio's look).

## The core trick (verified)

macOS has a built-in, Apple-sanctioned way to treat a USB-connected iPhone as a
"camera" whose picture is the phone's screen. It's the same mechanism QuickTime
uses for "New Movie Recording → iPhone". One small piece of code flips the switch
(the CoreMediaIO `kCMIOHardwarePropertyAllowScreenCaptureDevices` property), and
then the iPhone shows up as a normal capture device (`AVCaptureDevice`, type
`.muxed`) that delivers **both the screen video and the phone's audio** in one
stream.

Why this beats Apple's iPhone Mirroring for us:
- The phone stays **unlocked and usable** while mirrored (phone must be unlocked
  and have tapped "Trust This Computer" — same as QuickTime).
- The phone's audio arrives as data inside the stream, not through the Mac's
  speakers — so we can record it cleanly and choose whether to also play it out
  loud. This is the "audio mirroring" behavior you liked in Bezel.

Verified against: Bezel's own site/blog, Apple Developer Forums threads, and the
fact that Bezel (updated through 2026) ships on exactly this mechanism.

## Key decisions

1. **Swift + SwiftUI, native Mac app.** This is Apple-framework-heavy territory
   (AVFoundation, CoreMediaIO); Swift is the only sane choice.
2. **Distribute as a direct download (notarized), not the Mac App Store — at
   least initially.** The App Store sandbox blocks the iPhone-capture trick;
   Bezel had to ship a separate unsandboxed "Helper" app to work around it.
   Skipping the App Store means we skip that whole complication.
3. **USB first, wireless (AirPlay) in Phase 4 — and it's now viable.** This
   project will be **open source under GPLv3**, which means we're free to build
   the wireless receiver on UxPlay/RPiPlay code instead of reimplementing
   Apple's protocol from scratch. Still Phase 4, not MVP: it's a big
   integration (UxPlay is C, built on the GStreamer media framework, shipped as
   a standalone tool — not a drop-in library), and Bezel themselves shipped
   wireless video-only at first because AirPlay audio is a separate encrypted
   stream. USB covers the record-a-demo use case completely today.
4. **Record what you see (MVP), raw tracks later.** Screen Studio records raw
   streams plus an event log and applies effects at export. That's the right
   end-state, but the lazy correct MVP is: composite the canvas live (phone +
   camera bubble + background) and write one MP4. A project-file editor comes in
   Phase 3.
5. **Auto-zoom on taps is impossible today for a physical iPhone** — the USB
   stream is video-only; no touch coordinates cross the cable. Screen Studio's
   auto-zoom is driven by Mac mouse clicks. Every competitor (FocuSee, Tella)
   drops auto-zoom for device recordings. We ship **manual** zoom regions in the
   editor (Phase 3). A companion iOS app that streams touch locations is a
   genuinely novel differentiator — parked as a future idea, nobody does it yet.

## Phases

### Phase 1 — MVP recorder (the Twitter demo)
The goal: plug in iPhone → see it on screen → hit Record → get an MP4 with
phone screen + camera bubble + your voice + the phone's audio.

- Enable the CoreMediaIO screen-capture-devices switch; discover the iPhone as
  a `.muxed` AVCaptureDevice (devices appear ~1s after the switch, so listen
  for connect notifications).
- "Choose device" picker (like the Twitter screenshot): lists connected
  devices, shows ready state.
- Capture sessions: iPhone (video+audio), Mac camera, microphone.
- Live preview window: phone screen with rounded corners on a nice background,
  camera in a floating rounded bubble (drag to reposition, few size presets).
- Record button → AVAssetWriter writes H.264/HEVC using the Mac's hardware
  video encoder (fast, cool, quiet) to one MP4: composited video + mic and
  device audio.
- Device audio: recorded always; toggle for whether it also plays on the Mac's
  speakers.
- Permissions flow: camera + microphone prompts, "Trust This Computer"
  guidance, empty states for no device / locked device.

**Done when:** you can record a talking-head + phone demo like Paul's tweet in
one take, with clean audio from both sources.

### Phase 2 — Live polish (the Bezel look)
- [x] Device frame: synthetic bezel (clean dark frame, correct corner radii) —
      model-matched frames with real colors deferred to a later pass.
- [x] Auto-rotate with the device (canvas follows the live stream's shape).
- [x] Backgrounds: 6 gradient/color presets (wallpapers deferred).
- [x] Always-on-top pinning. (Full-screen via the standard green button.)
- [x] High-res screenshots (⌘S, saved to ~/Pictures/Record iPhone).
- [x] Vertical 9:16 and horizontal 16:9 canvas presets, in preview and export.
- [ ] Deferred: sleep/lock detection overlay, custom bezel colors,
      true-size/pixel-perfect zoom.

### Phase 3 — Editor + export (the Screen Studio look)
- Switch recording to raw tracks (phone video, phone audio, camera, mic) with
  synced timestamps + a project file; effects become non-destructive.
- Timeline: trim/cut, manual zoom-and-pan keyframes with smooth animated
  easing (this is the manual version of Screen Studio's signature move).
- Camera bubble layouts (corner bubble, side-by-side), background swap in post.
- Audio: volume normalization, background-noise removal (Apple's built-in
  voice isolation where available).
- Export presets: MP4/GIF, 4K/60, vertical for socials, web-friendly sizes.

### Phase 4 — Wireless + moonshots
- AirPlay receiver for cable-free mirroring, built on UxPlay/RPiPlay (GPLv3 —
  fine, the app is open source). Plan: adapt the protocol/decryption layer,
  replace the GStreamer playback path with our native AVFoundation pipeline so
  received frames flow into the same canvas/recorder as USB. Ship video first,
  audio second (AirPlay audio is a separate encrypted stream), matching how
  even Bezel staged it.
- Companion iOS app streaming touch coordinates → true tap-driven auto-zoom.
  Would be first-in-market.
- iPad / Apple TV / Vision Pro sources (the USB trick already covers iPad).

## Risks / open questions
- Exact behavior when the phone locks mid-recording — handle gracefully, test
  early (Phase 1).
- The CoreMediaIO switch is unsandboxed-app territory: fine for direct
  distribution, revisit only if App Store matters later.
- Compositing at 60fps: start with Core Image/Metal via AVFoundation's video
  output pipeline; measure before optimizing.

## Tech stack summary
Swift, SwiftUI (app UI), AVFoundation (capture + writing), CoreMediaIO (the
device switch), VideoToolbox hardware encoding (via AVAssetWriter defaults),
Metal/Core Image (canvas compositing). No third-party dependencies for the MVP.
