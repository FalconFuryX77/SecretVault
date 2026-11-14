"""A TCP proxy that behaves like a bad mobile connection.

    python flaky_proxy.py --listen 18081 --upstream 127.0.0.1:8080 \
        --cut-rate 0.2 --kbps 384 --up 20 --down 60 --seed 1

* --cut-rate: chance that a connection is cut after a random number of bytes
  (mid-request or mid-response), the way a mobile link drops.
* --kbps: bandwidth cap per direction (0 = unlimited).
* --up/--down: "pockets of signal". The link works for --up seconds, then
  refuses and cuts everything for --down seconds, repeating (0 = always up).

Counters are printed on exit and written to --stats if given. A no-Docker
stand-in for Toxiproxy, used by packages/sync_core/test/e2e_test.dart.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import random
import signal
import time

stats = {"connections": 0, "cut": 0, "refused": 0, "bytes_up": 0, "bytes_down": 0}


def link_is_up(args, t0: float) -> bool:
    if args.down <= 0:
        return True
    phase = (time.monotonic() - t0) % (args.up + args.down)
    return phase < args.up


async def pipe(reader, writer, budget: list[int], direction: str, args, t0: float):
    try:
        while True:
            data = await reader.read(16 * 1024)
            if not data:
                break
            if not link_is_up(args, t0):
                break
            if budget[0] >= 0 and len(data) >= budget[0]:
                writer.write(data[: budget[0]])
                stats["bytes_" + direction] += budget[0]
                await writer.drain()
                stats["cut"] += 1
                break
            if budget[0] >= 0:
                budget[0] -= len(data)
            if args.kbps > 0:
                await asyncio.sleep(len(data) * 8 / (args.kbps * 1000))
            writer.write(data)
            stats["bytes_" + direction] += len(data)
            await writer.drain()
    except (ConnectionError, asyncio.IncompleteReadError):
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def handle(client_r, client_w, args, rng: random.Random, t0: float):
    stats["connections"] += 1
    if not link_is_up(args, t0):
        stats["refused"] += 1
        client_w.close()
        return
    host, port = args.upstream.rsplit(":", 1)
    try:
        up_r, up_w = await asyncio.open_connection(host, int(port))
    except OSError:
        client_w.close()
        return
    # Shared byte budget across both directions: -1 = never cut.
    budget = [rng.randint(0, args.max_cut_bytes) if rng.random() < args.cut_rate else -1]
    tasks = [
        asyncio.create_task(pipe(client_r, up_w, budget, "up", args, t0)),
        asyncio.create_task(pipe(up_r, client_w, budget, "down", args, t0)),
    ]
    # When either direction ends (cut, link down, or a real close), drop the
    # whole connection, like a mobile link going away. Leaving the other half
    # open would make the client wait for its timeout instead of failing fast.
    await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    for w in (client_w, up_w):
        try:
            w.close()
        except Exception:
            pass
    for t in tasks:
        t.cancel()


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", type=int, required=True)
    ap.add_argument("--upstream", required=True)
    ap.add_argument("--cut-rate", type=float, default=0.0)
    ap.add_argument("--max-cut-bytes", type=int, default=600_000)
    ap.add_argument("--kbps", type=float, default=0)
    ap.add_argument("--up", type=float, default=0)
    ap.add_argument("--down", type=float, default=0)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--stats")
    args = ap.parse_args()
    rng = random.Random(args.seed)
    t0 = time.monotonic()
    server = await asyncio.start_server(lambda r, w: handle(r, w, args, rng, t0), "127.0.0.1", args.listen)
    print(f"flaky proxy on {args.listen} -> {args.upstream}", flush=True)
    stop = asyncio.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            asyncio.get_running_loop().add_signal_handler(sig, stop.set)
        except NotImplementedError:  # Windows
            pass
    async with server:
        try:
            await stop.wait()
        finally:
            if args.stats:
                with open(args.stats, "w") as f:
                    json.dump(stats, f)
            print(json.dumps(stats), flush=True)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
