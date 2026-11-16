# Vault Container Format

This describes the on-device storage format as implemented in
[`lib/vault/vault_container.dart`](../lib/vault/vault_container.dart) and
[`lib/vault/vault_index.dart`](../lib/vault/vault_index.dart). It is a
composition of standard primitives. Nothing here is a new cipher, but the
composition itself has not been externally reviewed.

The file layout has not changed since v1. The **index format** is now 2
(since v3.0): it no longer records which vault is "real", and any vault can
host a decoy. Format 1 indexes are migrated the first time they're opened
(§6.1).

## 1. Goals

- Every byte on disk is ciphertext or random filler: no headers, magic numbers
  or version fields in the clear.
- Up to 4 independent vaults ("records") share one file. You can't tell how
  many are in use.
- No vault can tell, from its own data, whether it is someone's decoy: every
  vault follows the same rules (§8).
- The file size doesn't track how much is stored.
- Keys come from the user's secrets plus device hardware. No key is stored in
  the clear anywhere.
- Large files stream through without being loaded into memory.
- A crash at any point leaves the previous consistent state readable.

## 2. Primitives

| Purpose | Primitive | Parameters |
|---|---|---|
| Authenticated encryption | AES-256-GCM | 96-bit random nonce, 128-bit tag |
| Password stretching | Argon2id | 64 MiB, 3 passes, p=1 · 32-byte output |
| Device binding | HMAC-SHA256 under a non-exportable Android Keystore key (`db0`, StrongBox if available) | |
| Key derivation | HKDF-SHA256 | 32-byte output |
| Random filler | AES-256-GCM keystream under a throwaway random key | |
| PIN normalisation | Unicode NFC (Android's `java.text.Normalizer`) | |

`seal(key, plaintext, aad)` produces `nonce(12) ‖ ciphertext ‖ tag(16)`, a
28-byte overhead.

## 3. Layout

The file is a sequence of **64 KiB chunks**. Chunk 0 is the header; every
other chunk is either a data/index chunk or random filler.

```
Chunk 0 (header, 65536 bytes)
  0x0000  salt            32 bytes   random, fixed for the container's life
  0x0020  (random)        32 bytes
  0x0040  record 0      8192 bytes
  0x2040  record 1      8192 bytes
  0x4040  record 2      8192 bytes
  0x6040  record 3      8192 bytes
  0x8040  (random)      to end of chunk
  0x9000  transfer slot 2076 bytes   only in a copy made to move the vault (§8.4)

Record r (8192 bytes, at 0x40 + r·8192)
  +0      PIN slot         60 bytes   seal(KEK_pin, VK, aad=[0x01, r])
  +64     Duress slot      60 bytes   seal(KEK_duress, VK, aad=[0x02, r])   (§8.3)
  +124    (reserved)      132 bytes   random filler (see §12)
  +256    Superblock A   2076 bytes   seal(K_super, S, aad=[0x03, r, 0])
  +2332   Superblock B   2076 bytes   seal(K_super, S, aad=[0x03, r, 1])
  rest    random
```

Unused records and slots are random bytes, written when the container is
created, and they can't be told apart from used ones.

## 4. Keys

```
salt          = header[0:32]
KEK_pin       = HKDF( HMAC_device( Argon2id("p:" ‖ NFC(PIN), salt, pin params) ),
                      salt, info="sv/pin-kek" )
KEK_duress    = the same, from the duress PIN
VK            = 32 random bytes per vault (never stored in the clear)
K_super       = HKDF(VK, salt="sv/vault", info="superblock")
K_index       = HKDF(VK, salt="sv/vault", info="index")
K_file        = 32 random bytes per stored file, kept in the index
```

PINs set before v2.2 were not normalised. Unlocking tries the normalised
form first and, if the PIN changes under NFC and nothing opened, the PIN as
typed; a match is re-stored under the normalised form.

## 5. Unlocking

Derive `KEK_pin` once, then try to open the PIN slot of **all 4 records**.
Every record is always tried, so timing doesn't reveal which one matched.
The first success yields `(r, VK)`; then read both superblocks of record `r`
and keep the valid one with the higher generation.

If no PIN slot opens, the same key is tried against the **duress slots** of
all 4 records (§8.3). A wrong PIN costs the same either way: one Argon2id
and eight AES-GCM attempts.

## 6. Superblock and index

Superblock plaintext `S` (2048 bytes):
`len(2) ‖ JSON {"g": generation, "l": index byte length, "e": [[start, count], …]} ‖ zero pad`

The **index** is the vault's encrypted catalogue. It is JSON, stored across the
chunks listed in `e`, each sealed under `K_index` with:

```
aad = 0x04 ‖ generation (u64 BE) ‖ sequence (u32 BE) ‖ is_last (u8)
```

Binding the generation into the AAD means index chunks from an older commit
can't be spliced into a newer one.

Index JSON, format 2 (`"v": 2`). Every vault has exactly these fields:

| Field | Meaning |
|---|---|
| `c` | Ceiling: the vault writes only below this chunk… |
| `g` | …or at and above this one (space it grew itself; absent if none) |
| `s` | Spare records: records this vault may give to a decoy (§8.2) |
| `e` | Entries: item metadata, file key, chunk extents, byte length |
| `l` | Links: `{record, VK}` of the decoy this vault hosts (at most one) |
| `x` | Settings (backup configuration, recording key, …), optional |

### 6.1 Format 1

Format 1 (`"v": 1`, or no `v`) also had `t`: `true` for the real vault,
`false` for its decoy. That flag was the problem: with the decoy's PIN, a
forensic examiner could decrypt its index and read `t: false`, proof that a
real vault existed.

When a format 1 index is opened it is rewritten as format 2: the vault that
had `t: true` was set up alone and used the whole file, so it gets
`c` = the file's size in chunks, no `g`, and every other record as a spare;
a format 1 decoy keeps its ceiling and gets no spares (it can show only the
stand-in decoy, §8.2). The migration is a normal commit (§9).

## 7. File data

A file of `n` bytes uses `max(1, ⌈n / 65508⌉)` chunks. Chunk `i` holds
`seal(K_file, bytes[i·65508 : …], aad)`, padded with random filler to 64 KiB:

```
aad = 0x05 ‖ item id (UTF-8) ‖ 0x00 ‖ sequence (u32 BE) ‖ is_last (u8)
```

The item id, the position and the last-chunk flag are all authenticated, so
a reader detects any flipped bit, any chunk swapped in from another file,
reordering, or truncation, and refuses the file.

## 8. Allocation (how vaults share the file without seeing each other)

Vaults form a **chain**: a vault set up alone, its decoy, the decoy's own
decoy, and so on (at most 4, one per record). Each vault knows the vaults
*below* it (it holds their keys in `l`) and nothing about the ones above.
Every vault follows the same rules, so none can tell where it sits.

- **Its space.** A vault writes only to chunks below its ceiling `c`, or at
  and above `g` (space it added by growing the file). A vault set up alone
  starts with `c` = the file's size, so its space is the whole file.
- **Direction.** A vault hosting a decoy allocates from the top of its space
  downward; any other vault from the bottom upward.
- **Protecting what's below.** A vault that's open knows every chunk of every
  vault below it and never touches them. Before it writes into the space of
  a vault below (under that vault's `c`, or above its `g`), it lowers that
  vault's ceiling (and clears its `g`) in that vault's index **first**, so a
  crash can never leave the lower vault free to overwrite the new data.
- **Keeping ceilings in step.** Each time a vault opens, and after each
  commit, it walks the chain below: each vault's ceiling becomes the lowest
  chunk used by any vault above it, kept inside the space of the vault
  directly above, and its `g` is cleared (the vault above knows those chunks
  now).
- **Taking back grown space.** When a vault below grew the file on its own,
  the space from its `g` to the end holds only its chunks and free ones (any
  vault above that wrote there would have cleared that `g` first). The vault
  that opens takes it into its own space by lowering its own `g`.
- **Growth.** When space runs out, the file grows by 256 MiB of random
  filler, and the vault that grew it sets `g` (if unset) to where it began.

### 8.1 Hosting a decoy

Setting up a decoy first moves the host's files to the **top** of its space
(a vault without a decoy filled from the bottom). Each moved chunk is copied
to a free chunk; the old copies stay reserved until the host's index, now
pointing at the new copies, is committed, and are then overwritten. A crash
at any point leaves the host's committed index pointing at intact data.

The decoy gets the ceiling of the host's lowest chunk, a record, and the
host's remaining spare records as its own spares.

### 8.2 Records and nesting

`s` lists the records a vault may give away. A vault set up alone has the
other three; the decoy it hosts gets one of them and the remaining two as
its spares, and so on. A vault with no spare left (the fourth in a chain, or
a decoy migrated from format 1) can't host a real decoy; its Settings offer
the **stand-in** decoy, which accepts a PIN and shows the decoy controls but
opens nothing.

Removing a decoy removes everything below it: the PIN and duress slots of
every record the vault gave away are overwritten first, then the link is
committed away, then those records and every chunk the removed vaults used
are overwritten. A decoy that can't be read (damaged index or superblocks)
is removed the same way: its own decoys can't be seen, but their records
are among the ones given away.

### 8.3 Duress PIN

A vault that hosts a decoy may set a duress PIN: its duress slot holds the
vault's own key sealed under `KEK_duress`. When the duress PIN is entered:

1. The vault's record is overwritten whole (PIN slot, duress slot,
   superblocks), then its index chunks (which hold every file key). Nothing
   in it can be opened again, with any PIN or code.
2. Its decoy opens in its place and takes over its space: its ceiling
   becomes the destroyed vault's ceiling (the whole file, for a vault set up
   alone), and the destroyed vault's record becomes one of its spares.

