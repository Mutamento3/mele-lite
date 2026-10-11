"""群聊接口（10-11，跟 Lite 小管家 groups/… 一样的样子，App 不分 Lite / Host）。"""
from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Body, Depends, File, HTTPException, Response, UploadFile
from fastapi.responses import FileResponse

from brain import archive, attachments, avatars, groups
from llm.catalog import cost

from .deps import Api, account, api

router = APIRouter()


async def _group(a: Api, acc: UUID, gid: UUID):
    g = await groups.row(a.deps.pool, acc, gid)
    if g is None:
        raise HTTPException(404, "没有这个群")
    return g


@router.get("/groups")
async def list_groups(acc: UUID = Depends(account), a: Api = Depends(api)):
    return [await groups.out(a.deps.pool, g) for g in await groups.list_for(a.deps.pool, acc)]


@router.post("/groups", status_code=201)
async def create_group(body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    try:
        ids = [UUID(str(x)) for x in body.get("members") or []]
        g = await groups.create(a.deps.pool, acc, str(body.get("name") or ""), ids, a.deps.now())
    except ValueError as e:
        raise HTTPException(400, str(e) if "TA" in str(e) else "成员编号不对") from None
    return await groups.out(a.deps.pool, g)


@router.get("/groups/{gid}")
async def get_group(gid: UUID, acc: UUID = Depends(account), a: Api = Depends(api)):
    return await groups.out(a.deps.pool, await _group(a, acc, gid))


@router.patch("/groups/{gid}")
async def patch_group(gid: UUID, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    await _group(a, acc, gid)
    return await groups.out(a.deps.pool, await groups.patch(a.deps.pool, acc, gid, body))


@router.delete("/groups/{gid}", status_code=204)
async def delete_group(gid: UUID, acc: UUID = Depends(account), a: Api = Depends(api)):
    await _group(a, acc, gid)
    a.rooms.drop(gid)
    await attachments.wipe(a.deps.pool, "conversation_id", gid)
    await archive.wipe(a.deps.pool, gid)
    await a.deps.pool.execute("DELETE FROM memory_edits WHERE conversation_id = $1", gid)
    from uuid import uuid5                       # 群里按「群 × TA」存的状态也一起删
    for c in await a.deps.pool.fetch("SELECT companion_id FROM group_members WHERE conversation_id = $1", gid):
        await archive.wipe(a.deps.pool, uuid5(gid, str(c["companion_id"])))
    await a.deps.pool.execute("DELETE FROM conversations WHERE id = $1", gid)
    avatars.remove(a.cfg.files_dir, gid)
    return Response(status_code=204)


@router.post("/groups/{gid}/members")
async def add_member(gid: UUID, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    await _group(a, acc, gid)
    try:
        await groups.add_member(a.deps.pool, acc, gid, UUID(str(body.get("companion"))), a.deps.now())
    except (LookupError, ValueError):
        raise HTTPException(404, "没有这个联系人") from None
    return await groups.out(a.deps.pool, await _group(a, acc, gid))


@router.delete("/groups/{gid}/members/{cid}")
async def kick_member(gid: UUID, cid: UUID, acc: UUID = Depends(account), a: Api = Depends(api)):
    await _group(a, acc, gid)
    try:
        await groups.kick(a.deps.pool, gid, cid, a.deps.now())
    except ValueError as e:
        raise HTTPException(400, str(e)) from None
    return await groups.out(a.deps.pool, await _group(a, acc, gid))


@router.put("/groups/{gid}/avatar")
async def put_avatar(gid: UUID, file: UploadFile = File(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    await _group(a, acc, gid)
    try:
        avatars.save(a.cfg.files_dir, gid, await file.read(avatars.MAX_BYTES + 1))
    except avatars.AvatarError as e:
        raise HTTPException(400, str(e)) from e
    await groups.bump_avatar(a.deps.pool, gid)
    return await groups.out(a.deps.pool, await _group(a, acc, gid))


@router.get("/groups/{gid}/avatar")
async def get_avatar(gid: UUID, acc: UUID = Depends(account), a: Api = Depends(api)):
    await _group(a, acc, gid)
    p = avatars.path(a.cfg.files_dir, gid)
    if not p.exists():
        raise HTTPException(404, "还没有头像")
    return FileResponse(p, media_type="image/jpeg")


@router.delete("/groups/{gid}/avatar")
async def delete_avatar(gid: UUID, acc: UUID = Depends(account), a: Api = Depends(api)):
    """恢复成员头像拼图"""
    await _group(a, acc, gid)
    avatars.remove(a.cfg.files_dir, gid)
    await groups.bump_avatar(a.deps.pool, gid, reset=True)
    return await groups.out(a.deps.pool, await _group(a, acc, gid))


@router.get("/groups/{gid}/estimate")
async def estimate(gid: UUID, acc: UUID = Depends(account), a: Api = Depends(api)):
    """「这个群大概一句多少钱」：每个成员判断一次（约 1500 token 进、几个出）+ 平均两个 TA 开口（各约 8000 进、300 出）"""
    from llm.types import Usage
    from brain.scope import Scope
    from brain.turn import resolve_route
    await _group(a, acc, gid)
    judge, replies, known = 0.0, [], True
    for c in await groups.members(a.deps.pool, gid):
        try:
            model = (await resolve_route(a.deps.keys, Scope(acc, c, gid))).chat_model
        except Exception:
            known = False
            continue
        j, r = cost(Usage(input=1500, output=5), model), cost(Usage(input=8000, output=300), model)
        if j is None or r is None:
            known = False
            continue
        judge += j
        replies.append(r)
    avg = sum(replies) / len(replies) if replies else 0.0
    return {"per_message_usd": judge + avg * min(2, len(replies)), "known": known and bool(replies)}
