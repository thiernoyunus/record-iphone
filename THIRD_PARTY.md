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

After the pin is verified, `build.sh` overlays
`Sources/AirPlayHelper/raop_rtp_mirror.c` onto
`Vendor/UxPlay/lib/raop_rtp_mirror.c`. That overlay:

- forwards codec VPS/SPS/PPS NALs to the app immediately
- treats the type-0x05 ~25 kB trailer used by current iPhones as encrypted video
- adds bounds and allocation checks for untrusted packets

`Sources/AirPlayHelper/main.c` is original to this project and talks to the
UxPlay library.

### Corresponding source

The shipped helper is GPLv3 because it links UxPlay. Corresponding source is:

- this repository (`Sources/AirPlayHelper/` and `build.sh`)
- UxPlay at the pinned commit above

To fetch the pinned UxPlay tree:

    git clone https://github.com/FDH2/UxPlay.git
    git -C UxPlay checkout a3c19cbc7fcc870d74a0960bc97817a2569b4808

A packaged app copies these notices to:

    Record iPhone.app/Contents/Resources/THIRD_PARTY.md
    Record iPhone.app/Contents/Resources/LICENSE
    Record iPhone.app/Contents/Resources/licenses/UxPlay.LICENSE
