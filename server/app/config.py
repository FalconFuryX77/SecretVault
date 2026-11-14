"""Server settings, read from environment variables (prefix SYNC_)."""

from __future__ import annotations

import os
from dataclasses import dataclass, field


def _env_list(name: str) -> list[str]:
    raw = os.environ.get(name, "").strip()
    return [x.strip() for x in raw.split(",") if x.strip()]


@dataclass
class Settings:
    # Storage
    db_url: str = field(default_factory=lambda: os.environ.get("SYNC_DB_URL", "sqlite:///./sync.db"))
    blob_dir: str = field(default_factory=lambda: os.environ.get("SYNC_BLOB_DIR", "./blobs"))
    #: Partially uploaded pieces (resumable uploads) wait here until complete.
    staging_dir: str = field(default_factory=lambda: os.environ.get("SYNC_STAGING_DIR", "./staging"))
    s3_endpoint: str | None = field(default_factory=lambda: os.environ.get("SYNC_S3_ENDPOINT"))
    s3_bucket: str = field(default_factory=lambda: os.environ.get("SYNC_S3_BUCKET", "pieces"))
    s3_access_key: str | None = field(default_factory=lambda: os.environ.get("SYNC_S3_ACCESS_KEY"))
    s3_secret_key: str | None = field(default_factory=lambda: os.environ.get("SYNC_S3_SECRET_KEY"))

    # Policy
    #: Comma-separated invite codes. Empty = open registration (dev only).
    invite_codes: list[str] = field(default_factory=lambda: _env_list("SYNC_INVITE_CODES"))
    #: New accounts start append-only: device tokens can't delete pieces.
    append_only_default: bool = field(
        default_factory=lambda: os.environ.get("SYNC_APPEND_ONLY_DEFAULT", "true").lower() == "true"
    )
    max_account_bytes: int = field(
        default_factory=lambda: int(os.environ.get("SYNC_MAX_ACCOUNT_BYTES", str(20 * 1024**3)))
    )
    max_piece_bytes: int = 2 * 1024 * 1024
    escrow_slot_bytes: int = 128
    escrow_slots: int = 4
    recovery_keys: int = 4

    # Auth
    token_ttl_seconds: int = 15 * 60
    challenge_ttl_seconds: int = 120
