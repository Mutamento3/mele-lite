"""让别的 AI 连上 TA 的记忆（10-16）：生成地址 → 用地址走一遍 MCP → 换钥匙旧的作废 → 关掉。测试用小满。"""
from uuid import UUID

from test_api import Env


def rpc(i, method, params=None):
    return {"jsonrpc": "2.0", "id": i, "method": method, "params": params or {}}


async def test_link_and_mcp_round_trip(pool):
    e = Env(pool, [])
    t, other = await e.login(), await e.login("mia@example.com")
    async with e.client(t) as c:
        lumi, _ = await e.first_window(c)
        cid = lumi["id"]
        assert (await c.get(f"/companions/{cid}/memory-link")).status_code == 404       # 不是 Host 不开
        e.app.state.api.cfg.host_mode = True
        assert (await c.get(f"/companions/{cid}/memory-link")).json() == {"url": None}
        url = (await c.post(f"/companions/{cid}/memory-link")).json()["url"]
        assert "/mcp/memory/" in url and (await c.get(f"/companions/{cid}/memory-link")).json()["url"] == url
        path = "/mcp/memory/" + url.rsplit("/", 1)[1]

        init = (await c.post(path, json=rpc(1, "initialize", {"protocolVersion": "2025-03-26"}))).json()
        assert init["result"]["protocolVersion"] == "2025-03-26" and "tools" in init["result"]["capabilities"]
        assert (await c.post(path, json={"jsonrpc": "2.0", "method": "notifications/initialized"})).status_code == 202
        names = [x["name"] for x in (await c.post(path, json=rpc(2, "tools/list"))).json()["result"]["tools"]]
        assert names == ["remember", "search", "list_memories", "update", "forget", "pin", "resolve"]

        async def call(i, name, args):
            r = (await c.post(path, json=rpc(i, "tools/call", {"name": name, "arguments": args}))).json()["result"]
            return r["content"][0]["text"], r["isError"]

        text, err = await call(3, "remember", {"content": "小满怕热，最喜欢秋天", "tags": ["季节"]})
        assert not err and text.startswith("Saved as #")
        mid = int(text.rsplit("#", 1)[1])
        # 存进的就是 TA 那本：App 的记忆库页看得到
        assert [m["id"] for m in (await c.get(f"/companions/{cid}/memories")).json()] == [mid]
        assert "小满怕热" in (await call(4, "search", {"query": "秋天"}))[0]
        assert f"#{mid}" in (await call(5, "list_memories", {}))[0]
        assert "很怕热" in (await call(6, "update", {"id": mid, "content": "小满很怕热"}))[0]
        assert "Pinned" in (await call(7, "pin", {"id": mid}))[0]
        assert (await call(8, "forget", {"id": 999999}))[1] is True                      # 别人的 / 没有的碰不到
        assert "Deleted" in (await call(9, "forget", {"id": mid}))[0]
        batch = (await c.post(path, json=[rpc(10, "ping"), {"jsonrpc": "2.0", "method": "notifications/x"}])).json()
        assert batch == [{"jsonrpc": "2.0", "id": 10, "result": {}}]
        assert (await c.post(path, json=rpc(11, "nope"))).json()["error"]["code"] == -32601

        # Bearer 也认
        token = url.rsplit("/", 1)[1]
        r = await c.post("/mcp/memory", json=rpc(12, "ping"), headers={"Authorization": f"Bearer {token}"})
        assert r.json()["result"] == {}

        # 换一把：旧地址作废
        url2 = (await c.post(f"/companions/{cid}/memory-link")).json()["url"]
        assert url2 != url and (await c.post(path, json=rpc(13, "ping"))).status_code == 401
        # 关掉
        assert (await c.delete(f"/companions/{cid}/memory-link")).json() == {"url": None}
        assert (await c.post("/mcp/memory/" + url2.rsplit("/", 1)[1], json=rpc(14, "ping"))).status_code == 401
    async with e.client(other) as c2:                                                  # 别人管不到小满的 TA
        assert (await c2.post(f"/companions/{cid}/memory-link")).status_code == 404
    assert UUID(cid)
