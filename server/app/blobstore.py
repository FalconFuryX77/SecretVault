"""Where piece bytes live: a local directory (dev/tests) or S3/MinIO."""

from __future__ import annotations

import os
import tempfile
from pathlib import Path
from typing import Protocol


class BlobStore(Protocol):
    def put(self, account: str, piece_id: str, data: bytes) -> None: ...
    def get(self, account: str, piece_id: str) -> bytes | None: ...
    def delete(self, account: str, piece_id: str) -> None: ...


class LocalBlobStore:
    """Files under root/<account>/<id[:2]>/<id>, written atomically."""

    def __init__(self, root: str | os.PathLike[str]):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)

    def _path(self, account: str, piece_id: str) -> Path:
        return self.root / account / piece_id[:2] / piece_id

    def put(self, account: str, piece_id: str, data: bytes) -> None:
        path = self._path(account, piece_id)
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".tmp-")
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(data)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, path)
        except BaseException:
            try:
                os.unlink(tmp)
            except FileNotFoundError:
                pass
            raise

    def get(self, account: str, piece_id: str) -> bytes | None:
        try:
            return self._path(account, piece_id).read_bytes()
        except FileNotFoundError:
            return None

    def delete(self, account: str, piece_id: str) -> None:
        try:
            self._path(account, piece_id).unlink()
        except FileNotFoundError:
            pass


class S3BlobStore:
    """S3-compatible storage (SeaweedFS in docker-compose; any S3 works)."""

    def __init__(self, endpoint: str, bucket: str, access_key: str | None, secret_key: str | None):
        import boto3  # imported lazily: only needed when S3 is configured

        self.bucket = bucket
        self.s3 = boto3.client(
            "s3",
            endpoint_url=endpoint,
            aws_access_key_id=access_key,
            aws_secret_access_key=secret_key,
        )
        # The store may still be starting (Compose starts both at once).
        import time

        for attempt in range(15):
            try:
                try:
                    self.s3.head_bucket(Bucket=bucket)
                except self.s3.exceptions.ClientError:
                    self.s3.create_bucket(Bucket=bucket)
                return
            except Exception:
                if attempt == 14:
                    raise
                time.sleep(2)

    def put(self, account: str, piece_id: str, data: bytes) -> None:
        self.s3.put_object(Bucket=self.bucket, Key=f"{account}/{piece_id}", Body=data)

    def get(self, account: str, piece_id: str) -> bytes | None:
        try:
            obj = self.s3.get_object(Bucket=self.bucket, Key=f"{account}/{piece_id}")
        except self.s3.exceptions.NoSuchKey:
            return None
        return obj["Body"].read()

    def delete(self, account: str, piece_id: str) -> None:
        self.s3.delete_object(Bucket=self.bucket, Key=f"{account}/{piece_id}")
