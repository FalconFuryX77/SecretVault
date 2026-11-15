# SecretVault 🔒

An encrypted file vault for Android, hidden inside a working file manager, built with Flutter. It is for people whose phones may be searched or seized: one PIN opens the real vault, a second PIN opens a harmless decoy.

Website: **https://falconfuryx77.github.io/SecretVault/**

**Status: v2.0.0, an early release.** It works end to end on real phones and is covered by the tests below, but it has not been independently audited. Don't make it the only copy of anything that matters yet.

## Install 📲

Download the APK from the [latest release](https://github.com/FalconFuryX77/SecretVault/releases/latest) and open it on the phone (Android 7 or newer; the PDF viewer needs Android 11). Check the SHA-256 against the one in the release notes.

* The vault lives inside the app's private storage. **Uninstalling the app erases it**, and so does installing a build signed with a different key over this one (this release is signed with a development key).
* The app shows up as **Files**. Triple-tap the storage header to reach the lock screen.

## How it protects your files 🔐

* **Your PIN is the key.** Nothing about your PIN is stored. The PIN goes through Argon2id (64 MiB) and then an HMAC under a non-exportable key in the phone's secure hardware (Android Keystore / StrongBox), so a copied vault can't be brute-forced on another machine.
* **Everything opens inside the app.** No other app ever sees a vault file, and nothing decrypted is written to storage:
  * **Video and audio** play through the phone's own media engine, fed from a private stream on `127.0.0.1` (random port, 256-bit secret path, closed with the player). Only the chunks being played are decrypted, so large files start at once.
  * **PDFs** are drawn by Android's PDF engine in an *isolated process*: its own throwaway user id with no permissions, no network and no access to the vault. A booby-trapped PDF that compromises the renderer gets nothing.
  * **Word documents and text** are read by memory-safe Dart code, with limits against zip bombs. Text files can be edited and saved in place.
  * **Images** are shown from memory.
* **Record straight into the vault.** Record audio from inside the vault, or arm the *hidden recorder*: with the screen off, press volume-down three times to start recording and three more to stop, without unlocking or looking at the phone. Recordings are encrypted as they're captured to a key only the vault can open, so recording works with the vault locked, the phone can't play them back, and they move into the vault the next time you unlock it. The decoy never sees the real vault's recordings.
* **No screenshots, no keyboard learning.** Vault screens are blocked from screenshots, screen recording and the recent-apps preview, and the keyboard is told not to learn anything typed in the vault.
* **Authenticated encryption.** Files are streamed in 64 KB chunks, each sealed with AES-256-GCM under a per-file key. Any modified, swapped, reordered or truncated chunk is detected and refused, never shown. Large files never have to fit in memory.
* **One container, no tells.** Everything (both vaults, all metadata) lives in a single pre-allocated file of ciphertext and random filler. It has no headers or markers, its size doesn't track how much you store, and there are always 4 key slots whether 1 or 2 are in use.
* **Decoy vault.** A second PIN opens a separate, ordinary-looking vault. Nothing in the container shows that another vault exists. The real vault knows about the decoy and never overwrites it, and a decoy opened on its own stays out of the real vault's space.
* **Secure delete.** Deleted files and old index copies are overwritten with random data, and their keys are dropped. (Flash wear-levelling makes this best effort at the physical level, but the keys are gone either way.)
* **Cover app.** It opens as a working Files manager with nothing visible about a vault. A covert triple-tap on the header opens the lock screen, where either PIN is typed into the same field.
* **Lockout & panic.** After 5 failed attempts it locks out for 30 s, doubling each time up to 1 h. A hard shake locks an open vault instantly and wipes the keys from memory (the motion sensor is only read while a vault is open). It also auto-locks on app switch or inactivity, and Android cloud/device backups are disabled.

### Known limits
* Nothing here stops someone who can force you to unlock the *real* vault. Use the decoy for that.
* Rollback attacks (restoring an older copy of the container file) aren't detected.
* Unlock is PIN-only by design. Fingerprint unlock was removed: a finger can be pressed to a sensor by force, and it can't tell the real vault from the decoy.
* iOS uses a software device-binding secret; the hardware Keystore binding is Android-only.
* Backup is manual for now: **Settings → Backup** sends encrypted copies of the open vault to a server you run (see [server/README.md](server/README.md); it runs in Docker). Automatic background backup and restoring a backup inside the app are not built yet (restore works from the command-line client).
* The app needs the internet permission for backup. It makes no connections until backup is set up, and then only to the server you entered. Release builds accept `https://` servers, or plain `http://` only to the phone's own `127.0.0.1` (a server reached through a USB tunnel such as `adb reverse`).
* Images are decoded by Flutter's built-in image codecs inside the app process; unlike PDFs they are not sandboxed yet.
* Not viewable inside the app yet: spreadsheets, slides, old `.doc` files, password-protected PDFs.
* The hidden recorder shows up the way Android requires: the green microphone dot while recording, and the app listed as running while armed. It must be armed from inside the vault, and again after a restart. If music or a video is playing, the volume keys control that instead. On Samsung phones, set the app's battery use to Unrestricted so Android doesn't stop it.

### Design docs
* [Threat model](docs/THREAT_MODEL.md): who this protects against, what each adversary still learns, and what's out of scope.
* [Container format](docs/CONTAINER_FORMAT.md): the on-device storage format, byte by byte.
* [Sync design](docs/SYNC_DESIGN.md): end-to-end encrypted, resumable sync for slow and intermittent connections (draft).
* [Roadmap](docs/ROADMAP.md): what's next, what's open, and ideas we parked.

## How to run it 🚀
You'll need a standard Flutter development environment and an Android device or emulator.

```bash
flutter pub get
flutter run
```

## Tests 🧪

| Suite | Command | What it covers |
|---|---|---|
| Unit / widget (desktop) | `flutter test` | Container format, crypto, decoy isolation, tamper detection, unlock flow, lockout, providers |
| On-device core | `flutter test integration_test/vault_device_test.dart -d <device>` | Real Android Keystore binding, native AES-GCM, production Argon2id, timings |
| In-vault viewers | `bash tool/device_test.sh integration_test/viewers_device_test.dart <device>` | Video/audio via private 127.0.0.1 stream, seek, PDF in isolated process, Word, text edit+save, tampered file refused, no files left behind |
| On-device UI flow | `bash tool/device_test.sh integration_test/app_flow_test.dart <device> [--dart-define=SYNC_SERVER=http://127.0.0.1:8080]` | Setup → note → lock → covert reopen → wrong PIN → decoy → file viewer, FLAG_SECURE state; with a server, the Backup screen too |
| Recorder | `bash tool/recorder_phone_test.sh <device>` | Recording in the vault, volume-down ×3 with the screen on and off, recording while locked, another vault's key refused, move into the vault on unlock, playback |
| Per-chunk benchmarks | `flutter test integration_test/bench_test.dart -d <device>` | Channel/IO/crypto costs |
| Sync server | `cd server && python -m pytest -q -s` | API, auth, append-only, log ordering, resumability under a flaky link |
| Phone → server → restore | `bash tool/sync_phone_test.sh <device>` | Backs up a vault from the phone to a running server, restores it on the PC from the recovery code, compares SHA-256 |

`flutter test` uninstalls the app when a device run ends, which erases the app's data. The `tool/` scripts therefore refuse to run if the app on the phone holds a vault (`tool/phone_guard.sh`).

For realistic timings, run the device tests in profile mode:
`flutter drive --driver=test_driver/integration_test.dart --target=integration_test/vault_device_test.dart -d <device> --profile`

Measured on a Samsung Galaxy M34 (Android 16, debug build): PIN unlock ~1.4 s, creating the 256 MiB container ~3.5 s, importing, reading or exporting a 20 MB file ~0.45 s each.

## Tech Stack 🛠️
* **Dart / Flutter**, `provider`
* `cryptography` + `cryptography_flutter` (AES-256-GCM, HKDF, Argon2id; native AES on Android)
* Android Keystore device binding and batched native AES-GCM (Kotlin, `MainActivity.kt`)
* `sensors_plus` (accelerometer, for shake-to-lock only)
* `flutter_secure_storage` (lockout counters and preferences only, no secrets)
* `video_player` (ExoPlayer) for audio and video; Android `PdfRenderer` in an isolated service (`PdfRenderService.kt`); `archive` + `xml` for Word documents
* Backup: `packages/sync_core` (Dart sync engine) and `server/` (FastAPI, PostgreSQL or SQLite, local or S3 storage)

Core code lives in `lib/vault/` (container format, crypto, platform keys); the viewers in `lib/viewers/`; backup in `lib/sync/`.
