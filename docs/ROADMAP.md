# Roadmap

What we've agreed to build, what's still open, and ideas we parked (and why).
Last updated 2026-11-16, at v3.0.0 (Undertow).

## Build plan (started 2026-11-16)

Built in this order, each part tested on the emulator (and on the PC where it
can be) and committed on its own. Decisions taken: both hidden triggers
(volume and assistant button), a video-trimmer cover app, the name
**Undertow**, and the "keep it safe" decoy design.

1. **Capture**
   - [x] Trigger options: volume-down or volume-up, 2–6 presses, and an
         opt-in assistant-button trigger.
   - [x] Recording keys rotate daily; staged recordings look like random data.
   - [x] Camera: photos straight into the vault (since v3.2.1 with their metadata and place, as evidence).
   - [x] Camera: video into the vault, encrypted while it's recorded.
2. **Vault hardening**
   - [x] The real vault opens even if its decoy's index is damaged.
   - [x] Passphrases are Unicode-normalised (the old form still opens).
   - [x] Images are decoded in the isolated process, like PDFs.
   - [x] Text copied out of the vault is marked sensitive and cleared on lock.
   - [x] Rollback of the container file is detected.
   - [x] A decoy whose index doesn't say "decoy", and that can host a real
         decoy of its own (index format 2, migrated on unlock).
   - [x] Duress PIN (opt-in).
3. **Backup**
   - [x] Padded log records, chain-head checks, manifests for very large files.
   - [x] Automatic backup while unlocked: on change, on unlock, when a network
         appears, with retries.
   - [x] Restore in the app from the recovery code; device list and
         revocation; start over on a new account; restore "as of" a time,
         skipping revoked devices.
   - [x] **Backup accounts:** decided, one per vault (see parked ideas).
   - [x] **Upload while locked** (outbox, decision D1 option B): on by
         default, an off switch, and a quiet emergency stop ("Clear cache"
         in the cover app, or a stop code on the lock screen) that wipes
         the queue and its upload-only login and leaves it off until it's
         turned on again in the vault.
   - [x] Previews first: small copies of new photos, videos and recordings
         go up before the originals; originals can wait for Wi-Fi.
   - [x] Version history and pruning ("Free up server space").
   - [x] Server: HTTPS through Caddy, S3 storage tested (SeaweedFS; the
         MinIO images couldn't be pulled), Tor through Orbot, and a
         deployment guide.
4. **Viewers:** [x] landscape video; [x] spreadsheets, slides and `.doc`;
   [x] password-protected PDFs and search (Android 15+).
5. **Disguise:** [x] a "move vault" tool, [x] the video-trimmer cover,
   [x] the rename to Undertow (new package and permanent signing key).
6. **Docs, landing page and release.**

Two items can't be finished from here: the **independent security review**
(an audit brief is ready for reviewers) and **putting a server on the
internet** (needs a domain and a host; the configuration and
[guide](DEPLOY.md) are ready).

## Next up

- **Pairing a second phone** with a QR code (SYNC_DESIGN §10), as an
  alternative to the recovery code.
- **Offload**: "delete from this phone once it's safely on the server"
  (SYNC_DESIGN §8.2).
- **Previews first on restore too**: download small copies before the
  originals on a slow link.
- **Recovery-code wordlists** beyond English (SYNC_DESIGN §16).
- Confirm the screen-off triggers by hand on more phone makers.

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
- **One backup account per phone**, shared by its vaults: it would only
  hide the number of vaults from the server, which the user runs and
  trusts. A seized phone shows nothing either way, and separate accounts
  mean a decoy's recovery code can never reach the real vault's backup.
- **Hiding the decoy's layout numbers** (its ceiling and spare-record count):
  doing so would mean dropping the rules that keep vaults from overwriting
  each other. We chose safety; see the threat model.

## Done (for reference)

- v2.0.0: encrypted container with a decoy, PIN-only unlock, in-vault
  viewers (video, audio, PDF in an isolated process, Word, text editing),
  manual backup to a self-hosted server, landing page.
- v2.1.0: audio recorder in the vault, screen-off volume trigger, recording
  while locked.
- v3.0.0 (Undertow): everything checked above.