The destroyed vault's file chunks stay as unreadable ciphertext until the
decoy writes over them. A vault above the destroyed one (if it was itself a
decoy) sees its decoy as damaged and keeps to the chunks it owns.

The duress PIN must differ from every PIN and duress PIN in the container
(checked the same way as PINs). It goes with the decoy: removing the decoy
clears it. Moving the vault to another phone clears it too, because the
duress slot is bound to the old phone's hardware like the PIN slots.

### 8.4 Transfer slot

Moving a vault to another phone or app copies the whole file. The copy (and
only the copy) carries a **transfer slot** at 0x9000 in chunk 0, inside its
random tail: `seal(K_transfer, JSON {v, vaults: [{r, k}, …]}, aad="sv/transfer")`
with `K_transfer = HKDF(code, salt, info="sv/transfer")` from a 16-byte
transfer code shown once. It lists the moved vault and every vault below it.
The new install opens the slot with the code, writes new PIN slots under its
own hardware binding, and overwrites the slot.

## 9. Commits (crash safety)

Every change to a vault's index is copy-on-write:

1. Write the new index into freshly allocated chunks, then flush.
2. Write the superblock (generation + 1) into the *other* slot (A↔B), then flush.
3. Overwrite the old index chunks with random filler.

A crash before step 2 leaves the old superblock and index intact; the new
chunks are just unreferenced ciphertext. A crash during step 2 leaves one
valid superblock.

