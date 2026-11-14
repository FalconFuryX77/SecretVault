from __future__ import annotations

import base64
import hashlib
import os
import sys

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from fastapi.testclient import TestClient

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from app.config import Settings  # noqa: E402
from app.main import create_app  # noqa: E402
from app.security import signed_message  # noqa: E402


def b64(b: bytes) -> str:
    return base64.b64encode(b).decode()


def pub_bytes(k: Ed25519PrivateKey) -> bytes:
    return k.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)


def piece_id(content: bytes) -> str:
    return hashlib.sha256(b"id:" + content).hexdigest()


class Account:
    """Test double for a phone + its recovery phrase."""

    def __init__(self, client: TestClient, *, append_only: bool | None = None, invite: str | None = None):
        self.client = client
        self.recovery = [Ed25519PrivateKey.generate() for _ in range(4)]
        body = {
            "recovery_keys": [b64(pub_bytes(k)) for k in self.recovery],
            "escrow": [b64(os.urandom(128)) for _ in range(4)],
        }
        if append_only is not None:
            body["append_only"] = append_only
        if invite is not None:
            body["invite_code"] = invite
        r = client.post("/v1/accounts", json=body)
        assert r.status_code == 201, r.text
        self.id = r.json()["account_id"]
        self.devices: dict[str, Ed25519PrivateKey] = {}

    def nonce(self) -> str:
        r = self.client.post("/v1/challenges", json={"account_id": self.id})
        assert r.status_code == 200, r.text
        return r.json()["nonce"]

    def recovery_header(self, op: str, body: bytes = b"", key_index: int = 0) -> dict:
        n = self.nonce()
        sig = self.recovery[key_index].sign(signed_message(op, self.id, n, body))
        return {"X-Recovery-Auth": f"{key_index}.{n}.{b64(sig)}"}

    def add_device(self) -> str:
        key = Ed25519PrivateKey.generate()
        import json

        raw = json.dumps({"public_key": b64(pub_bytes(key))}).encode()
        r = self.client.post(
            f"/v1/accounts/{self.id}/devices",
            content=raw,
            headers={"Content-Type": "application/json", **self.recovery_header("add-device", raw)},
        )
        assert r.status_code == 201, r.text
        dev = r.json()["device_id"]
        self.devices[dev] = key
        return dev

    def login(self, device_id: str) -> dict:
        n = self.nonce()
        sig = self.devices[device_id].sign(signed_message(f"login:{device_id}", self.id, n, b""))
        r = self.client.post(
            "/v1/auth/token",
            json={"account_id": self.id, "device_id": device_id, "nonce": n, "signature": b64(sig)},
        )
        assert r.status_code == 200, r.text
        return {"Authorization": f"Bearer {r.json()['token']}"}


@pytest.fixture
def settings(tmp_path) -> Settings:
    return Settings(
        db_url=f"sqlite:///{tmp_path / 'sync.db'}",
        blob_dir=str(tmp_path / "blobs"),
        staging_dir=str(tmp_path / "staging"),
        invite_codes=[],
        append_only_default=True,
        max_account_bytes=10 * 1024 * 1024,
    )


@pytest.fixture
def client(settings) -> TestClient:
    return TestClient(create_app(settings))


@pytest.fixture
def account(client) -> Account:
    return Account(client)


@pytest.fixture
def phone(account) -> tuple[Account, str, dict]:
    dev = account.add_device()
    return account, dev, account.login(dev)
