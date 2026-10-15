"""群聊调度（10-11，跟 Lite 的 LocalBrain.runGroup 同义）：
你说一句 → 没被你 @ 的 TA 各用自己的模型判断「说 / 过」→ 想说的排队一个一个说（被 @ 的最前，其余随机）→
每说完一个，别的 TA 再判断要不要接（TA 之间 @ 不强制）→ 每有一个 TA 开口算一轮，到上限停 → 你插话 = 说完这个就停。"""
from __future__ import annotations

import asyncio
import logging
from typing import Callable
from uuid import UUID

from llm.catalog import cost
from llm.errors import LLMError
from llm.router import call
from llm.types import Block, ChatRequest, Msg

from . import archive, groups
from . import group as G
from .persona import Persona
from .scope import Scope
from .settings import Settings
from .turn import Deps, GroupCtx, get_adapter, resolve_route, run_turn, user_label

log = logging.getLogger(__name__)
JUDGE_TAG = {"zh": "群聊判断", "en": "group judge"}


async def judge(deps: Deps, account: UUID, companion: UUID, gid: UUID, gname: str) -> bool:
    """它自己的模型判断一下想不想接（只回一个字）；没 key、出错、看不懂都算「过」。用量记成「模型 · 群聊判断」"""
    pool = deps.pool
    settings = Settings.from_dict(await archive.get_settings(pool, companion))
    lang = settings.lang
    try:
        route = await resolve_route(deps.keys, Scope(account, companion, gid), chore="dedupe")
    except Exception:                     # 没钥匙、试用用完：这次不说
        return False
    persona = Persona.from_dict(await archive.get_persona(pool, companion), lang)
    me, uname = persona.name or "TA", user_label(settings, lang)
    others = [await groups.name_of(pool, c, lang) for c in await groups.members(pool, gid) if c != companion]
    recent = []
    for m in await archive.recent(pool, gid, 12):
        if m.role == "wake":
            continue
        who = (m.speaker_name or "TA") if m.role == "assistant" else uname
        recent.append((("你" if lang == "zh" else "you") if who == me else who, m.text))
    system, user = G.judge_prompt(zh=lang == "zh", me=me, persona=persona.imported or persona.personality or "",
                                  group=gname, user_name=uname, others=others, recent=recent)
    req = ChatRequest(model=route.chat_model, system=[Block(system)], messages=[Msg("user", user)], max_tokens=32,
                      thinking=False)
    try:
        reply = await call(get_adapter(deps, route), req)
    except LLMError as e:
        log.info("group judge failed: %s", e)
        return False
    day = deps.now().date()
    await archive.add_usage(pool, account, day, f"{route.chat_model} · {JUDGE_TAG[lang]}", reply.usage,
                            cost(reply.usage, route.chat_model))
    return G.wants_to_speak(reply.text)


async def judge_all(deps: Deps, account: UUID, comps: list[UUID], gid: UUID, gname: str) -> list[UUID]:
    """并行问一圈，按名单顺序返回想说的"""
    if not comps:
        return []
    yes = await asyncio.gather(*(judge(deps, account, c, gid, gname) for c in comps))
    return [c for c, ok in zip(comps, yes) if ok]


async def run_group(deps: Deps, account: UUID, gid: UUID, text: str, emit, interrupted: Callable[[], bool], *,
                    resend: bool = False, parts: list[str] | None = None, attachments: list | None = None) -> bool:
    """跑一串。resend = 倒回后重来（你那句已经在存档最后了）。返回有没有人说话"""
    from . import attachments as files
    pool = deps.pool
    said_any = False
    try:
        g = await pool.fetchrow("SELECT * FROM conversations WHERE id = $1 AND kind = 'group'", gid)
        if g is None:
            return False
        if resend:
            last = next((m for m in reversed(await archive.unrolled(pool, gid)) if m.role == "user"), None)
            user_msg, text = (last.id, last.text) if last else (None, text)
        else:
            u = await archive.add_message(pool, gid, "user", text, parts=parts, now=deps.now())
            if attachments:
                await files.claim(pool, gid, attachments, u.id)
            user_msg = u.id
        members = await groups.members(pool, gid)
        if not members:
            return False
        names = {c: await groups.name_of(pool, c) for c in members}
        roster = [G.Member(str(c), n) for c, n in names.items()]
        gname = await groups.display_name(pool, g)
        first_called = [UUID(x) for x in G.mentioned(text, roster)]
        wanting = await judge_all(deps, account, [c for c in members if c not in first_called], gid, gname)
        queue = [UUID(x) for x in G.order([str(c) for c in first_called], [str(c) for c in wanting])]
        rounds = 0
        while queue and rounds < g["max_rounds"]:
            if interrupted():
                break
            cid = queue.pop(0)
            current = await groups.members(pool, gid)
            if cid not in current:
                continue
            ms = await groups.membership(pool, gid, cid)
            others = [names.get(c) or await groups.name_of(pool, c) for c in current if c != cid]
            ctx = GroupCtx(name=gname, others=tuple(others),
                           user_msg=user_msg, joined_at=groups.joined_late(g, ms["joined_at"] if ms else None),
                           sees_history=g["new_member_sees_history"])
            out = await run_turn(deps, Scope(account, cid, gid), text, emit, group=ctx)
            if not out.said:
                continue
            said_any = True
            rounds += 1
            if rounds >= g["max_rounds"] or interrupted():
                break
            rest = [c for c in await groups.members(pool, gid) if c != cid and c not in queue]
            queue += [UUID(x) for x in G.order([], [str(c) for c in await judge_all(deps, account, rest, gid, gname)])]
        return said_any
    finally:
        await emit({"type": "round_end"})
