"""Database models. The server stores only opaque ciphertext plus the
minimum metadata needed to serve it (see docs/THREAT_MODEL.md, A5)."""

from __future__ import annotations

from datetime import datetime, timezone

from sqlalchemy import (
    JSON,
    BigInteger,
    Boolean,
    DateTime,
    ForeignKey,
    Integer,
    LargeBinary,
    String,
    UniqueConstraint,
    create_engine,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, sessionmaker


def utcnow() -> datetime:
    return datetime.now(timezone.utc).replace(tzinfo=None)


class Base(DeclarativeBase):
    pass


class Account(Base):
    __tablename__ = "accounts"

    id: Mapped[str] = mapped_column(String(32), primary_key=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    append_only: Mapped[bool] = mapped_column(Boolean, default=True)
    #: Exactly N Ed25519 public keys (base64). Unused ones are real keys whose
    #: private half was discarded, so the count never reveals vault count.
    recovery_keys: Mapped[list] = mapped_column(JSON)
    #: Exactly N opaque fixed-size slots (base64): SRKs wrapped under RS.
    escrow: Mapped[list] = mapped_column(JSON)
    #: 64-bit: a 32-bit column overflowed at 2 GiB on PostgreSQL, so every
    #: account stopped backing up there (the default quota is 20 GiB).
    bytes_used: Mapped[int] = mapped_column(BigInteger, default=0)


class Device(Base):
    __tablename__ = "devices"

    id: Mapped[str] = mapped_column(String(32), primary_key=True)
    account_id: Mapped[str] = mapped_column(ForeignKey("accounts.id"), index=True)
    public_key: Mapped[bytes] = mapped_column(LargeBinary(32))
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    #: Last accepted log counter for this device's chain.
    last_counter: Mapped[int] = mapped_column(Integer, default=0)


class Challenge(Base):
    __tablename__ = "challenges"

    nonce: Mapped[str] = mapped_column(String(64), primary_key=True)
    account_id: Mapped[str] = mapped_column(String(32), index=True)
    expires_at: Mapped[datetime] = mapped_column(DateTime)


class Token(Base):
    __tablename__ = "tokens"

    token_hash: Mapped[str] = mapped_column(String(64), primary_key=True)
    account_id: Mapped[str] = mapped_column(String(32), index=True)
    device_id: Mapped[str] = mapped_column(String(32), index=True)
    expires_at: Mapped[datetime] = mapped_column(DateTime)


class Piece(Base):
    __tablename__ = "pieces"

    account_id: Mapped[str] = mapped_column(String(32), primary_key=True)
    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    size: Mapped[int] = mapped_column(Integer)
    sha256: Mapped[str] = mapped_column(String(64))
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)


class LogRecord(Base):
    __tablename__ = "log"
    __table_args__ = (UniqueConstraint("account_id", "device_id", "counter"),)

    seq: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    account_id: Mapped[str] = mapped_column(String(32), index=True)
    device_id: Mapped[str] = mapped_column(String(32))
    counter: Mapped[int] = mapped_column(Integer)
    record: Mapped[bytes] = mapped_column(LargeBinary)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)


def make_sessionmaker(db_url: str):
    connect_args = {"check_same_thread": False} if db_url.startswith("sqlite") else {}
    engine = create_engine(db_url, connect_args=connect_args, future=True)
    Base.metadata.create_all(engine)
    _migrate(engine)
    return sessionmaker(engine, expire_on_commit=False, future=True)


def _migrate(engine) -> None:
    """In-place upgrades for databases created by older versions."""
    if engine.dialect.name == "postgresql":
        from sqlalchemy import text

        with engine.begin() as conn:
            conn.execute(text("ALTER TABLE accounts ALTER COLUMN bytes_used TYPE BIGINT"))
