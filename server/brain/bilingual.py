"""双语气泡（10-15 Aporia：别家截图那种，TA 说英文、每泡下面一行中文；你的泡也双语）。
TA 设定里开：TA 说什么话（bilingual_lang）、译成什么（bilingual_to，空 = App 语言）、
译文谁写（bilingual_by：key = 钥匙串「翻译」那把翻，便宜；self = TA 每泡自己写一行〔译〕）。
译文跟气泡一一对应存一列 translations；历史里你的话用翻好的那版，TA 的话只有原文，译文不进上下文。
Lite 那份是 ios/Lite/LocalBilingual.swift，改一边改另一边。"""
from __future__ import annotations

import json
import logging
import re

from llm.router import call
from llm.types import Block, ChatRequest, Msg

from .settings import Settings

log = logging.getLogger(__name__)

MARK = "〔译〕"
_MARK_LINE = re.compile(r"\n?\s*[〔\[【(（]\s*译\s*[〕\]】)）]\s*[:：]?\s*")


def active(settings: Settings, group) -> bool:
    return bool(settings.bilingual) and group is None


def target(settings: Settings) -> str:
    return (settings.bilingual_to or "").strip() or ("中文" if settings.lang == "zh" else "English")


def speaks(settings: Settings) -> str:
    return (settings.bilingual_lang or "").strip() or "English"


def rule(settings: Settings) -> str:
    """每轮压在尾巴上的一行"""
    lang, to = speaks(settings), target(settings)
    if settings.lang == "zh":
        line = f"〔双语〕你一直用{lang}说话（对方用别的语言跟你说也照样用{lang}回）。"
        if settings.bilingual_by == "self":
            line += f"每个气泡写完原文，另起一行写「{MARK}」加上这句的{to}翻译，翻译跟原文的语气一样。"
        return line
    line = f"〔Bilingual〕Always speak {lang}, even when they write to you in another language."
    if settings.bilingual_by == "self":
        line += f" After each bubble, on a new line, write \"{MARK}\" followed by its {to} translation in the same tone."
    return line


def split_self(bubbles: list[str]) -> tuple[list[str], list[str | None]]:
    """TA 自己写的〔译〕切下来：(原文们, 译文们)。〔译〕单独成了一泡的，算前一泡的译文。"""
    originals: list[str] = []
    trans: list[str | None] = []
    for b in bubbles:
        m = _MARK_LINE.search(b)
        if m is None:
            originals.append(b)
            trans.append(None)
            continue
        head, tail = b[:m.start()].strip(), b[m.end():].strip()
        if not head and originals:                  # 〔译〕自己一泡：接到前一泡
            if trans[-1] is None:
                trans[-1] = tail or None
            continue
        originals.append(head or b)
        trans.append(tail or None)
    return originals, trans


def parse_list(text: str, n: int) -> list[str | None]:
    """翻译模型回的 JSON 数组（可能包在 ```json 里）→ 长度 n 的列表；对不上就全 None"""
    t = (text or "").strip()
    a, b = t.find("["), t.rfind("]")
    try:
        got = json.loads(t[a:b + 1]) if 0 <= a < b else None
    except ValueError:
        got = None
    if not isinstance(got, list) or len(got) != n:
        return [None] * n
    return [str(x).strip() or None if x is not None else None for x in got]


PROMPT = {
    "zh": "把下面编号的 {n} 句从{src}翻成{dst}。口语、保持原来的语气和称呼，不解释、不加东西。"
          "只回一个 JSON 字符串数组，{n} 个元素，顺序跟编号一样。\n\n{items}",
    "en": "Translate the {n} numbered lines below from {src} into {dst}. Keep it conversational, same tone and forms of address; "
          "no explanations, nothing added. Reply with only a JSON array of {n} strings, in order.\n\n{items}",
}


async def translate(deps, scope, texts: list[str], src: str, dst: str, lang: str) -> list[str | None]:
    """一次翻好几句；钥匙用钥匙串「翻译」那把，没勾用聊天那把。出错 = 全 None（只显示原文）"""
    from .turn import get_adapter, resolve_route
    from . import archive
    from llm.catalog import cost
    if not texts:
        return []
    try:
        route = await resolve_route(deps.keys, scope, chore="translate")
    except Exception:
        log.exception("bilingual: no route")
        return [None] * len(texts)
    items = "\n".join(f"{i + 1}. {t}" for i, t in enumerate(texts))
    req = ChatRequest(model=route.chat_model, system=[Block("You are a careful translator.")],
                      messages=[Msg("user", PROMPT[lang].format(n=len(texts), src=src, dst=dst, items=items))],
                      max_tokens=200 + 200 * len(texts), thinking=False)
    try:
        reply = await call(get_adapter(deps, route), req)
    except Exception as e:
        log.warning("bilingual translate failed: %s", e)
        return [None] * len(texts)
    try:
        day = deps.now().date()
        await archive.add_usage(deps.pool, scope.account, day, route.chat_model, reply.usage, cost(reply.usage, route.chat_model))
    except Exception:
        log.exception("bilingual: usage not recorded")
    return parse_list(reply.text, len(texts))


def user_side(text: str, translations: list | None) -> str:
    """历史里你那句：翻好了（每段都有）就用翻好的那版"""
    if translations and all(isinstance(t, str) and t.strip() for t in translations):
        return "\n".join(translations)
    return text
