# Running a backup server on the internet

The app backs up to a server you (or your newsroom, or an organisation you
trust) run. Everything the server stores is ciphertext: it never receives a
key, a file name or anything readable. It still learns *when* a phone
uploads and roughly *how much*, so who runs it matters.

This guide puts the reference server (`server/`) on a small Linux machine
with HTTPS. Tested locally with the same files; you need a domain name and a
machine to do it for real.

## What you need

- A Linux machine reachable from the internet (a small VPS is enough:
  1 CPU, 1 GB RAM, disk for the backups), with Docker and the Compose plugin.
- A domain name (or subdomain), e.g. `backup.example.org`, with an `A`
  (and/or `AAAA`) record pointing at the machine.
- Ports 80 and 443 open. Port 80 is only used to obtain the certificate.

## Steps

```bash
git clone https://github.com/FalconFuryX77/Undertow.git
cd Undertow/server
cp deploy/env.example .env
```

Edit `.env`:

| Setting | What to put |
|---|---|
| `SYNC_DOMAIN` | your domain, e.g. `backup.example.org` |
| `SYNC_DB_PASSWORD`, `SYNC_S3_PASSWORD` | long random strings (`openssl rand -base64 32`) |
| `SYNC_INVITE_CODES` | one code per person or team, comma-separated |

Then:

```bash
docker compose -f docker-compose.yml -f docker-compose.public.yml up -d --build
```

Caddy obtains a Let's Encrypt certificate for `SYNC_DOMAIN` on its own and
renews it. Check it: `curl https://backup.example.org/health` should print
`{"ok":true}`.

In the app: Settings → Backup → server address `https://backup.example.org`
and the invite code you gave that person.

## What runs

| Service | Reachable from | Purpose |
|---|---|---|
| `caddy` | the internet, 80/443 | HTTPS; forwards to the API |
| `api` | inside Docker only | the sync API (FastAPI) |
| `db` | inside Docker only | PostgreSQL: accounts, devices, the encrypted change log |
| `s3` | inside Docker only | SeaweedFS (S3): the encrypted file pieces |

Nothing logs requests: the API runs without an access log and Caddy discards
its access and request-error logs, so client addresses and paths are not
written to disk. Caddy still logs its own messages (certificates, start-up).

## Keeping it safe

- **Accounts are append-only** by default: a phone can upload but not delete,
  so a seized phone can't erase what already got out. Pruning needs the
  owner's recovery code.
- **Back up the server's volumes** (`dbdata`, `s3data`) somewhere else. They
  are ciphertext; losing them loses the backups.
- **Updates:** `git pull && docker compose -f docker-compose.yml -f
  docker-compose.public.yml up -d --build`.
- The server can see when a phone connects and how much it sends. Running it
  over **Tor** hides the phones' addresses from it: the app can connect
  through Orbot (Backup → "Connect through Tor"), including to a `.onion`
  address if you also publish the server as an onion service.
- Invite codes are the only thing stopping strangers from creating accounts
  (and using your disk). Give each person their own, and remove codes that
  leak.

## Other ways to run it

- **On your own computer**, for testing or a single household:
  `docker compose -p vaultsync -f docker-compose.yml -f docker-compose.local.yml up -d --build db api`
  (pieces stored as plain files in `SYNC_DATA_DIR`). Phones reach it over USB
  with `adb reverse tcp:8080 tcp:8080`, or on the same Wi-Fi with
  `SYNC_API_BIND=0.0.0.0` and the firewall open on 8080. Debug builds of the
  app allow plain `http://`; release builds only to the phone itself.
- **Another S3 store** (AWS, Backblaze B2, Wasabi, Garage…): set
  `SYNC_S3_ENDPOINT`, `SYNC_S3_BUCKET`, `SYNC_S3_ACCESS_KEY`,
  `SYNC_S3_SECRET_KEY` on the `api` service and drop the `s3` service.
