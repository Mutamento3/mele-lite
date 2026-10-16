"""看图和画图（10-15 Aporia：让用户自己填 Gemini key 看图、填生图 key；Lite 本机那份是 ios/Lite/LocalMedia.swift）。

钥匙串里勾了看图 / 画图的钥匙（10-15 起存在 media.chores）；以前是 Me →「看图和画图」从钥匙串里挑两把，存在 accounts.media（{vision_key, image_key, image_model}）：
- 看图：TA 聊天的模型看不见图时，照片先交给这把写描述（brain/vision._describer 先看它，再看钥匙串里第一把会看图的，再用我们的）。
- 画图：挑了 TA 才有 draw 工具。Gemini 走 generateContent（图片模型），OpenAI / 兼容口走 /images/generations。
  画好的存成附件，跟它这一轮的话挂在一起；不限张数（用户自己的 key，想画多少画多少）。

10-16 Aporia：从钥匙串挑太绕（还得先填个聊天模型，内测把画图模型填成了聊天模型）、看图画图一般不是同一把——
Me →「看图和画图」改成两栏直接填（哪家 / key / 中转站地址 / 模型），存在 accounts.media.direct.{vision,draw}，
key 用 box 加密；不进钥匙串，TA 的聊天钥匙里选不到。直接填的优先，没填照旧看钥匙串里勾的。
存的时候查一遍这家的模型列表（不花钱）：key 对不对、有没有这个模型、中转站的画图模型叫什么。
中转站画图：/images/generations 不通就换 /chat/completions 再要一次（很多中转站的出图模型只走聊天接口，图在回话里）。"""
from __future__ import annotations

import base64
import json
import logging
import re
import uuid
from datetime import datetime, timedelta
from pathlib import Path
from uuid import UUID

import httpx

from llm.router import Route

from . import chores as CH

log = logging.getLogger(__name__)

DEFAULT_MODELS = {"gemini": "gemini-2.5-flash-image", "openai": "gpt-image-1", "openai-compatible": "gpt-image-1"}
VISION_DEFAULTS = {"anthropic": "claude-haiku-4-5", "gemini": "gemini-3.5-flash-lite", "openai": "gpt-4.1-mini"}
DIRECT_PROVIDERS = {"vision": ("gemini", "anthropic", "openai", "openai-compatible"),
                    "draw": ("gemini", "openai", "openai-compatible")}
IMAGEY = ("image", "dall", "flux", "imagen", "banana", "seedream", "kolors", "midjourney", "sdxl", "stable-diffusion")
SEEING = ("anthropic", "openai", "gemini", "openai-compatible")
GEMINI = "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
TRANSPORT: httpx.AsyncBaseTransport | None = None     # 测试里换成假的出图服务


class DrawError(Exception):
    pass


async def get(pool, account: UUID) -> dict:
    raw = await pool.fetchval("SELECT media FROM accounts WHERE id = $1", account)
    if isinstance(raw, str):
        raw = json.loads(raw)
    return dict(raw or {})


async def _key(pool, account: UUID, kid) -> dict | None:
    try:
        kid = UUID(str(kid))
    except (TypeError, ValueError):
        return None
    r = await pool.fetchrow("SELECT id, provider, chat_model, base_url, secret FROM keyring WHERE account_id = $1 AND id = $2",
                            account, kid)
    return dict(r) if r else None


async def public(pool, account: UUID, now: datetime) -> dict:
    t = await CH.get_table(pool, account)
    live = await CH.live_keys(pool, account)
    direct = {slot: ({k: v for k, v in d.items() if k != "secret"} if (d := (t.get("direct") or {}).get(slot)) else None)
              for slot in ("vision", "draw")}
    return {"vision_key": CH.pick(t["chores"], "vision", live), "image_key": CH.pick(t["chores"], "draw", live),
            "image_model": t["draw_model"], "default_models": DEFAULT_MODELS, "vision_defaults": VISION_DEFAULTS,
            "direct": direct, "drawn_today": await drawn_today(pool, account, now)}


