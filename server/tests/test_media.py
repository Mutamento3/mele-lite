"""看图和画图（10-15）：Me 里挑看图钥匙（模型看不见图时先给它看）、挑画图钥匙（TA 才有 draw，画好挂在它那句上）。测试用小满。"""
import base64
import json
from uuid import UUID

import httpx

from brain import media
from llm.fake import FakeModel
from test_api import Env
from test_vision import go, png


async def _keys(c):
    ds = (await c.post("/keys", json={"provider": "deepseek", "api_key": "sk-deepseek-1111", "chat_model": "deepseek-flash"})).json()
    gm = (await c.post("/keys", json={"provider": "gemini", "api_key": "AIza-gemini-2222", "chat_model": "gemini-3.5-flash-lite"})).json()
    return ds, gm


async def test_settings(pool):
    e = Env(pool)
    t = await e.login()
    async with e.client(t) as c:
        ds, gm = await _keys(c)
        got = (await c.get("/me/media")).json()
        assert got["vision_key"] is None and got["image_key"] is None and got["default_models"]["gemini"]
        assert (await c.put("/me/media", json={"vision_key": ds["id"]})).status_code == 400       # DeepSeek 看不见
        assert (await c.put("/me/media", json={"image_key": ds["id"]})).status_code == 400
        assert (await c.put("/me/media", json={"vision_key": "00000000-0000-0000-0000-000000000000"})).status_code == 404
        got = (await c.put("/me/media", json={"vision_key": gm["id"], "image_key": gm["id"], "image_model": " my-image "})).json()
        assert got["vision_key"] == gm["id"] and got["image_key"] == gm["id"] and got["image_model"] == "my-image"
        await c.delete(f"/keys/{gm['id']}")                                   # 钥匙删了：设置里当没挑
        got = (await c.get("/me/media")).json()
        assert got["vision_key"] is None and got["image_key"] is None


async def test_picked_vision_key_describes_for_a_blind_model(pool, tmp_path):
    e = Env(pool, ["看到海了"])
    eye = FakeModel(["一张蓝色的方图。"])
    chat = e.deps.adapter_for
    seen = []
    e.deps.adapter_for = lambda r: (seen.append(r.api_key), eye)[1] if r.provider == "gemini" else chat(r)
    t = await e.login()
    async with e.client(t) as c:
        _, gm = await _keys(c)
        await c.put("/me/media", json={"vision_key": gm["id"]})
    conv = await go(e, t, tmp_path, ["今天拍的"])
    assert seen == ["AIza-gemini-2222"] and eye.requests[0].messages[0].images
    assert "一张蓝色的方图" in e.model.requests[0].messages[-1].text
    assert await pool.fetchval("SELECT caption_source FROM attachments WHERE conversation_id = $1", conv) == "key"


def fake_gemini(calls):
    def handle(req: httpx.Request):
        assert req.headers["x-goog-api-key"] == "AIza-gemini-2222" and "my-image" in req.url.path
        calls.append(json.loads(req.content)["contents"][0]["parts"][0]["text"])
        return httpx.Response(200, json={"candidates": [{"content": {"parts": [
            {"text": "好的"}, {"inlineData": {"mimeType": "image/png", "data": base64.b64encode(png()).decode()}}]}}]})
    return httpx.MockTransport(handle)


async def test_draw_attaches_to_the_reply(pool, tmp_path):
    calls = []
    media.TRANSPORT = fake_gemini(calls)
    try:
        e = Env(pool, [{"calls": [("draw", {"prompt": "傍晚的海边，水彩"})]}, "给你画的", "嗯"])
        e.deps.files_dir = tmp_path
        e.app.state.api.cfg.files_dir = tmp_path
        t = await e.login()
        async with e.client(t) as c:
            comp, conv = await e.first_window(c)
            await c.patch(f"/companions/{comp['id']}", json={"settings": {"reply_wait": 0}})
            _, gm = await _keys(c)
            await c.put("/me/media", json={"image_key": gm["id"], "image_model": "my-image"})
            await c.post(f"/conversations/{conv['id']}/messages", json={"text": "画个海给我看"})
            await e.rooms.idle(UUID(conv["id"]))
            msgs = (await c.get(f"/conversations/{conv['id']}/messages")).json()["messages"]
            mine = [m for m in msgs if m["role"] == "assistant"][-1]
            assert mine["text"] == "给你画的" and [a["kind"] for a in mine["attachments"]] == ["image"]
            assert (await c.get(f"/attachments/{mine['attachments'][0]['id']}")).status_code == 200
            assert (await c.get("/me/media")).json()["drawn_today"] == 1
            await c.post(f"/conversations/{conv['id']}/messages", json={"text": "好看"})
            await e.rooms.idle(UUID(conv["id"]))
        assert calls == ["傍晚的海边，水彩"]
        assert "draw" in {s.name for s in e.model.requests[0].tools}
        assert "〔你画了一张图：傍晚的海边，水彩〕" in "\n".join(m.text for m in e.model.requests[-1].messages)
    finally:
        media.TRANSPORT = None


