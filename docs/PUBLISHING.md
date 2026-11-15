# Publishing MacRemote source

MacRemote is published on GitHub with complete source, build instructions and contributor documentation. Binary distribution is a separate release milestone after dependency-license and signing reviews.

## GitHub publication checklist

1. Publish the new standalone **main** branch, containing a single curated root commit. Previous local engineering history is backed up **outside the repository** and must never be pushed.
2. Before publishing, review tracked files and commit metadata, third-party notices, and run python3 tools/check-public-source.py. Do not add development-history backups to this repository.
3. Enable GitHub Actions, private vulnerability reporting and, when available, secret scanning and branch protection. Avoid automatic binary releases.
4. Keep LICENSE, THIRD_PARTY_NOTICES.md, SECURITY.md, CONTRIBUTING.md, bilingual README and the GitHub issue templates in the published tree.
5. Once the GitHub repository URL is known, update clone instructions and repository-specific links. Verify source tests and dependencies on a clean machine.

Only main is intended for public push. Avoid git push --all, git push --mirror or unreviewed tags.

## Ad-hoc DMG distribution

The release build disables both FFmpeg and SWScale in FreeRDP. The bundled binary is checked for libavcodec, libavutil, libswscale, libx264 and libx265, and license texts are included in the App bundle. Do not upload previous Homebrew FFmpeg-derived developer builds.

Use tools/package-dmg.py to validate architecture, Ad-hoc code signing, the dynamic library list and license texts, then create and verify a compressed DMG. GitHub Actions builds both arm64 and x86_64 on their respective native macOS runners. Only upload binaries when the per-architecture jobs pass.

Ad-hoc builds cannot be notarized. Explain the macOS Privacy & Security > Open Anyway first-launch workflow in release notes. Developer ID signing, notarization and broader integration testing remain future work.

## Current quality baseline

- Local full build previously passed 11/11 native tests, Swift port-preferences tests, Mach-O dependency relocation and code signing.
- GitHub Actions runs source checks and a native ARM64/Intel DMG build workflow; end-to-end hardware behavior still requires manual verification.
- Windows mstsc connected in Classic graphics mode previously; full regression testing of the latest standalone App remains open.

## Repository security

Never commit runtime credentials, server certificates, private configuration files, personal screen recordings, local IP addresses or personal host paths. The public-source check detects several high-confidence accidental disclosures; it is not a substitute for review before publication.
