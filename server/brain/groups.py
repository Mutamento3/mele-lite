"""群聊的存储（10-11，跟 Lite 的 ios/Lite/LocalGroups.swift 同一套）：建群、改名、加人踢人、捞别的房间。

群是一种窗口（conversations.kind = 'group'，companion_id 空），成员在 group_members（left_at 不空 = 以前的成员）。
「一段脑子」：TA 在哪说话，都从它待过的别的房间捞最近 N 条——它在 / 待过的群（被踢的只到踢出那刻）+ 它最近的私聊窗口。
别的 TA 的私聊、无痕都不捞；心声和思考不带。"""
from __future__ import annotations

import uuid
from datetime import datetime, timedelta
from uuid import UUID

from . import archive
from .persona import Persona
from .timeline import Item, group_room, private_room

DEFAULT_ROUNDS = 6
HISTORY_ON_JOIN = 30


async def name_of(pool, companion: UUID, lang: str = "zh") -> str:
    return Persona.from_dict(await archive.get_persona(pool, companion), lang).name or "TA"


async def is_group(pool, conv: UUID) -> bool:
    return (await pool.fetchval("SELECT kind FROM conversations WHERE id = $1", conv)) == "group"


async def row(pool, account: UUID, gid: UUID):
    return await pool.fetchrow("SELECT * FROM conversations WHERE id = $1 AND account_id = $2 AND kind = 'group'",
                               gid, account)


async def members(pool, gid: UUID) -> list[UUID]:
    """现在的成员，按拉进来的先后"""
    return [r["companion_id"] for r in await pool.fetch(
        "SELECT companion_id FROM group_members WHERE conversation_id = $1 AND left_at IS NULL ORDER BY position, joined_at", gid)]


async def membership(pool, gid: UUID, companion: UUID):
    return await pool.fetchrow("SELECT joined_at, left_at FROM group_members WHERE conversation_id = $1 AND companion_id = $2",
                               gid, companion)


async def display_name(pool, g) -> str:
    n = (g["name"] or "").strip()
    if n:
        return n
    return "、".join([await name_of(pool, c) for c in await members(pool, g["id"])])


async def out(pool, g) -> dict:
    """接口里的样子（跟 Lite 的 groupOut 一样的字段）"""
    gid = g["id"]
    last = await pool.fetchrow("SELECT role, text, speaker_name FROM chat_messages WHERE user_id = $1 AND role <> 'wake' "
                               "ORDER BY id DESC LIMIT 1", gid)
    preview = (last["text"] if last else "")[:40]
    if last and last["role"] == "assistant" and last["speaker_name"]:
        preview = f"{last['speaker_name']}：{preview}"
    former = [r["companion_id"] for r in await pool.fetch(
        "SELECT companion_id FROM group_members WHERE conversation_id = $1 AND left_at IS NOT NULL ORDER BY left_at", gid)]
    return {"id": str(gid), "kind": "group", "name": g["name"], "display_name": await display_name(pool, g),
            "members": [str(c) for c in await members(pool, gid)], "former_members": [str(c) for c in former],
            "avatar_ver": g["avatar_ver"], "max_rounds": g["max_rounds"],
            "new_member_sees_history": g["new_member_sees_history"],
            "last_at": g["last_at"].isoformat(), "created_at": g["created_at"].isoformat(), "preview": preview,
            "incognito": False}


async def list_for(pool, account: UUID) -> list:
    return await pool.fetch("SELECT * FROM conversations WHERE account_id = $1 AND kind = 'group' ORDER BY last_at DESC",
                            account)


async def create(pool, account: UUID, name: str, member_ids: list[UUID], now: datetime):
    """建群：至少两个这个账号的 TA；返回那一行。成员不够 → ValueError"""
    mine = {r["id"] for r in await pool.fetch("SELECT id FROM companions WHERE account_id = $1", account)}
    ids: list[UUID] = []
    for m in member_ids:
        if m in mine and m not in ids:
            ids.append(m)
    if len(ids) < 2:
        raise ValueError("群里至少要两个 TA")
    gid = uuid.uuid4()
    await pool.execute("INSERT INTO conversations (id, account_id, companion_id, kind, name, created_at, last_at) "
                       "VALUES ($1, $2, NULL, 'group', $3, $4, $4)", gid, account, name.strip()[:30], now)
    for i, m in enumerate(ids):
        await pool.execute("INSERT INTO group_members (conversation_id, companion_id, position, joined_at) VALUES ($1, $2, $3, $4)",
                           gid, m, i, now)
    return await row(pool, account, gid)


