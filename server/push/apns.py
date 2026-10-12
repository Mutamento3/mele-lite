"""推送真发（iOS 第三块第 2 步）：扫 push_queue 里没发的，用苹果的推送钥匙（.p8，ES256 JWT）走 HTTP/2 发给这个账号的每台手机。

没配钥匙就不起这个循环，推送只排队（跟以前一样）。传输可以换成假的（测试里记下发了什么）。"""
from __future__ import annotations

import asyncio
import json
import logging
import time
from datetime import timedelta
from dataclasses import dataclass, field


from brain import archive
from brain.bubbles import split_reply
from brain.drawer import push_title as drawer_push_title
from brain.persona import Persona

from . import es256

log = logging.getLogger(__name__)
BODY_CHARS = 120
MAX_BUBBLES = 8         # 一段话最多推几条
GAP = 0.35              # 两条之间隔多久（秒）
STALE = timedelta(minutes=30)
PREVIEW_CHARS = 60


@dataclass
class ApnsConfig:
    key_pem: bytes            # .p8 文件内容
    key_id: str
    team_id: str
    topic: str                # app 的包名
    sandbox: bool = True      # 开发时装的 app 只认沙盒
    _jwt: tuple[str, float] | None = field(default=None, repr=False)

    @property
    def host(self) -> str:
        return "https://api.sandbox.push.apple.com" if self.sandbox else "https://api.push.apple.com"


def make_jwt(cfg: ApnsConfig, now: float) -> str:
    """苹果要的登录凭证：ES256 签的 JWT，一小时内有效；50 分钟换一次（换太勤苹果会拒）。"""
    if cfg._jwt and now - cfg._jwt[1] < 50 * 60:
        return cfg._jwt[0]
    token = es256.sign(cfg.key_pem, cfg.key_id, {"iss": cfg.team_id, "iat": int(now)})
    cfg._jwt = (token, now)
    return token


def payload(title: str, text: str, conversation: str, companion: str, *, urgent: bool = False,
            quiet: bool = False) -> dict:
    """一条气泡一个推送（09-28 Aporia：它说五条只推一条很容易漏，跟正常聊天软件一样一条条推）。
    urgent = 时效性通知（09-30）：开了勿扰 / 专注模式也能收到（要 App 有 time-sensitive 权限）。"""
    body = text.strip() if len(text.strip()) <= BODY_CHARS else text.strip()[:BODY_CHARS - 1] + "…"
    aps = {"alert": {"title": title, "body": body}, "thread-id": conversation}
    if not quiet:                        # quiet：早上那句（10-01），不响、TA 醒来一看就在
        aps["sound"] = "default"
    if urgent:
        aps["interruption-level"] = "time-sensitive"
    return {"aps": aps, "conversation": conversation, "companion": companion}


def seal(push_key_b64: str, payload_dict: dict) -> str:
    """推送内容加密（Mele Host 中转，10-04）：AES-256-GCM，12 字节随机数 + 密文 + 标签，base64。手机的通知扩展解开。"""
    import base64
    import os
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    nonce = os.urandom(12)
    ct = AESGCM(base64.b64decode(push_key_b64)).encrypt(nonce, json.dumps(payload_dict, ensure_ascii=False).encode(), None)
    return base64.b64encode(nonce + ct).decode()


def not_sent(e: BaseException) -> bool:
    """这个错是不是「请求根本没发出去」（连不上、排不上队）——只有这种重发才不会让手机收到两遍"""
    try:
        import httpx
        if isinstance(e, (httpx.ConnectError, httpx.ConnectTimeout, httpx.PoolTimeout)):
            return True
    except ImportError:
        pass
    return isinstance(e, ConnectionRefusedError)


