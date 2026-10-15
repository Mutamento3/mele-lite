"""记忆库页 + 用量页（10-15 Aporia：连着 Mele Host 时「记忆库」软件打不开、Me 里没有用量）。

App 的记忆库页原来只读手机里那本（LocalMemory）；连 Host 时记忆在这台服务器上，每个 TA 一本（memories.user_id = 联系人）。
这里给那页喂同一套东西：列、写、改、钉、了结、删，加星图（照 LocalMemory.graph 的样子：相近的连线、挂得多的标签成行星、
提到你名字的挂到爱心上）。「关于 TA」和日记不进列表也不进星图，跟 list_memories / graph 一样。
用量归账号（人物卡、钥匙同理），按天 × 模型，形状跟 Lite 本机的 GET usage 一样，App 用同一页看。"""
from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Body, Depends, HTTPException, Response

import memory as M
from brain import accounts, archive
from brain.settings import Settings

from .deps import Api, account, api, own_companion

router = APIRouter()


def _view(m) -> dict:
    return {"id": m.id, "kind": m.kind, "content": m.content, "tags": m.tags, "importance": m.importance,
            "resolved": m.resolved, "created_at": m.created_at.isoformat()}


def _tags(v) -> list[str] | None:
    if v is None:
        return None
    if isinstance(v, str):
        v = v.replace("，", ",").replace("、", ",").split(",")
    return [str(t).strip() for t in v if str(t).strip()]


@router.get("/companions/{cid}/memories")
async def list_memories(cid: UUID, acc: UUID = Depends(account), a: Api = Depends(api)):
    await own_companion(a, acc, cid)
    return [_view(m) for m in await M.list_memories(a.deps.pool, cid, limit=5000) if m.kind != "person"]


@router.post("/companions/{cid}/memories", status_code=201)
async def add_memory(cid: UUID, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    await own_companion(a, acc, cid)
    content = str(body.get("content") or "").strip()
    if not content:
        raise HTTPException(400, "写点什么再存")
    r = await M.remember(a.deps.pool, a.deps.embedder, cid, content, importance=int(body.get("importance") or 5),
                         tags=_tags(body.get("tags")) or [], kind="core" if body.get("pinned") else "memory",
                         now=a.deps.now())
    return _view(r.memory) | {"merged": r.merged}


@router.patch("/companions/{cid}/memories/{mid}")
async def edit_memory(cid: UUID, mid: int, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    await own_companion(a, acc, cid)
    pool = a.deps.pool
    m = await M.get(pool, cid, mid)
    if m is None or m.kind == "person":
        raise HTTPException(404, "没有这条记忆")
    if any(k in body for k in ("content", "tags", "importance")):
        imp = body.get("importance")
        m = await M.update(pool, a.deps.embedder, cid, mid, content=body.get("content"),
                           importance=int(imp) if imp is not None else None, tags=_tags(body.get("tags")),
                           now=a.deps.now()) or m
    if "pinned" in body and bool(body["pinned"]) != (m.kind == "core"):
        m = await M.pin(pool, cid, mid, bool(body["pinned"])) or m
    if "resolved" in body and bool(body["resolved"]) != m.resolved:
        m = await M.resolve(pool, cid, mid, bool(body["resolved"])) or m
    return _view(m)


@router.delete("/companions/{cid}/memories/{mid}", status_code=204)
async def delete_memory(cid: UUID, mid: int, acc: UUID = Depends(account), a: Api = Depends(api)):
    await own_companion(a, acc, cid)
    m = await M.get(a.deps.pool, cid, mid)
    if m is None or m.kind == "person" or not await M.delete(a.deps.pool, cid, mid):
        raise HTTPException(404, "没有这条记忆")
    return Response(status_code=204)


@router.get("/companions/{cid}/memories/stars")
async def stars(cid: UUID, acc: UUID = Depends(account), a: Api = Depends(api)):
    """星图要的数据，形状跟 App 里 LocalMemory.StarGraph 一一对上。"""
    await own_companion(a, acc, cid)
    pool = a.deps.pool
    mems = {m.id: m for m in await M.list_memories(pool, cid, limit=5000) if m.kind != "person"}
    g = await M.graph(pool, cid, now=a.deps.now())
    stars = [{"id": n.id, "label": n.label, "tags": mems[n.id].tags, "weight": n.weight, "content": mems[n.id].content}
             for n in g.nodes if n.id in mems]
    edges = [{"a": e.source, "b": e.target, "strength": e.strength}
             for e in g.edges if e.kind == "similar" and e.source in mems and e.target in mems]
    # 行星：一个标签挂的记忆 ≥ max(4, 总数 × 5%) 就单独成一颗星（跟本机一样）
    by_tag: dict[str, set[int]] = {}
    for m in mems.values():
        for t in m.tags:
            by_tag.setdefault(t, set()).add(m.id)
    need = max(4, -(-len(mems) * 5 // 100))
    hubs = sorted(({"label": t, "members": sorted(ids)} for t, ids in by_tag.items() if len(ids) >= need),
                  key=lambda h: -len(h["members"]))
    # 正中间的「你」：正文里提到用户名字的记忆（名字在 TA 设定里，跟账本写对方用的同一个）
    me = Settings.from_dict(await archive.get_settings(pool, cid)).user_name.strip()
    mine = [m.id for m in mems.values() if me and me.lower() in m.content.lower()]
    return {"stars": stars, "edges": edges, "hubs": hubs, "mine": mine, "user_label": me}


@router.get("/usage")
async def usage(acc: UUID = Depends(account), a: Api = Depends(api)):
    """按天 × 模型，最近的在前。大多记在账号名下；早先有几处记在联系人名下的也一起算上。"""
    pool = a.deps.pool
    ids = [acc, *await accounts.list_companions(pool, acc)]
    rows = await pool.fetch(
        """SELECT day, model, SUM(calls) AS calls, SUM(input) AS input, SUM(cache_read) AS cache_read,
                  SUM(cache_write) AS cache_write, SUM(output) AS output, SUM(cost_usd) AS cost_usd,
                  SUM(unknown_cost_calls) AS unknown
           FROM usage_daily WHERE user_id = ANY($1::uuid[])
           GROUP BY day, model ORDER BY day DESC, model""", ids)
    days: dict[str, list[dict]] = {}
    for r in rows:
        calls = int(r["calls"])
        days.setdefault(r["day"].isoformat(), []).append({
            "model": r["model"], "calls": calls, "input": int(r["input"]), "cache_read": int(r["cache_read"]),
            "cache_write": int(r["cache_write"]), "output": int(r["output"]),
            "cost": None if calls and int(r["unknown"]) >= calls else float(r["cost_usd"]),   # 全都没价目就不报钱
        })
    return [{"day": d, "models": ms} for d, ms in days.items()]
