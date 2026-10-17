"""让别的 AI 连上 TA 的记忆（10-16 Aporia：「OB 也是跑在服务器上，同时连官方和之前自用的 App」——一份记忆、几家一起连）。

Host 自己开一个 MCP 地址，每个 TA 一个：https://<Host>/mcp/memory/<钥匙>。Claude 桌面版 / claude.ai 的自定义连接器、
别的会 MCP 的软件填这个地址就连上 TA 正在用的同一本记忆（memories.user_id = 联系人），不用另装记忆库。
钥匙放在地址里（很多连接器填不了请求头），也认 Authorization: Bearer <钥匙> 打 /mcp/memory。
库里存 sha256（查）+ 主密钥加密的原文（App 里随时能再看）；换一把 = 旧地址立刻作废。

MCP 只做 streamable HTTP 的 JSON 回法（不开 SSE）：initialize / ping / tools/list / tools/call，通知回 202。
工具说给外面的 AI 听，用「the user」：remember / search / list_memories / update / forget / pin / resolve。"""
from __future__ import annotations

import hashlib
import json
import secrets
from datetime import datetime
from uuid import UUID

import memory as M

PROTOCOL = "2025-06-18"
MAX_CONTENT = 2000


def _hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


async def get_token(pool, box, cid: UUID) -> str | None:
    row = await pool.fetchrow("SELECT secret FROM memory_links WHERE companion_id = $1", cid)
    return box.unlock(row["secret"]) if row else None


async def new_token(pool, box, cid: UUID, *, now: datetime) -> str:
    """生成一把（有旧的就换掉，旧地址作废）"""
    token = secrets.token_urlsafe(24)
    await pool.execute("""INSERT INTO memory_links (companion_id, token_hash, secret, created_at) VALUES ($1, $2, $3, $4)
                          ON CONFLICT (companion_id) DO UPDATE SET token_hash = $2, secret = $3, created_at = $4""",
                       cid, _hash(token), box.lock(token), now)
    return token


async def revoke(pool, cid: UUID) -> bool:
    return await pool.fetchval("DELETE FROM memory_links WHERE companion_id = $1 RETURNING companion_id", cid) is not None


async def companion_for(pool, token: str) -> UUID | None:
    if not token:
        return None
    return await pool.fetchval("SELECT companion_id FROM memory_links WHERE token_hash = $1", _hash(token))


# ── MCP ──

def _obj(props: dict, required: list[str]) -> dict:
    return {"type": "object", "properties": props, "required": required}


_ID = {"type": "integer", "description": "Memory id (the #number shown by search / list_memories)"}
TOOLS = [
    {"name": "remember", "description": "Save something worth remembering about the user or your shared life "
     "(a correction, something you agreed on, a big event). One or two clear sentences. "
     "This is the same memory the user's companion in Mele uses.",
     "inputSchema": _obj({"content": {"type": "string"},
                          "importance": {"type": "integer", "minimum": 1, "maximum": 10},
                          "tags": {"type": "array", "items": {"type": "string"}}}, ["content"])},
    {"name": "search", "description": "Search the memory by meaning and keywords. Use it before answering when the "
     "user mentions a name, place, date or asks \"do you remember\".",
     "inputSchema": _obj({"query": {"type": "string"},
                          "limit": {"type": "integer", "minimum": 1, "maximum": 20}}, ["query"])},
    {"name": "list_memories", "description": "List the most recent memories (newest first).",
     "inputSchema": _obj({"limit": {"type": "integer", "minimum": 1, "maximum": 100}}, [])},
    {"name": "update", "description": "Rewrite a memory, or change its tags / importance.",
     "inputSchema": _obj({"id": _ID, "content": {"type": "string"},
                          "tags": {"type": "array", "items": {"type": "string"}},
                          "importance": {"type": "integer", "minimum": 1, "maximum": 10}}, ["id"])},
    {"name": "forget", "description": "Delete a memory that is wrong or no longer wanted.",
     "inputSchema": _obj({"id": _ID}, ["id"])},
    {"name": "pin", "description": "Pin (or unpin) a memory as a core one that should always be kept in mind.",
     "inputSchema": _obj({"id": _ID, "pinned": {"type": "boolean"}}, ["id"])},
    {"name": "resolve", "description": "Mark a memory as resolved (a worry that's settled, a plan that's done), or reopen it.",
     "inputSchema": _obj({"id": _ID, "resolved": {"type": "boolean"}}, ["id"])},
]