async def patch(pool, account: UUID, gid: UUID, body: dict):
    if "name" in body:
        await pool.execute("UPDATE conversations SET name = $2 WHERE id = $1", gid, str(body["name"] or "").strip()[:30])
    if "max_rounds" in body:
        await pool.execute("UPDATE conversations SET max_rounds = $2 WHERE id = $1", gid, max(1, min(12, int(body["max_rounds"]))))
    if "new_member_sees_history" in body:
        await pool.execute("UPDATE conversations SET new_member_sees_history = $2 WHERE id = $1", gid,
                           bool(body["new_member_sees_history"]))
    return await row(pool, account, gid)


async def add_member(pool, account: UUID, gid: UUID, companion: UUID, now: datetime) -> None:
    if not await pool.fetchval("SELECT 1 FROM companions WHERE id = $1 AND account_id = $2", companion, account):
        raise LookupError("没有这个联系人")
    pos = await pool.fetchval("SELECT coalesce(max(position), -1) + 1 FROM group_members WHERE conversation_id = $1", gid)
    await pool.execute("INSERT INTO group_members (conversation_id, companion_id, position, joined_at) VALUES ($1, $2, $3, $4) "
                       "ON CONFLICT (conversation_id, companion_id) DO UPDATE SET left_at = NULL, joined_at = $4 "
                       "WHERE group_members.left_at IS NOT NULL", gid, companion, pos, now)


async def kick(pool, gid: UUID, companion: UUID, now: datetime, *, force: bool = False) -> None:
    """踢出去：以后看不到这个群，说过的话留着。群里至少留一个（删 TA 时 force）"""
    current = await members(pool, gid)
    if companion not in current:
        return
    if len(current) <= 1 and not force:
        raise ValueError("群里至少留一个 TA")
    await pool.execute("UPDATE group_members SET left_at = $3 WHERE conversation_id = $1 AND companion_id = $2", gid, companion, now)


async def companion_removed(pool, companion: UUID, now: datetime) -> None:
    """删掉一个 TA：自动退所有群"""
    await pool.execute("UPDATE group_members SET left_at = $2 WHERE companion_id = $1 AND left_at IS NULL", companion, now)


async def bump_avatar(pool, gid: UUID, *, reset: bool = False) -> None:
    await pool.execute("UPDATE conversations SET avatar_ver = CASE WHEN $2 THEN 0 ELSE avatar_ver + 1 END WHERE id = $1", gid, reset)


async def set_last_speaker(pool, gid: UUID, companion: UUID) -> None:
    await pool.execute("UPDATE conversations SET last_speaker = $2 WHERE id = $1", gid, companion)


def joined_late(g, joined_at: datetime | None) -> datetime | None:
    """建群时就在的不算「后来拉进来的」"""
    if joined_at is None or joined_at <= g["created_at"] + timedelta(seconds=1):
        return None
    return joined_at


async def main_window(pool, companion: UUID) -> UUID | None:
    """这个 TA 最近在用的普通私聊窗口（不是无痕、不是群）"""
    return await pool.fetchval("SELECT id FROM conversations WHERE companion_id = $1 AND kind = 'dm' AND NOT incognito "
                               "ORDER BY last_at DESC LIMIT 1", companion)


async def other_rooms(pool, companion: UUID, except_conv: UUID, limit: int, user_name: str, lang: str) -> list[Item]:
    """TA 待过的别的房间最近 limit 条（按时间）：它在 / 待过的群 + 在群里时它的私聊"""
    if limit <= 0:
        return []
    zh = lang == "zh"
    out: list[Item] = []

    async def add(room: str, conv: UUID, since: datetime | None, until: datetime | None) -> None:
        rows = await pool.fetch(
            "SELECT id, role, text, created_at, speaker_id, speaker_name FROM chat_messages "
            "WHERE user_id = $1 AND role IN ('user', 'assistant') AND ($2::timestamptz IS NULL OR created_at >= $2) "
            "AND ($3::timestamptz IS NULL OR created_at <= $3) ORDER BY id DESC LIMIT $4", conv, since, until, limit)
        for r in rows:
            text = (r["text"] or "").strip()
            if not text:
                continue
            if r["role"] == "assistant":
                who = None if r["speaker_id"] in (None, companion) else (r["speaker_name"] or "TA")
            else:
                who = user_name
            out.append(Item(f"{conv}-{r['id']}", room, who, text, r["created_at"]))

    for g in await pool.fetch(
            "SELECT c.*, m.joined_at, m.left_at FROM group_members m JOIN conversations c ON c.id = m.conversation_id "
            "WHERE m.companion_id = $1 AND c.id <> $2", companion, except_conv):
        since = None if g["new_member_sees_history"] else joined_late(g, g["joined_at"])
        await add(group_room(await display_name(pool, g), zh), g["id"], since, g["left_at"])
    if await is_group(pool, except_conv):            # 私聊只在它人在群里时捞（在私聊窗口里，那段本来就是当前房间）
        main = await main_window(pool, companion)
        if main:
            await add(private_room(zh), main, None, None)
    return sorted(out, key=lambda o: o.at)[-limit:]
