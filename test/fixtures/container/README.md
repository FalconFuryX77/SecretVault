# Container fixtures

`v1.bin` is a container written by the format 1 code (commit `d252602`, the
last before format 2). The migration test opens it with the current code and
checks every byte survives.

How it was made:

- Device binding: `FixedDeviceBinding()` (all zeros), `KdfParams.testing`,
  `growChunks: 8`, `initialChunks: 24`. The file is 1,572,864 bytes
  (24 chunks).
- The real vault, PIN `real-pin-v1`, holds four files made with
  `importBytes`, ids `r0` to `r3`, titles `<id>.bin`:

  | id | bytes   | byte k is      |
  |----|---------|----------------|
  | r0 | 70,000  | (k × 3) & 0xff |
  | r1 | 70,001  | (k × 4) & 0xff |
  | r2 | 70,002  | (k × 5) & 0xff |
  | r3 | 200,000 | (k × 11) & 0xff |

  and one setting, `rec.key` = `{"pub": "AAAA", "priv": "BBBB"}`.
- Its decoy, PIN `decoy-pin-v1`, holds `d0`: 100,000 bytes, byte k is
  (k × 7) & 0xff.

Nothing in it is real data or personal.
