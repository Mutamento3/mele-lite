"""标记表情（2026-09-27，iOS 第一块；照之前自用的 App〔她点了表情〕）：TA 长按它的一句点个 ❤️。
只点表情不叫它回话；下一轮易变区多一行告诉它，说过就不再说。它给 TA 点表情先不做。
10-11：一条拆成几个气泡，表情按气泡记（每泡一个）；bubble = -1 是之前整条记的，画在最后一泡。"""
from __future__ import annotations

from uuid import UUID

SNIP = 20
LINE = {"zh": "〔TA 给你那句「{t}」点了 {e}〕", "en": "〔They reacted {e} to your line \"{t}\"〕"}


async def set_reaction(pool, conversation: UUID, message_id: int, emoji: str | None,
                       bubble: int = -1, quote: str = "") -> None:
    if emoji:
        await pool.execute(
            """INSERT INTO reactions (message_id, conversation_id, emoji, bubble, quote) VALUES ($1, $2, $3, $4, $5)
               ON CONFLICT (message_id, bubble) DO UPDATE SET emoji = $3, quote = $5, created_at = now(), told = FALSE""",
            message_id, conversation, emoji, bubble, quote)
    else:
        await pool.execute("DELETE FROM reactions WHERE message_id = $1 AND bubble = $2", message_id, bubble)


async def for_messages(pool, ids: list[int]) -> dict[int, dict[int, str]]:
    """消息号 → {第几泡: 表情}（-1 = 老的，画在最后一泡）"""
    if not ids:
        return {}
    rows = await pool.fetch("SELECT message_id, bubble, emoji FROM reactions WHERE message_id = ANY($1::bigint[])", ids)
    out: dict[int, dict[int, str]] = {}
    for r in rows:
        out.setdefault(r["message_id"], {})[r["bubble"]] = r["emoji"]
    return out


def per_bubble(marks: dict[int, str], count: int) -> list[str | None]:
    """跟 bubbles 并排一列；老的 -1 落在最后一泡（那泡自己有就让它）"""
    out: list[str | None] = [marks.get(i) for i in range(count)]
    if -1 in marks and count and out[-1] is None:
        out[-1] = marks[-1]
    return out


async def pending_lines(pool, conversation: UUID, lang: str) -> list[str]:
    """还没告诉它的表情，一条一行；取了就标 told。"""
    rows = await pool.fetch(
        """UPDATE reactions r SET told = TRUE FROM chat_messages m
           WHERE r.message_id = m.id AND r.conversation_id = $1 AND NOT r.told
           RETURNING r.emoji, r.quote, m.text, r.created_at""", conversation)
    out = []
    for r in sorted(rows, key=lambda r: r["created_at"]):
        t = " ".join((r["quote"] or r["text"]).split())
        out.append(LINE[lang].format(t=t if len(t) <= SNIP else t[:SNIP] + "…", e=r["emoji"]))
    return out