def _direct_route(t: dict, box, slot: str) -> tuple[str, str, str, str | None] | None:
    d = (t.get("direct") or {}).get(slot)
    if not d or box is None:
        return None
    try:
        key = box.unlock(base64.b64decode(d["secret"]))
    except Exception:              # noqa: BLE001 —— 换过主密钥之类，当没填
        return None
    defaults = DEFAULT_MODELS if slot == "draw" else VISION_DEFAULTS
    return d["provider"], key, d.get("model") or defaults.get(d["provider"], ""), d.get("base_url") or None


async def put_direct(pool, box, account: UUID, slot: str, body: dict | None) -> dict | None:
    """填 / 改 / 清一栏。body = {provider, api_key?, base_url?, model?}；None = 清掉。
    改的时候 api_key 空着 = 用原来那串。返回查过的结果 {ok, message}（清掉返回 None）"""
    if slot not in DIRECT_PROVIDERS:
        raise ValueError("没有这一栏")
    t = await CH.get_table(pool, account)
    direct = dict(t.get("direct") or {})
    if body is None:
        direct.pop(slot, None)
        t["direct"] = direct
        await CH.save_table(pool, account, t)
        return None
    provider = str(body.get("provider") or "")
    if provider not in DIRECT_PROVIDERS[slot]:
        raise ValueError("这家不会画图，挑 Gemini、OpenAI 或中转站" if slot == "draw" else "挑 Gemini、Claude、OpenAI 或中转站")
    base = str(body.get("base_url") or "").strip().rstrip("/")[:300] or None
    if provider == "openai-compatible" and not base:
        raise ValueError("中转站要填地址（一般以 /v1 结尾）")
    model = str(body.get("model") or "").strip()[:100]
    if provider == "openai-compatible" and not model:
        raise ValueError("中转站要填模型名：去中转站后台看它的" + ("画图模型" if slot == "draw" else "会看图的模型") + "叫什么")
    api_key = str(body.get("api_key") or "").strip()
    old = direct.get(slot)
    if not api_key:
        if not old:
            raise ValueError("要填 key")
        secret = old["secret"]
        api_key = box.unlock(base64.b64decode(secret))
    else:
        if box is None:
            raise ValueError("这台 Host 没配加密钥匙，存不了 key")
        secret = base64.b64encode(box.lock(api_key)).decode()
    direct[slot] = {"provider": provider, "base_url": base if provider == "openai-compatible" else None,
                    "model": model, "last4": api_key[-4:], "secret": secret}
    t["direct"] = direct
    await CH.save_table(pool, account, t)
    defaults = DEFAULT_MODELS if slot == "draw" else VISION_DEFAULTS
    return await check(provider, api_key, model or defaults.get(provider, ""), base, slot)


async def _get(url: str, headers: dict) -> tuple[int, dict]:
    async with (httpx.AsyncClient(transport=TRANSPORT) if TRANSPORT else httpx.AsyncClient()) as http:
        try:
            r = await http.get(url, headers=headers, timeout=20)
        except httpx.HTTPError:
            return 0, {}
    try:
        return r.status_code, r.json()
    except ValueError:
        return r.status_code, {}


async def check(provider: str, key: str, model: str, base: str | None, slot: str) -> dict:
    """查模型列表（不花钱）：key 通不通、有没有这个模型；中转站没有就列出它像画图的那几个"""
    if provider == "gemini":
        code, obj = await _get("https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000", {"x-goog-api-key": key})
        ids = [str(m.get("name", "")).removeprefix("models/") for m in obj.get("models") or []]
    elif provider == "anthropic":
        code, obj = await _get("https://api.anthropic.com/v1/models?limit=1000", {"x-api-key": key, "anthropic-version": "2023-06-01"})
        ids = [str(m.get("id", "")) for m in obj.get("data") or []]
    else:
        code, obj = await _get(f"{(base or 'https://api.openai.com/v1').rstrip('/')}/models", {"Authorization": f"Bearer {key}"})
        ids = [str(m.get("id", "")) for m in obj.get("data") or []]
    return verdict(code, ids, model, slot)


