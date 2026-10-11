"""群聊（10-11 Aporia定）：谁被 @ 了、谁先说、要不要接话的那一下、群里的规矩。
被用户 @ 的直接说；其余每个 TA 用自己的模型判断一下「说 / 过」，想说的排队一个一个说，后说的看得到先说的。
跟 Lite 的 MeleLiteCore/Chat/GroupChat.swift 同一份意思、同一份文案。"""
from __future__ import annotations

import random
from dataclasses import dataclass
from typing import Callable


@dataclass(frozen=True)
class Member:
    id: str
    name: str


def mentioned(text: str, members: list[Member]) -> list[str]:
    """正文里 @ 到的成员 id，按出现先后、不重复。名字长的先认（「@小满满」不会被认成小满）"""
    hits: list[tuple[int, str]] = []
    taken: list[tuple[int, int]] = []
    for m in sorted(members, key=lambda m: -len(m.name)):
        if not m.name:
            continue
        needle, start = "@" + m.name, 0
        while (i := text.find(needle, start)) >= 0:
            span = (i, i + len(needle))
            if not any(a < span[1] and span[0] < b for a, b in taken):
                taken.append(span)
                if all(h[1] != m.id for h in hits):
                    hits.append((i, m.id))
            start = span[1]
    return [mid for _, mid in sorted(hits)]


def order(mentioned_ids: list[str], wanting: list[str],
          shuffle: Callable[[list[str]], list[str]] | None = None) -> list[str]:
    """排队：被 @ 的按 @ 的先后排最前；其余想说的打乱"""
    head: list[str] = []
    for i in mentioned_ids:
        if i not in head:
            head.append(i)
    rest = [w for w in wanting if w not in head]
    if shuffle is None:
        rest = random.sample(rest, len(rest))
    else:
        rest = shuffle(rest)
    return head + rest


def wants_to_speak(reply: str) -> bool:
    """判断的回答：有「过 / pass」= 过；有「说 / speak」= 说；看不懂 = 过（别让一个坏回答卡住群）"""
    t = reply.lower()
    if "过" in t or "pass" in t:
        return False
    return "说" in t or "speak" in t


def label(name: str) -> str:
    return f"〔{name}〕"


def judge_prompt(*, zh: bool, me: str, persona: str, group: str, user_name: str,
                 others: list[str], recent: list[tuple[str, str]]) -> tuple[str, str]:
    """判断要不要接话那一下：人设摘要 + 群里最近十来句，只回一个字"""
    who = [x for x in [user_name, *others] if x]
    lines = "\n".join(label(w) + t for w, t in recent)
    brief = persona.strip()[:800]
    if zh:
        system = f"你是{me}。" + (f"\n\n{brief}" if brief else "") + f"\n\n你在群「{group}」里，群里还有：{'、'.join(who)}。"
        user = (f"群里最近的聊天：\n{lines or '（还没人说话）'}\n\n"
                "看最后那句，按你的性子来：想接话、想插嘴、被提到了，就回「说」；这句轮不到你，就回「过」。只回一个字。")
        return system, user
    system = f"You are {me}." + (f"\n\n{brief}" if brief else "") + f"\n\nYou're in the group \"{group}\" with: {', '.join(who)}."
    user = (f"Recent messages in the group:\n{lines or '(nobody has spoken yet)'}\n\n"
            "Look at the last message and go with your nature: if you want to reply, chime in, or you were mentioned, "
            "answer \"speak\"; if it's not your turn, answer \"pass\". One word only.")
    return system, user


def room_rules(*, zh: bool, group: str, me: str, user_name: str, others: list[str]) -> str:
    """群里 TA 的 system 多这一段"""
    everyone = [x for x in [user_name, *others] if x]
    if zh:
        return (f"【群聊】这里是群「{group}」，群里有{'、'.join(everyone)}，还有你{me}。"
                "别人的话前面标着〔名字〕。你只说你自己的话，不替别人开口，开头也不写自己的名字。想接谁的话就接谁的，想点名就 @名字。\n"
                f"你们现在在群聊里，群里每个人都看得到你说的话。私聊里的日常小事顺嘴提起没关系；很私密的——亲密的事、{user_name}只跟你一个人讲的心事和秘密——留在私聊里说。")
    return (f"[Group chat] This is the group \"{group}\" — {', '.join(everyone)}, and you, {me}. "
            "Other people's lines start with 〔name〕. Speak only as yourself, never for anyone else, and don't start with your own name. "
            "Reply to whoever you like; @name to call someone out.\n"
            f"You're in a group chat now — everyone here sees what you say. Everyday bits from your DMs are fine to mention; "
            f"the truly private things — intimacy, and secrets or feelings {user_name} shared only with you — stay in your DMs.")


def strip_own_label(text: str, name: str) -> str:
    """模型偶尔学着历史给自己也垫个名字：开头的「〔阿橘〕」「阿橘：」去掉"""
    t = text.strip()
    for head in (label(name), name + "：", name + ":"):
        if t.startswith(head):
            return t[len(head):].strip()
    return t


def join_note(zh: bool) -> str:
    """刚被拉进群、看得到之前的聊天时，垫在最前面"""
    return "（你刚被拉进群，翻了翻前面的聊天记录）" if zh else "(You were just added to the group and scrolled back through the earlier messages.)"
