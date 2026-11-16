# Changelog

Every release of Undertow (called SecretVault until v3.0.0), newest first.
Security-relevant changes are marked **security**.

## v3.1.1 (2026-11-16)

- Fixed: with "Keep uploading while locked" on, a change made in the last
  half-minute before the vault locked (by default it locks after 30 s idle)
  only reached the queue at the next unlock. A change now goes to the server
  or the queue 3 seconds after it's made.
- Fixed: after the emergency stop, the vault kept saying locked upload was on
  until it next got online, while queueing nothing. It now notices the stop
  as soon as it's unlocked, offline too, and turns the old login off on the
  server once it's online.
- Each vault that backs up has its own account and recovery code, by design
  (the server is yours; a decoy's code can never reach the real vault's
  backup). The docs no longer list a shared account as missing.

## v3.1.0 (2026-11-16): uploading while locked

- **Keeps uploading while locked** (on by default, with an off switch in
  Settings → Backup). When backup can't reach the server, what's left is
  sealed into a queue that the phone sends whenever a network appears, even
  with the vault locked, in order, through Tor if the vault uses it. The
  next online backup settles it: anything that didn't arrive goes again.
- **security** The phone keeps only an upload-only login for this: the
  server lets it add pieces and log records, never read, list or delete
  anything. It's renewed at each backup and revoked when no longer used.
- **security** Emergency stop, without unlocking anything: "Clear cache" in
  Video Trimmer's menu, or a stop code typed on the lock screen (it looks
  like a wrong PIN). Either wipes the queue, its state and login. Nothing in
  the vault or on the server is touched, and locked upload stays off until
  it's turned on again inside the vault.
- The queue uses at most 1 GiB, or a tenth of the free space, and always
  leaves 2 GiB free. Only one vault on a phone uses it at a time.
- Server: upload-only tokens (`POST`/`DELETE /v1/auth/upload-token`), with
  read and delete endpoints refusing them; older databases are upgraded.
- **security** The file a vault is moved out to is suggested as
  `trim-projects.bak` instead of a name with "vault" in it.

## v3.0.0 (2026-11-16): Undertow

