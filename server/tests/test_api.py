from __future__ import annotations

import base64
import hashlib
import json
import os

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app
from app.security import signed_message

from conftest import Account, b64, piece_id


def digest_header(data: bytes) -> dict:
    return {"Content-Digest": f"sha-256=:{base64.b64encode(hashlib.sha256(data).digest()).decode()}:"}


# ─── accounts & auth ─────────────────────────────────────────────────────


def test_account_requires_exactly_four_valid_recovery_keys(client):
    bad = {"recovery_keys": [b64(os.urandom(32))] * 3, "escrow": [b64(os.urandom(128))] * 4}
    assert client.post("/v1/accounts", json=bad).status_code == 400
    bad["recovery_keys"] = [b64(b"short")] * 4
    assert client.post("/v1/accounts", json=bad).status_code == 400


def test_invite_code_enforced_when_configured(tmp_path):
    s = Settings(db_url=f"sqlite:///{tmp_path / 'db'}", blob_dir=str(tmp_path / "b"), invite_codes=["newsroom-42"])
    c = TestClient(create_app(s))
    try:
        Account(c)
        raise AssertionError("account created without invite")
    except AssertionError as e:
        assert "403" in str(e) or "invite" in str(e)
    Account(c, invite="newsroom-42")


def test_device_registration_needs_recovery_signature(account):
    raw = json.dumps({"public_key": b64(os.urandom(32))}).encode()
    r = account.client.post(f"/v1/accounts/{account.id}/devices", content=raw)
    assert r.status_code == 401
    # Signature over a different body is rejected (body is bound into the signature).
    hdr = account.recovery_header("add-device", b'{"public_key":"something-else"}')
    r = account.client.post(f"/v1/accounts/{account.id}/devices", content=raw, headers=hdr)
    assert r.status_code == 401


def test_challenge_nonces_are_single_use(account):
    dev = account.add_device()
    n = account.nonce()
    sig = account.devices[dev].sign(signed_message(f"login:{dev}", account.id, n, b""))
    body = {"account_id": account.id, "device_id": dev, "nonce": n, "signature": b64(sig)}
    assert account.client.post("/v1/auth/token", json=body).status_code == 200
    assert account.client.post("/v1/auth/token", json=body).status_code == 401  # replay


def test_login_rejects_wrong_key_and_other_accounts_nonce(client, account):
    dev = account.add_device()
    other = Account(client)
    n = other.nonce()  # nonce issued for another account
    sig = account.devices[dev].sign(signed_message(f"login:{dev}", account.id, n, b""))
    r = client.post("/v1/auth/token", json={"account_id": account.id, "device_id": dev, "nonce": n, "signature": b64(sig)})
    assert r.status_code == 401
    n = account.nonce()
    sig = Ed25519PrivateKey.generate().sign(signed_message(f"login:{dev}", account.id, n, b""))
    r = client.post("/v1/auth/token", json={"account_id": account.id, "device_id": dev, "nonce": n, "signature": b64(sig)})
    assert r.status_code == 401


def test_revoked_device_loses_access_immediately(phone):
    account, dev, auth = phone
    assert account.client.get("/v1/log", headers=auth).status_code == 200
    r = account.client.delete(
        f"/v1/accounts/{account.id}/devices/{dev}", headers=account.recovery_header(f"revoke-device:{dev}")
    )
    assert r.status_code == 204
    assert account.client.get("/v1/log", headers=auth).status_code == 401
    n = account.nonce()
    sig = account.devices[dev].sign(signed_message(f"login:{dev}", account.id, n, b""))
    r = account.client.post(
        "/v1/auth/token", json={"account_id": account.id, "device_id": dev, "nonce": n, "signature": b64(sig)}
    )
    assert r.status_code == 401


def test_any_of_the_four_recovery_keys_works(account):
    dev = account.add_device()
    hdr = account.recovery_header(f"revoke-device:{dev}", key_index=3)
    assert account.client.delete(f"/v1/accounts/{account.id}/devices/{dev}", headers=hdr).status_code == 204


