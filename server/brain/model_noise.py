"""模型自己漏出来的内部标记（10-11 群聊真 key 测出来：DeepSeek 在回复开头吐了一段 <ds_safety>…</ds_safety> 安全分类）。
不是 TA 说的话，进气泡之前删掉。跟 Lite 的 MeleLiteCore/Chat/ModelNoise.swift 同一份规则。"""
import re

_BLOCK = re.compile(r"<(ds_[A-Za-z_]+)>[\s\S]*?</\1>")
_OPEN = re.compile(r"<ds_[A-Za-z_]+>[^\n]*\n?")


def strip(text: str) -> str:
    t = _OPEN.sub("", _BLOCK.sub("", text))
    return text if t == text else t.strip()
