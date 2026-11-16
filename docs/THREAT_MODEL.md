# Threat Model

Status legend: **Built** = in the code today · **Server** = built and tested
on the server or in the sync engine, with no app screen for it yet ·
**Planned** = designed in [SYNC_DESIGN.md](SYNC_DESIGN.md), not built yet.

Backup in the app is manual today (Settings → Backup). Automatic background
upload and in-app restore are Planned.

## 1. Who this is for

People who carry sensitive material on a phone in places where the phone may
be inspected or seized: journalists and fixers in conflict zones, human-rights
documenters, people crossing hostile checkpoints or borders. Their main risks
are being made to unlock the phone, the phone being taken, and losing the
material before it reaches someone safe.

The design priorities, in order:

1. Nothing harmful is visible to a casual inspection of the phone.
2. Being forced to unlock reveals only harmless content.
3. Material that has left the phone can't be read or erased by whoever takes it.
4. Material gets off the phone even over slow, intermittent connections.

## 2. What we protect

| Asset | Example |
|---|---|
| File contents | Photos, video, audio, documents, notes |
| File metadata | Names, types, sizes, dates, how many files there are |
| Existence of the real vault | That there is more than the decoy |
| Evidence that material was captured or sent | Timing and volume of uploads (Planned) |
| Sync identity | Which server and account the material goes to (Planned) |

## 3. Adversaries

### A1. Casual inspector
A soldier or official scrolls through the unlocked phone at a checkpoint,
possibly for a few minutes. No tools, no prior knowledge of this app.

| Defence | Status |
|---|---|
| App opens as a working cover app (a video trimmer that really trims, under a neutral package name) with no vault UI, buttons or wording | Built |
| Vault entry is a covert triple-tap on the cover app's header | Built |
| The motion sensor is read only while a vault is open; the cover app never reacts to movement | Built |
| Vault screens set `FLAG_SECURE` (no screenshots, blank in the recents list) | Built |
| Vault locks when the app is backgrounded, on inactivity, and on a hard shake | Built |

**Residual risk:** someone who watches you open the vault, or who knows this
app, isn't fooled by the cover. That's what the decoy (A2) is for.

### A2. Coercer
Forces you to "open the vault" or hand over the PIN, under threat.