# ─── pieces ──────────────────────────────────────────────────────────────


def test_upload_is_idempotent_and_resumable_by_asking_whats_missing(phone):
    account, _, auth = phone
    pieces = {piece_id(bytes([i]) * 10): os.urandom(4096) for i in range(5)}
    ids = list(pieces)
    r = account.client.post("/v1/pieces/missing", json={"ids": ids}, headers=auth)
    assert r.json()["missing"] == ids
    # Upload two, "lose the connection", ask again: only the rest are missing.
    for pid in ids[:2]:
        r = account.client.put(f"/v1/pieces/{pid}", content=pieces[pid], headers={**auth, **digest_header(pieces[pid])})
        assert r.status_code == 201
        assert r.json()["sha256"] == hashlib.sha256(pieces[pid]).hexdigest()
    r = account.client.post("/v1/pieces/missing", json={"ids": ids}, headers=auth)
    assert r.json()["missing"] == ids[2:]
    # Re-sending an already stored piece is harmless and never overwrites it.
    r = account.client.put(f"/v1/pieces/{ids[0]}", content=b"different ciphertext", headers=auth)
    assert r.status_code == 200
    assert r.json()["created"] is False
    assert account.client.get(f"/v1/pieces/{ids[0]}", headers=auth).content == pieces[ids[0]]


def test_corruption_in_transit_is_rejected(phone):
    account, _, auth = phone
    data = os.urandom(1000)
    bad = bytearray(data)
    bad[10] ^= 1
    r = account.client.put(f"/v1/pieces/{piece_id(data)}", content=bytes(bad), headers={**auth, **digest_header(data)})
    assert r.status_code == 400
    assert account.client.post("/v1/pieces/missing", json={"ids": [piece_id(data)]}, headers=auth).json()["missing"]


def test_range_download_for_resuming(phone):
    account, _, auth = phone
    data = os.urandom(10_000)
    pid = piece_id(data)
    account.client.put(f"/v1/pieces/{pid}", content=data, headers=auth)
    r = account.client.get(f"/v1/pieces/{pid}", headers={**auth, "Range": "bytes=4000-"})
    assert r.status_code == 206
    assert r.headers["Content-Range"] == "bytes 4000-9999/10000"
    assert r.content == data[4000:]
    r = account.client.get(f"/v1/pieces/{pid}", headers={**auth, "Range": "bytes=-100"})
    assert r.content == data[-100:]
    r = account.client.get(f"/v1/pieces/{pid}", headers={**auth, "Range": "bytes=20000-"})
    assert r.status_code == 416


def test_accounts_are_isolated(client, phone):
    account, _, auth = phone
    data = os.urandom(100)
    pid = piece_id(data)
    account.client.put(f"/v1/pieces/{pid}", content=data, headers=auth)
    other = Account(client)
    odev = other.add_device()
    oauth = other.login(odev)
    assert client.get(f"/v1/pieces/{pid}", headers=oauth).status_code == 404
    assert client.post("/v1/pieces/missing", json={"ids": [pid]}, headers=oauth).json()["missing"] == [pid]
    assert client.get(f"/v1/accounts/{account.id}/devices", headers=oauth).status_code == 404


def test_size_limits_and_quota(phone, settings):
    account, _, auth = phone
    too_big = os.urandom(settings.max_piece_bytes + 1)
    assert account.client.put(f"/v1/pieces/{piece_id(too_big)}", content=too_big, headers=auth).status_code == 413
    chunk = 2 * 1024 * 1024
    stored = 0
    status = 201
    for i in range(10):
        data = os.urandom(chunk)
        status = account.client.put(f"/v1/pieces/{piece_id(data)}", content=data, headers=auth).status_code
        if status != 201:
            break
        stored += chunk
    assert status == 413
    assert stored <= settings.max_account_bytes


