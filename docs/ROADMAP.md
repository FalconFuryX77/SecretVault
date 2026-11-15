# Roadmap

What we've agreed to build, what's still open, and ideas we parked (and why).
Collected from the project discussions; last updated 2026-11-16, at v2.0.0.

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