async def test_no_image_key_no_draw_tool(pool, tmp_path):
    e = Env(pool, ["嗯"])
    e.deps.files_dir = tmp_path
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"reply_wait": 0}})
        await c.post(f"/conversations/{conv['id']}/messages", json={"text": "在吗"})
        await e.rooms.idle(UUID(conv["id"]))
    assert "draw" not in {s.name for s in e.model.requests[0].tools}


def fake_relay(seen, *, models=("gemini-2.5-flash", "gpt-image-1-mini", "nano-banana"), images_ok=False):
    """假中转站：/models 列表；/images/generations 503（没这条渠道）；/chat/completions 回带 data URI 的图"""
    def handle(req: httpx.Request):
        seen.append((req.method, req.url.path))
        assert req.headers["authorization"] == "Bearer sk-relay-3333"
        if req.url.path.endswith("/models"):
            return httpx.Response(200, json={"data": [{"id": m} for m in models]})
        if req.url.path.endswith("/images/generations"):
            if images_ok:
                return httpx.Response(200, json={"data": [{"b64_json": base64.b64encode(png()).decode()}]})
            return httpx.Response(503, json={"error": {"message": "no available channel for model"}})
        b64 = base64.b64encode(png()).decode()
        return httpx.Response(200, json={"choices": [{"message": {"content": f"好的 ![img](data:image/png;base64,{b64})"}}]})
    return httpx.MockTransport(handle)


async def test_direct_keys_check_and_route_10_16(pool):
    """10-16：Me 里直接填看图 / 画图钥匙——存时查模型列表；直接填的优先于钥匙串；清掉回到钥匙串"""
    seen = []
    media.TRANSPORT = fake_relay(seen)
    try:
        e = Env(pool)
        t = await e.login()
        async with e.client(t) as c:
            relay = {"provider": "openai-compatible", "api_key": "sk-relay-3333", "base_url": "https://relay.example/v1/"}
            assert (await c.put("/me/media/direct/draw", json={**relay, "model": ""})).status_code == 400      # 中转站要填模型
            assert (await c.put("/me/media/direct/draw", json={"provider": "deepseek", "api_key": "x"})).status_code == 400
            got = (await c.put("/me/media/direct/draw", json={**relay, "model": "gpt-image-1"})).json()
            assert got["check"]["ok"] is False and "gpt-image-1-mini" in got["check"]["message"] and "nano-banana" in got["check"]["message"]
            assert got["direct"]["draw"]["last4"] == "3333" and "secret" not in got["direct"]["draw"]
            assert got["direct"]["draw"]["base_url"] == "https://relay.example/v1"
            got = (await c.put("/me/media/direct/draw", json={**relay, "api_key": "", "model": "nano-banana"})).json()   # 不重填 key
            assert got["check"]["ok"] is True
            acc = await pool.fetchval("SELECT id FROM accounts LIMIT 1")
            assert await media.image_route(pool, e.deps.keys.box, acc) == ("openai-compatible", "sk-relay-3333", "nano-banana", "https://relay.example/v1")
            assert await media.vision_route(pool, e.deps.keys.box, acc) is None
            _, gm = await _keys(c)
            await c.put("/me/media", json={"image_key": gm["id"]})
            assert (await media.image_route(pool, e.deps.keys.box, acc))[0] == "openai-compatible"        # 直接填的优先
            got = (await c.put("/me/media/direct/draw")).json()                                             # 清掉
            assert got["direct"]["draw"] is None and got["check"] is None
            assert (await media.image_route(pool, e.deps.keys.box, acc))[0] == "gemini"                    # 回到钥匙串那把
    finally:
        media.TRANSPORT = None


async def test_relay_draw_falls_back_to_chat_10_16():
    seen = []
    media.TRANSPORT = fake_relay(seen)
    try:
        data = await media.generate("openai-compatible", "sk-relay-3333", "nano-banana", "https://relay.example/v1", "海")
        assert data == png() and [p for _, p in seen] == ["/v1/images/generations", "/v1/chat/completions"]
    finally:
        media.TRANSPORT = None


def test_verdict_10_16():
    assert media.verdict(401, [], "x", "draw")["ok"] is False
    assert media.verdict(404, [], "x", "draw")["ok"] is True                     # 不给看列表：存下，用时才知道
    assert media.verdict(200, ["gpt-4.1-mini"], "gpt-4.1-mini", "vision")["ok"] is True
    assert "没有画图模型" in media.verdict(200, ["gpt-4.1-mini"], "gpt-image-1", "draw")["message"]
