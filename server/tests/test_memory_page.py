"""记忆库页 + 用量页（10-15）：连着 Host 时 App 读这些。别人的联系人碰不到；人物卡、关于 TA 不进列表。测试用小满。"""
from datetime import date
from uuid import UUID

import memory as M
from brain import archive
from llm.types import Usage
from test_api import Env


async def test_memory_page_and_usage(pool):
    e = Env(pool, [])
    t, other = await e.login(), await e.login("mia@example.com")
    async with e.client(t) as c:
        lumi, _ = await e.first_window(c)
        cid = lumi["id"]
        r = await c.post(f"/companions/{cid}/memories", json={"content": "小满怕热，最喜欢秋天", "tags": "季节，喜好",
                                                               "importance": 7, "pinned": True})
        assert r.status_code == 201
        m = r.json()
        assert (m["kind"], m["tags"], m["importance"]) == ("core", ["季节", "喜好"], 7)
        await M.remember(pool, e.deps.embedder, UUID(cid), "关于 TA 的小事", kind="about")
        assert [x["id"] for x in (await c.get(f"/companions/{cid}/memories")).json()] == [m["id"]]

        p = (await c.patch(f"/companions/{cid}/memories/{m['id']}",
                           json={"content": "小满很怕热", "pinned": False, "resolved": True})).json()
        assert (p["content"], p["kind"], p["resolved"]) == ("小满很怕热", "memory", True)

        g = (await c.get(f"/companions/{cid}/memories/stars")).json()
        assert [s["id"] for s in g["stars"]] == [m["id"]] and g["hubs"] == []

        me = UUID((await c.get("/me")).json()["id"])
        await archive.add_usage(pool, me, date(2026, 10, 15), "m1", Usage(input=100, output=20, cache_read=50), 0.01)
        await archive.add_usage(pool, me, date(2026, 10, 15), "m1", Usage(input=10, output=2), 0.001)
        u = (await c.get("/usage")).json()
        assert u[0]["day"] == "2026-10-15"
        row = u[0]["models"][0]
        assert (row["model"], row["calls"], row["input"], row["cache_read"], row["output"]) == ("m1", 2, 110, 50, 22)
        assert abs(row["cost"] - 0.011) < 1e-9

    async with e.client(other) as c:
        assert (await c.get(f"/companions/{cid}/memories")).status_code == 404
        assert (await c.delete(f"/companions/{cid}/memories/{m['id']}")).status_code == 404
        assert (await c.get("/usage")).json() == []

    async with e.client(t) as c:
        assert (await c.delete(f"/companions/{cid}/memories/{m['id']}")).status_code == 204
        assert (await c.get(f"/companions/{cid}/memories")).json() == []
