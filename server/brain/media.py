"""看图和画图（10-15 Aporia：让用户自己填 Gemini key 看图、填生图 key；Lite 本机那份是 ios/Lite/LocalMedia.swift）。

Me →「看图和画图」从钥匙串里挑两把，存在 accounts.media（{vision_key, image_key, image_model}）：
- 看图：TA 聊天的模型看不见图时，照片先交给这把写描述（brain/vision._describer 先看它，再看钥匙串里第一把会看图的，再用我们的）。
- 画图：挑了 TA 才有 draw 工具。Gemini 走 generateContent（图片模型），OpenAI / 兼容口走 /images/generations。
  画好的存成附件，跟它这一轮的话挂在一起；不限张数（用户自己的 key，想画多少画多少）。"""
from __future__ import annotations

import base64
import json
import logging
import uuid
from datetime import datetime, timedelta
from pathlib import Path
from uuid import UUID

import httpx

from llm.router import Route

log = logging.getLogger(__name__)

DEFAULT_MODELS = {"gemini": "gemini-2.5-flash-image", "openai": "gpt-image-1", "openai-compatible": "gpt-image-1"}
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
    m = await get(pool, account)
    out = {}
    for k in ("vision_key", "image_key"):
        out[k] = m.get(k) if m.get(k) and await _key(pool, account, m[k]) else None
    return {**out, "image_model": m.get("image_model") or "", "default_models": DEFAULT_MODELS,
            "drawn_today": await drawn_today(pool, account, now)}


async def put(pool, account: UUID, body: dict) -> None:
    """{vision_key?, image_key?, image_model?}；钥匙 null = 不挑。挑错家的报 ValueError（给人看的话）"""
    m = await get(pool, account)
    for k in ("vision_key", "image_key"):
        if k not in body:
            continue
        if not body[k]:
            m[k] = None
            continue
        key = await _key(pool, account, body[k])
        if key is None:
            raise LookupError("没有这把钥匙")
        if k == "vision_key" and key["provider"] not in SEEING:
            raise ValueError("DeepSeek 看不见图，挑一把 Gemini / Claude / OpenAI 的")
        if k == "image_key" and key["provider"] not in DEFAULT_MODELS:
            raise ValueError("这家不会画图，挑一把 Gemini 或 OpenAI（兼容口）的")
        m[k] = str(key["id"])
    if "image_model" in body:
        m["image_model"] = str(body.get("image_model") or "").strip()[:100]
    await pool.execute("UPDATE accounts SET media = $2::jsonb WHERE id = $1", account, json.dumps(m))


async def vision_route(pool, box, account: UUID) -> Route | None:
    """挑过的看图钥匙；没挑 / 删了 = None（vision 再往下找）"""
    if box is None:
        return None
    m = await get(pool, account)
    k = await _key(pool, account, m.get("vision_key")) if m.get("vision_key") else None
    if k is None or k["provider"] not in SEEING:
        return None
    return Route(k["provider"], box.unlock(k["secret"]), k["chat_model"], k["chat_model"], base_url=k["base_url"])


async def image_route(pool, box, account: UUID) -> tuple[str, str, str, str | None] | None:
    """(哪家, key, 模型, 地址)；没挑 = None"""
    if box is None:
        return None
    m = await get(pool, account)
    k = await _key(pool, account, m.get("image_key")) if m.get("image_key") else None
    if k is None or k["provider"] not in DEFAULT_MODELS:
        return None
    return k["provider"], box.unlock(k["secret"]), m.get("image_model") or DEFAULT_MODELS[k["provider"]], k["base_url"]


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
    obj = await _post(f"{base}/images/generations", {"Authorization": f"Bearer {key}"},
                      {"model": model, "prompt": prompt, "n": 1, "size": "1024x1024"})
    first = (obj.get("data") or [{}])[0]
    if first.get("b64_json"):
        return base64.b64decode(first["b64_json"])
    if first.get("url"):
        async with (httpx.AsyncClient(transport=TRANSPORT) if TRANSPORT else httpx.AsyncClient()) as http:
            r = await http.get(first["url"], timeout=60)
            if r.status_code == 200:
                return r.content
    raise DrawError("没有图")


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
