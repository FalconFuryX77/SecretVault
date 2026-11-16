# Roadmap

What we've agreed to build, what's still open, and ideas we parked (and why).
Collected from the project discussions; last updated 2026-11-16, at v2.1.0.

## Build plan (started 2026-11-16)

Everything below is being built in this order. Each part is tested on the
emulator (and on the PC where it can be), then committed on its own.
Decisions taken: both hidden triggers (volume and assistant button), a
video-trimmer cover app, and the name **Undertow**.

1. **Capture**
   1. Trigger options: volume-down or volume-up, 2–6 presses, and an opt-in
      assistant-button trigger.
   2. Recording keys rotate; staged recordings look like random data
      (needed before video, which uses the same staging).
   3. Camera: photos straight into the vault.
   4. Camera: video into the vault, encrypted while it's recorded.
2. **Vault hardening**
   1. The real vault opens even if its decoy's index is damaged.
   2. Passphrases are Unicode-normalised (the old form still opens).
   3. Images are decoded in the isolated process, like PDFs.
   4. Text copied out of the vault is marked sensitive and cleared on lock.
   5. Rollback of the container file is detected.
   6. A decoy that can't be told from a lone vault, and that can host a real
      decoy of its own (container v2, migrated on unlock).
   7. Duress PIN (opt-in).
3. **Backup**
   1. Padded log records, chain-head checks, manifests for very large files.
   2. Automatic backup while unlocked: on change, on unlock, when a network
      appears, with retries.
   3. Restore in the app from the recovery code; device list and revocation;
      key rotation; restore "as of" a time, skipping revoked devices.
   4. One backup account per phone.
   5. Upload while locked (outbox, decision D1 option B), with a switch.
   6. Previews first on bad connections.
   7. Version history and pruning.
   8. Server: HTTPS through Caddy, MinIO tested, Tor through Orbot, and a
      deployment guide.
4. **Viewers:** landscape video; spreadsheets, slides and `.doc`;
   password-protected PDFs and search (Android 15+).
5. **Disguise:** a "move vault" tool first, then the video-trimmer cover,
   then the rename to Undertow (new package and permanent signing key).
6. **Docs, landing page and release.**

Two items can't be finished from here: the **independent security review**
(an audit brief will be prepared for reviewers) and **putting a server on
the internet** (needs a domain and a host; the configuration and a guide
will be ready).

## Next up

- [x] **Audio recorder inside the vault** (v2.1.0).
- [x] **Screen-off recording trigger**: volume-down ×3 (v2.1.0). Replaces the
      original "draw MIC on a dark screen" idea, which Android doesn't let
      apps detect. Still to confirm by hand on more phone makers.
- [x] **Record while the vault is locked** (v2.1.0).
- [ ] **Camera capture into the vault.** Photos (and later video) taken
      straight into encrypted storage, never touching the gallery.

## Backup and sync

The user's top priority after the vault itself: "connect to a server and
automatically keep syncing there."

- [ ] **Automatic background backup** (M2 scheduler): start uploading the
      moment any network appears, retry on bad links. Today backup is a button.
- [ ] **Put the server on the internet with HTTPS.** Tested so far only from
      the phone over a USB tunnel to Docker on the PC. Needs a TLS proxy and a
      domain; the reference Docker stack doesn't include one.
- [ ] **Restore inside the app** (M3), plus setting up a new phone from the
      recovery phrase, revoking a lost phone, key rotation. Restore works from
      the command-line client only.
- [ ] **Previews first on a bad connection** (M4): send a small copy of a video
      first, the original later on Wi-Fi.
- [ ] **Upload while the vault is locked** (M5, decision D1 in
      [SYNC_DESIGN.md](SYNC_DESIGN.md)), with a setting to turn it off.
