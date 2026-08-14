# Third-party notices

Wireless Screen Mirroring uses the UxPlay AirPlay protocol library
(https://github.com/FDH2/UxPlay), licensed under the GNU GPL v3.
The helper in `Sources/AirPlayHelper` links that library and does not
use GStreamer; video is decoded in the app with VideoToolbox.
