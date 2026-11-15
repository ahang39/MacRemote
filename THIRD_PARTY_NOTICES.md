# Third-party licensing and binary distribution

The **original MacRemote code** in the current source tree is offered under
[PolyForm Noncommercial License 1.0.0](LICENSE). It permits uses described in
that license, including noncommercial modification and distribution. Commercial
use of MacRemote original code requires separate authorization.

**Third-party code and patches derived from upstream FreeRDP remain under their
original licenses.** Publishing MacRemote under PolyForm does not relicense them.

| Dependency | Use | Upstream licensing |
| --- | --- | --- |
| [FreeRDP / WinPR](https://github.com/FreeRDP/FreeRDP) | RDP server and channels, including MacRemote integration patches against pinned FreeRDP 3.33.1 | Apache License 2.0 |
| [OpenSSL](https://www.openssl.org/source/license.html) | TLS and cryptography | Apache License 2.0 (OpenSSL 4) |
| [Opus](https://opus-codec.org/license/) | Audio encoding | BSD-style license |
| [json-c](https://github.com/json-c/json-c) | JSON processing | MIT license |

The bundled application includes the license texts for these components in
MacRemote.app/Contents/Resources/Licenses/ and retains upstream notices.

## Distribution safeguards

The distribution build uses FreeRDP with FFmpeg and SWScale disabled. It
does not bundle FFmpeg, x264 or x265. The packaging script checks the
architecture, signature, prohibited media libraries, and required license files.

An earlier development build used GPL-enabled Homebrew FFmpeg and x264/x265;
**those developer binaries must not be redistributed**. Every new build must
pass the dependency review and packaging checks for each architecture.

## Historical GPL release

An earlier v0.2.0-adhoc.1 preview was distributed with the original
MacRemote code under GPL-3.0-or-later. Its GitHub Release and tag have since
been deleted. Recipients who already obtained the earlier version keep their
GPL rights. The current PolyForm license applies to this newly published
source snapshot and does not revoke prior GPL grants.
