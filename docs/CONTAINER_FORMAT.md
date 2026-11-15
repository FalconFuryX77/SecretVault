# Vault Container Format (v1)

This describes the on-device storage format as implemented in
[`lib/vault/vault_container.dart`](../lib/vault/vault_container.dart). It is a
composition of standard primitives. Nothing here is a new cipher, but the
composition itself has not been externally reviewed.

## 1. Goals

- Every byte on disk is ciphertext or random filler: no headers, magic numbers
  or version fields in the clear.
- Up to 4 independent vaults ("records") share one file. You can't tell how
  many are in use.
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

Record r (8192 bytes, at 0x40 + r·8192)
  +0      PIN slot         60 bytes   seal(KEK_pin, VK, aad=[0x01, r])
  +64     (reserved)      156 bytes   random filler (see §12)
  +256    Superblock A   2076 bytes   seal(K_super, S, aad=[0x03, r, 0])
  +2332   Superblock B   2076 bytes   seal(K_super, S, aad=[0x03, r, 1])
  rest    random
```

Unused records and slots are random bytes, written when the container is
created, and they can't be told apart from used ones.

## 4. Keys

```
salt          = header[0:32]
KEK_pin       = HKDF( HMAC_device( Argon2id("p:" ‖ PIN, salt, pin params) ),
                      salt, info="sv/pin-kek" )
VK            = 32 random bytes per vault (never stored in the clear)
K_super       = HKDF(VK, salt="sv/vault", info="superblock")
K_index       = HKDF(VK, salt="sv/vault", info="index")
K_file        = 32 random bytes per stored file, kept in the index
```

## 5. Unlocking

Derive `KEK_pin` once, then try to open the PIN slot of **all 4
records**. Every record is always tried, so timing doesn't reveal which one
matched. The first success yields `(r, VK)`.

Then read both superblocks of record `r` and keep the valid one with the
higher generation.

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

Index JSON (`v: 1`):

| Field | Meaning |
|---|---|
| `t` | `true` for a real vault (allocates top-down), `false` for a decoy (bottom-up) |
| `c` | Ceiling: chunks at or above this belong to a vault the decoy can't see |
| `g` | Grown-from: the first chunk of space a decoy added itself, while alone |
| `e` | Entries: item metadata, file key, chunk extents, byte length |
| `l` | Links: `{record, VK}` of vaults this one manages (real → decoy) |

## 7. File data

A file of `n` bytes uses `max(1, ⌈n / 65508⌉)` chunks. Chunk `i` holds
`seal(K_file, bytes[i·65508 : …], aad)`, padded with random filler to 64 KiB:

```
aad = 0x05 ‖ item id (UTF-8) ‖ 0x00 ‖ sequence (u32 BE) ‖ is_last (u8)
```

The item id, the position and the last-chunk flag are all authenticated, so
a reader detects any flipped bit, any chunk swapped in from another file,
reordering, or truncation, and refuses the file.

## 8. Allocation (how two vaults share the file without seeing each other)

- The real vault allocates from the **top** of the file downward. A decoy
  allocates from the **bottom** upward.
- The real vault stores the decoy's VK in its index (`l`), so whenever the
  real vault is open it knows every chunk the decoy uses and never touches them.
- A decoy opened on its own can't see the real vault. It only allocates below
  its **ceiling** `c`, or in space it grew itself (`g` and above).
- Before the real vault writes below the decoy's ceiling, it lowers the
  ceiling in the decoy's index **first**, so a crash can never leave the decoy
  free to overwrite real data. Each time the real vault opens, it re-syncs
  the ceiling and clears `g`.
- When space runs out, the file grows by 256 MiB of random filler.

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

- **No rollback detection.** Restoring an older copy of the whole file is not
  detected.
- **Superblock extent list** is capped by its 2 KiB plaintext (roughly 100+
  extents). A very fragmented index fails to commit with `index too fragmented`.
  Index chunks are allocated contiguously where possible.
- **One decoy, no nesting** (see the threat model).
- **PIN is not Unicode-normalised.**
- **Versioning:** the format version lives only inside encrypted structures
  (`v` in the index). A future v2 must be detectable by trial decryption.

## 12. History: the removed gesture slot

An earlier version stored a second slot at record offset +64 (156 bytes):
a blob sealed under a key derived from a motion gesture, which a
biometric-bound Android Keystore key (`k0`–`k3`) then unwrapped into VK.
Gesture and fingerprint unlock were removed; unlock is PIN-only.

The format did not change. New containers leave those bytes as random
filler. Containers created by the old version may still hold a sealed blob
there; it is never read, and the app deletes the `k0`–`k3` keystore keys on
startup, so the blob can no longer be opened by anyone.
