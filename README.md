<img width="300" height="300" alt="Sonos Control" src="https://github.com/user-attachments/assets/79b0a36f-0ad2-41d8-8da8-f93aef9d5407" />

# Sonos Control

A minimal, fast Sonos controller for macOS — lives in the menu bar, opens
instantly, plays/pauses your zone in a single click.

Built to replace the official Sonos desktop app for the 99% case (play, pause,
volume, pick a station) without the slow startup or requiring Rosetta.

There are many Sonos apps out there. This is mine.

<img width="398" height="418" alt="Sonos Control App" src="https://github.com/user-attachments/assets/ede4c685-f2c9-4f3e-a157-55261bad8a93" />

## Install

Download the latest release from
[**GitHub Releases**](https://github.com/nfarina/SonosControl/releases/latest),
unzip, and drag `Sonos Control.app` to `/Applications`. macOS will prompt for
**Local Network** access the first time you launch — grant it so the app can
discover your Sonos speakers.

Auto-updates are handled via [Sparkle](https://sparkle-project.org/).

## Features

- **Menu bar app, no dock icon.** Opens in ~50ms, gets out of your way.
- **Play/pause, transport, volume.** Single tap. Volume slider is live as you drag.
- **Zone control.** Pick a primary zone; toggle any other zones to join or leave its group with a switch.
- **Now playing.** Song / artist / album-or-station. Click the album art for full-resolution view + "Open in Apple Music."
- **Recently played.** Last 10 songs the system played, even when the menu was closed. Click any to find it in Apple Music.
- **Favorites.** Pick from your Sonos favorites (radio stations, playlists, albums).
- **Global hotkey.** Default `F8` for play/pause from anywhere. Fully customizable.
- **In-menu shortcuts.** `⌘P` play/pause, `⌘=` / `⌘−` volume. All customizable.
- **Offline-aware.** Icon greys out when off the home network.
- **Auto-updates** via Sparkle.

## How it works

Talks directly to your Sonos players over the local LAN using their built-in
UPnP/SOAP API on port 1400. No Sonos account login required, no cloud
round-trip — every command is a single HTTP request to the speaker, typically
20–50ms.

Players are discovered via SSDP (`M-SEARCH` to `239.255.255.250:1900`) on
launch. After discovery the app caches IPs and polls now-playing every 10s in
the background, 3s while the menu is open.

## Notes

### Sandbox is off

SSDP multicast requires unsandboxed networking, so `ENABLE_APP_SANDBOX = NO`.
The Sparkle framework is signed with hardened runtime. The app has no
filesystem access beyond `~/Library/Application Support/SonosControl/` (logs).

### Limitations

- No multi-room source switching (each group plays one source — the primary).
- No queue management UI (favorites/streams replace the queue when picked).
- No search.
- No iOS/iPad version.

By design — this is a 99%-case controller, not a full Sonos app.

## Building locally

Requirements: Xcode 16.2+ (macOS 14+).

Open `SonosControl.xcodeproj` in Xcode and ⌘R to run a Debug build, or:

```bash
# Build in Release, sign with your Developer ID, install to /Applications.
./Scripts/local-install-app.sh
```

Requires a Developer ID Application certificate in your login keychain.

### Forking

If you want to publish your own builds (with your own update feed), replace
these before building:

| File | Setting | What to change |
|---|---|---|
| `SonosControl.xcodeproj/project.pbxproj` | `PRODUCT_BUNDLE_IDENTIFIER` | `com.yourname.SonosControl` |
| `SonosControl.xcodeproj/project.pbxproj` | `DEVELOPMENT_TEAM` | your Apple Developer team ID |
| `SonosControl/Info.plist` | `SUFeedURL` | URL of your appcast.xml |
| `SonosControl/Info.plist` | `SUPublicEDKey` | public key from `generate_keys` (Sparkle) |
| `Scripts/sparkle-config.sh` | various | your GitHub repo & Pages URLs |

If you don't plan to publish updates, blank out `SUPublicEDKey` and Sparkle
will just sit quietly.

### Releasing

```bash
# Build, sign, notarize, staple → dist/SonosControl-<version>-macos.zip
./Scripts/local-release-build.sh 1.0.1

# Or do the whole release flow: build → GH release → appcast → push
./Scripts/publish-release.sh 1.0.1
```

Requires:
- Developer ID Application certificate
- `xcrun notarytool store-credentials sonoscontrol-notary` (one-time setup)
- `gh` CLI authenticated
- Sparkle key pair generated via `generate_keys` and stored in your keychain
  under the `SPARKLE_KEY_ACCOUNT` from `sparkle-config.sh`
- GitHub Pages enabled on your fork, serving from `main/docs`

## License

MIT. See [LICENSE](LICENSE).