def test_bad_piece_ids_rejected(phone):
    account, _, auth = phone
    assert account.client.put("/v1/pieces/../../etc", content=b"x", headers=auth).status_code in (400, 404)
    assert account.client.put("/v1/pieces/ABC", content=b"x", headers=auth).status_code == 400


def test_listing_pages_through_everything(phone):
    account, _, auth = phone
    ids = set()
    for _ in range(7):
        data = os.urandom(50)
        pid = piece_id(data)
        ids.add(pid)
        account.client.put(f"/v1/pieces/{pid}", content=data, headers=auth)
    seen, after = set(), ""
    while True:
        page = account.client.get(f"/v1/pieces?after={after}&limit=3", headers=auth).json()
        seen |= {p["id"] for p in page["pieces"]}
        if not page["next"]:
            break
        after = page["next"]
    assert seen == ids


# ─── append-only retention ───────────────────────────────────────────────


def test_append_only_blocks_device_deletes_but_allows_recovery_key(phone):
    account, _, auth = phone
    data = os.urandom(100)
    pid = piece_id(data)
    account.client.put(f"/v1/pieces/{pid}", content=data, headers=auth)
    raw = json.dumps({"ids": [pid]}).encode()
    r = account.client.post("/v1/pieces/delete", content=raw, headers={**auth, "Content-Type": "application/json"})
    assert r.status_code == 401, "a seized phone must not be able to erase server copies"
    hdr = account.recovery_header("delete-pieces", raw)
    r = account.client.post("/v1/pieces/delete", content=raw, headers={**auth, **hdr, "Content-Type": "application/json"})
    assert r.json() == {"deleted": 1}
    assert account.client.get(f"/v1/pieces/{pid}", headers=auth).status_code == 404


def test_without_append_only_devices_can_prune(client):
    acct = Account(client, append_only=False)
    dev = acct.add_device()
    auth = acct.login(dev)
    data = os.urandom(100)
    pid = piece_id(data)
    client.put(f"/v1/pieces/{pid}", content=data, headers=auth)
    r = client.post("/v1/pieces/delete", json={"ids": [pid]}, headers=auth)
    assert r.json() == {"deleted": 1}


# ─── change log ──────────────────────────────────────────────────────────


def test_log_enforces_per_device_counter_order(phone):
    account, dev, auth = phone
    c = account.client
    assert c.post("/v1/log", json={"counter": 1, "record": b64(b"r1")}, headers=auth).status_code == 201
    r = c.post("/v1/log", json={"counter": 3, "record": b64(b"r3")}, headers=auth)
    assert r.status_code == 409
    assert r.json()["detail"]["expected"] == 2
    assert c.post("/v1/log", json={"counter": 1, "record": b64(b"dup")}, headers=auth).status_code == 409
    assert c.post("/v1/log", json={"counter": 2, "record": b64(b"r2")}, headers=auth).status_code == 201

    # A second device has its own chain.
    dev2 = account.add_device()
    auth2 = account.login(dev2)
    assert c.post("/v1/log", json={"counter": 1, "record": b64(b"other")}, headers=auth2).status_code == 201

    recs = c.get("/v1/log?after=0", headers=auth).json()["records"]
    assert [base64.b64decode(r["record"]) for r in recs] == [b"r1", b"r2", b"other"]
    seqs = [r["seq"] for r in recs]
    assert seqs == sorted(seqs)
    later = c.get(f"/v1/log?after={seqs[0]}", headers=auth).json()["records"]
    assert len(later) == 2


# ─── escrow ──────────────────────────────────────────────────────────────


def test_escrow_readable_with_recovery_key_before_any_device(account):
    r = account.client.get(
        f"/v1/accounts/{account.id}/escrow", headers=account.recovery_header("get-escrow")
    )
    assert r.status_code == 200
    assert len(r.json()["slots"]) == 4
    assert account.client.get(f"/v1/accounts/{account.id}/escrow").status_code == 401