def _line(m) -> str:
    flags = ("📌" if m.kind == "core" else "") + ("✓" if m.resolved else "")
    tags = f" #{' #'.join(m.tags)}" if m.tags else ""
    return f"#{m.id} [{m.created_at:%Y-%m-%d}]{flags} {m.content}{tags}"


async def _own(pool, cid: UUID, mid) -> object | None:
    try:
        m = await M.get(pool, cid, int(mid))
    except (TypeError, ValueError):
        return None
    return None if m is None or m.kind == "person" else m


async def call_tool(pool, embedder, cid: UUID, name: str, a: dict, *, now: datetime) -> tuple[str, bool]:
    """(给它看的话, 是不是出错)"""
    if name == "remember":
        content = str(a.get("content") or "").strip()[:MAX_CONTENT]
        if not content:
            return "content is empty", True
        tags = [str(t).strip() for t in a.get("tags") or [] if str(t).strip()][:10]
        r = await M.remember(pool, embedder, cid, content, importance=max(1, min(10, int(a.get("importance") or 5))),
                             tags=tags, kind="memory", now=now)
        return (f"Merged into #{r.memory.id}" if r.merged else f"Saved as #{r.memory.id}"), False
    if name == "search":
        q = str(a.get("query") or "").strip()
        if not q:
            return "query is empty", True
        hits = await M.search(pool, embedder, cid, q, limit=max(1, min(20, int(a.get("limit") or 5))), now=now)
        hits = [h for h in hits if h.memory.kind != "person"]
        return ("\n".join(_line(h.memory) for h in hits) if hits else "Nothing found."), False
    if name == "list_memories":
        mems = [m for m in await M.list_memories(pool, cid, limit=max(1, min(100, int(a.get("limit") or 30))))
                if m.kind != "person"]
        return ("\n".join(_line(m) for m in mems) if mems else "No memories yet."), False
    m = await _own(pool, cid, a.get("id"))
    if m is None:
        return "No memory with that id.", True
    if name == "update":
        content = str(a["content"]).strip()[:MAX_CONTENT] if a.get("content") else None
        tags = [str(t).strip() for t in a["tags"] if str(t).strip()][:10] if isinstance(a.get("tags"), list) else None
        imp = max(1, min(10, int(a["importance"]))) if a.get("importance") is not None else None
        m = await M.update(pool, embedder, cid, m.id, content=content, importance=imp, tags=tags, now=now) or m
        return f"Updated: {_line(m)}", False
    if name == "forget":
        await M.delete(pool, cid, m.id)
        return f"Deleted #{m.id}", False
    if name == "pin":
        m = await M.pin(pool, cid, m.id, bool(a.get("pinned", True))) or m
        return f"{'Pinned' if m.kind == 'core' else 'Unpinned'} #{m.id}", False
    if name == "resolve":
        m = await M.resolve(pool, cid, m.id, bool(a.get("resolved", True))) or m
        return f"{'Resolved' if m.resolved else 'Reopened'} #{m.id}", False
    return f"Unknown tool: {name}", True


async def handle(pool, embedder, cid: UUID, msg: dict, *, now: datetime, name: str) -> dict | None:
    """一条 JSON-RPC → 回话（通知回 None）"""
    method, mid = msg.get("method"), msg.get("id")
    if mid is None:
        return None
    def ok(result):
        return {"jsonrpc": "2.0", "id": mid, "result": result}
    if method == "initialize":
        asked = str((msg.get("params") or {}).get("protocolVersion") or PROTOCOL)
        return ok({"protocolVersion": asked, "capabilities": {"tools": {}},
                   "serverInfo": {"name": f"Mele memory · {name}", "version": "1"},
                   "instructions": f"This is the long-term memory of {name}, the user's companion in Mele. "
                                   "Search it before answering about the past; remember what's worth keeping."})
    if method == "ping":
        return ok({})
    if method == "tools/list":
        return ok({"tools": TOOLS})
    if method == "tools/call":
        p = msg.get("params") or {}
        args = p.get("arguments") if isinstance(p.get("arguments"), dict) else {}
        try:
            text, err = await call_tool(pool, embedder, cid, str(p.get("name") or ""), args, now=now)
        except (TypeError, ValueError, KeyError) as e:
            text, err = f"Bad arguments: {e}", True
        return ok({"content": [{"type": "text", "text": text}], "isError": err})
    return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"Method not found: {method}"}}


def parse(body: bytes) -> list[dict] | dict | None:
    try:
        v = json.loads(body or b"null")
    except ValueError:
        return None
    return v if isinstance(v, (list, dict)) else None
