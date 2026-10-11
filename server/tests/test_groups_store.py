"""群聊存储（10-11）：建群、加人踢人、删 TA 退群、一段脑子捞别的房间。测试用阿橘 / 小满。"""
from datetime import datetime, timedelta, timezone

import pytest

from brain import accounts, archive, groups

T0 = datetime(2026, 10, 11, 12, 0, tzinfo=timezone.utc)


async def setup(pool):
    acc = await accounts.create_account(pool)
    ju = await accounts.create_companion(pool, acc)
    man = await accounts.create_companion(pool, acc)
    await archive.save_persona(pool, ju, {"name": "阿橘"})
    await archive.save_persona(pool, man, {"name": "小满"})
    return acc, ju, man


async def test_create_needs_two_and_lists(pool):
    acc, ju, man = await setup(pool)
    with pytest.raises(ValueError):
        await groups.create(pool, acc, "", [ju], T0)
    g = await groups.create(pool, acc, "", [ju, man, ju], T0)
    o = await groups.out(pool, g)
    assert o["display_name"] == "阿橘、小满" and o["members"] == [str(ju), str(man)] and o["max_rounds"] == 6
    assert [r["id"] for r in await groups.list_for(pool, acc)] == [g["id"]]
    # 群不出现在联系人的窗口列表里
    assert all(c.id != g["id"] for c in await accounts.list_conversations(pool, acc, ju))


async def test_kick_rejoin_and_delete_companion(pool):
    acc, ju, man = await setup(pool)
    xiao = await accounts.create_companion(pool, acc)
    g = await groups.create(pool, acc, "三人行", [ju, man, xiao], T0)
    await groups.kick(pool, g["id"], xiao, T0 + timedelta(minutes=1))
    o = await groups.out(pool, g)
    assert o["members"] == [str(ju), str(man)] and o["former_members"] == [str(xiao)]
    await groups.add_member(pool, acc, g["id"], xiao, T0 + timedelta(minutes=2))
    assert (await groups.out(pool, g))["former_members"] == []
    await groups.kick(pool, g["id"], man, T0)
    await groups.kick(pool, g["id"], xiao, T0)
    with pytest.raises(ValueError):
        await groups.kick(pool, g["id"], ju, T0)                 # 至少留一个
    await groups.companion_removed(pool, ju, T0)                # 删 TA：force 退群
    assert await groups.members(pool, g["id"]) == []


async def test_other_rooms_interleave_and_privacy(pool):
    acc, ju, man = await setup(pool)
    dm_ju = await accounts.new_conversation(pool, acc, ju)
    dm_man = await accounts.new_conversation(pool, acc, man)
    g = await groups.create(pool, acc, "三人行", [ju, man], T0)
    await archive.add_message(pool, dm_ju, "user", "悄悄跟阿橘说", now=T0 + timedelta(minutes=1))
    await archive.add_message(pool, dm_man, "user", "悄悄跟小满说", now=T0 + timedelta(minutes=2))
    await archive.add_message(pool, g["id"], "user", "大家好", now=T0 + timedelta(minutes=3))
    await archive.add_message(pool, g["id"], "assistant", "嗨", speaker=man, speaker_name="小满", now=T0 + timedelta(minutes=4))
    await archive.add_message(pool, g["id"], "assistant", "来啦", speaker=ju, speaker_name="阿橘", now=T0 + timedelta(minutes=5))
    # 阿橘在私聊里：看得到群里的，自己说的标成自己
    items = await groups.other_rooms(pool, ju, dm_ju, 30, "她", "zh")
    assert [(i.room, i.who, i.text) for i in items] == [("群「三人行」", "她", "大家好"), ("群「三人行」", "小满", "嗨"),
                                                        ("群「三人行」", None, "来啦")]
    # 阿橘在群里：看得到自己的私聊，看不到小满的私聊
    items = await groups.other_rooms(pool, ju, g["id"], 30, "她", "zh")
    assert [i.text for i in items] == ["悄悄跟阿橘说"]
    assert await groups.other_rooms(pool, ju, g["id"], 0, "她", "zh") == []


async def test_kicked_member_sees_group_only_until_kick(pool):
    acc, ju, man = await setup(pool)
    dm_ju = await accounts.new_conversation(pool, acc, ju)
    g = await groups.create(pool, acc, "", [ju, man], T0)
    await archive.add_message(pool, g["id"], "user", "踢之前", now=T0 + timedelta(minutes=1))
    await groups.kick(pool, g["id"], ju, T0 + timedelta(minutes=2))
    await archive.add_message(pool, g["id"], "user", "踢之后", now=T0 + timedelta(minutes=3))
    assert [i.text for i in await groups.other_rooms(pool, ju, dm_ju, 30, "她", "zh")] == ["踢之前"]
