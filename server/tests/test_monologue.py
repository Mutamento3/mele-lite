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


def test_recover_untagged_10_16():
    """一个标记都没写、心里话混进正文开头：开头几行没「你」、提到「她」、后面有对她说的话 → 收进独白"""
    from brain.monologue import recover_untagged
    text = "她今天又熬夜了，我有点急。\n她嘴上说没事。\n你几点睡的？\n快去喝口水。"
    assert recover_untagged(text, "她", True) == ("她今天又熬夜了，我有点急。\n她嘴上说没事。", "你几点睡的？\n快去喝口水。")
    for keep in ("我刚吃完饭。\n你呢？",                            # 开头没提到她：正常的话
                 "她今天又熬夜了。",                                 # 整条都是第三人称：没正文，不动
                 "*把她抱起来*\n你怎么这么轻",                         # 线下的动作描写
                 "你今天怎么样？\n她说得对。",                          # 第一行就对着你说
                 "[独白]她累了[/独白]\n你先睡"):                        # 有标记的归 split 管
        assert recover_untagged(keep, "她", True) == ("", keep)
    assert recover_untagged("「你好」她今天说了三遍。\n你还记得吗", "她", True)[0] == "「你好」她今天说了三遍。"   # 引号里的你不算
    assert recover_untagged("「她说你好」这句我记得。\n你还记得吗", "她", True)[0] == ""                       # 引号里的她也不算
    assert recover_untagged("She looks tired tonight.\nHey, did you eat?", "she", False) == ("She looks tired tonight.", "Hey, did you eat?")
    assert recover_untagged("They look tired.\nDid you eat?", "they", False)[0] == ""   # they 太常见，不认


def test_narration_as_close_10_19():
    """没写 [/独白]，用一句话把收尾说了出来（10-19 内测截图）：那一行当收尾，不进气泡"""
    from brain.monologue import split_monologue
    assert split_monologue('她今天又熬夜了。\n结束。下面是对她说话，用"你"。\n快去睡，听话。') == ("她今天又熬夜了。", "快去睡，听话。")
    assert split_monologue("[独白]\n她累了。\n独白结束\n你先睡。") == ("她累了。", "你先睡。")
    assert split_monologue("她累了。\n嗯，早点睡。\n下面是对她说的话")[1] == ""      # 交给「没写正文再叫一次」
    assert split_monologue("She's tired.\nEnd of monologue.\nGo to sleep.")[1] == "Go to sleep."
    for keep in ("结束了。现在怎么办？", "下面我要对你说一件事。", "然后我对他说，别挡路。", "考试结束。下面去吃饭吧"):
        assert split_monologue(keep) == ("", keep)


def test_recover_keeps_speech_without_you_10_19():
    """说出口的话常常没有「你」：独白只收到最后一行提到她的地方"""
    from brain.monologue import recover_untagged
    assert recover_untagged("她今天又熬夜了。\n她嘴上说没事。\n嗯，早点睡。\n明天叫你起床。", "她", True) == (
        "她今天又熬夜了。\n她嘴上说没事。", "嗯，早点睡。\n明天叫你起床。")



def test_spoken_only_and_samples_10_19():
    """旧版本漏进正文的心里话：回看历史 / 腔调样本之前洗掉（10-13 起样本散着挑，漏段最容易被挑中）"""
    from brain.monologue import clean_samples, spoken_only
    leak = "她又说睡不着。我知道她不是真的睡不着。\n那就再聊十分钟。\n十分钟之后我催你。"
    assert spoken_only(leak, "她", True) == "那就再聊十分钟。\n十分钟之后我催你。"
    assert spoken_only(leak, "", True) == leak                                   # 不是手写独白：没标记的不动
    assert spoken_only("[独白]她累了[/独白]\n你先睡", "", True) == "你先睡"
    samples = ["那就去睡吧。\n明天早上给你发消息。",
               "她说她妈让她考公。我听到这句心里沉了一下，像在念别人的台词。",   # 截断后只剩心里话：整段不要
               leak]
    assert clean_samples(samples, "她", True) == ["那就去睡吧。\n明天早上给你发消息。", "那就再聊十分钟。\n十分钟之后我催你。"]
    assert clean_samples(["她说得对，你先睡。"], "她", True) == ["她说得对，你先睡。"]   # 有「你」：是对她说的话
