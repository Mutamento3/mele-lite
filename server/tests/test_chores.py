"""钥匙串分活（10-15）：一样活归一把钥匙，没人勾就跟聊天那把。测试用小满。"""
import pytest

from brain import chores as C


def test_can_by_provider():
    assert C.can("elevenlabs") == ["voice"]
    ds = C.can("deepseek")
    assert "ledger" in ds and "diary" in ds and not {"vision", "caption", "draw", "voice"} & set(ds)
    assert "vision" in C.can("anthropic") and "draw" not in C.can("anthropic")
    assert "draw" in C.can("gemini") and "voice" not in C.can("gemini")
    assert C.can("openai-compatible") == C.can("openai") == C.can("gemini")


def test_assign_moves_and_clears():
    t, moved = C.assign({}, "g", "gemini", ["vision", "draw"])
    assert t == {"vision": "g", "draw": "g"} and moved == []
    t, moved = C.assign(t, "d", "deepseek", ["ledger"])
    assert t == {"vision": "g", "draw": "g", "ledger": "d"} and moved == []
    t, moved = C.assign(t, "o", "openai", ["draw", "ledger"])
    assert t == {"vision": "g", "draw": "o", "ledger": "o"}
    assert moved == [{"chore": "draw", "from_key": "g"}, {"chore": "ledger", "from_key": "d"}]
    t, _ = C.assign(t, "g", "gemini", [])                     # 全不勾 = 这把的活全取消
    assert t == {"draw": "o", "ledger": "o"}
    with pytest.raises(ValueError):
        C.assign(t, "d", "deepseek", ["vision"])


def test_migrate_from_old_media():
    old = {"vision_key": "g", "image_key": "o", "image_model": "gpt-image-1"}
    m = C.migrate(old)
    assert m["chores"] == {"vision": "g", "draw": "o"} and m["draw_model"] == "gpt-image-1"
    assert "chores" not in old                               # 不改入参
    again = C.migrate({**m, "vision_key": "x"})               # 搬过了就不再搬
    assert again["chores"] == {"vision": "g", "draw": "o"}
    assert C.migrate({})["chores"] == {} and C.migrate({})["draw_model"] == ""


def test_pick():
    t = {"vision": "g", "ledger": "gone", "draw": "d"}
    live = {"g": "gemini", "d": "deepseek"}
    assert C.pick(t, "vision", live) == "g"
    assert C.pick(t, "ledger", live) is None                  # 钥匙删了
    assert C.pick(t, "draw", live) is None                    # 那家干不了
    assert C.pick(t, "diary", live) is None                   # 没人勾


def test_groups():
    assert C.OWN == {"diary", "day", "moments", "tarot", "focus"}
    assert C.ODD == {"dedupe", "food", "caption", "import", "music", "translate"}
    assert set(C.CHORES) == {"vision", "draw", "ledger", "voice"} | C.OWN | C.ODD


from test_api import Env


async def _two_keys(c):
    ds = (await c.post("/keys", json={"provider": "deepseek", "api_key": "sk-deepseek-1111", "chat_model": "deepseek-flash"})).json()
    gm = (await c.post("/keys", json={"provider": "gemini", "api_key": "AIza-gemini-2222", "chat_model": "gemini-3.5-flash-lite"})).json()
    return ds, gm


async def test_keys_carry_chores_and_patch_moves(pool):
    e = Env(pool)
    async with e.client(await e.login()) as c:
        ds, gm = await _two_keys(c)
        got = {k["id"]: k for k in (await c.get("/keys")).json()}
        assert got[gm["id"]]["chores"] == [] and "draw" in got[gm["id"]]["can"] and "vision" not in got[ds["id"]]["can"]
        r = await c.patch(f"/keys/{gm['id']}", json={"chores": ["vision", "draw", "ledger"], "draw_model": " my-image "})
        assert r.status_code == 200 and r.json()["chores"] == ["vision", "draw", "ledger"] and r.json()["draw_model"] == "my-image"
        r = await c.patch(f"/keys/{ds['id']}", json={"chores": ["ledger"]})
        assert r.json()["moved"] == [{"chore": "ledger", "from_key": gm["id"]}]
        assert (await c.patch(f"/keys/{ds['id']}", json={"chores": ["vision"]})).status_code == 400
        assert (await c.patch("/keys/00000000-0000-0000-0000-000000000000", json={"chores": []})).status_code == 404
        media = (await c.get("/me/media")).json()                 # 旧接口照样读得到
        assert media["vision_key"] == gm["id"] and media["image_key"] == gm["id"] and media["image_model"] == "my-image"


async def test_old_media_put_writes_chores(pool):
    e = Env(pool)
    async with e.client(await e.login()) as c:
        ds, gm = await _two_keys(c)
        await c.put("/me/media", json={"vision_key": gm["id"]})
        got = {k["id"]: k for k in (await c.get("/keys")).json()}
        assert got[gm["id"]]["chores"] == ["vision"]


from uuid import UUID as _UUID

from brain.scope import Scope
from brain.turn import resolve_route


async def test_resolve_route_uses_picked_key_then_falls_back(pool):
    e = Env(pool)
    async with e.client(await e.login()) as c:
        lumi, _ = await e.first_window(c)
        ds, gm = await _two_keys(c)
        await c.patch(f"/companions/{lumi['id']}", json={"key_id": ds["id"]})
        await c.patch(f"/keys/{gm['id']}", json={"chores": ["diary", "food"]})
    comp = _UUID(lumi["id"])
    acc = await pool.fetchval("SELECT account_id FROM companions WHERE id = $1", comp)
    scope = Scope(acc, comp, None)
    diary = await resolve_route(e.deps.keys, scope, chore="diary")
    assert diary.provider == "gemini" and diary.chat_model == diary.ledger_model == "gemini-3.5-flash-lite"
    music = await resolve_route(e.deps.keys, scope, chore="music")       # 没人勾 = 聊天那把
    assert music.provider == "deepseek"
    assert (await resolve_route(e.deps.keys, scope)).provider == "deepseek"


from datetime import date

from brain import ledger
from llm.errors import LLMError
from llm.fake import FakeModel


async def test_ledger_leg_can_be_another_key():
    cheap = FakeModel([LLMError("other", "boom")])            # 勾了写账本的那把挂了
    chat = FakeModel(["晚上吃了芒果冰，说下次还要那家。"])
    entry, spent = await ledger.write_entry(chat, [(cheap, "cheap-model"), (chat, "chat-model")],
                                            "小满：晚上吃了芒果冰，下次还去那家", date(2026, 10, 15), "", name="Lumi", lang="zh")
    assert entry and "芒果" in entry
    assert cheap.requests[0].model == "cheap-model" and chat.requests[0].model == "chat-model"
    assert spent[0][0] == "chat-model"
