"""双语气泡（10-15）：TA 说英文、每泡下面一行中文；你的泡也双语。测试用小满。"""
from brain import archive, bilingual
from brain.settings import Settings
from llm.fake import FakeModel
from test_turn import make_deps, of, turn


def test_split_self():
    o, t = bilingual.split_self(["...Right.\n〔译〕……对。", "Keegan? Krueger?\n[译]: 基根？克鲁格？", "No translation here"])
    assert o == ["...Right.", "Keegan? Krueger?", "No translation here"]
    assert t == ["……对。", "基根？克鲁格？", None]
    o, t = bilingual.split_self(["What?", "〔译〕什么？"])           # 〔译〕自己成了一泡：接到前一泡
    assert o == ["What?"] and t == ["什么？"]


def test_parse_list():
    assert bilingual.parse_list('```json\n["对。", "基根？"]\n```', 2) == ["对。", "基根？"]
    assert bilingual.parse_list('["只有一句"]', 2) == [None, None]
    assert bilingual.parse_list("不是 JSON", 1) == [None]


def test_rule_and_user_side():
    s = Settings.from_dict({"bilingual": True, "bilingual_by": "self"})
    assert "English" in bilingual.rule(s) and "〔译〕" in bilingual.rule(s) and bilingual.target(s) == "中文"
    assert bilingual.user_side("你知道吗？", ["Did you know?"]) == "Did you know?"
    assert bilingual.user_side("你知道吗？", [None]) == "你知道吗？"


async def _on(pool, user, by="key"):
    await archive.save_settings(pool, user, {**(await archive.get_settings(pool, user)),
                                             "bilingual": True, "bilingual_by": by, "thinking_mode": "native"})


async def test_turn_translates_only_ta_with_key(pool, user_a):
    """10-15 内测：用户不要翻自己那句——你的话原样发给 TA、泡上不加译文；只翻 TA 的。"""
    m = FakeModel(["...Right.\n\nKeegan? Or that giant child?",                    # TA 用英文回
                   '["……对。", "基根？还是那个巨大的孩子？"]'])                       # 再翻 TA 的两泡
    await _on(pool, user_a)
    ev = await turn(make_deps(pool, m), user_a, "你知道吗？我想我爱上某个人了…")
    bubbles = of(ev, "bubble")
    assert [b["text"] for b in bubbles] == ["...Right.", "Keegan? Or that giant child?"]
    assert [b.get("translation") for b in bubbles] == ["……对。", "基根？还是那个巨大的孩子？"]
    assert "你知道吗" in m.requests[0].messages[-1].text and "〔双语〕" in m.requests[0].messages[-1].text
    assert of(ev, "user_translation") == []
    msgs = await archive.recent(pool, user_a, 5)
    me, ta = [x for x in msgs if x.role == "user"][-1], [x for x in msgs if x.role == "assistant"][-1]
    assert me.text == "你知道吗？我想我爱上某个人了…" and me.translations is None
    assert ta.text == "...Right.\n\nKeegan? Or that giant child?" and ta.translations == ["……对。", "基根？还是那个巨大的孩子？"]


async def test_self_mode_cuts_translation_lines(pool, user_a):
    m = FakeModel(["What?\n〔译〕什么？\n\nWhy?\n〔译〕为什么？"])
    await _on(pool, user_a, by="self")
    ev = await turn(make_deps(pool, m), user_a, "什么？为什么？")
    assert [(b["text"], b.get("translation")) for b in of(ev, "bubble")] == [("What?", "什么？"), ("Why?", "为什么？")]
    ta = [x for x in await archive.recent(pool, user_a, 5) if x.role == "assistant"][-1]
    assert ta.text == "What?\n\nWhy?" and "〔译〕" not in ta.text


async def test_translation_failure_shows_original(pool, user_a):
    m = FakeModel(["Sure.", "不是 JSON"])
    await _on(pool, user_a)
    ev = await turn(make_deps(pool, m), user_a, "好吗")
    assert [(b["text"], b.get("translation")) for b in of(ev, "bubble")] == [("Sure.", None)]
