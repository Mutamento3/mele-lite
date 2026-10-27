"""回声（10-27 内测：Host 设置里看账本、上次什么时候卷的、改一天）。测试用小满。"""
from datetime import date

from brain import archive
from test_api import Env


async def test_echo_lists_and_edits_ledger(pool):
    e = Env(pool)
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        assert (await c.get(f"/companions/{comp['id']}/echo")).json() == []          # 没卷过不列
        await archive.put_ledger(pool, conv["id"], {date(2026, 10, 25): "小满去试镜。", date(2026, 10, 26): "小满累了。"})
        await archive.save_state(pool, conv["id"], {"ledger_at": "2026-10-26T12:00:00+00:00", "voice_samples": ["好呀"]})
        got = (await c.get(f"/companions/{comp['id']}/echo")).json()
        assert [d["day"] for d in got[0]["days"]] == ["2026-10-26", "2026-10-25"]
        assert got[0]["at"] == "2026-10-26T12:00:00+00:00" and got[0]["samples"] == ["好呀"] and got[0]["fails"] == 0
        assert (await c.put(f"/conversations/{conv['id']}/echo", json={"day": "2026-10-25", "text": ""})).status_code == 200
        got = (await c.get(f"/companions/{comp['id']}/echo")).json()
        assert [d["day"] for d in got[0]["days"]] == ["2026-10-26"]
        assert (await c.put(f"/conversations/{conv['id']}/echo", json={"day": "坏的"})).status_code == 400
