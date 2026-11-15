# Sync server (M1)

Reference implementation of the server in [docs/SYNC_DESIGN.md](../docs/SYNC_DESIGN.md) §7.
It stores opaque, content-named encrypted pieces and an append-only log of
opaque records. It never sees keys, file names or contents.

## Run the tests (no Docker needed)

```bash
cd server
pip install -r requirements.txt
python -m pytest -q -s
```

They use SQLite and a local folder for piece storage. Coverage:

- **Auth:** single-use challenge nonces, device login signatures, recovery-key
  signatures bound to the operation, the account and the exact request body.
  Replays, cross-account nonces and wrong keys are refused.
- **Devices:** registration needs a recovery-key signature; revocation cuts
  access immediately (live tokens included); any of the 4 recovery keys works.
- **Pieces:** "which are missing?" plus idempotent `PUT` (re-sends never
  overwrite), `Content-Digest` check against corruption in transit, `Range`
  downloads, per-piece size limit and account quota, cross-account isolation,
  strict piece-id format, paged listing.
- **Append-only mode:** device tokens can't delete; the recovery key can.
- **Log:** per-device counters enforced (409 with the expected counter), global
  sequence for paging, independent chains per device.
- **Escrow:** readable with the recovery key before any device exists; slot
  writes need the recovery key and a fixed size.
- **Resumability under a flaky link** (`tests/test_resume.py`): requests are
  dropped before sending, mid-upload, or after the server stored the piece but
  before the reply.
- **Resume within a piece** (`/v1/uploads`): parts append at the server's
  offset; a wrong offset gets 409 with the right one; the assembled piece must
  match its digest or it's discarded (422); partial uploads are per-account.

### Measurements

**End to end** (`packages/sync_core/test/e2e_test.dart`: real server on
localhost, real Dart client, and `harness/flaky_proxy.py` cutting TCP
connections mid-stream):

| Scenario | Result |
|---|---|
| 3 MB through a link that cuts 30% of connections | done in 2.4 s, 1.14× bytes on the wire, 2 recoveries; restored intact on a second device from the recovery secret alone |
| Pockets of signal: up 2 s / down 3 s at 64 kB/s, 1 MB | 62 s (theoretical minimum ~41 s), 1.35× bytes, 75 recoveries. **Before resumable parts: never finished** |
| Uploading an identical 2 MB file again | 1.6 KB on the wire (deduplication) |
| 1 MB of repetitive text | 3.5 KB (compression) |
| 7-byte file | 873 B (fixed per-file cost: query + manifest + log record) |
| Server flips a bit in a stored piece / deletes a log record | refused on restore / chain break detected |

**Protocol only** (`tests/test_resume.py`, simulated drops, one seed):
re-sending after drops costs 1.21× bytes at a 30% drop rate and 1.07× at
15%, against 1.98× for restart-from-zero at 15%.

All on localhost, so bandwidth limits come from the proxy, not a real radio.
Numbers on real mobile links come next.

## Run it in Docker

**Single machine (tested):** the API and PostgreSQL, with the encrypted
pieces kept as ordinary files in a folder you choose.

```bash
cd server
docker compose -p vaultsync -f docker-compose.yml -f docker-compose.local.yml up -d --build db api
```

- API: `http://localhost:8080` (`/health`, `/docs`)
- Stored pieces: `D:/VaultSyncServer/pieces/<account>/` by default; set
  `SYNC_DATA_DIR` to put them elsewhere. Every file there is ciphertext.
- Stop it with `docker compose -p vaultsync down` (add `-v` to also drop the
  database volume).

**With an object store:** `docker-compose.yml` on its own also starts MinIO
and Toxiproxy. The MinIO image it names could not be pulled from Docker Hub
when this was tested, so that variant is currently untested; point
`SYNC_S3_ENDPOINT` at any S3-compatible store instead.

Before using this anywhere but your own machine: change every password in
`docker-compose.yml`, set `SYNC_INVITE_CODES` so only people you invite can
create accounts, and put a TLS reverse proxy (for example Caddy) in front of
the API. The app's release builds refuse plain `http://` servers.

To reach a server on your PC from a phone on the same Wi-Fi, the PC's
firewall has to allow incoming connections on port 8080. Without that, a
phone connected by USB can use `adb reverse tcp:8080 tcp:8080`.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `SYNC_DB_URL` | `sqlite:///./sync.db` | SQLAlchemy URL (`postgresql+psycopg://…` in Compose) |
| `SYNC_BLOB_DIR` | `./blobs` | Piece storage when no S3 endpoint is set |
| `SYNC_STAGING_DIR` | `./staging` | Partial uploads waiting to be completed |
| `SYNC_S3_ENDPOINT`, `SYNC_S3_BUCKET`, `SYNC_S3_ACCESS_KEY`, `SYNC_S3_SECRET_KEY` | unset | S3/MinIO piece storage |
| `SYNC_INVITE_CODES` | empty (open) | Comma-separated invite codes required to create an account |
| `SYNC_APPEND_ONLY_DEFAULT` | `true` | New accounts can't delete from devices |
| `SYNC_MAX_ACCOUNT_BYTES` | 20 GiB | Per-account quota |

## Signed message format

```
sv-sync-v1 | <operation> | <account id> | <server nonce> | <sha256 hex of request body>
```

Operations: `login:<device id>`, `add-device`, `revoke-device:<device id>`,
`get-escrow`, `put-escrow:<slot>`, `delete-pieces`. Recovery-key requests
send `X-Recovery-Auth: <key index>.<nonce>.<base64 signature>`.

## Not built yet

- Pairing codes and the X25519 key-exchange relay (M3).
- Cleanup of abandoned partial uploads in `SYNC_STAGING_DIR`.
- Rate limiting, metrics, and structured audit logs.
- TLS: the stack has no HTTPS proxy of its own.
- The MinIO / Toxiproxy Compose variant is untested (see above); failure
  injection is covered by `harness/flaky_proxy.py`.
