#!/usr/bin/env python3
"""E2E: Move-to atomicity + no-auto-open, against the LIVE SwiftMind app.

Drives the real AppModel.transferMap path through the agent bridge
(method `transfer`), reproducing exactly the reported bug's preconditions:
the source map is OPEN and ACTIVE when the move happens, and it carries an
assets folder.

Preconditions:
  - SwiftMind running WITH the agent bridge reachable at a path this
    script can read. The container default is unreadable without Full
    Disk Access, so launch the app with the override:
      open SwiftMind.app --args --agent-bridge-dir ~/Documents/SwiftMind
    (unsandboxed/dev builds can use the plain ~/Library/SwiftMind default)
  - cfprefsd / tccd healthy (a pending consent dialog on screen wedges
    bookmarkData() inside the app AND container reads outside it — if
    every command in this script hangs, click the dialog first).

Usage: python3 scripts/e2e_move_atomicity.py [bridge-dir]
"""
import json
import shutil
import socket
import struct
import sys
import time
from pathlib import Path

BRIDGE = Path(sys.argv[1]).expanduser() if len(sys.argv) > 1 else Path.home() / "Library/SwiftMind"


def call(method, params=None, timeout=30):
    token = (BRIDGE / "agent.token").read_text().strip()
    req = {"id": method, "method": method, "token": token, "params": params or {}}
    body = json.dumps(req).encode()
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(str(BRIDGE / "agent.sock"))
    s.sendall(struct.pack(">I", len(body)) + body)
    hdr = b""
    while len(hdr) < 4:
        chunk = s.recv(4 - len(hdr))
        if not chunk:
            raise RuntimeError("connection closed mid-header")
        hdr += chunk
    (n,) = struct.unpack(">I", hdr)
    data = b""
    while len(data) < n:
        chunk = s.recv(n - len(data))
        if not chunk:
            raise RuntimeError("connection closed mid-body")
        data += chunk
    s.close()
    return json.loads(data)


def main():
    checks = []

    def check(name, cond, detail=""):
        checks.append(cond)
        print(("  ✓ " if cond else "  ✗ ") + name + (f"  [{detail}]" if detail and not cond else ""))

    print("== E2E: Move to 原子性 + 不自动打开（真实 app）==")

    r = call("new", {"title": "E2E Move A"})
    if not r.get("ok"):
        print("new failed:", r)
        return 1
    a_html = Path(r["result"]["path"])
    a_assets = a_html.parent / "E2E Move A.swiftmind.assets"
    check("new 创建并打开 A", a_html.exists())

    sess = call("session")["result"]
    check("A 是当前活动文档（复活 bug 的前置条件）", sess.get("mapPath") == str(a_html), str(sess.get("mapPath")))

    a_assets.mkdir(exist_ok=True)
    (a_assets / "img.png").write_bytes(b"\x89PNG-fake")
    check("A assets 就位", (a_assets / "img.png").exists())

    r = call("transfer", {"source": str(a_html), "directory": str(a_html.parent),
                          "baseName": "E2E Move B", "move": True})
    check("transfer 调用成功", r.get("ok") is True, json.dumps(r)[:150])
    time.sleep(1.5)  # a resurrecting write-back would land inside this window

    b_html = a_html.parent / "E2E Move B.swiftmind.html"
    b_assets = a_html.parent / "E2E Move B.swiftmind.assets"

    check("B.html 存在", b_html.exists())
    check("B assets 存在且图片随迁", (b_assets / "img.png").exists())
    check("★ A.html 未复活（原 bug）", not a_html.exists())
    check("★ A assets 已随迁消失（原 bug）", not a_assets.exists())

    sess = call("session")["result"]
    check("★ 未自动打开 B", sess.get("mapPath") != str(b_html), f"active={sess.get('mapPath')}")

    for p in [b_html, b_assets, a_html, a_assets]:
        if p.is_dir():
            shutil.rmtree(p, ignore_errors=True)
        elif p.exists():
            p.unlink()

    passed = sum(checks)
    print(f"\n{passed}/{len(checks)} 通过" + ("" if passed == len(checks) else "  —— 有失败！"))
    return 0 if passed == len(checks) else 1


if __name__ == "__main__":
    sys.exit(main())
