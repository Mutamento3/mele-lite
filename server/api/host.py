"""Mele Host 命令行（10-04）。在 Host 的容器里跑：
    python -m api.host pair            # 出一张新配对码并打印（旧的没用过的作废）
    python -m api.host status          # 有没有主人、有没有没用的码
    python -m api.host warm            # 预先下载记忆模型 bge-m3（约 2.3GB），免得第一次聊天卡住
    python -m api.host memory-link     # 接上 Host 自带的记忆库（mele-host memory on 调；钥匙从 MELE_MEMORY_TOKEN 来）
    python -m api.host memory-unlink   # 断开（mele-host memory off 调）

配对码只在出的那一刻看得到原文（库里只存哈希），所以 `pair` 每次都出一张新的。"""
from __future__ import annotations

import argparse
import asyncio
import os
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Mapping
from urllib.parse import quote

from brain import host


@dataclass
class Flags:
    host: bool
    rerank: bool
    public_url: str


def flags(environ: Mapping[str, str]) -> Flags:
    return Flags(host=environ.get("NEWAPP_HOST", "0") == "1",
                 rerank=environ.get("NEWAPP_RERANK", "0") == "1",
                 public_url=environ.get("NEWAPP_PUBLIC_URL", "").strip().rstrip("/"))


def pairing_link(public_url: str, code: str) -> str:
    return f"mele://host?u={quote(public_url, safe='')}&c={code}"


async def ensure_code(pool, *, secret: str) -> str | None:
    """新服务器（没主人、也没码）出一张；其他情况不动。返回新码或 None。"""
    if await host.owner(pool) is not None or await host.has_code(pool):
        return None
    return await host.new_code(pool, secret=secret, now=datetime.now(timezone.utc))


def announce(public_url: str, code: str) -> None:
    print("\n=== Mele Host 配对码 ===", flush=True)
    print(f"配对码：{code}", flush=True)
    if public_url:
        print(f"地址：{public_url}", flush=True)
        print(f"配对链接（App 扫二维码用）：{pairing_link(public_url, code)}", flush=True)
    print("在 Mele Lite → Me → Mele Host 里扫码或手动输入。用一次就作废。\n", flush=True)


async def _main(args) -> int:
    if args.cmd == "warm":
        from memory.embed import BgeM3Embedder
        print("下载 / 加载记忆模型 bge-m3（第一次约 2.3GB）……", flush=True)
        BgeM3Embedder().embed(["你好"])
        print("好了。", flush=True)
        return 0
    dsn, secret = os.environ.get("NEWAPP_DSN", ""), os.environ.get("NEWAPP_SECRET", "")
    if not dsn or not secret:
        print("缺 NEWAPP_DSN / NEWAPP_SECRET（在 Host 的容器里跑：mele-host pair）", file=sys.stderr)
        return 2
    import memory as M
    from brain import archive
    await M.apply_schema(dsn)
    await archive.apply_brain_schema(dsn)
    pool = await M.create_pool(dsn)
    try:
        if args.cmd in ("memory-link", "memory-unlink"):
            return await _memory(args.cmd, pool)
        if args.cmd == "status":
            print(f"版本：{os.environ.get('NEWAPP_BUILD', '').strip() or '（本机，没打版本）'}；"
                  f"主人：{'已配对' if await host.owner(pool) else '还没有'}；"
                  f"没用的配对码：{'有' if await host.has_code(pool) else '没有'}")
            return 0
        code = await host.new_code(pool, secret=secret, now=datetime.now(timezone.utc))
        announce(flags(os.environ).public_url, code)
        return 0
    finally:
        await pool.close()


async def _memory(cmd: str, pool) -> int:
    from brain import auth, mcp
    acc = await host.owner(pool)
    if acc is None:
        print("还没配对：先在 App 里配对（mele-host pair），再跑一次 mele-host memory on", file=sys.stderr)
        return 1
    if cmd == "memory-unlink":
        print("断开了记忆库" if await mcp.unlink_bundled_memory(pool, acc) else "本来就没接")
        return 0
    token, key = os.environ.get("MELE_MEMORY_TOKEN", "").strip(), os.environ.get("NEWAPP_MASTER_KEY", "")
    if not token or not key:
        print("缺 MELE_MEMORY_TOKEN / NEWAPP_MASTER_KEY", file=sys.stderr)
        return 2
    sv, ticked = await mcp.link_bundled_memory(pool, auth.KeyBox(key), acc, token, now=datetime.now(timezone.utc))
    try:
        found = await mcp.tools(sv, fresh=True)
    except mcp.MCPError as e:
        print(f"接上了，但试的时候没通：{mcp.explain(e, sv.url)}", file=sys.stderr)
        return 1
    print(f"✅ 记忆库接好了（{len(found)} 个工具）。" + (f"已经给 {ticked} 个 TA 勾上；" if ticked else "")
          + "以后新加的 TA 在 TA 设定 → MCP 服务里勾「记忆库」。")
    return 0


if __name__ == "__main__":
    ap = argparse.ArgumentParser(prog="python -m api.host")
    ap.add_argument("cmd", choices=["pair", "status", "warm", "memory-link", "memory-unlink"])
    sys.exit(asyncio.run(_main(ap.parse_args())))