def verdict(code: int, ids: list[str], model: str, slot: str) -> dict:
    if code == 0:
        return {"ok": False, "message": "连不上这个地址，检查一下地址和网络"}
    if code in (401, 403):
        return {"ok": False, "message": "key 不对，或者这把 key 没权限"}
    if not 200 <= code < 300 or not ids:
        return {"ok": True, "message": "存好了。这家不给看模型列表，没法提前确认模型名，用的时候才知道"}
    if model in ids:
        return {"ok": True, "message": f"通了：这家有「{model}」"}
    hint = ""
    if slot == "draw":
        like = [i for i in ids if any(w in i.lower() for w in IMAGEY)][:8]
        hint = ("。像画图的有：" + "、".join(like)) if like else "。这家好像没有画图模型"
    return {"ok": False, "message": f"这家没有叫「{model}」的模型{hint}"}


async def put(pool, account: UUID, body: dict) -> None:
    """旧 App 的接口（10-15 起背后是分活表）：{vision_key?, image_key?, image_model?}"""
    t = await CH.get_table(pool, account)
    for k, chore in (("vision_key", "vision"), ("image_key", "draw")):
        if k not in body:
            continue
        if not body[k]:
            t["chores"].pop(chore, None)
            continue
        key = await _key(pool, account, body[k])
        if key is None:
            raise LookupError("没有这把钥匙")
        if chore not in CH.can(key["provider"]):
            raise ValueError("DeepSeek 看不见图，挑一把 Gemini / Claude / OpenAI 的" if chore == "vision"
                             else "这家不会画图，挑一把 Gemini 或 OpenAI（兼容口）的")
        t["chores"][chore] = str(key["id"])
    if "image_model" in body:
        t["draw_model"] = str(body.get("image_model") or "").strip()[:100]
    await CH.save_table(pool, account, t)


async def _picked(pool, account: UUID, chore: str) -> dict | None:
    t = await CH.get_table(pool, account)
    kid = CH.pick(t["chores"], chore, await CH.live_keys(pool, account))
    return await _key(pool, account, kid) if kid else None


async def vision_route(pool, box, account: UUID) -> Route | None:
    """Me 里直接填的看图钥匙（10-16）→ 钥匙串里勾了「看图」的那把；都没有 = None（vision 再往下找）"""
    if box is None:
        return None
    if d := _direct_route(await CH.get_table(pool, account), box, "vision"):
        provider, key, model, base = d
        return Route(provider, key, model, model, base_url=base)
    k = await _picked(pool, account, "vision")
    if k is None:
        return None
    return Route(k["provider"], box.unlock(k["secret"]), k["chat_model"], k["chat_model"], base_url=k["base_url"])


async def image_route(pool, box, account: UUID) -> tuple[str, str, str, str | None] | None:
    """(哪家, key, 模型, 地址)；没勾「画图」= None"""
    if box is None:
        return None
    if d := _direct_route(await CH.get_table(pool, account), box, "draw"):
        return d
    k = await _picked(pool, account, "draw")
    if k is None:
        return None
    t = await CH.get_table(pool, account)
    own = k.get("chat_model") or ""          # 钥匙上本来填的就是画图模型（10-16 内测）就用它
    model = t["draw_model"] or (own if CH.is_image_model(own) else DEFAULT_MODELS[k["provider"]])
    return k["provider"], box.unlock(k["secret"]), model, k["base_url"]


async def drawn_today(pool, account: UUID, now: datetime) -> int:
    return await pool.fetchval("SELECT count(*) FROM attachments WHERE account_id = $1 AND caption_source = 'drawn' "
                               "AND created_at >= $2", account, now - timedelta(days=1))


async def _post(url: str, headers: dict, body: dict) -> dict:
    async with (httpx.AsyncClient(transport=TRANSPORT) if TRANSPORT else httpx.AsyncClient()) as http:
        try:
            resp = await http.post(url, json=body, headers=headers, timeout=120)
        except httpx.HTTPError as e:
            raise DrawError("画图那边连不上") from e
    try:
        obj = resp.json()
    except ValueError:
        obj = {}
    if not 200 <= resp.status_code < 300:
        msg = (obj.get("error") or {}).get("message") if isinstance(obj.get("error"), dict) else resp.text[:200]
        raise DrawError(f"{resp.status_code} {msg}")
    return obj


