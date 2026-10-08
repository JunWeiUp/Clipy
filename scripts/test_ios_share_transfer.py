#!/usr/bin/env python3
"""Native share-client wire regression on macOS; requires Python cryptography.

Runs the production Swift sender against an independent v3 receiver. The large
case streams exactly 1 GiB through AES-GCM while retaining only one chunk.
No user app, LAN scan, history or Downloads directory is touched.
"""
import hashlib
import json
import os
import re
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import threading
import time
import uuid

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

ROOT = Path(__file__).resolve().parents[1]
KEY = AESGCM(hashlib.sha256(b"ClipySyncSecret2026").digest())
LIMIT = 1024**3
CHUNK = 1024**2


def exact(connection, length):
    result = bytearray()
    while len(result) < length:
        data = connection.recv(length - len(result))
        if not data:
            raise EOFError()
        result.extend(data)
    return result


def receive(connection):
    length = struct.unpack(">I", exact(connection, 4))[0]
    assert 0 < length <= 2 * CHUNK
    frame = json.loads(exact(connection, length))
    assert frame["v"] == 3
    return frame


def opened(frame):
    import base64
    data = base64.b64decode(frame["payload"])
    return KEY.decrypt(data[:12], data[12:], None)


def send(connection, peer_id, kind, payload=None):
    import base64
    frame = dict(v=3, type=kind, peerId=peer_id, name="Fixture", port=5566,
                 msgId=str(uuid.uuid4()), ts=time.time())
    if payload is not None:
        nonce = os.urandom(12)
        frame["payload"] = base64.b64encode(nonce + KEY.encrypt(nonce, json.dumps(payload).encode(), None)).decode()
    body = json.dumps(frame).encode()
    connection.sendall(struct.pack(">I", len(body)) + body)


def exercise(binary, source, mode="ok", expected="acknowledged"):
    peer_id = str(uuid.uuid4())
    failures = []
    verified = []
    server = socket.socket()
    server.bind(("127.0.0.1", 0))
    server.listen(1)
    server.settimeout(15)
    port = server.getsockname()[1]

    def receiver():
        try:
            with server.accept()[0] as conn:
                conn.settimeout(120)
                assert receive(conn)["type"] == "hello"
                if mode == "invalid":
                    conn.sendall(struct.pack(">I", 2 * CHUNK + 1))
                    return
                send(conn, str(uuid.uuid4()) if mode == "wrong" else peer_id, "hello")
                assert receive(conn)["type"] == "welcome"
                if mode == "wrong":
                    return
                if mode == "cancel":
                    time.sleep(1)
                    return
                send(conn, peer_id, "ping")
                meta = None
                pong = False
                while meta is None:
                    frame = receive(conn)
                    if frame["type"] == "pong":
                        pong = True
                    else:
                        assert frame["type"] == "file.meta"
                        meta = json.loads(opened(frame))
                assert meta["size"] == source.stat().st_size
                assert meta["chunks"] == (meta["size"] + CHUNK - 1) // CHUNK
                assert meta["chunkSize"] == CHUNK
                if mode == "reject":
                    send(conn, peer_id, "file.ack", dict(fileId=meta["fileId"], ok=False, error="tooLarge"))
                    # Keep the socket alive until the sender observes the explicit reject.
                    while conn.recv(65536):
                        pass
                    return
                if mode == "disconnect":
                    return
                digest = hashlib.sha256()
                count = 0
                for index in range(meta["chunks"]):
                    frame = receive(conn)
                    if frame["type"] == "pong":
                        pong = True
                        frame = receive(conn)
                    assert frame["type"] == "file.chunk" and frame["msgId"] == meta["fileId"]
                    data = opened(frame)
                    assert struct.unpack(">I", data[:4])[0] == index
                    digest.update(data[4:])
                    count += len(data) - 4
                assert count == meta["size"] and digest.hexdigest() == meta["sha256"]
                if not pong:
                    assert receive(conn)["type"] == "pong"
                verified.append(count)
                send(conn, peer_id, "file.ack", dict(fileId=meta["fileId"], ok=True))
        except BaseException as error:
            failures.append(error)
        finally:
            server.close()

    thread = threading.Thread(target=receiver, daemon=True)
    thread.start()
    env = os.environ.copy()
    if mode == "cancel":
        env["CLIPY_TEST_CANCEL_MS"] = "500"
    command = [str(binary), "127.0.0.1", str(port), peer_id, str(source)]
    if source.stat().st_size == LIMIT:
        command = ["/usr/bin/time", "-l"] + command
    result = subprocess.run(command,
                            capture_output=True, text=True, timeout=180, env=env)
    thread.join(10)
    assert not thread.is_alive(), "receiver was not released"
    assert not failures, failures
    assert expected in result.stdout, (mode, result.stdout, result.stderr)
    assert result.returncode == (0 if mode == "ok" else 2)
    if source.stat().st_size == LIMIT:
        rss = int(re.search(r"(\d+)\s+maximum resident set size", result.stderr)[1])
        assert rss < 128 * CHUNK, f"unbounded sender memory: {rss}"
        print(f"1 GiB sender peak RSS: {rss / CHUNK:.1f} MiB")
    print(f"{mode}: {source.stat().st_size} bytes; {result.stdout.strip()}")
    return verified


def main():
    with tempfile.TemporaryDirectory(prefix="clipy-ios-share-test-") as directory:
        temp = Path(directory)
        binary = temp / "share-probe"
        subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library",
                        str(ROOT / "clipy_android/ios/Shared/ShareTransferClient.swift"),
                        str(ROOT / "clipy_android/ios/Tests/ShareTransferProbe.swift"),
                        "-o", str(binary)], check=True)
        source = temp / "fixture.bin"
        source.write_bytes(os.urandom(CHUNK + 17))
        exercise(binary, source)
        exercise(binary, source, "reject", "rejected")
        exercise(binary, source, "disconnect", "connection")
        exercise(binary, source, "wrong", "wrongDevice")
        exercise(binary, source, "invalid", "invalidFrame")
        exercise(binary, source, "cancel", "cancelled")
        source.write_bytes(b"")
        exercise(binary, source)
        with source.open("wb") as file:
            file.truncate(LIMIT)
        assert exercise(binary, source) == [LIMIT]
        with source.open("wb") as file:
            file.truncate(LIMIT + 1)
        rejected = subprocess.run([str(binary), "127.0.0.1", "1", str(uuid.uuid4()), str(source)],
                                  capture_output=True, text=True, timeout=5)
        assert rejected.returncode == 2 and "tooLarge" in rejected.stdout
        print("1 GiB + 1 byte rejected before hashing/connecting; all share transfer regressions passed")


if __name__ == "__main__":
    main()
