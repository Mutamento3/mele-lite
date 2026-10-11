from datetime import datetime, timezone

from brain import timeline as T
from brain.archive import StoredMsg


def t(hm: str) -> datetime:
    h, m = map(int, hm.split(":"))
    return datetime(2026, 10, 11, h, m, tzinfo=timezone.utc)


ROOM = T.group_room("三人行", True)


def test_interleaves_by_time():
    dm = [StoredMsg(1, "user", "今天好累", "", t("20:00")), StoredMsg(2, "assistant", "抱抱", "", t("20:01")),
          StoredMsg(6, "user", "我回来了", "", t("20:10"))]
    group = [T.Item("g3", ROOM, "她", "@小满 你昨天说的那家店叫什么", t("20:05")),
             T.Item("g4", ROOM, "小满", "叫「半糖」", t("20:06")),
             T.Item("g5", ROOM, None, "又背着我去吃好吃的？", t("20:06"))]
    out = T.merge(dm, group, 30)
    assert [m.text for m in out] == ["今天好累", "抱抱", "〔群「三人行」 · 她〕@小满 你昨天说的那家店叫什么",
                                     "〔群「三人行」 · 小满〕叫「半糖」", "〔群「三人行」〕又背着我去吃好吃的？", "我回来了"]
    assert [m.role for m in out] == ["user", "assistant", "user", "user", "assistant", "user"]


def test_keeps_latest_n_and_zero_means_off():
    others = [T.Item(f"g{i}", ROOM, "小满", f"第{i}句", t(f"19:0{i}")) for i in range(5)]
    cur = [StoredMsg(1, "user", "在吗", "", t("20:00"))]
    assert [m.text for m in T.merge(cur, others, 2)] == ["〔群「三人行」 · 小满〕第3句", "〔群「三人行」 · 小满〕第4句", "在吗"]
    assert T.merge(cur, others, 0) == cur


def test_current_first_on_ties():
    cur = [StoredMsg(1, "user", "这边", "", t("20:00"))]
    o = [T.Item("g", T.private_room(True), "她", "那边", t("20:00"))]
    assert [m.text for m in T.merge(cur, o, 5)] == ["这边", "〔私聊 · 她〕那边"]
