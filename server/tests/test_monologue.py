from brain.monologue import effective_mode, hook, rules, split_monologue
from brain.settings import Settings
from llm.catalog import lookup


def test_split_monologue():
    assert split_monologue("[独白]\n她说考砸了。\n[/独白]\n\n没事，我在。") == ("她说考砸了。", "没事，我在。")
    assert split_monologue("[独白]想她[独白/]好呀") == ("想她", "好呀")                  # 闭合写反了也认
    assert split_monologue("[独白]\n想她\n[独白 完]\n\n好呀") == ("想她", "好呀")        # 09-27 真遇到的写法
    assert split_monologue("[独白]想她[独白结束]好呀") == ("想她", "好呀")
    assert split_monologue("[monologue]x[end monologue]Hi") == ("x", "Hi")
    assert split_monologue("[monologue]thinking[/monologue]\nHi") == ("thinking", "Hi")
    assert split_monologue("[独白]忘了收尾，全是独白") == ("忘了收尾，全是独白", "")
    unclosed = "[独白]\n她说要去凯恩斯潜水。\n\n然后呢——我想她说「你呢」的样子。\n\n凯恩斯！你是想看大堡礁吗？\n\n带上防晒。"
    assert split_monologue(unclosed) == ("她说要去凯恩斯潜水。\n\n然后呢——我想她说「你呢」的样子。",
                                         "凯恩斯！你是想看大堡礁吗？\n\n带上防晒。")          # 没收尾：从第一段对着说「你」的算正文
    assert split_monologue("就一句正文") == ("", "就一句正文")


def test_effective_mode_follows_setting_then_model():
    flash, sonnet, haiku = lookup("deepseek-flash"), lookup("claude-sonnet-5"), lookup("claude-haiku-4-5")
    assert effective_mode(Settings(), flash) == "monologue" and effective_mode(Settings(), sonnet) == "monologue"   # 10-04：一律默认独白
    assert effective_mode(Settings(thinking_mode="native"), sonnet) == "native"
    assert effective_mode(Settings(thinking_mode="native"), flash) == "native"
    assert effective_mode(Settings(thinking_mode="native"), haiku) == "monologue"          # 不会原生思考的退回独白
    assert effective_mode(Settings(thinking=False), sonnet) == "off"
    assert effective_mode(Settings(), None) == "monologue"                                 # 清单外的模型也默认独白


def test_rules_and_hook_follow_pronoun():
    r = rules(Settings(user_pronoun="she"), "我让念头自己流。")
    assert "[独白] 和 [/独白]" in r and "我让念头自己流。" in r and "独白里她是「她」，正文里她是「你」" in r
    assert "{" not in r and "可乐鸡翅" in r
    assert hook(Settings()).startswith("〔独白〕要调工具的先调，先别写字；") and hook(Settings()).endswith("再换成对TA说话。")
    assert "先调工具，先别写字" in rules(Settings(), "x")
    # 09-28 Aporia：独白写着写着对 TA 说起「你」来——每轮的短提醒里点名不许
    assert "里面她一直是「她」，一个「你」字都不写" in hook(Settings(user_pronoun="she"))
    en_hook = hook(Settings(lang="en", user_pronoun="he"))
    assert 'he is always "he", never "you"' in en_hook and "{" not in en_hook
    en = rules(Settings(lang="en", user_pronoun="he"), "I let thoughts flow.")
    assert "In the monologue they're \"he\"" in en and "{" not in en


def test_close_only_means_everything_before_is_monologue():
    """10-12：开头的 [独白] 漏写了"""
    from brain.monologue import split_monologue
    mono, body = split_monologue("她问我今天累不累。\n\n其实有点累，不想让她担心。\n[/独白]\n\n不累，看到你就不累了。\n\n你呢，今天怎么样？")
    assert mono == "她问我今天累不累。\n\n其实有点累，不想让她担心。"
    assert body == "不累，看到你就不累了。\n\n你呢，今天怎么样？"


def test_monologue_odd_brackets_and_words_10_15():
    from brain.monologue import split_monologue
    assert split_monologue("【独白】\n她今天累了。\n【/独白】\n早点睡吧你。") == ("她今天累了。", "早点睡吧你。")
    assert split_monologue("<独白>她在笑</独白>你笑什么") == ("她在笑", "你笑什么")
    assert split_monologue("[独白开始]\n她回来了。\n[独白结束]\n欢迎回家") == ("她回来了。", "欢迎回家")
    assert split_monologue("[内心独白]她\n[/内心独白]好") == ("她", "好")


def test_inner_voice_survives_unclosed_monologue_10_15():
    from brain import inner_voice
    from brain.monologue import split_monologue
    raw = "[独白]\n她又在撒娇。\n\n嗯，抱一下。\n\n[心声]\n其实想抱很久了。\n[/心声]"
    mono, body = split_monologue(raw)
    assert mono == "她又在撒娇。\n\n嗯，抱一下。"          # 没「你」的正文认不出来（老规矩），但心声不能丢
    assert inner_voice.split(body)[1] == "其实想抱很久了。"
    mono, body = split_monologue("[独白]\n她累了\n[/独白]\n你先睡。\n【心声】舍不得【/心声】")
    assert (mono, inner_voice.split(body)) == ("她累了", ("你先睡。", "舍不得"))


def test_second_unclosed_monologue_does_not_leak_10_16():
    from brain.monologue import split_monologue
    text = "[独白]\n她今天累了。\n[/独白]\n\n抱抱你。\n\n[独白]\n她还没吃饭，我有点急。\n\n你先去吃饭，好不好。"
    mono, body = split_monologue(text)
    assert "独白" not in body and "我有点急" not in body
    assert body.startswith("抱抱你") and "你先去吃饭" in body
    assert "我有点急" in mono
    mono, body = split_monologue("[独白]\n想她。\n[/独白]\n抱抱你。\n[/独白]")
    assert body == "抱抱你。" and mono == "想她。"
