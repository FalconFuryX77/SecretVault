"""Signatures, nonces and tokens.

Every signed request covers: a fixed protocol tag, the operation, the
account, a single-use server nonce, and the SHA-256 of the exact request
body. A signature can therefore never be replayed, moved to another account,
or reused for a different operation or body.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import secrets

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

PROTOCOL_TAG = b"sv-sync-v1"


def b64e(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def b64d(text: str) -> bytes:
    """Decodes standard or URL-safe base64, with or without padding."""
    t = text.strip().replace("-", "+").replace("_", "/")
    t += "=" * (-len(t) % 4)
    try:
        return base64.b64decode(t, validate=True)
    except (binascii.Error, ValueError) as e:
        raise ValueError("invalid base64") from e


def signed_message(op: str, account_id: str, nonce: str, body: bytes) -> bytes:
    return b"|".join(
        [
            PROTOCOL_TAG,
            op.encode("utf-8"),
            account_id.encode("ascii"),
            nonce.encode("ascii"),
            hashlib.sha256(body).hexdigest().encode("ascii"),
        ]
    )


def verify_signature(public_key: bytes, signature: bytes, message: bytes) -> bool:
    if len(public_key) != 32 or len(signature) != 64:
        return False
    try:
        Ed25519PublicKey.from_public_bytes(public_key).verify(signature, message)
        return True
    except (InvalidSignature, ValueError):
        return False


def is_valid_public_key(public_key: bytes) -> bool:
    if len(public_key) != 32:
        return False
    try:
        Ed25519PublicKey.from_public_bytes(public_key)
        return True
    except ValueError:
        return False


def new_id() -> str:
    return secrets.token_hex(16)


def new_nonce() -> str:
    return secrets.token_urlsafe(32)


def new_token() -> str:
    return secrets.token_urlsafe(32)


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode("ascii")).hexdigest()
