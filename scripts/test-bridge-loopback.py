#!/usr/bin/env python3
"""Minimal fake AgentBridge for CLI loopback tests (stdlib only).

Mirrors the app-side wire protocol from Apps/SwiftMindMac/SwiftMindMac/AgentBridge.swift:
one request per connection, 4-byte big-endian length-prefixed JSON frames.

Usage: test-bridge-loopback.py <bridge-dir>
Writes <bridge-dir>/agent.token (fixed token) and serves <bridge-dir>/agent.sock
until killed. Replies ok:true with {"loopback": true, "method": <method>} for the
correct token, ok:false unauthorized otherwise.
"""
import atexit
import json
import os
import socket
import struct
import sys

TOKEN = "loopback-test-token"


def read_fully(conn, count):
    data = b""
    while len(data) < count:
        chunk = conn.recv(min(65536, count - len(data)))
        if not chunk:
            return None
        data += chunk
    return data


def main():
    if len(sys.argv) != 2:
        print("usage: test-bridge-loopback.py <bridge-dir>", file=sys.stderr)
        sys.exit(2)
    bridge_dir = sys.argv[1]
    os.makedirs(bridge_dir, mode=0o700, exist_ok=True)
    os.chmod(bridge_dir, 0o700)

    token_path = os.path.join(bridge_dir, "agent.token")
    with open(token_path, "w") as f:
        f.write(TOKEN)
    os.chmod(token_path, 0o600)

    sock_path = os.path.join(bridge_dir, "agent.sock")
    try:
        os.unlink(sock_path)
    except FileNotFoundError:
        pass

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(sock_path)
    server.listen(8)

    def cleanup():
        server.close()
        for path in (sock_path, token_path):
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass

    atexit.register(cleanup)

    while True:
        conn, _ = server.accept()
        try:
            header = read_fully(conn, 4)
            if header is None:
                continue
            (length,) = struct.unpack(">I", header)
            if length == 0 or length > 4 * 1024 * 1024:
                continue
            body = read_fully(conn, length)
            if body is None:
                continue
            try:
                request = json.loads(body)
            except ValueError:
                continue
            req_id = request.get("id")
            if request.get("token") != TOKEN:
                reply = {
                    "id": req_id,
                    "ok": False,
                    "error": {"code": "unauthorized", "message": "missing or wrong token"},
                }
            else:
                reply = {
                    "id": req_id,
                    "ok": True,
                    "result": {"loopback": True, "method": request.get("method")},
                }
            payload = json.dumps(reply).encode("utf-8")
            conn.sendall(struct.pack(">I", len(payload)) + payload)
        finally:
            conn.close()


if __name__ == "__main__":
    main()
