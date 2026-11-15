"""Sync server API (v1). Design: docs/SYNC_DESIGN.md §7.

The server is deliberately dumb: it stores opaque, content-named pieces and an
append-only log of opaque records, and enforces only authentication, quotas,
per-device log ordering and (optionally) append-only retention.
"""


import base64
import hashlib
import os
import time
import re
from datetime import timedelta
from pathlib import Path
from typing import Annotated

from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request, Response
from pydantic import BaseModel, Field
from sqlalchemy import delete, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session
from starlette.concurrency import run_in_threadpool
from starlette.requests import ClientDisconnect

from .blobstore import BlobStore, LocalBlobStore, S3BlobStore
from .config import Settings
from .db import Account, Challenge, Device, LogRecord, Piece, Token, make_sessionmaker, utcnow
from .security import (
    b64d,
    b64e,
    hash_token,
    is_valid_public_key,
    new_id,
    new_nonce,
    new_token,
    signed_message,
    verify_signature,
)

PIECE_ID = re.compile(r"^[0-9a-f]{64}$")
MAX_MISSING_BATCH = 1000
MAX_PAGE = 1000


# ─── Request / response bodies ───────────────────────────────────────────


class CreateAccount(BaseModel):
    invite_code: str | None = None
    recovery_keys: list[str]
    escrow: list[str]
    append_only: bool | None = None


class ChallengeRequest(BaseModel):
    account_id: str


class TokenRequest(BaseModel):
    account_id: str
    device_id: str
    nonce: str
    signature: str


class AddDevice(BaseModel):
    public_key: str


class MissingRequest(BaseModel):
    ids: list[str] = Field(max_length=MAX_MISSING_BATCH)


class DeleteRequest(BaseModel):
    ids: list[str] = Field(max_length=MAX_MISSING_BATCH)


class AppendLog(BaseModel):
    counter: int
    record: str


# ─── App factory ─────────────────────────────────────────────────────────


MAX_OPEN_UPLOADS = 64
LOG_HEADROOM_BYTES = 16 * 1024 * 1024
STAGING_TTL_SECONDS = 24 * 3600


def _clean_staging(folder: Path) -> None:
    """Deletes partial uploads untouched for a day."""
    cutoff = time.time() - STAGING_TTL_SECONDS
    for f in folder.iterdir():
        try:
            if f.stat().st_mtime < cutoff:
                f.unlink()
        except OSError:
            pass


class _BodyLimit:
    """ASGI middleware: refuses a request body over the limit for its path,
    by Content-Length up front and by counting what actually arrives."""

    def __init__(self, app, limit_for):
        self.app = app
        self.limit_for = limit_for

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        limit = self.limit_for(scope["path"])
        for k, v in scope.get("headers", []):
            if k == b"content-length":
                try:
                    too_big = int(v) > limit
                except ValueError:
                    too_big = True
                if too_big:
                    await send({"type": "http.response.start", "status": 413,
                                "headers": [(b"content-type", b"application/json")]})
                    await send({"type": "http.response.body", "body": b'{"detail":"request too large"}'})
                    return
        seen = 0

        async def limited():
            nonlocal seen
            msg = await receive()
            if msg["type"] == "http.request":
                seen += len(msg.get("body", b""))
                if seen > limit:
                    raise HTTPException(413, "request too large")
            return msg

        await self.app(scope, limited, send)


