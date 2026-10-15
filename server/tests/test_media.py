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
