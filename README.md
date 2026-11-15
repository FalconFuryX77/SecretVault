# SecretVault 🔒

An encrypted file vault for Android, hidden inside a working file manager, built with Flutter. It is for people whose phones may be searched or seized: one PIN opens the real vault, a second PIN opens a harmless decoy.

## How it protects your files 🔐

* **Your PIN is the key.** Nothing about your PIN is stored. The PIN goes through Argon2id (64 MiB) and then an HMAC under a non-exportable key in the phone's secure hardware (Android Keystore / StrongBox), so a copied vault can't be brute-forced on another machine.
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
* There's no backup/export of the whole vault yet. The container is device-bound by design. Encrypted sync is designed but not built (see below).

### Design docs
* [Threat model](docs/THREAT_MODEL.md): who this protects against, what each adversary still learns, and what's out of scope.
* [Container format](docs/CONTAINER_FORMAT.md): the on-device storage format, byte by byte.
* [Sync design](docs/SYNC_DESIGN.md): end-to-end encrypted, resumable sync for slow and intermittent connections (draft).

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
| On-device UI flow | `bash tool/device_test.sh integration_test/app_flow_test.dart <device>` | Setup → note → lock → covert reopen → wrong PIN → decoy → file viewer, FLAG_SECURE state |
| Per-chunk benchmarks | `flutter test integration_test/bench_test.dart -d <device>` | Channel/IO/crypto costs |
| Sync server | `cd server && python -m pytest -q -s` | API, auth, append-only, log ordering, resumability under a flaky link |

For realistic timings, run the device tests in profile mode:
`flutter drive --driver=test_driver/integration_test.dart --target=integration_test/vault_device_test.dart -d <device> --profile`

Measured on a Samsung Galaxy M34 (Android 16, debug build): PIN unlock ~1.4 s, creating the 256 MiB container ~3.5 s, importing, reading or exporting a 20 MB file ~0.45 s each.

## Tech Stack 🛠️
* **Dart / Flutter**, `provider`
* `cryptography` + `cryptography_flutter` (AES-256-GCM, HKDF, Argon2id; native AES on Android)
* Android Keystore device binding and batched native AES-GCM (Kotlin, `MainActivity.kt`)
* `sensors_plus` (accelerometer, for shake-to-lock only)
* `flutter_secure_storage` (lockout counters and preferences only, no secrets)

Core code lives in `lib/vault/` (container format, crypto, platform keys).