def test_escrow_slot_update_requires_recovery_key_and_fixed_size(phone):
    account, _, auth = phone
    new = os.urandom(128)
    r = account.client.put(f"/v1/accounts/{account.id}/escrow/2", content=new, headers=auth)
    assert r.status_code == 401
    r = account.client.put(
        f"/v1/accounts/{account.id}/escrow/2", content=new, headers=account.recovery_header("put-escrow:2", new)
    )
    assert r.status_code == 204
    slots = account.client.get(f"/v1/accounts/{account.id}/escrow", headers=auth).json()["slots"]
    assert base64.b64decode(slots[2]) == new
    short = os.urandom(64)
    r = account.client.put(
        f"/v1/accounts/{account.id}/escrow/1", content=short, headers=account.recovery_header("put-escrow:1", short)
    )
    assert r.status_code == 400


# ─── resumable uploads within a piece ───────────────────────────────────


def _part_headers(auth, offset, total, whole: bytes):
    return {
        **auth,
        "Upload-Offset": str(offset),
        "Upload-Length": str(total),
        "Piece-Digest": f"sha-256=:{base64.b64encode(hashlib.sha256(whole).digest()).decode()}:",
    }


def test_piece_can_be_uploaded_in_parts_and_resumed(phone):
    account, _, auth = phone
    c = account.client
    data = os.urandom(100_000)
    pid = piece_id(data)
    assert c.get(f"/v1/uploads/{pid}", headers=auth).json() == {"offset": 0, "done": False}
    r = c.patch(f"/v1/uploads/{pid}", content=data[:30_000], headers=_part_headers(auth, 0, len(data), data))
    assert r.json() == {"done": False, "offset": 30_000}
    # Connection dropped; the phone asks where to continue.
    assert c.get(f"/v1/uploads/{pid}", headers=auth).json()["offset"] == 30_000
    # Not visible as a piece until complete.
    assert c.post("/v1/pieces/missing", json={"ids": [pid]}, headers=auth).json()["missing"] == [pid]
    # A part at the wrong offset is refused with the right one.
    r = c.patch(f"/v1/uploads/{pid}", content=data[10_000:20_000], headers=_part_headers(auth, 10_000, len(data), data))
    assert r.status_code == 409
    assert r.json()["detail"]["offset"] == 30_000
    r = c.patch(f"/v1/uploads/{pid}", content=data[30_000:], headers=_part_headers(auth, 30_000, len(data), data))
    assert r.status_code == 201
    assert r.json()["done"] is True
    assert r.json()["sha256"] == hashlib.sha256(data).hexdigest()
    assert c.get(f"/v1/pieces/{pid}", headers=auth).content == data
    assert c.get(f"/v1/uploads/{pid}", headers=auth).json()["done"] is True


def test_corrupted_parts_are_caught_at_assembly(phone):
    account, _, auth = phone
    c = account.client
    data = os.urandom(50_000)
    pid = piece_id(data)
    bad = bytearray(data)
    bad[45_000] ^= 1
    c.patch(f"/v1/uploads/{pid}", content=data[:25_000], headers=_part_headers(auth, 0, len(data), data))
    r = c.patch(f"/v1/uploads/{pid}", content=bytes(bad[25_000:]), headers=_part_headers(auth, 25_000, len(data), data))
    assert r.status_code == 422
    # Staging was discarded: the next attempt starts from zero.
    assert c.get(f"/v1/uploads/{pid}", headers=auth).json()["offset"] == 0
    assert c.post("/v1/pieces/missing", json={"ids": [pid]}, headers=auth).json()["missing"] == [pid]


def test_staged_parts_are_per_account(client, phone):
    account, _, auth = phone
    data = os.urandom(20_000)
    pid = piece_id(data)
    client.patch(f"/v1/uploads/{pid}", content=data[:5_000], headers=_part_headers(auth, 0, len(data), data))
    other = Account(client)
    oauth = other.login(other.add_device())
    assert client.get(f"/v1/uploads/{pid}", headers=oauth).json()["offset"] == 0
