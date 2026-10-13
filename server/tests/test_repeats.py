"""重复（10-13 内测「一上午都是汤」）：腔调样本去重散取、回话里抄回来的气泡丢掉。测试数据用小满。"""
from brain import repeats as R


def test_similarity_catches_reworded_repeats():
    assert R.similarity("等天擦黑，河边灯一亮，我们再去走走。不急着起。", "等天擦黑，河边灯亮了再出去走，不赶。") > 0.75
    assert R.similarity("小满今天吃了橘子", "明天要去考数学") < 0.3
    assert R.similarity("I love you so much", "I love tea") < 0.75
    assert R.similarity("Sleep well, see you tomorrow.", "sleep well — see you tomorrow") == 1.0


def test_samples_distinct_and_spread():
    lines = ["想听。你讲，我汤正喝到最后一口，热着。", "那我回来。汤见底了，回来听你讲完剩下的半截。",
             "小满你昨天说的那本书我翻了两页，写得慢但好看。", "嗯。", "你考完数学记得吃饭，别又忘了。", "汤还热着，你讲你的。"]
    picked = R.pick_samples(lines)
    assert "嗯。" not in picked and "汤还热着，你讲你的。" not in picked
    assert "小满你昨天说的那本书我翻了两页，写得慢但好看。" in picked
    many = ["小满今天吃了橘子，酸得眯眼", "明天要去考数学，复习到几点", "楼下猫又来蹭饭了", "下雨了，记得带伞出门",
            "昨晚那部电影结尾我没看懂", "耳机左边不响了，得修", "咖啡续了第三杯，手在抖", "周末想去爬山看日出",
            "新买的书到了，封面是蓝的", "妈妈打电话问我吃没吃饭", "地铁堵在隧道里十分钟", "晚饭想吃番茄炒蛋"]
    spread = R.pick_samples(many)
    assert len(spread) == 6 and spread[0] == many[0] and spread[-1] == many[-1]


def test_repeated_bubbles_dropped_but_never_all():
    recent = ["还躺着就再赖五分钟，我给你倒杯温的放床头。", "等天擦黑，河边灯一亮，我们再去走走。不急着起。"]
    assert R.drop_repeated(["先别起来，醒了会晕，坐床边缓一缓。", "等天擦黑，河边灯亮了再出去走，不赶。"], recent) == ["先别起来，醒了会晕，坐床边缓一缓。"]
    assert R.drop_repeated(["等天擦黑，河边灯一亮，我们再去走走。不急着起。"], recent) == ["等天擦黑，河边灯一亮，我们再去走走。不急着起。"]
