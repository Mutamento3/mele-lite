from brain import inner_voice as IV
from brain.settings import Settings


def test_split_last_block_and_sloppy_ends():
    assert IV.split("来，下地。\n\n[心声]\n她喊得急。\n[/心声]") == ("来，下地。", "她喊得急。")
    assert IV.split("好。[心声]高兴[心声 完]")[1] == "高兴"
    assert IV.split("好。\n[心声]没收尾")[1] == "没收尾"
    assert IV.split("前面[心声]一[/心声]中间\n[心声]二[/心声]") == ("前面中间", "二")
    assert IV.split("ok.\n[Inner Voice] cute [/inner voice]") == ("ok.", "cute")
    assert IV.split("就一句") == ("就一句", "")


def test_rules_hook_context():
    s = Settings(user_pronoun="she")
    r = IV.rules(s)
    assert "[心声]" in r and "[/心声]" in r and "口是心非" in r
    own = IV.rules(Settings(inner_voice_style="只写一句。"))
    assert "只写一句。" in own and "口是心非" not in own
    assert IV.hook(s).startswith("〔心声〕")
    assert IV.context_line("高兴", "zh") == "（当时心里：高兴）"
    assert IV.context_line("glad", "en") == "(What I felt then: glad)"
