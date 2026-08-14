# Third-party notices

## UxPlay (AirPlay protocol library)

Record iPhone's `airplay-helper` is built from UxPlay
<https://github.com/FDH2/UxPlay> and is licensed under the GNU GPL v3.
The helper links that library and does not use GStreamer; video is decoded
in the app with VideoToolbox.

Pinned upstream revision (audited, not the moving default branch):

    a3c19cbc7fcc870d74a0960bc97817a2569b4808

`build.sh` clones that commit and refuses to configure CMake or copy overlay
sources unless `Vendor/UxPlay` HEAD matches this SHA.

### Local modifications

After the pin is verified, `build.sh` overlays these files onto
`Vendor/UxPlay/lib/`:

- `Sources/AirPlayHelper/raop_rtp_mirror.c` — forwards codec VPS/SPS/PPS
  NALs immediately, treats the type-0x05 ~25 kB trailer used by current
  iPhones as encrypted video, and rejects malformed packet sizes
- `Sources/AirPlayHelper/mirror_buffer.c` / `mirror_buffer.h` — snapshot
  and restore the video cipher so a rejected trailer cannot scramble later
  frames
- `Sources/AirPlayHelper/crypto.c` / `crypto.h` — copy the AES-CTR state
  used by that snapshot

`Sources/AirPlayHelper/main.c` is original to this project and talks to the
UxPlay library.

### Corresponding source (GPLv3 source offer)

The shipped `airplay-helper` binary is GPLv3 because it links UxPlay. This
repository **is** the corresponding source for every build we ship:

- `Sources/AirPlayHelper/` (helper, overlays, and build map)
- `build.sh` (pins UxPlay and applies the overlays)
- UxPlay at the pinned commit above

Anyone who receives a copy of the app may obtain that complete source from
this public repository, which is the corresponding-source location for
every binary we ship:

    https://github.com/thiernoyunus/record-iphone

Use the git revision that built the app (or a later commit on the same
branch that still contains these overlays). A GitHub “Source code” archive
of that revision is an immutable copy of this tree. If you redistribute a
binary, include this notice and the pinned UxPlay SHA, and keep that
repository (or an archive of the same revision) available to recipients.

To fetch the pinned UxPlay tree:

    git clone https://github.com/FDH2/UxPlay.git
    git -C UxPlay checkout a3c19cbc7fcc870d74a0960bc97817a2569b4808

A packaged app copies these notices to:

    Record iPhone.app/Contents/Resources/THIRD_PARTY.md
    Record iPhone.app/Contents/Resources/LICENSE
    Record iPhone.app/Contents/Resources/licenses/UxPlay.LICENSE
