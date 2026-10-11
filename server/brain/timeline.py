"""一个 TA 一段脑子（10-11 Aporia：私聊和群聊合在一起，「不然不太像一个人」）：
TA 在哪个房间说话，都把它待过的别的房间最近 N 条按真实时间插进来，前面标房间和说话人。
只按条数截、不限时间（「太久之前才显得真」）。跟 Lite 的 MeleLiteCore/Chat/RoomTimeline.swift 同一份意思。"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime

from .archive import StoredMsg


@dataclass(frozen=True)
class Item:
    id: str
    room: str              # 排好的房间名：群「三人行」/ 私聊
    who: str | None        # 说话人名字；None = 就是这个 TA 自己说的
    text: str
    at: datetime


def group_room(name: str, zh: bool) -> str:
    return f"群「{name}」" if zh else f'group "{name}"'


def private_room(zh: bool) -> str:
    return "私聊" if zh else "DM"


def merge(current: list[StoredMsg], others: list[Item], limit: int) -> list[StoredMsg]:
    """别的房间最近 limit 条按时间插进当前历史：TA 自己说的 = assistant「〔房间〕…」，别人说的 = user「〔房间 · 名字〕…」。
    同一时刻当前房间的在前；limit ≤ 0 原样返回。插进来的那几条 id = -1（不是这个窗口的消息）"""
    if limit <= 0 or not others:
        return current
    picked = sorted(others, key=lambda o: o.at)[-limit:]
    extra = [StoredMsg(-1, "assistant" if o.who is None else "user",
                       f"〔{o.room}{'' if o.who is None else ' · ' + o.who}〕{o.text}", "", o.at) for o in picked]
    out: list[StoredMsg] = []
    i = j = 0
    while i < len(current) or j < len(extra):
        if j >= len(extra) or (i < len(current) and current[i].created_at <= extra[j].created_at):
            out.append(current[i]); i += 1
        else:
            out.append(extra[j]); j += 1
    return out