def create_app(settings: Settings | None = None, blobs: BlobStore | None = None) -> FastAPI:
    settings = settings or Settings()
    SessionLocal = make_sessionmaker(settings.db_url)
    if blobs is None:
        blobs = (
            S3BlobStore(settings.s3_endpoint, settings.s3_bucket, settings.s3_access_key, settings.s3_secret_key)
            if settings.s3_endpoint
            else LocalBlobStore(settings.blob_dir)
        )

    if not settings.invite_codes or "dev-invite" in settings.invite_codes:
        import logging

        logging.getLogger("uvicorn.error").warning(
            "SYNC_INVITE_CODES is %s: anyone who can reach this server can create accounts. "
            "Set it to a secret of your own before exposing the server.",
            "empty" if not settings.invite_codes else "the development code 'dev-invite'",
        )
    app = FastAPI(title="Vault sync server", version="1")
    app.state.settings = settings
    app.state.blobs = blobs

    # Bodies are capped before anything reads them, including on endpoints
    # that read the body before checking auth: without this, anyone could
    # make the server buffer arbitrarily large requests in memory.
    piece_limit = settings.max_piece_bytes + 4096
    log_limit = settings.max_piece_bytes * 4 // 3 + 4096  # base64 in JSON

    def body_limit(path: str) -> int:
        if path.startswith("/v1/pieces/") and not path.startswith("/v1/pieces/missing") \
                and not path.startswith("/v1/pieces/delete"):
            return piece_limit
        if path.startswith("/v1/uploads/"):
            return piece_limit
        if path == "/v1/log":
            return log_limit
        if path.startswith("/v1/pieces/missing") or path.startswith("/v1/pieces/delete"):
            return 256 * 1024
        return 64 * 1024

    app.add_middleware(_BodyLimit, limit_for=body_limit)

    @app.exception_handler(ClientDisconnect)
    async def _client_gone(request: Request, exc: ClientDisconnect):
        # The phone lost signal mid-upload. Nothing was stored (pieces are only
        # recorded after the full body arrives); the client will ask what's
        # missing next time. Not an error.
        return Response(status_code=499)

    def get_db():
        db = SessionLocal()
        try:
            yield db
        finally:
            db.close()

    DB = Annotated[Session, Depends(get_db)]

    # ── helpers ──

    def account_or_404(db: Session, account_id: str) -> Account:
        acct = db.get(Account, account_id)
        if acct is None:
            raise HTTPException(404, "unknown account")
        return acct

    def consume_challenge(db: Session, account_id: str, nonce: str) -> None:
        ch = db.get(Challenge, nonce)
        if ch is None or ch.account_id != account_id:
            raise HTTPException(401, "unknown or used challenge")
        db.delete(ch)  # single use, even if the signature turns out bad
        db.commit()
        if ch.expires_at < utcnow():
            raise HTTPException(401, "challenge expired")

    def require_recovery(db: Session, acct: Account, header: str | None, op: str, body: bytes) -> None:
        """X-Recovery-Auth: <key index>.<nonce>.<base64 signature>"""
        if not header:
            raise HTTPException(401, "recovery signature required")
        try:
            idx_s, nonce, sig_b64 = header.split(".", 2)
            idx = int(idx_s)
            sig = b64d(sig_b64)
            pub = b64d(acct.recovery_keys[idx])
        except (ValueError, IndexError):
            raise HTTPException(401, "malformed recovery signature")
        consume_challenge(db, acct.id, nonce)
        if not verify_signature(pub, sig, signed_message(op, acct.id, nonce, body)):
            raise HTTPException(401, "bad recovery signature")

    def require_device(
        db: DB, authorization: Annotated[str | None, Header()] = None
    ) -> tuple[str, str]:
        if not authorization or not authorization.startswith("Bearer "):
            raise HTTPException(401, "bearer token required")
        tok = db.get(Token, hash_token(authorization[7:]))
        if tok is None or tok.expires_at < utcnow():
            raise HTTPException(401, "invalid or expired token")
        dev = db.get(Device, tok.device_id)
        if dev is None or dev.revoked_at is not None:
            raise HTTPException(401, "device revoked")
        return tok.account_id, tok.device_id

    Caller = Annotated[tuple[str, str], Depends(require_device)]

    def check_piece_id(piece_id: str) -> None:
        if not PIECE_ID.match(piece_id):
            raise HTTPException(400, "piece id must be 64 lowercase hex characters")

    # ── health ──

    @app.get("/health")
    def health():
        return {"ok": True}

    # ── accounts & auth ──

    @app.post("/v1/accounts", status_code=201)
    def create_account(body: CreateAccount, db: DB):
        if settings.invite_codes and body.invite_code not in settings.invite_codes:
            raise HTTPException(403, "invite code required")
        if len(body.recovery_keys) != settings.recovery_keys:
            raise HTTPException(400, f"exactly {settings.recovery_keys} recovery keys required")
        if len(body.escrow) != settings.escrow_slots:
            raise HTTPException(400, f"exactly {settings.escrow_slots} escrow slots required")
        try:
            keys = [b64d(k) for k in body.recovery_keys]
            escrow = [b64d(e) for e in body.escrow]
        except ValueError:
            raise HTTPException(400, "invalid base64")
        if not all(is_valid_public_key(k) for k in keys):
            raise HTTPException(400, "recovery keys must be Ed25519 public keys")
        if any(len(e) != settings.escrow_slot_bytes for e in escrow):
            raise HTTPException(400, f"escrow slots must be {settings.escrow_slot_bytes} bytes")
        acct = Account(
            id=new_id(),
            recovery_keys=[b64e(k) for k in keys],
            escrow=[b64e(e) for e in escrow],
            # A client may ask for append-only, but can't opt out of the
            # operator's default (a seized phone creating accounts mustn't
            # get deletable ones).
            append_only=settings.append_only_default or bool(body.append_only),
        )
        db.add(acct)
        db.commit()
        return {"account_id": acct.id, "append_only": acct.append_only}

    @app.post("/v1/challenges")
    def challenge(body: ChallengeRequest, db: DB):
        account_or_404(db, body.account_id)
        nonce = new_nonce()
        db.add(
            Challenge(
                nonce=nonce,
                account_id=body.account_id,
                expires_at=utcnow() + timedelta(seconds=settings.challenge_ttl_seconds),
            )
        )
        db.commit()
        return {"nonce": nonce, "expires_in": settings.challenge_ttl_seconds}

    @app.post("/v1/auth/token")
    def login(body: TokenRequest, db: DB):
        account_or_404(db, body.account_id)
        consume_challenge(db, body.account_id, body.nonce)
        dev = db.get(Device, body.device_id)
        if dev is None or dev.account_id != body.account_id or dev.revoked_at is not None:
            raise HTTPException(401, "unknown or revoked device")
        try:
            sig = b64d(body.signature)
        except ValueError:
            raise HTTPException(401, "bad signature")
        msg = signed_message(f"login:{dev.id}", body.account_id, body.nonce, b"")
        if not verify_signature(dev.public_key, sig, msg):
            raise HTTPException(401, "bad signature")
        token = new_token()
        db.add(
            Token(
                token_hash=hash_token(token),
                account_id=body.account_id,
                device_id=dev.id,
                expires_at=utcnow() + timedelta(seconds=settings.token_ttl_seconds),
            )
        )
        db.commit()
        return {"token": token, "expires_in": settings.token_ttl_seconds}

    # ── devices (recovery-key operations) ──

    @app.post("/v1/accounts/{account_id}/devices", status_code=201)
    async def add_device(
        account_id: str,
        request: Request,
        db: DB,
        x_recovery_auth: Annotated[str | None, Header()] = None,
    ):
        raw = await request.body()
        acct = account_or_404(db, account_id)
        require_recovery(db, acct, x_recovery_auth, "add-device", raw)
        try:
            pub = b64d(AddDevice.model_validate_json(raw).public_key)
        except ValueError:
            raise HTTPException(400, "invalid public key")
        if not is_valid_public_key(pub):
            raise HTTPException(400, "invalid public key")
        dev = Device(id=new_id(), account_id=account_id, public_key=pub)
        db.add(dev)
        db.commit()
        return {"device_id": dev.id}

    @app.get("/v1/accounts/{account_id}/devices")
    def list_devices(account_id: str, caller: Caller, db: DB):
        if caller[0] != account_id:
            raise HTTPException(404, "unknown account")
        rows = db.scalars(select(Device).where(Device.account_id == account_id).order_by(Device.created_at)).all()
        return [
            {"device_id": d.id, "created_at": d.created_at.isoformat(), "revoked": d.revoked_at is not None}
            for d in rows
        ]

    @app.delete("/v1/accounts/{account_id}/devices/{device_id}", status_code=204)
    async def revoke_device(
        account_id: str,
        device_id: str,
        request: Request,
        db: DB,
        x_recovery_auth: Annotated[str | None, Header()] = None,
    ):
        raw = await request.body()
        acct = account_or_404(db, account_id)
        require_recovery(db, acct, x_recovery_auth, f"revoke-device:{device_id}", raw)
        dev = db.get(Device, device_id)
        if dev is None or dev.account_id != account_id:
            raise HTTPException(404, "unknown device")
        dev.revoked_at = utcnow()
        db.execute(delete(Token).where(Token.device_id == device_id))
        db.commit()
        return Response(status_code=204)

    # ── escrow ──

    @app.get("/v1/accounts/{account_id}/escrow")
    async def get_escrow(
        account_id: str,
        request: Request,
        db: DB,
        authorization: Annotated[str | None, Header()] = None,
        x_recovery_auth: Annotated[str | None, Header()] = None,
    ):
        acct = account_or_404(db, account_id)
        if x_recovery_auth:  # restoring from the phrase, before any device exists
            require_recovery(db, acct, x_recovery_auth, "get-escrow", b"")
        else:
            caller = require_device(db, authorization)
            if caller[0] != account_id:
                raise HTTPException(404, "unknown account")
        return {"slots": acct.escrow}

    @app.put("/v1/accounts/{account_id}/escrow/{slot}", status_code=204)
    async def put_escrow(
        account_id: str,
        slot: int,
        request: Request,
        db: DB,
        x_recovery_auth: Annotated[str | None, Header()] = None,
    ):
        raw = await request.body()
        acct = account_or_404(db, account_id)
        require_recovery(db, acct, x_recovery_auth, f"put-escrow:{slot}", raw)
        if not 0 <= slot < settings.escrow_slots or len(raw) != settings.escrow_slot_bytes:
            raise HTTPException(400, "bad slot or size")
        slots = list(acct.escrow)
        slots[slot] = b64e(raw)
        acct.escrow = slots
        db.commit()
        return Response(status_code=204)

    # ── pieces ──

    # ── resumable uploads (within one piece) ──
    #
    # For links too slow or short-lived to carry a whole piece in one go:
    # the client appends parts at the offset the server reports, and the
    # piece is committed only once the whole thing matches its digest.

    staging_root = Path(settings.staging_dir)

    def staging_path(account_id: str, piece_id: str) -> Path:
        return staging_root / account_id / piece_id

    def reserve_quota(db: Session, account_id: str, n: int, headroom: int = 0) -> None:
        """Adds [n] bytes to the account's usage in one SQL statement, so
        concurrent uploads can't overwrite each other's update and slip past
        the quota. Part of the caller's transaction: a rollback releases it."""
        res = db.execute(
            update(Account)
            .where(Account.id == account_id, Account.bytes_used + n <= settings.max_account_bytes + headroom)
            .values(bytes_used=Account.bytes_used + n)
        )
        if res.rowcount != 1:
            db.rollback()
            raise HTTPException(413, "account quota exceeded")

    def store_piece(db: Session, acct: Account, piece_id: str, data: bytes, digest: bytes) -> dict:
        reserve_quota(db, acct.id, len(data))
        try:
            blobs.put(acct.id, piece_id, data)
        except Exception:
            db.rollback()
            raise
        db.add(Piece(account_id=acct.id, id=piece_id, size=len(data), sha256=digest.hex()))
        try:
            db.commit()
        except IntegrityError:
            db.rollback()
            existing = db.get(Piece, (acct.id, piece_id))
            return {"done": True, "created": False, "sha256": existing.sha256 if existing else digest.hex()}
        return {"done": True, "created": True, "sha256": digest.hex()}

    @app.get("/v1/uploads/{piece_id}")
    def upload_offset(piece_id: str, caller: Caller, db: DB):
        check_piece_id(piece_id)
        existing = db.get(Piece, (caller[0], piece_id))
        if existing is not None:
            return {"offset": existing.size, "done": True, "sha256": existing.sha256}
        p = staging_path(caller[0], piece_id)
        return {"offset": p.stat().st_size if p.exists() else 0, "done": False}

    @app.patch("/v1/uploads/{piece_id}")
    async def upload_part(
        piece_id: str,
        request: Request,
        response: Response,
        caller: Caller,
        db: DB,
        upload_offset: Annotated[int, Header()],
        upload_length: Annotated[int, Header()],
        piece_digest: Annotated[str, Header()],
    ):
        check_piece_id(piece_id)
        account_id = caller[0]
        existing = db.get(Piece, (account_id, piece_id))
        if existing is not None:
            return {"done": True, "created": False, "sha256": existing.sha256, "offset": existing.size}
        if not 0 < upload_length <= settings.max_piece_bytes:
            raise HTTPException(413, "piece too large")
        m = re.fullmatch(r"\s*sha-256=:([A-Za-z0-9+/=]+):\s*", piece_digest)
        if not m:
            raise HTTPException(400, "Piece-Digest must be sha-256=:<base64>:")
        expected_digest = base64.b64decode(m.group(1))
        # Read the whole part before touching the staging file: a part cut
        # off mid-way leaves the offset exactly where it was.
        part = await request.body()
        path = staging_path(account_id, piece_id)
        path.parent.mkdir(parents=True, exist_ok=True)
        if not path.exists():
            # A new upload: drop abandoned ones, and cap how many can be open,
            # so staging (which isn't counted in the quota) can't fill the disk.
            await run_in_threadpool(_clean_staging, path.parent)
            if sum(1 for _ in path.parent.iterdir()) >= MAX_OPEN_UPLOADS:
                raise HTTPException(429, "too many unfinished uploads")
        current = path.stat().st_size if path.exists() else 0
        if upload_offset != current:
            raise HTTPException(409, {"error": "offset mismatch", "offset": current})
        if current + len(part) > upload_length:
            path.unlink(missing_ok=True)
            raise HTTPException(400, "part runs past Upload-Length")
        with open(path, "ab") as f:
            f.write(part)
            f.flush()
            os.fsync(f.fileno())
        new_offset = current + len(part)
        if new_offset < upload_length:
            return {"done": False, "offset": new_offset}
        data = path.read_bytes()
        digest = hashlib.sha256(data).digest()
        path.unlink(missing_ok=True)
        if digest != expected_digest:
            raise HTTPException(422, "assembled piece does not match Piece-Digest; start again")
        acct = account_or_404(db, account_id)
        result = await run_in_threadpool(store_piece, db, acct, piece_id, data, digest)
        response.status_code = 201 if result["created"] else 200
        return {**result, "offset": len(data)}

    @app.post("/v1/pieces/missing")
    def missing(body: MissingRequest, caller: Caller, db: DB):
        for pid in body.ids:
            check_piece_id(pid)
        have = set(
            db.scalars(select(Piece.id).where(Piece.account_id == caller[0], Piece.id.in_(body.ids))).all()
        )
        return {"missing": [pid for pid in body.ids if pid not in have]}

    @app.put("/v1/pieces/{piece_id}")
    async def put_piece(
        piece_id: str,
        request: Request,
        response: Response,
        caller: Caller,
        db: DB,
        content_digest: Annotated[str | None, Header()] = None,
    ):
        check_piece_id(piece_id)
        data = await request.body()
        if len(data) > settings.max_piece_bytes:
            raise HTTPException(413, "piece too large")
        digest = hashlib.sha256(data).digest()
        if content_digest is not None:
            m = re.fullmatch(r"\s*sha-256=:([A-Za-z0-9+/=]+):\s*", content_digest)
            if not m or base64.b64decode(m.group(1)) != digest:
                raise HTTPException(400, "Content-Digest mismatch (corrupted in transit)")
        account_id = caller[0]
        existing = db.get(Piece, (account_id, piece_id))
        if existing is not None:
            # Same content name → already stored. Idempotent: never overwritten.
            response.status_code = 200
            return {"sha256": existing.sha256, "created": False}
        acct = account_or_404(db, account_id)
        # One worker thread does reserve → write → commit: the quota UPDATE
        # holds the account row's lock until the commit, and holding it across
        # an await let a second upload block the event loop on that lock.
        result = await run_in_threadpool(store_piece, db, acct, piece_id, data, digest)
        response.status_code = 201 if result["created"] else 200
        return {"sha256": result["sha256"], "created": result["created"]}

    @app.get("/v1/pieces/{piece_id}")
    async def get_piece(
        piece_id: str,
        caller: Caller,
        db: DB,
        range: Annotated[str | None, Header()] = None,
    ):
        check_piece_id(piece_id)
        if db.get(Piece, (caller[0], piece_id)) is None:
            raise HTTPException(404, "no such piece")
        data = await run_in_threadpool(blobs.get, caller[0], piece_id)
        if data is None:
            raise HTTPException(404, "no such piece")
        headers = {"Accept-Ranges": "bytes", "Content-Type": "application/octet-stream"}
        if range is None:
            return Response(content=data, headers=headers)
        span = _parse_range(range, len(data))
        if span is None:
            return Response(status_code=416, headers={"Content-Range": f"bytes */{len(data)}"})
        start, end = span
        headers["Content-Range"] = f"bytes {start}-{end}/{len(data)}"
        return Response(content=data[start : end + 1], status_code=206, headers=headers)

    @app.get("/v1/pieces")
    def list_pieces(
        caller: Caller,
        db: DB,
        after: str = "",
        limit: Annotated[int, Query(ge=1, le=MAX_PAGE)] = MAX_PAGE,
    ):
        rows = db.scalars(
            select(Piece)
            .where(Piece.account_id == caller[0], Piece.id > after)
            .order_by(Piece.id)
            .limit(limit)
        ).all()
        return {
            "pieces": [{"id": p.id, "size": p.size, "created_at": p.created_at.isoformat()} for p in rows],
            "next": rows[-1].id if len(rows) == limit else None,
        }

    @app.post("/v1/pieces/delete")
    async def delete_pieces(
        request: Request,
        caller: Caller,
        db: DB,
        x_recovery_auth: Annotated[str | None, Header()] = None,
    ):
        raw = await request.body()
        body = DeleteRequest.model_validate_json(raw)
        acct = account_or_404(db, caller[0])
        if acct.append_only:
            # A seized phone must not be able to erase what already got out.
            require_recovery(db, acct, x_recovery_auth, "delete-pieces", raw)
        for pid in body.ids:
            check_piece_id(pid)

        def _delete() -> int:
            deleted = 0
            for pid in body.ids:
                p = db.get(Piece, (acct.id, pid))
                if p is None:
                    continue
                blobs.delete(acct.id, pid)
                db.execute(
                    update(Account).where(Account.id == acct.id).values(bytes_used=Account.bytes_used - p.size)
                )
                db.delete(p)
                deleted += 1
            db.commit()
            return deleted

        return {"deleted": await run_in_threadpool(_delete)}

    # ── change log ──

    @app.post("/v1/log", status_code=201)
    def append_log(body: AppendLog, caller: Caller, db: DB):
        account_id, device_id = caller
        try:
            record = b64d(body.record)
        except ValueError:
            raise HTTPException(400, "invalid base64")
        if not record or len(record) > settings.max_piece_bytes:
            raise HTTPException(413, "record too large")
        dev = db.scalars(select(Device).where(Device.id == device_id).with_for_update()).one()
        expected = dev.last_counter + 1
        if body.counter != expected:
            raise HTTPException(409, {"error": "counter out of order", "expected": expected})
        # Log records take space too; they count toward the quota.
        # Headroom so that, at quota, deletions can still be recorded.
        reserve_quota(db, account_id, len(record), headroom=LOG_HEADROOM_BYTES)
        rec = LogRecord(account_id=account_id, device_id=device_id, counter=body.counter, record=record)
        db.add(rec)
        dev.last_counter = body.counter
        try:
            db.commit()
        except IntegrityError:
            db.rollback()
            raise HTTPException(409, {"error": "counter out of order", "expected": expected})
        return {"seq": rec.seq}

    @app.get("/v1/log")
    def read_log(
        caller: Caller,
        db: DB,
        after: int = 0,
        limit: Annotated[int, Query(ge=1, le=MAX_PAGE)] = 500,
    ):
        rows = db.scalars(
            select(LogRecord)
            .where(LogRecord.account_id == caller[0], LogRecord.seq > after)
            .order_by(LogRecord.seq)
            .limit(limit)
        ).all()
        return {
            "records": [
                {"seq": r.seq, "device_id": r.device_id, "counter": r.counter, "record": b64e(r.record)}
                for r in rows
            ]
        }

    return app


def _parse_range(header: str, size: int) -> tuple[int, int] | None:
    """Single byte range per RFC 9110: bytes=a-b | a- | -n."""
    m = re.fullmatch(r"\s*bytes=(\d*)-(\d*)\s*", header)
    if not m or (m.group(1) == "" and m.group(2) == ""):
        return None
    if m.group(1) == "":
        n = int(m.group(2))
        if n == 0:
            return None
        return max(0, size - n), size - 1
    start = int(m.group(1))
    end = int(m.group(2)) if m.group(2) else size - 1
    if start >= size or end < start:
        return None
    return start, min(end, size - 1)

