"""群聊接口（10-11）：建群、@ 的必须接、没人想说就停、补拉带说话人、加人踢人、删群。测试用阿橘。"""
import asyncio
from uuid import UUID

from brain import archive
from test_api import Env


async def setup(pool, script):
    e = Env(pool, script)
    t = await e.login()
    async with e.client(t) as c:
        lumi = (await c.get("/companions")).json()[0]
        ju = (await c.post("/companions", json={"name": "阿橘"})).json()
    await archive.save_persona(pool, UUID(ju["id"]), {**(await archive.get_persona(pool, UUID(ju["id"])) or {}), "name": "阿橘"})
    return e, t, lumi, ju


async def wait_round(e, gid):
    await asyncio.sleep(0.05)
    await e.rooms.idle(UUID(gid))


async def test_group_round_mentioned_speaks_others_judge(pool):
    e, t, lumi, ju = await setup(pool, ["过", "你好呀", "过"])
    async with e.client(t) as c:
        r = await c.post("/groups", json={"name": "", "members": [lumi["id"], ju["id"]]})
        assert r.status_code == 201
        g = r.json()
        assert g["display_name"] == f"{lumi['name']}、阿橘" and g["max_rounds"] == 6
        assert [x["id"] for x in (await c.get("/groups")).json()] == [g["id"]]
        r = await c.post(f"/conversations/{g['id']}/messages", json={"text": f"@{lumi['name']} 在吗", "client_id": "x1"})
        assert r.status_code == 202
        await wait_round(e, g["id"])
        msgs = (await c.get(f"/conversations/{g['id']}/messages")).json()["messages"]
        assert [(m["role"], m["speaker"], m["text"]) for m in msgs] == [
            ("user", None, f"@{lumi['name']} 在吗"), ("assistant", lumi["id"], "你好呀")]
        assert msgs[1]["speaker_name"] == lumi["name"]
        # 判断那两次记成「模型 · 群聊判断」
        rows = await pool.fetch("SELECT model, calls FROM usage_daily WHERE model LIKE '%群聊判断'")
        assert sum(r["calls"] for r in rows) == 2
        assert (await c.get("/groups")).json()[0]["preview"] == f"{lumi['name']}：你好呀"


async def test_nobody_wants_to_speak_is_quiet(pool):
    e, t, lumi, ju = await setup(pool, ["过", "过"])
    async with e.client(t) as c:
        g = (await c.post("/groups", json={"members": [lumi["id"], ju["id"]]})).json()
        await c.post(f"/conversations/{g['id']}/messages", json={"text": "大家好", "client_id": "x1"})
        await wait_round(e, g["id"])
        msgs = (await c.get(f"/conversations/{g['id']}/messages")).json()["messages"]
        assert [m["role"] for m in msgs] == ["user"]


async def test_manage_members_and_delete(pool):
    e, t, lumi, ju = await setup(pool, [])
    async with e.client(t) as c:
        assert (await c.post("/groups", json={"members": [lumi["id"]]})).status_code == 400
        g = (await c.post("/groups", json={"members": [lumi["id"], ju["id"]]})).json()
        gid = g["id"]
        r = (await c.patch(f"/groups/{gid}", json={"name": "三人行", "max_rounds": 99, "new_member_sees_history": False})).json()
        assert r["name"] == "三人行" and r["max_rounds"] == 12 and r["new_member_sees_history"] is False
        r = (await c.delete(f"/groups/{gid}/members/{ju['id']}")).json()
        assert r["members"] == [lumi["id"]] and r["former_members"] == [ju["id"]]
        assert (await c.delete(f"/groups/{gid}/members/{lumi['id']}")).status_code == 400
        r = (await c.post(f"/groups/{gid}/members", json={"companion": ju["id"]})).json()
        assert r["members"] == [lumi["id"], ju["id"]]
        est = (await c.get(f"/groups/{gid}/estimate")).json()
        assert "per_message_usd" in est
        assert (await c.delete(f"/groups/{gid}")).status_code == 204
        assert (await c.get("/groups")).json() == []