## 10. Deletion

1. Remove the entry from the index and commit.
2. Overwrite its chunks with random filler and drop `K_file` from memory.

Old index copies are also overwritten (§9 step 3), so no stale index still
holds the deleted file's key. On flash storage the overwrite is best effort;
the guarantee rests on the key being gone.

## 11. Limits and open items

- **Rollback** of the whole file to an older copy is detected by a separate
  state file (`thumbnails.idx`), not by the container itself: see the threat
  model.
- **Superblock extent list** is capped by its 2 KiB plaintext (roughly 100+
  extents). A very fragmented index fails to commit with `index too fragmented`.
  Index chunks are allocated contiguously where possible.
- **Layout tells with a decoy's PIN.** The index no longer names a role, but
  its numbers still say something to an examiner who has the decoy's PIN and
  decrypts its index: a ceiling below the file's end with nothing grown
  (space above that belongs to someone else), and fewer than three spare
  records (a vault set up alone has three; each level of decoy has one
  fewer). Hiding these would mean giving up the safety rules that keep
  vaults from overwriting each other; we chose safety.
- **Versioning:** the format version lives only inside encrypted structures
  (`v` in the index). A future format must be detectable by trial decryption.

## 12. History: the removed gesture slot

An earlier version stored a second slot at record offset +64 (156 bytes):
a blob sealed under a key derived from a motion gesture, which a
biometric-bound Android Keystore key (`k0`–`k3`) then unwrapped into VK.
Gesture and fingerprint unlock were removed; unlock is PIN-only.

Bytes +64 to +123 now hold the duress slot. A blob left there by the gesture
version can't open as a duress slot (different key and associated data), so
it reads as an unused slot, and the app deletes the `k0`–`k3` keystore keys
on startup, so the blob can no longer be opened by anyone.