async def generate(provider: str, key: str, model: str, base_url: str | None, prompt: str) -> bytes:
    if provider == "gemini":
        obj = await _post(GEMINI.format(model=model), {"x-goog-api-key": key},
                          {"contents": [{"parts": [{"text": prompt}]}],
                           "generationConfig": {"responseModalities": ["TEXT", "IMAGE"]}})
        for c in obj.get("candidates") or []:
            for p in (c.get("content") or {}).get("parts") or []:
                inline = p.get("inlineData") or p.get("inline_data") or {}
                if inline.get("data"):
                    return base64.b64decode(inline["data"])
        raise DrawError("没有图（模型名对吗？要选会出图的，比如 gemini-2.5-flash-image）")
    base = (base_url or "https://api.openai.com/v1").rstrip("/")
    try:
        obj = await _post(f"{base}/images/generations", {"Authorization": f"Bearer {key}"},
                          {"model": model, "prompt": prompt, "n": 1, "size": "1024x1024"})
    except DrawError as first_err:
        if provider != "openai-compatible":
            raise
        try:                       # 中转站的出图模型常只走聊天接口（10-16 内测 503）
            return await _via_chat(base, key, model, prompt)
        except DrawError as e:
            raise DrawError(f"{first_err}；换聊天接口也不行：{e}") from e
    first = (obj.get("data") or [{}])[0]
    if first.get("b64_json"):
        return base64.b64decode(first["b64_json"])
    if first.get("url"):
        async with (httpx.AsyncClient(transport=TRANSPORT) if TRANSPORT else httpx.AsyncClient()) as http:
            r = await http.get(first["url"], timeout=60)
            if r.status_code == 200:
                return r.content
    raise DrawError("没有图")


_DATA_URI = re.compile(r"data:image/[a-zA-Z+]+;base64,([A-Za-z0-9+/=]+)")
_IMG_URL = re.compile(r"https?://[^\s)\]\"']+")


async def _via_chat(base: str, key: str, model: str, prompt: str) -> bytes:
    """中转站出图模型走 /chat/completions：图可能在 message.images（OpenRouter 那种）、content 的 image_url 段、
    或者正文里的 data URI / 链接"""
    obj = await _post(f"{base}/chat/completions", {"Authorization": f"Bearer {key}"},
                      {"model": model, "messages": [{"role": "user", "content": prompt}]})
    msg = ((obj.get("choices") or [{}])[0].get("message") or {})
    urls: list[str] = []
    for im in msg.get("images") or []:
        u = (im.get("image_url") or {}).get("url") if isinstance(im, dict) else None
        if u:
            urls.append(u)
    content = msg.get("content")
    if isinstance(content, list):
        for part in content:
            if isinstance(part, dict):
                u = (part.get("image_url") or {}).get("url") if isinstance(part.get("image_url"), dict) else part.get("image_url")
                if u:
                    urls.append(u)
                if isinstance(part.get("text"), str):
                    urls += [m.group(0) for m in _DATA_URI.finditer(part["text"])] + _IMG_URL.findall(part["text"])
    elif isinstance(content, str):
        urls += [m.group(0) for m in _DATA_URI.finditer(content)] + _IMG_URL.findall(content)
    for u in urls:
        if m := _DATA_URI.match(u):
            return base64.b64decode(m.group(1))
        async with (httpx.AsyncClient(transport=TRANSPORT) if TRANSPORT else httpx.AsyncClient()) as http:
            try:
                r = await http.get(u, timeout=60)
            except httpx.HTTPError:
                continue
            if r.status_code == 200 and r.headers.get("content-type", "").startswith("image/"):
                return r.content
    raise DrawError("回话里没有图（这个模型会出图吗？）")


async def draw(pool, box, files_dir: Path, *, account: UUID, conversation: UUID, prompt: str, now: datetime):
    """画一张，存成附件（还没挂到消息上），返回 Attachment"""
    from . import attachments
    route = await image_route(pool, box, account)
    if route is None:
        raise DrawError("还没挑画图钥匙")
    data = await generate(*route, prompt)
    try:
        att = await attachments.save(pool, files_dir, account=account, conversation=conversation,
                                     name=f"drawn-{uuid.uuid4().hex[:8]}.jpg", mime="image/jpeg", data=data)
    except attachments.AttachmentError as e:
        raise DrawError("画出来的不是图") from e
    await pool.execute("UPDATE attachments SET caption = $2, caption_source = 'drawn' WHERE id = $1", att.id, prompt[:2000])
    att.caption = prompt[:2000]
    return att
