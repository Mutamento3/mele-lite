from brain import group as G
from brain import model_noise

JU, MAN, MANMAN = G.Member("a", "阿橘"), G.Member("b", "小满"), G.Member("c", "小满满")


def test_mentions_in_order_of_appearance():
    assert G.mentioned("@小满 你说呢 @阿橘", [JU, MAN]) == ["b", "a"]
    assert G.mentioned("没有人被点名", [JU, MAN]) == []
    assert G.mentioned("@阿橘 @阿橘", [JU, MAN]) == ["a"]


def test_longer_name_wins():
    assert G.mentioned("@小满满 来", [MAN, MANMAN]) == ["c"]
    assert G.mentioned("@小满满 和 @小满", [MAN, MANMAN]) == ["c", "b"]


def test_mentioned_first_others_shuffled():
    assert G.order(["b"], ["a", "b", "c"], shuffle=lambda x: list(reversed(x))) == ["b", "c", "a"]
    assert G.order([], ["a", "c"], shuffle=lambda x: x) == ["a", "c"]
    assert G.order(["c"], [], shuffle=lambda x: x) == ["c"]


def test_judge_replies():
    assert G.wants_to_speak("说") and G.wants_to_speak(" 说。\n") and G.wants_to_speak("Speak")
    assert not any(G.wants_to_speak(x) for x in ["过", "嗯……过吧", "pass", "", "???"])


def test_judge_prompt_has_no_negative_opt_out():
    s, u = G.judge_prompt(zh=True, me="阿橘", persona="嘴硬心软的猫", group="三人行", user_name="她",
                          others=["小满"], recent=[("她", "今天吃什么"), ("小满", "火锅！")])
    both = s + u
    assert "阿橘" in both and "三人行" in both and "〔小满〕火锅！" in both
    assert "不想" not in both and "不说" not in both
    _, eu = G.judge_prompt(zh=False, me="Ju", persona="", group="Trio", user_name="her", others=["Man"], recent=[])
    assert "speak" in eu and "pass" in eu


def test_room_rules():
    r = G.room_rules(zh=True, group="三人行", me="阿橘", user_name="她", others=["小满"])
    assert all(x in r for x in ["三人行", "小满", "她", "〔", "群聊里", "留在私聊里"])


def test_strip_own_label():
    assert G.strip_own_label("〔阿橘〕好啊", "阿橘") == "好啊"
    assert G.strip_own_label("阿橘：好啊", "阿橘") == "好啊"
    assert G.strip_own_label("阿橘: 好啊", "阿橘") == "好啊"
    assert G.strip_own_label("阿橘觉得好", "阿橘") == "阿橘觉得好"
    assert G.strip_own_label("〔小满〕好啊", "阿橘") == "〔小满〕好啊"


def test_model_noise():
    raw = "<ds_safety>[用户未成年]否 [分类]其他 [判定]日常闲聊。 [规则]无</ds_safety>  那口汤记我名下。\n\n小满，吃完把碗放那儿。"
    assert model_noise.strip(raw) == "那口汤记我名下。\n\n小满，吃完把碗放那儿。"
    assert model_noise.strip("<ds_safety>[分类]其他\n好啊") == "好啊"
    assert model_noise.strip("  就一句话 <b>不是</b>") == "  就一句话 <b>不是</b>"