async def send_pending(pool, cfg: ApnsConfig | None, transport, *, limit: int = 20, relay_url: str | None = None) -> int:
    """发一批。transport(url, headers, body_bytes) -> (status, reason)。返回发了几条（每条可能多台手机）。
    cfg = 我们自己的苹果钥匙（直连）；relay_url = 推送中转（Mele Host 用：relay: 开头的设备加密后交给它）。"""
    # 排了太久的不推了（服务器停过几小时再开，别把积压的旧话一口气全弹出来）；话在聊天里照样看得到
    await pool.execute("UPDATE push_queue SET sent_at = now() WHERE sent_at IS NULL AND created_at < now() - $1::interval",
                       STALE)
    rows = await pool.fetch("SELECT id, account_id, companion_id, conversation_id, text, kind, urgent, quiet FROM push_queue "
                            "WHERE sent_at IS NULL ORDER BY id LIMIT $1", limit)
    for r in rows:
        if r["kind"] == "activity":       # 灵动岛 10-02 拿掉了；以前排下的旧条目直接标掉
            await pool.execute("UPDATE push_queue SET sent_at = now() WHERE id = $1", r["id"])
            continue
        rows_d = await pool.fetch("SELECT apns_token, relay_secret, push_key FROM devices WHERE account_id = $1 "
                                  "ORDER BY updated_at DESC", r["account_id"])
        # 同一部手机（加密钥匙一样）只推最新登记的那个（10-12 内测：旧版每次打开都登记一个新编号，登记时才清，
        # 已经登记好不再登记的手机旧编号一直在，一条推好几遍）
        seen: set[str] = set()
        rows_d = [d for d in rows_d if not d["push_key"] or not (d["push_key"] in seen or seen.add(d["push_key"]))]
        relayed = {d["apns_token"]: d for d in rows_d if d["apns_token"].startswith("relay:")}
        devices = [d["apns_token"] for d in rows_d
                   if (d["apns_token"] in relayed and relay_url) or (d["apns_token"] not in relayed and cfg)]
        headers = {"authorization": f"bearer {make_jwt(cfg, time.time())}", "apns-topic": cfg.topic,
                   "apns-push-type": "alert", "apns-priority": "10"} if cfg else {}
        if r["kind"] == "drawer":        # 抽屉解锁（09-28）：一条，点开进抽屉
            lang = (await archive.get_settings(pool, r["companion_id"])).get("lang") or "zh"
            bodies = [{"aps": {"alert": {"title": drawer_push_title(lang), "body": r["text"]}, "sound": "default"},
                       "room": "drawer"}]
        else:
            p = Persona.from_dict(await archive.get_persona(pool, r["companion_id"]))
            bodies = [payload(p.name, bubble, str(r["conversation_id"]), str(r["companion_id"]), urgent=r["urgent"],
                              quiet=r["quiet"])
                      for bubble in split_reply(r["text"], cap=MAX_BUBBLES)]
        sent_any = False
        for i, one in enumerate(bodies):
            body = json.dumps(one, ensure_ascii=False).encode()
            # 同一条气泡每次都带同一个 collapse id（10-13 内测「改了好多版还是重复」）：不管 Host 为什么又推了一遍
            # ——没更新、重启到一半、回话没等到——苹果和手机都认它是同一条，锁屏上只留一条
            collapse = f"{r['id']}-{i}"
            if i:
                await asyncio.sleep(GAP)          # 隔一小下，锁屏上按顺序叠
            for token in list(devices):
                if token in relayed:                 # 中转：只给它编号、加密的内容、响不响 / 急不急
                    d = relayed[token]
                    aps = one.get("aps", {})
                    url, h = f"{relay_url.rstrip('/')}/push", {"authorization": f"Bearer {d['relay_secret']}",
                                                                "content-type": "application/json"}
                    b = json.dumps({"relay_id": token[len("relay:"):], "sealed": seal(d["push_key"], one),
                                    "sound": "sound" in aps, "collapse": collapse,
                                    "urgent": aps.get("interruption-level") == "time-sensitive"}).encode()
                else:
                    url, h, b = f"{cfg.host}/3/device/{token}", {**headers, "apns-collapse-id": collapse}, body
                try:
                    status, reason = await transport(url, h, b)
                except Exception as e:              # noqa: BLE001
                    log.warning("apns send failed: %s", e)
                    if not sent_any and not_sent(e):    # 根本没连上（请求没出去）：整条留着下一轮再发，不会重复
                        return 0
                    # 请求可能已经到了、只是回话没等到（10-13 内测：国内连 workers.dev 常这样，每 3 秒重推一遍、
                    # 刷满一屏、推满 30 分钟）：当它送到了，宁可偶尔漏一条也不刷屏；这台这条就算了
                    devices.remove(token)
                    sent_any = True
                    continue
                sent_any = True
                if status == 410 or reason in ("BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"):
                    devices.remove(token)
                    await pool.execute("DELETE FROM devices WHERE account_id = $1 AND apns_token = $2",
                                       r["account_id"], token)
                elif status != 200:
                    log.warning("apns %s %s", status, reason)
        await pool.execute("UPDATE push_queue SET sent_at = now() WHERE id = $1", r["id"])
    return len(rows)


def httpx_transport():
    """真的传输：HTTP/2 的长连接，一直用一个。"""
    import httpx
    client = httpx.AsyncClient(http2=True, timeout=10)

    async def send(url: str, headers: dict, body: bytes) -> tuple[int, str]:
        resp = await client.post(url, headers=headers, content=body)
        reason = ""
        if resp.status_code != 200:
            try:
                reason = resp.json().get("reason", "")
            except ValueError:
                reason = resp.text[:80]
        return resp.status_code, reason
    return send


async def push_loop(pool, cfg: ApnsConfig | None, transport=None, every: float = 3.0, relay_url: str | None = None) -> None:
    transport = transport or httpx_transport()
    while True:
        try:
            await send_pending(pool, cfg, transport, relay_url=relay_url)
        except Exception:                        # noqa: BLE001
            log.exception("push loop")
        await asyncio.sleep(every)
