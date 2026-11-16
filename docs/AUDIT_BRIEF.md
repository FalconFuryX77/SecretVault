# Audit brief

For an independent security review of Undertow. It says what to look at,
what we claim, and where we already know the weak points are. Nothing here
replaces reading the code; everything here should be checkable against it.

## What it is

An Android app (Flutter, with Kotlin for the platform parts) that hides an
encrypted file vault behind a working video trimmer. One PIN opens the real
vault, another a decoy; nothing on the phone shows how many vaults exist.
It can record audio, photos and video straight into the vault, and back the
vault up, end-to-end encrypted, to a server the user runs.

Who it's for and what they face: [THREAT_MODEL.md](THREAT_MODEL.md).

## Claims to test

1. **Confidentiality at rest.** Without a PIN *and* the phone's hardware
   key, the container reveals nothing but its size. No plaintext, metadata
   or structure in the clear. ([CONTAINER_FORMAT.md](CONTAINER_FORMAT.md))
2. **Deniability against a coercer.** With one vault's PIN, nothing in the
   app or its storage proves another vault exists. Known limits: the
   forensic layout tells in CONTAINER_FORMAT §11 and the stand-in decoy.
3. **No plaintext on disk.** Viewing, recording, transcoding previews,
   backing up and restoring never write decrypted content to storage.
4. **Integrity.** Any change to the container, a backup piece, a manifest or
   the backup log is detected and refused, never shown or restored wrong.
5. **Isolation of untrusted parsers.** PDFs and images are parsed only in an
   isolated process with no permissions; office documents by memory-safe
   Dart with size limits.
6. **The server learns nothing useful.** It stores sealed pieces, padded log
   records and wrapped keys; it can withhold or drop data but not read or
   forge it, and clients detect rolled-back logs. ([SYNC_DESIGN.md](SYNC_DESIGN.md))
7. **A seized phone can't erase the backup** on an append-only server, and a
   revoked phone is refused.
8. **Crash safety.** A crash at any point leaves every vault openable with
   its previous or new state (including while hosting a decoy, which moves
   files, and while a duress PIN destroys a vault).

## Where to look first

| Area | Code | Why |
|---|---|---|
| Container and allocation | `lib/vault/vault_container.dart`, `lib/vault/vault_index.dart` | Format 2's rule that no vault writes into another's space, the decoy chain, relocation, duress |
| Keys and device binding | `lib/vault/crypto_primitives.dart`, `lib/vault/platform_keys.dart`, `MainActivity.kt` (keystore, bulk AES-GCM) | Argon2id parameters, HMAC under a StrongBox key, nonce handling in the native batch path |
| Recording while locked | `RecordingFormat.kt`, `RecorderService.kt`, `lib/recorder/vault_recorder.dart` | Hybrid encryption to the vault's public key, staging format v2, key rotation |
| Camera and video export | `VaultCamera.kt`, `Mp4Export.kt`, `JpegClean.kt` | Metadata stripping, two-pass MP4 writer over sealed staging |
| Previews | `PreviewMaker.kt`, `lib/sync/previews.dart` | Transformer reading from the loopback stream; custom muxer sealing samples |
| Isolated renderer | `PdfRenderService.kt`, `PdfSandbox.kt` | Treats the renderer's replies as hostile; timeouts |
| Loopback media stream | `lib/viewers/vault_media_server.dart` | 127.0.0.1 only, 256-bit path, range handling |
| Backup engine | `packages/sync_core/lib/src/` | Piece naming (HMAC), sealing, padded log, chain verification, pruning |
| Server | `server/app/` | Auth (Ed25519 challenges), recovery signatures, append-only, quotas |
| Move tool | `vault_container.dart` (`exportForTransfer`, `completeTransfer`), `FileMover.kt` | Transfer slot sealed under a one-time code |
| Assistant trigger | `AssistTriggerActivity.kt` | Accepts only system callers |

## Known weak points (already listed)

[THREAT_MODEL.md §6](THREAT_MODEL.md#6-known-gaps-and-open-decisions). In
short: forensic layout tells with a decoy PIN; the stand-in decoy; the
recorder's media session is visible to apps with notification access; a
rollback of the container and its guard file together isn't detected; two
backup accounts if two vaults back up; a pruning race with several phones.

## How to run it

- Unit and desktop tests: `flutter test`; the sync engine:
  `cd packages/sync_core && dart test` (needs Python and
  `server/requirements.txt` for the end-to-end tests); the server:
  `cd server && python -m pytest -q`.
- On an emulator: the scripts in `tool/` (see the README's test table).
- Build: `flutter build apk --release` (see [RELEASING.md](RELEASING.md)).

## Out of scope

A coercer who gets the *real* PIN; a compromised phone OS or keyboard; the
user's server host itself (we assume the operator may be hostile, but not
that the user's own phone is).
