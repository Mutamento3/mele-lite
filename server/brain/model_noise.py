"""模型自己漏出来的内部标记（10-11 群聊真 key 测出来：DeepSeek 在回复开头吐了一段 <ds_safety>…</ds_safety> 安全分类）。
不是 TA 说的话，进气泡之前删掉。跟 Lite 的 MeleLiteCore/Chat/ModelNoise.swift 同一份规则。"""
import json
import re

_BLOCK = re.compile(r"<(ds_[A-Za-z_]+)>[\s\S]*?</\1>")
_OPEN = re.compile(r"<ds_[A-Za-z_]+>[^\n]*\n?")
# 10-23 内测：〔醒来〕里「不说就只写 <silent>」整段存进历史，普通聊天它也学着写，原样进了气泡。醒来那条路先由 split_silent 判过
_SILENT = re.compile(r"<\s*/?\s*silent\s*/?\s*>", re.I)


def unsilence(text: str) -> str:
    """历史里它以前漏出来的 <silent> 抠掉；整句只剩它就原样留着（删空了这一轮就没了，前后两句用户话会挤在一起）"""
    t = _SILENT.sub("", text).strip() if "silent" in text.lower() else text
    return t or text


def strip(text: str) -> str:
    t = text_tool_calls(_SILENT.sub("", _OPEN.sub("", _BLOCK.sub("", text))))[1]
    return text if t == text else t.strip()


# ── 写成文字的工具调用（10-15 内测：本机模式 <function_calls><invoke name="memory_recall">… 原样进了气泡）──
# 有的中转 / 模型不走工具接口，把调用当正文写出来。认三种：<function_calls><invoke>…、单独的 <invoke>…、<tool_call>{json}…；
# 收尾标签常常写漏（截图里就没有 </args_json>），没收尾就算到下一个调用或者结尾。

_WRAPPER = re.compile(r"<(?:antml:)?function_calls>([\s\S]*?)(?:</(?:antml:)?function_calls>|$)")
_INVOKE = re.compile(r"""<(?:antml:)?invoke\s+name\s*=\s*["']([^"']+)["']\s*>([\s\S]*?)(?:</(?:antml:)?invoke>|(?=<(?:antml:)?invoke[\s>])|$)""")
_TOOL_CALL = re.compile(r"<tool_call>([\s\S]*?)(?:</tool_call>|$)")
_PARAM = re.compile(r"""<(?:antml:)?parameter\s+name\s*=\s*["']([^"']+)["']\s*>([\s\S]*?)</(?:antml:)?parameter>""")


def _obj(s: str) -> dict | None:
    try:
        o = json.loads(s.strip())
    except ValueError:
        return None
    return o if isinstance(o, dict) else None


def _from_invoke(name: str, body: str) -> tuple[str, dict]:
    params = _PARAM.findall(body)
    if params:
        out = {}
        for k, v in params:
            v = v.strip()
            try:
                out[k] = json.loads(v)
            except ValueError:
                out[k] = v
        return name, out
    a, b = body.find("{"), body.rfind("}")      # <args_json>{…}</args_json> / 直接一段 JSON
    return name, (_obj(body[a:b + 1]) if 0 <= a < b else None) or {}


def text_tool_calls(text: str) -> tuple[list[tuple[str, dict]], str]:
    """找出写成文字的调用，返回 ([(工具名, 参数)], 删掉之后的正文)。没有就原样还回去"""
    if "<" not in text:
        return [], text
    calls: list[tuple[str, dict]] = []
    for inner in _WRAPPER.findall(text):
        calls += [_from_invoke(n, b) for n, b in _INVOKE.findall(inner)]
    rest = _WRAPPER.sub("", text)
    calls += [_from_invoke(n, b) for n, b in _INVOKE.findall(rest)]
    rest = _INVOKE.sub("", rest)
    for inner in _TOOL_CALL.findall(rest):
        o = _obj(inner)
        if o and isinstance(o.get("name"), str):
            args = o.get("arguments", o.get("parameters", {}))
            calls.append((o["name"], args if isinstance(args, dict) else {}))
    rest = _TOOL_CALL.sub("", rest)
    if rest == text:
        return [], text
    return calls, re.sub(r"\n{3,}", "\n\n", rest).strip()