The app is renamed Undertow and shows up as a working **Video Trimmer**,
under a new package name (`com.videotrimmer.local`) and signed with a
permanent release key (certificate SHA-256
`120bc48910582d88bca8bd3068b726974672d2b678ee24d4fa252b64a0c51de1`).
It can't update the old app in place: see
[Moving from the old app](docs/RELEASING.md#moving-from-the-old-app-secretvault--files-up-to-v210).

### Capture
- Hidden recorder trigger is configurable: volume-down or volume-up, 2–6
  presses; pressing the other button resets the count.
- Opt-in assistant-button trigger (the "4th button" on some phones). It
  accepts only the system as its caller, so other apps can't start it.
- Camera inside the vault: photos (location and device metadata stripped,
  only orientation kept) and video (H.264 + AAC, encrypted while it's
  recorded, turned into an MP4 as a stream into the vault). Front and back
  cameras, torch. Nothing touches the gallery. A video cut off by a lock
  moves into the vault at the next unlock.
- **security** Recording keys rotate daily (old ones kept for 7 days so
  pending recordings still open). Staged recordings no longer have any
  visible structure: headers and segment lengths are masked, so they look
  like random data.

### Vault
- **security** Container index format 2: a vault's own data no longer says
  whether it's the real vault or a decoy. Every vault keeps to its own
  space by the same rules, a vault hosting a decoy fills from the top, and
  each vault protects every vault below it before writing into its space.
- Any vault can host a decoy, a decoy too: chains of up to four vaults.
  Hosting a decoy first moves the host's files to the top of its space,
  crash-safely. Removing a decoy removes everything below it.
- Format 1 vaults are upgraded on their first unlock (tested byte for byte
  against a vault made by the old code).
- **security** Duress PIN (opt-in, behind a warning): entered on the lock
  screen, it overwrites the record and index of the vault that set it and
  opens its decoy, which takes over its space.
- **security** A damaged decoy no longer stops the real vault opening; the
  real vault then writes only where the decoy can't be.
- **security** Passphrases are Unicode-normalised (NFC), so every keyboard
  gives the same key; ones set before are still accepted and re-stored.
- **security** Rollback detection: an older copy of the vault file put back
  in place is noticed at the next unlock.
- **security** Images are decoded in the isolated process, like PDFs.
- **security** Text copied out of the vault is marked sensitive (kept out
  of clipboard previews) and cleared after a minute or when the vault locks.
- Move a vault to another phone or app: a copy of the vault file plus a
  one-time transfer code; the other side sets its own PINs.
- The vault's role ("real" or "decoy") is no longer known anywhere in the
  app, so no screen can behave differently because of it.

### Backup
- Automatic backup while a vault is open: on every change, at unlock, and
  as soon as a network appears, with retries and backoff.
- Restore in the app from the recovery code: set up a new phone, bring back
  deleted files, or restore the backup as it was on a given day, skipping a
  revoked phone's changes.
- Phones with access: list them, revoke a lost one, or start over on a new
  account (everything uploaded again; the old account closed).
- Version history: every version of every file, current, replaced or
  deleted; any version still on the server comes back as a copy.
- Free up server space: removes old versions after a retention period you
  choose; needs the recovery code; verifies everything before deleting.
- Small previews first: new photos (1600 px JPEG), videos (480p) and
  recordings (32 kbit/s) go up as small copies before the originals, made
  without writing plaintext anywhere. Originals can wait for Wi-Fi.
- Backup over Tor, through the Orbot app.
- **security** Log records are padded (so their size doesn't show what they
  hold); every phone's chain is checked against the positions seen before
  (so a server can't quietly roll back or drop records).
- Very large files (over ~2 GB) are backed up, with their piece list split
  across several manifests.
- Server: HTTPS through Caddy (with no access logs), S3 storage
  (SeaweedFS), account lookup by recovery code, account deletion, a public
  deployment guide.

### Viewers
- Spreadsheets (`.xlsx`, `.ods`), slides (`.pptx`, `.odp`), old Word
  (`.doc`) and `.odt`, read by memory-safe Dart code.
- Password-protected PDFs; search inside PDFs (Android 15+).
- Full-screen landscape video.

### Cover app
- A real video trimmer: pick a video, choose start and end, keep or drop
  the sound, save (lossless cut). Clips land in Movies/Video Trimmer.
- The old file manager and its storage permissions are gone: the app asks
  for nothing it doesn't use.

### Docs and tooling
- New: audit brief, release guide, deployment guide, this changelog;
  measured backup numbers in the sync design.
- Test helpers no longer change a storage app-op that made Android kill the
  app as tests started.

## v2.1.0 (2026-11-16): record into the vault

- Record audio inside the vault, encrypted as it's captured.
- Hidden recorder: with the screen off, volume-down ×3 starts and stops
  recording, without unlocking.
- Records while the vault is locked, to a key only the vault holds; the
  recording moves in at the next unlock. The decoy never sees it.
- Crash-safe: saved every second, long recordings split into parts.
- **security** Fixes from an adversarial review: a lock during a save could
  lose both versions; decoy space and crash-safety gaps; decoy Settings and
  PIN-change tells; lockouts skippable by changing the clock; vault content
  visible after a lock; crashes from long recordings and hostile PDFs;
  backup edits, quota and request-size issues; the recovery code is
  confirmed before the account exists and never stored.

## v2.0.0 (2026-11-15): PIN-only vault with a decoy

- One container file of ciphertext and random filler; Argon2id + a
  hardware-bound key; AES-256-GCM in 64 KB chunks with tamper detection.
- PIN-only unlock with a real decoy vault (gesture and fingerprint unlock
  removed).
- In-vault viewers: video and audio streamed from memory, PDFs in an
  isolated process, Word documents and text (editable).
- No keyboard learning, no screenshots inside the vault.
- Self-hosted, end-to-end encrypted backup (manual).
- Cover app: a file manager showing the phone's real storage.

## v1.1.0 (2026-08-30)

Secure notes with motion-gesture unlock; a stabilised gesture engine.

## v1.0.0 (2026-04-14)

First release: notes protected by fingerprint plus a motion gesture.
