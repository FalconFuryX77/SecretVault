# SecretVault 🔒

A motion-controlled encrypted file vault for Android, built with Flutter, hidden inside a working file manager.

I built this project to experiment with alternative, physical ways of authentication. Instead of typing a PIN or drawing a screen pattern (which can easily be shoulder-surfed by someone sitting next to you), SecretVault relies on a unique Two-Factor Authentication system:
1. **Biometrics:** Scans your fingerprint to prove identity.
2. **Spatial Gestures:** A secret sequence of 4–8 physical movements (Tilt Left, Tilt Up, Tilt Down, Tilt Right, Shake) selects the vault before the fingerprint releases its key.

## How it protects your files 🔐

* **Your secrets are the keys.** Nothing about your PIN or gesture is stored. The PIN goes through Argon2id (64 MiB) and then an HMAC under a non-exportable key in the phone's secure hardware (Android Keystore / StrongBox), so a copied vault can't be brute-forced on another machine.
* **The gesture never opens anything on its own.** A 4–8 move motion gesture picks the vault, and then a fingerprint has to release that vault's key from the hardware keystore. Enrolling a new fingerprint on the phone invalidates that key, so the PIN is needed again.
* **Authenticated encryption.** Files are streamed in 64 KB chunks, each sealed with AES-256-GCM under a per-file key. Any modified, swapped, reordered or truncated chunk is detected and refused, never shown. Large files never have to fit in memory.
* **One container, no tells.** Everything (both vaults, all metadata) lives in a single pre-allocated file of ciphertext and random filler. It has no headers or markers, its size doesn't track how much you store, and there are always 4 key slots whether 1 or 2 are in use.
* **Decoy vault.** A second PIN (and optionally a second gesture) opens a separate, ordinary-looking vault. Nothing in the container shows that another vault exists. The real vault knows about the decoy and never overwrites it, and a decoy opened on its own stays out of the real vault's space.
* **Secure delete.** Deleted files and old index copies are overwritten with random data, and their keys are dropped. (Flash wear-levelling makes this best effort at the physical level, but the keys are gone either way.)
* **Cover app.** It opens as a working Files manager with nothing visible about a vault. A covert triple-tap on the header opens the lock screen, and the lock screen shows only dots, never the gesture directions.
* **Lockout & panic.** After 5 failed attempts it locks out for 30 s, doubling each time up to 1 h. A hard shake locks the vault instantly and wipes the keys from memory. It also auto-locks on app switch or inactivity, and Android cloud/device backups are disabled.

### Known limits
* Nothing here stops someone who can force you to unlock the *real* vault. Use the decoy for that.
* Rollback attacks (restoring an older copy of the container file) aren't detected.
* iOS currently runs PIN-only with a software device-binding secret; the native Keystore/biometric side is Android-only.
* There's no backup/export of the whole vault yet. The container is device-bound by design. Encrypted sync is designed but not built (see below).

### Design docs
* [Threat model](docs/THREAT_MODEL.md): who this protects against, what each adversary still learns, and what's out of scope.
* [Container format](docs/CONTAINER_FORMAT.md): the on-device storage format, byte by byte.
* [Sync design](docs/SYNC_DESIGN.md): end-to-end encrypted, resumable sync for slow and intermittent connections (draft).

## How to run it 🚀
You'll need a standard Flutter development environment setup. Wait – **connect a physical Android device!** Gestures don't work reliably on Android Emulators since they lack real-world hardware accelerometers.

```bash
flutter pub get
flutter run
```

## Tech Stack 🛠️
* **Dart / Flutter**, `provider`
* `cryptography` + `cryptography_flutter` (AES-256-GCM, HKDF, Argon2id; native AES on Android)
* Android Keystore + `androidx.biometric` `BiometricPrompt` with a CryptoObject (Kotlin, `MainActivity.kt`)
* `sensors_plus` (accelerometer / gyroscope gestures)
* `flutter_secure_storage` (lockout counters and preferences only, no secrets)

Core code lives in `lib/vault/` (container format, crypto, platform keys).
