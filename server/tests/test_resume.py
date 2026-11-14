"""Resumability under an unreliable connection (protocol level, no Docker).

A FlakyLink wraps the test client and drops requests at random, either
*before* the server sees them, or *after* the server stored the piece but
before the reply arrives (the lost-acknowledgement case). We compare:

* resume: ask "which pieces are missing?" after every drop, send only those;
* restart: what a naive uploader does, starting over from the first piece.

This measures protocol behaviour, not real-network performance; the
Toxiproxy harness covers that once the Dart client exists.
"""

from __future__ import annotations

import os
import random

from conftest import piece_id


class Dropped(Exception):
    pass


class FlakyLink:
    def __init__(self, client, auth, drop_rate: float, seed: int):
        self.c = client
        self.auth = auth
        self.rng = random.Random(seed)
        self.drop_rate = drop_rate
        self.bytes_sent = 0
        self.requests = 0

    def _maybe_drop(self, stage: str):
        if self.rng.random() < self.drop_rate / 3:
            raise Dropped(stage)

    def missing(self, ids):
        self.requests += 1
        self._maybe_drop("before")
        self.bytes_sent += 70 * len(ids)  # ~JSON size of the id list
        r = self.c.post("/v1/pieces/missing", json={"ids": ids}, headers=self.auth)
        self._maybe_drop("after")
        return r.json()["missing"]

    def put(self, pid, data):
        self.requests += 1
        self._maybe_drop("before")
        if self.rng.random() < self.drop_rate / 3:
            # Connection dies mid-upload: part of the piece went out for nothing.
            self.bytes_sent += int(len(data) * self.rng.random())
            raise Dropped("during")
        self.bytes_sent += len(data)
        r = self.c.put(f"/v1/pieces/{pid}", content=data, headers=self.auth)
        assert r.status_code in (200, 201)
        self._maybe_drop("after")  # stored, but the phone never hears back


def make_file(n_pieces: int, size: int):
    pieces = [os.urandom(size) for _ in range(n_pieces)]
    return [(piece_id(p), p) for p in pieces]


def upload_resume(link: FlakyLink, pieces, max_pockets=10_000):
    ids = [pid for pid, _ in pieces]
    data = dict(pieces)
    pockets = 0
    while pockets < max_pockets:
        pockets += 1
        try:
            todo = link.missing(ids)
            if not todo:
                return pockets
            for pid in todo:
                link.put(pid, data[pid])
        except Dropped:
            continue  # connection gone; wait for the next pocket of signal
    raise AssertionError("never finished")


def upload_restart(link: FlakyLink, pieces, max_pockets=100_000):
    pockets = 0
    while pockets < max_pockets:
        pockets += 1
        try:
            for pid, data in pieces:
                link.put(pid, data)
            return pockets
        except Dropped:
            continue  # start again from the first piece
    raise AssertionError("never finished")


def test_resume_finishes_intact_and_wastes_little(client, phone):
    account, _, auth = phone
    pieces = make_file(n_pieces=16, size=64 * 1024)  # 1 MiB in 64 KiB pieces
    payload = sum(len(p) for _, p in pieces)

    link = FlakyLink(client, auth, drop_rate=0.3, seed=7)
    upload_resume(link, pieces)

    # Everything arrived, byte for byte.
    assert client.post("/v1/pieces/missing", json={"ids": [p for p, _ in pieces]}, headers=auth).json()["missing"] == []
    for pid, data in pieces:
        assert client.get(f"/v1/pieces/{pid}", headers=auth).content == data

    overhead = link.bytes_sent / payload
    print(f"\n[measure] resume: {link.bytes_sent} bytes sent for {payload} payload ({overhead:.2f}x), {link.requests} requests")
    # Each drop wastes at most the one piece in flight.
    assert overhead < 1.5


def test_resume_beats_restart_on_the_same_bad_link(client, settings):
    from conftest import Account

    results = {}
    for name, strategy in (("resume", upload_resume), ("restart", upload_restart)):
        acct = Account(client)
        dev = acct.add_device()
        auth = acct.login(dev)
        pieces = make_file(n_pieces=16, size=64 * 1024)
        link = FlakyLink(client, auth, drop_rate=0.15, seed=11)
        strategy(link, pieces)
        results[name] = link.bytes_sent / sum(len(p) for _, p in pieces)
    print(f"\n[measure] bytes sent per payload byte at 15% drop rate: {results}")
    assert results["resume"] < results["restart"]
