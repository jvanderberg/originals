# Originals

A Mac app for getting your photos and videos out of Apple Photos as unmodified originals, fast, with real progress.

Exporting from Photos is painful when your library lives in iCloud. Photos has to download each original first, it does that at about 0.7 MB/s no matter how fast your connection is, and it shows no progress while it works. A 5 GB video can take two hours with nothing on screen.

Originals downloads the same files straight from iCloud at the full speed of your connection (about 33 MB/s on a 280 Mbps line in testing, versus 0.7 MB/s), and shows every file's progress, speed and time left.

## Features

- Browse your library, albums and smart albums in a fast thumbnail grid. Select like Finder (click, ⌘-click, ⇧-click, drag, ⌘A).
- Export unmodified originals (⌘E): the HEIC, MOV, RAW and Live Photo video files exactly as they were captured, with their original names and capture dates.
- Export smaller versions (⌥⌘E) when you don't need the full file: iCloud's 1080p, 720p or 360p video, or a ~2,048 px JPEG.
- An export queue with per-file and overall progress, speed, time left, pause, cancel and retry. Files already in the destination folder are skipped.
- Double-click or press Space to preview any item, including videos that are only in iCloud.

## Install

Download the latest `Originals-*.dmg` from [Releases](../../releases), open it, and drag Originals to Applications. It is signed and notarized, so it opens normally.

Requires macOS 14 or later. On first launch it asks for access to your Photos library.

## Fast iCloud downloads

Originals asks you to sign in to iCloud on Apple's own icloud.com sign-in page, shown inside the app. Two-factor authentication works as it does in Safari.

- Your password goes only to Apple. Originals never sees it.
- The resulting iCloud session is kept in your login Keychain, so you stay signed in between launches. Sign out from the toolbar's iCloud menu or in Settings.
- With the session, Originals talks to the same iCloud Photos web service that icloud.com uses. It only reads: it looks up the download links for the items you export or preview, then downloads them. Nothing in your library is changed.

You can skip signing in. Files that are already on your Mac export at disk speed either way. Files that have to come from iCloud then go through Photos at its usual ~0.7 MB/s, and Originals asks before doing that.

## Build from source

You need Xcode 16 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
./build.sh          # Debug build into build/
./build.sh --run    # build and launch
```

Debug builds are signed with an Apple Development certificate. To build with your own team, change `DEVELOPMENT_TEAM` in `project.yml`.

## Releases

Pushing a tag like `v0.2.0` runs `.github/workflows/release.yml`. It builds a universal app, signs it with Developer ID, notarizes and staples it, wraps it in a notarized DMG and publishes a GitHub release. It needs these repository secrets:

| Secret | What it is |
| --- | --- |
| `DEVELOPER_ID_P12` | The Developer ID Application certificate and key, exported as .p12 and base64-encoded |
| `DEVELOPER_ID_P12_PASSWORD` | The .p12's password |
| `NOTARY_APPLE_ID` | Apple ID used for notarization |
| `NOTARY_PASSWORD` | An app-specific password for that Apple ID |
| `NOTARY_TEAM_ID` | The Developer Team ID |

`scripts/build-release.sh` does the same locally, using a `notarytool` keychain profile (`NOTARY_PROFILE=name scripts/build-release.sh`).