| Defence | Status |
|---|---|
| Decoy vault opened by its own PIN, typed into the same field as the real one | Built |
| No fingerprint unlock: a finger can be pressed to the sensor by force, and a fingerprint can't choose between the real vault and the decoy | Built |
| Nothing in the decoy's UI, settings or storage shows that another vault exists | Built |
| Container has 4 key records whether 1 or 2 are in use; unused ones are random bytes | Built |
| Decoy can never be made to reveal the real vault's key: only the real vault knows about the decoy, not the other way round | Built |
| A decoy can host a real decoy of its own, up to four vaults in a chain; every vault follows the same rules, so none can tell whether it is someone's decoy | Built |
| Optional duress PIN: opens the decoy and destroys the vault that set it (its record and index, so every file key). Opt-in behind a warning | Built |
| Each vault has its own recording key and sees only its own recordings and recorder state; opening the decoy never reveals the real vault's recordings | Built |
| Settings look the same in every vault: the same decoy section, the same duress option. Only the fourth vault in a chain (no record left to give) shows a stand-in decoy whose PIN opens nothing: someone who tests it can tell | Built |
| Refused PIN changes say nothing about why and count as failed unlock attempts; failures expire after 24 h instead of being reset by any successful unlock (so the decoy PIN can't be used to reset guesses at the real one) | Built |

**Residual risk:** the coercer may not believe there is only one vault. The
cryptography can't prove that a second vault *doesn't* exist, but it also
can't prove that it does. Whether to rely on that is the user's call. If the
coercer demands the real PIN and gets it, everything in the real vault is
exposed. Nothing on the device can prevent that, which is why sync with
optional "delete after upload" matters (A5).

### A3. Forensic examiner with the device
Full file-system extraction (e.g. a commercial phone-forensics tool), possibly
after forcing an unlock of the phone itself, with time and tools.

| Defence | Status |
|---|---|
| All vault data in one file of AES-256-GCM ciphertext and random filler; no headers, magic bytes or plaintext fields | Built |
| File size reveals neither how much is stored nor how many vaults exist (pre-allocated, grows in 256 MiB random-filled steps) | Built |
| The PIN is never stored; it derives keys via Argon2id and then an HMAC under a non-exportable hardware key (Android Keystore / StrongBox) | Built |
| Offline brute force is impossible: every guess must run on this phone's secure hardware | Built |
| Deleted files' ciphertext and old index copies are overwritten with random data; their keys are dropped | Built |
| App data excluded from Android cloud backup and device-to-device transfer | Built |
| Viewing a file never writes a decrypted copy to storage: media is streamed from memory, documents are opened in memory (checked on a phone: no new files after every viewer ran) | Built |
| Recordings made while the vault is locked are encrypted to the vault's public key (ECDH P-256 + AES-256-GCM, a fresh key per recording). The phone can write them but can't read them back; the private key exists only inside the encrypted vault index | Built |
| The keyboard is asked not to learn anything typed in the vault (`IME_FLAG_NO_PERSONALIZED_LEARNING`), so notes don't end up in its suggestions. Gboard and most keyboards honour this; a keyboard app is free to ignore it | Built |

**What the examiner still learns:**
- The app is installed, and it holds a large high-entropy file. We don't hide
  that encrypted data exists, only how much and how many vaults.
- With the decoy PIN *and* a copy of the file system, an examiner can read
  the decoy's own index. Since format 2 it no longer says "decoy", but its
  numbers still hint at one: a ceiling below the end of the file with
  nothing grown above it, and fewer than three spare records (see
  [CONTAINER_FORMAT.md](CONTAINER_FORMAT.md) §11). A casual inspector, or a
  coercer without forensic tools, doesn't get this.
- An examiner who imaged the phone *before* a duress PIN was used can see,
  comparing images, that one record and some chunks were overwritten.
- If uploading while locked is on and something is waiting, the queue: its
  size, the server address and an upload-only token (the phone can open the
  sealed state, so root can too). The emergency stop removes it.
- Recordings waiting to move into a vault sit encrypted in the app's private
  storage until the next unlock, so their number and sizes show that
  something was recorded (not what, or for which vault).
- While the hidden recorder is armed, Android lists the app as running, and
  the system privacy log records microphone use.
- The keystore holds one key (`db0`) regardless of setup. (Keys from the old
  fingerprint unlock, `k0`–`k3`, are deleted on start.)
- If the phone is seized **while the vault is unlocked**, keys are in RAM.
  Dart can't guarantee every copy is wiped. Locking (or the panic shake) closes
  the session and wipes the copies we control.
- On flash storage, overwriting is best effort at the physical level. The
  security of deleted data rests on its keys being gone, not on the overwrite.
- A weak PIN can still be guessed *on the device*. Argon2id makes each guess
  cost one to a few seconds, so all 1 million 6-digit PINs can be tried within
  a few weeks. The app's lockout only slows the app's own UI, not someone
  running the derivation directly on a rooted phone. A passphrase is strongly
  recommended.
- A hardware-keystore vulnerability on a given phone model would weaken the
  device binding back to "Argon2id only".

### A4. Thief / lost phone
A weaker A3 with no particular interest in you. Covered by the A3 defences.

### A5. Sync server operator, or someone who seizes the server
Runs or seizes the server that stores synced material.

| Defence | Status |
|---|---|
| Client-side encryption; the server never sees keys, file names or contents | Built |
| Content pieces named by a keyed hash, so the server can't test whether you hold a known file | Built |
| Content-defined piece boundaries are keyed, so piece sizes don't fingerprint known files | Built |
| Piece sizes padded to buckets (Padmé) | Built |
| Change log records chained per device, so reordering or dropping records in the middle is detected (checked on restore) | Built |
| "Append-only" server mode (the default): phones can upload but not delete; only the recovery key can delete | Built |

**What the server learns:** the account, the registered devices, IP addresses
and timing of every request, the number and padded sizes of stored pieces,
total storage used, and which pieces were uploaded together (timing
correlation). It can refuse service, delete data (unless append-only mode is on
and the operator is honest), or withhold the newest records. Withholding is
detected only against a newer state the client has already seen.

### A6. Network observer
ISP, state-level monitoring, or a hostile Wi-Fi network.

| Defence | Status |
|---|---|
| Release builds accept only `https://` servers (the server needs a TLS proxy in front; the reference stack doesn't include one). The one exception is plain `http://` to the phone's own `127.0.0.1`, which only reaches a server through a USB tunnel and never crosses a network | Built |
| Padded piece sizes | Built |
| Routing over Tor | Not planned yet |

**What the observer learns:** the phone talks to the sync server's address, when,
and roughly how much. The cover app should have a plausible reason to talk to a
server (e.g. a video app's cloud project backup).

### A7. Seized phone used against the sync account
The adversary has the phone and the real vault's PIN, so they hold the sync key
and the device's credentials.

| Defence | Status |
|---|---|
| Devices never hold the recovery secret (shown once when backup is set up); only it can revoke devices or let a revoked one back in | Built |
| Revocation lists every registered device, so any device the seized phone paired before revocation can be cut off too | Server |
| Revoking the seized device from another device stops all further server access | Server |
| Rotating the sync key protects everything uploaded afterwards | Planned |
| Append-only mode stops the seized device from deleting server copies | Built |

**Residual risk:** anything the seized device could already read stays exposed.
Revocation stops *future* access; it can't take back what was already
downloaded or what was on the phone.

### A8. Booby-trapped file
Someone sends you a document or recording crafted to exploit the software
that opens it, hoping to reach the vault's keys.

| Defence | Status |
|---|---|
| Vault files are only ever opened inside the app, never handed to another app | Built |
| PDFs are parsed and drawn in an **isolated process**: its own throwaway uid, no permissions, no network, no access to the app's files, the vault or its keys. It receives the document as an in-memory file, returns pixels through shared memory, and is killed when the viewer closes | Built (verified on a phone: the renderer runs as `u0_i…`, the app as `u0_a…`) |
| Word documents and text are parsed by memory-safe Dart code, with size limits against zip bombs and no DTD processing | Built |
| Audio and video are unpacked by ExoPlayer's Java extractors (memory-safe) and decoded by Android's media codecs, which run in their own sandboxed system process | Built (platform) |
| A file that fails its integrity check is refused, not opened | Built |
| Images are decoded inside the app process by Flutter's native codecs | **Not sandboxed yet** |

**What the attacker still gets:** a PDF renderer exploit can read the one
document it was given. Reaching the vault would take a second bug that
escapes Android's process sandbox. While media plays, a socket listens on a
random 127.0.0.1 port; other apps on the phone could notice it, but without
the 256-bit path in the URL they can't read from it.

## 4. Out of scope

- **Spyware or a compromised OS** (e.g. state-grade implants). If the phone
  itself is compromised, it can read the screen, the keyboard and memory.
  Nothing an app does survives that.
- **Hardware attacks on the secure element** beyond what the vendor defends against.
- **Being watched while unlocking** the real vault (camera, shoulder-surfing
  the PIN). The PIN field hides what is typed, but the keyboard can be
  observed. A long passphrase is harder to shoulder-surf than 6 digits.
- **Proving the decoy is the only vault.** Deniability means "can't be proven",
  not "will be believed".
- **iOS.** It currently runs PIN-only, with a software device-binding secret.

## 5. Assumptions

- The phone has a secure lock screen, so the hardware keystore is protected at rest.
- The hardware keystore behaves as documented by the vendor.
- The real and decoy PINs are different from each other and from the phone's
  own unlock PIN. (The app rejects a decoy PIN equal to the real one.)
- The user fills the decoy with believable content. An empty decoy is a tell.

## 6. Known gaps and open decisions

| Gap | Notes |
|---|---|
| Decoy layout tells | With the decoy's PIN and a copy of the file, its index shows a ceiling below the file's end and fewer than three spare records. Hiding them would mean dropping the rules that stop vaults overwriting each other. See [CONTAINER_FORMAT.md](CONTAINER_FORMAT.md) §11. |
| Stand-in decoy | Only for the fourth vault in a chain: its decoy PIN and duress PIN open nothing, which a coercer can test. |
| Duress PIN | Destroys the vault that set it, at once and for good. Someone who saw the vault before, or imaged the phone, may notice it's gone. A vault above the destroyed one shows its decoy as damaged. |
| Hidden recorder visible to other apps | While armed with the screen off, the recorder holds an active media session. Apps with notification access (smartwatch companions, automation apps) can see it, and could start a recording with volume commands. |
| Rollback guard | A rolled-back container is detected from a small state file kept beside it (sealed under the hardware binding). Rolling back the container *and* that file together isn't detected. |
| Clipboard | Copied text is marked sensitive and cleared after a minute or on lock, but a keyboard's own clipboard history may keep it. The recovery code can't be copied. |
| Backup accounts per vault | SYNC_DESIGN §11 calls for one sync account per phone shared by its vaults. Today each vault that backs up creates its own, so if two vaults back up, the server sees two accounts (from the same address, unless over Tor). Sharing one safely needs per-vault scoping on the server, not built yet. |
| Pruning with several phones | Freeing up server space deletes pieces that only old versions used. If another phone backs up the same content at that very moment and finds those pieces still there, its new version can lose them; a restore then refuses that file (every file is checked end to end) rather than return it wrong. |
| Moving a vault | Anyone holding the moved copy *and* its transfer code can open the vaults in it without a PIN until the new phone finishes the move. The code is shown once and never stored. |
| Tor | Backups over Tor go through Orbot's local proxy; if Orbot isn't running the app refuses rather than falling back. Trust in Orbot is assumed. |
| Container format needs external review | It is a composition of standard primitives (see [CONTAINER_FORMAT.md](CONTAINER_FORMAT.md)) and hasn't been reviewed by a third party. |
| Uploading while locked | On by default. With root, an examiner can see the queue, its size, the server address and an upload-only token (which can add to the account, never read or delete). "Clear cache" in the cover app, or the stop code on the lock screen, wipes all of it; use one before handing the phone over. Only one vault on a phone can use the queue. See [SYNC_DESIGN.md §9.1](SYNC_DESIGN.md#91-as-built-v31). |

Closed since the review of 2026-11-16: duress PIN, rollback detection, PIN
normalisation, recording-key rotation (daily, with structureless staging
files), clipboard handling, padded backup log records, chain-head checks,
restore "as of" a time and ignoring a revoked phone, manifests for very large
files, sandboxed image decoding, and nested decoys.