- [ ] **Version history screen and pruning** (M6); publish measured results.
- [ ] Test S3/MinIO storage in Docker (the MinIO image wouldn't pull; local
      disk storage is what's tested).
- [ ] Refresh the milestone table in SYNC_DESIGN.md (M1 is further along than
      it says: Docker stack, failure proxy and CLI client exist).

## Disguise

- [ ] **Decide the cover app.** Still the "Files" manager. Recommended: a
      simple video trimmer/compressor, because it explains camera, microphone
      and gallery access and gigabytes of "project cache". Runner-up: a
      podcast player. Offline maps was dropped (looks like spying in a
      conflict zone).
- [ ] **Remove identifying names before anyone else installs it.** The package
      is still `com.example.gesture_unlock`. Changing it later makes it a
      different app, so updating would erase people's vaults.
- [ ] **Pick the product name.** "SecretVault" is a placeholder. Candidates:
      Undertow (recommended), Seep, Palimpsest. DropSync is taken (an existing
      Dropbox sync app). A public repo that says "secret vault" also weakens
      the cover against someone who looks the app up.
- [ ] **Permanent release signing key**, created once and kept safe. v2.0.0 is
      signed with a development key; switching later means uninstalling.

## Security hardening

Found by the independent review (2026-11-16) and not fixed yet; details in
[THREAT_MODEL.md](THREAT_MODEL.md) §6:

- [ ] **Decoy can host a real decoy of its own.** Today a decoy's "Set up a
      decoy" only pretends (the PIN opens nothing). Needs a container format
      change: the decoy must be able to reserve a record and space the real
      vault knows about.
- [ ] **Decoy index looks like any lone vault's** (forensic tell with the
      decoy PIN).
- [ ] **Rotate the recording key pair**; consider making staged recordings
      indistinguishable from random.
- [ ] **One backup account per phone**, shared by its vaults (SYNC_DESIGN §11).
- [ ] **Pad backup log records**; check device chains against known heads.
- [ ] **Restore "as of" a time** and ignoring a revoked device's records.
- [ ] Open the real vault even if its decoy's index is damaged (today a
      corrupted decoy index stops the real vault opening).

- [ ] **Duress PIN** (opt-in, with a clear warning): opens the decoy and
      silently destroys the real vault's key.
- [ ] **Sandbox image decoding** like PDFs (images are decoded in the app
      process today).
- [ ] Detect rollback of the container file.
- [ ] Normalise passphrases (Unicode NFC) so different keyboards give the same key.
- [ ] **Independent security review.** In this category the real moat is
      trust: an audit, open code, never losing data, and newsrooms or NGOs
      relying on it.
- [ ] Routing backups over Tor (idea, not designed yet).

## In-vault viewers

- [ ] Spreadsheets, slides and old `.doc` files.
- [ ] Password-protected PDFs; search in PDFs.
- [ ] Full-screen landscape video.
- [ ] "Choose your own shortcut" list, once the volume trigger has proven
      reliable on real phones.

## Parked ideas (decided against, with the reason)

- **On-chain storage (Arkiv):** files on a public chain stay forever and can
  be cracked later, a wallet links the vault to a person, and it's far too
  expensive for photos and video. A tiny tamper-evidence record (a hash of the
  file list) could be an optional extra later.
- **Splitting the vault into fake "system apps":** Android doesn't allow it
  quietly, it breaks store rules, and forensic tools would spot it at once.
  Replaced by the fixed-size container, which is built.
- **Gesture and fingerprint unlock:** removed. Gestures were unreliable under
  stress; a finger can be forced onto a sensor and can't pick the decoy.
- **Compression for backups:** not worth it; photos and video are already
  compressed.

## Done (for reference)

v2.0.0: encrypted container with a decoy, PIN-only unlock, real cover-app
figures, in-vault viewers (video, audio, PDF in an isolated process, Word,
text editing), manual backup to a self-hosted server, landing page on GitHub
Pages. See the [release notes](https://github.com/FalconFuryX77/SecretVault/releases/tag/v2.0.0).
