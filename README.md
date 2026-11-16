# Undertow 🔒

An encrypted vault for Android, hidden inside a working video trimmer, built with Flutter. It is for people whose phones may be searched or seized: one PIN opens the real vault, another opens a harmless decoy, and nothing on the phone shows how many vaults there are. It records audio, photos and video straight into the vault, and backs the vault up, end-to-end encrypted, to a server you run.

Website: **https://falconfuryx77.github.io/Undertow/**

**Status: v3.0.0, an early release.** It works end to end on emulators and real phones and is covered by the tests below. Each release goes through an adversarial review of the whole codebase for bugs and security issues, with a regression test for every fix; what that review found but didn't fix is listed in the [threat model](docs/THREAT_MODEL.md#6-known-gaps-and-open-decisions). None of that replaces an independent audit, which it hasn't had yet ([audit brief](docs/AUDIT_BRIEF.md)). Don't make it the only copy of anything that matters.

## Install 📲

Download the APK from the [latest release](https://github.com/FalconFuryX77/Undertow/releases/latest) and open it on the phone (Android 7 or newer). Check its SHA-256 against the release notes, and that it's signed by our key:

```
SHA-256 of the signing certificate:
120bc48910582d88bca8bd3068b726974672d2b678ee24d4fa252b64a0c51de1
```

* The app shows up as **Video Trimmer**, and it is one: pick a video, trim it, save it. Triple-tap the title on its home screen to reach the lock screen.
* The vault lives inside the app's private storage. **Uninstalling the app erases it.** To move a vault to another phone or app, use Settings → *Move to Another Phone or App*.
* **Coming from the old app** (SecretVault, which showed up as "Files")? It can't be updated in place. Follow [Moving from the old app](docs/RELEASING.md#moving-from-the-old-app-secretvault--files-up-to-v210).

## How it protects your files 🔐

* **Your PIN is the key.** Nothing about it is stored. The PIN (Unicode-normalised, so every keyboard gives the same key) goes through Argon2id (64 MiB) and then an HMAC under a non-exportable key in the phone's secure hardware (Android Keystore / StrongBox), so a copied vault can't be brute-forced on another machine.
* **Everything opens inside the app**, and nothing decrypted is ever written to storage:
  * **Video and audio** play through the phone's own media engine, fed from a private stream on `127.0.0.1` (random port, 256-bit secret path, closed with the player). Video goes full screen in landscape.
  * **PDFs and images** are decoded by Android in an *isolated process*: its own throwaway user id with no permissions, no network and no access to the vault. A booby-trapped file that compromises the decoder gets nothing. Password-protected PDFs open; on Android 15+ PDFs can be searched.
  * **Word (`.docx` and old `.doc`), spreadsheets (`.xlsx`, `.ods`), slides (`.pptx`, `.odp`), `.odt` and text** are read by memory-safe Dart code with limits against zip bombs. Text files can be edited in place.
  * Text copied out of the vault is marked sensitive (kept out of clipboard previews) and cleared after a minute or when the vault locks.
* **Capture straight into the vault.** Take photos (their metadata stripped) and record video and audio from inside the vault; nothing touches the gallery. Or arm the *hidden recorder*: with the screen off, press volume-down or volume-up 2–6 times (your choice) to start and stop recording, or use the phone's assistant button. Recordings are encrypted as they're captured to a key only the vault can open, so recording works while the vault is locked, the phone can't play them back, and they move into the vault at the next unlock. Recording keys rotate daily.
* **No screenshots, no keyboard learning.** Vault screens are blocked from screenshots, screen recording and the recent-apps preview, and the keyboard is told not to learn anything typed in the vault.
* **Authenticated encryption.** Files are streamed in 64 KB chunks, each sealed with AES-256-GCM under a per-file key. Any modified, swapped, reordered or truncated chunk is detected and refused, never shown.
* **One container, no tells.** Every vault and all metadata live in a single pre-allocated file of ciphertext and random filler, with no headers or markers. Its size doesn't track how much you store, and there are always 4 key slots whether 1 or 4 are in use.
* **Decoys.** A second PIN opens a separate, ordinary-looking vault, and a decoy can have a decoy of its own (up to four vaults). No vault records whether it's "real": each follows the same rules and protects the vaults below it without being able to see the ones above.
* **Duress PIN** (opt-in, behind a warning). Entered on the lock screen, it erases the vault that set it, for good, and opens its decoy as if it were the only vault.
* **Rollback detection.** Restoring an older copy of the vault file is noticed and reported at the next unlock.
* **Secure delete.** Deleted files and old index copies are overwritten with random data, and their keys are dropped. (Flash wear-levelling makes the overwrite best effort; the keys are gone either way.)
* **Lockout & panic.** After 5 failed attempts it locks out for 30 s, doubling each time up to 1 h. A hard shake locks an open vault and wipes the keys from memory. It also locks on app switch or inactivity, and Android's cloud and device-to-device backups are off.

## Backup ☁️

Settings → Backup sends the open vault to a server you run ([server/README.md](server/README.md), [deployment guide](docs/DEPLOY.md): Docker, with HTTPS through Caddy). The server only ever sees sealed pieces of random-looking data.

* **Automatic** while the vault is open: on every change, at unlock, and as soon as a network appears, retrying through drops. Pieces resume where they stopped, so a few seconds of signal count.
* **Small previews first:** new photos, videos and recordings go up as a small copy, then in full; full-size originals can wait for Wi-Fi.
* **Restore in the app** with the recovery code: set up a new phone, bring back deleted files, or go back to how the backup was on a given day.
* **Version history:** every version of every file, kept until you free up space (which needs the recovery code, so a taken phone can't erase the backup).
* **Phones with access:** see them, revoke a lost one, or start over on a fresh account.
* **Over Tor**, through the Orbot app, if you choose.

### Known limits
* Nothing here stops someone who forces you to open the *real* vault. Use a decoy, or the duress PIN.
* Someone with a decoy's PIN *and* forensic tools can see hints in its numbers that another vault may exist ([details](docs/CONTAINER_FORMAT.md#11-limits-and-open-items)). A casual look shows nothing.
* Backup runs only while a vault is open. Uploading while locked is being designed.
* If two vaults on one phone both back up, the server sees two accounts.
* Unlock is PIN-only by design: a finger can be pressed to a sensor by force, and it can't tell the real vault from a decoy.
* The hidden recorder shows up the way Android requires: the green microphone dot while recording, and the app listed as running while armed. If music or a video is playing, the volume keys control that instead. On Samsung phones, set the app's battery use to Unrestricted.
* On Android 7–10, images are decoded inside the app instead of the isolated process, and PDFs can't be opened.
* iOS uses a software device-binding secret; the hardware binding is Android-only.

### Design docs
* [Threat model](docs/THREAT_MODEL.md): who this protects against, what each adversary still learns, and what's out of scope.
* [Container format](docs/CONTAINER_FORMAT.md): the on-device storage format, byte by byte.
* [Sync design](docs/SYNC_DESIGN.md): end-to-end encrypted, resumable backup for slow and intermittent connections, with [measurements](docs/SYNC_DESIGN.md#measured-2026-11-16).
* [Audit brief](docs/AUDIT_BRIEF.md): what to check, and where.
* [Roadmap](docs/ROADMAP.md) and [Releasing](docs/RELEASING.md).

## How to run it 🚀
You'll need a standard Flutter development environment and an Android device or emulator.

```bash
flutter pub get
flutter run
```

## Tests 🧪

| Suite | Command | What it covers |
|---|---|---|
| Unit / widget (desktop) | `flutter test` | Container format (including the format 1 migration, chains of decoys, duress), crypto, tamper detection, unlock flow, lockout, backup against a real server (history, pruning, previews, restore, Tor) |
| Sync engine | `cd packages/sync_core && dart test` | End to end against the real server through a flaky link; dedup, resume, padding, chain checks, pruning |
| Sync server | `cd server && python -m pytest -q -s` | API, auth, append-only, log ordering, recovery, resumability |
| On-device core | `bash tool/device_test.sh integration_test/vault_device_test.dart <device>` | Real Keystore binding, native AES-GCM, production Argon2id, NFC, timings |
| On-device UI flow | `bash tool/device_test.sh integration_test/app_flow_test.dart <device> [--dart-define=SYNC_SERVER=…]` | Setup → note → lock → covert reopen → wrong PIN → decoy → duress PIN → sandboxed image, screenshot protection; with a server, backup |
| Viewers | `bash tool/device_test.sh integration_test/viewers_device_test.dart <device>` | Video/audio over the private stream, PDFs (locked, search), office files, text editing, tampered file refused, nothing left behind |
| Recorder | `bash tool/recorder_phone_test.sh <device>` | Volume triggers with the screen on and off, the assistant button, recording while locked, staging format, moving into the vault |
| Camera | `bash tool/camera_test.sh <device>` | Photos and video into the vault, metadata stripped, front camera, preview orientation |
| Previews | `bash tool/device_test.sh integration_test/preview_device_test.dart <device>` | Photo, video and recording previews, with no readable plaintext on disk |
| Restore, move, cover | `integration_test/restore_flow_test.dart`, `move_device_test.dart`, `cover_device_test.dart` (through `tool/device_test.sh`) | New-phone restore, moving a vault between installs, the trimmer really trims |

`flutter test` uninstalls the app when a device run ends, which erases its data. The `tool/` scripts therefore refuse to run if the app on the phone holds a vault (`tool/phone_guard.sh`).

## Tech Stack 🛠️
* **Dart / Flutter**, `provider`
* `cryptography` + `cryptography_flutter` (AES-256-GCM, HKDF, Argon2id; native AES on Android)
* Kotlin: Android Keystore device binding, batched AES-GCM, Camera2 and MediaCodec capture, an MP4 writer, Media3 Transformer for previews, the isolated renderer (`PdfRenderService.kt`)
* `video_player` (ExoPlayer) for audio and video; `archive` + `xml` for office documents
* Backup: `packages/sync_core` (Dart sync engine) and `server/` (FastAPI, PostgreSQL or SQLite, local disk or S3)

Core code lives in `lib/vault/` (container format, crypto, platform keys); the viewers in `lib/viewers/`; backup in `lib/sync/`; the cover app in `lib/cover/`.
