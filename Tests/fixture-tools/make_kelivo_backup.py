"""造一份假的 Kelivo 整包备份给单测用（10-11）：Tests/MeleLiteCoreTests/Fixtures/kelivo-backup.zip

只造解析用得到的表和列；名字用小满 / Mia。zip 照 Kelivo 的写法：deflate + 数据描述符、
目录尾永远是 ZIP64 那套（条数 0xFFFF、位置 0xFFFFFFFF），另外让一个文件在目录里走 ZIP64 附加块。
跑：python3 Tests/fixture-tools/make_kelivo_backup.py
"""
import json, os, sqlite3, struct, tempfile, zlib

OUT = os.path.join(os.path.dirname(__file__), "..", "MeleLiteCoreTests", "Fixtures", "kelivo-backup.zip")
T0 = 1_760_000_000_000_000          # 微秒


def us(sec):
    return T0 + sec * 1_000_000


def make_db(path):
    db = sqlite3.connect(path)
    db.executescript("""
    CREATE TABLE conversation_rows (id TEXT PRIMARY KEY, title TEXT NOT NULL, created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL, is_pinned INTEGER NOT NULL DEFAULT 0, assistant_id TEXT,
      truncate_index INTEGER NOT NULL DEFAULT -1, version_selections_json TEXT NOT NULL DEFAULT '{}');
    CREATE TABLE message_rows (id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, role TEXT NOT NULL,
      timestamp INTEGER NOT NULL, group_id TEXT, version INTEGER NOT NULL DEFAULT 0, message_order INTEGER NOT NULL);
    CREATE TABLE message_part_rows (part_id INTEGER PRIMARY KEY AUTOINCREMENT, conversation_id TEXT NOT NULL,
      revision_id TEXT NOT NULL, ordinal INTEGER NOT NULL, kind TEXT NOT NULL, payload TEXT NOT NULL,
      created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
    CREATE TABLE assistant_rows (id TEXT PRIMARY KEY, sort_order INTEGER NOT NULL, payload TEXT NOT NULL, updated_at INTEGER NOT NULL);
    CREATE TABLE assistant_memory_rows (id TEXT PRIMARY KEY, sort_order INTEGER NOT NULL, assistant_id TEXT NOT NULL,
      payload TEXT NOT NULL, updated_at INTEGER NOT NULL);
    CREATE TABLE provider_rows (provider_key TEXT PRIMARY KEY, sort_order INTEGER NOT NULL, payload TEXT NOT NULL, updated_at INTEGER NOT NULL);
    """)
    db.execute("INSERT INTO assistant_rows VALUES ('a-mia', 0, ?, 0)", (json.dumps({"name": "Mia", "systemPrompt": "你是 Mia"}),))
    db.execute("INSERT INTO provider_rows VALUES ('openai', 0, ?, 0)", (json.dumps({"apiKey": "sk-fake-not-read"}),))
    for i, (mem, aid) in enumerate([("小满喜欢海", "a-mia"), ("小满怕冷", "a-mia"), ("  ", "a-mia")]):
        db.execute("INSERT INTO assistant_memory_rows VALUES (?, ?, ?, ?, 0)", (f"mem{i}", i, aid, json.dumps({"id": i, "content": mem})))

    # 周末去哪：没选过版本 → 取最新的回答；思考、工具、只有图片的那条不要
    db.execute("INSERT INTO conversation_rows (id,title,created_at,updated_at,assistant_id) VALUES ('c-beach','周末去哪',?,?,'a-mia')", (us(0), us(100)))
    # 睡不着：选过旧版本；没有角色；有一条 system
    db.execute("INSERT INTO conversation_rows (id,title,created_at,updated_at,version_selections_json) VALUES ('c-sleep','睡不着',?,?,?)",
               (us(1000), us(1100), json.dumps({"g-sleep": 0})))
    # 空对话：不要
    db.execute("INSERT INTO conversation_rows (id,title,created_at,updated_at) VALUES ('c-empty','新对话',?,?)", (us(2000), us(2000)))

    msgs = [
        # id, conv, role, t, group, version, order, parts[(kind, payload)]
        ("m1", "c-beach", "user", 10, None, 0, 0, [("text", "周末想去海边，你觉得呢")]),
        ("m2", "c-beach", "assistant", 11, "g-beach", 0, 1, [("text", "被重新生成掉的回答")]),
        ("m3", "c-beach", "assistant", 12, "g-beach", 1, 2, [("reasoning", "想一想"), ("text", "去吧"),
                                                            ("tool_call", json.dumps({"name": "weather"})), ("text", "记得带外套")]),
        ("m4", "c-beach", "user", 20, None, 0, 3, [("image", json.dumps({"uri": "kelivo-file:///upload/a.png"}))]),
        ("m5", "c-beach", "user", 30, None, 0, 4, [("text", "这是那天拍的"), ("image", json.dumps({"uri": "kelivo-file:///upload/a.png"}))]),
        ("s1", "c-sleep", "system", 1001, None, 0, 0, [("text", "系统提示")]),
        ("s2", "c-sleep", "user", 1010, None, 0, 1, [("text", "睡不着，陪我聊会儿")]),
        ("s3", "c-sleep", "assistant", 1011, "g-sleep", 0, 2, [("text", "好，我在")]),
        ("s4", "c-sleep", "assistant", 1012, "g-sleep", 1, 3, [("text", "没被选中的新版本")]),
    ]
    for mid, cid, role, t, g, v, order, parts in msgs:
        db.execute("INSERT INTO message_rows VALUES (?,?,?,?,?,?,?)", (mid, cid, role, us(t), g, v, order))
        # 故意倒着插，验证按 ordinal 排
        for ordinal, (kind, payload) in reversed(list(enumerate(parts))):
            db.execute("INSERT INTO message_part_rows (conversation_id,revision_id,ordinal,kind,payload,created_at,updated_at) VALUES (?,?,?,?,?,?,?)",
                       (cid, mid, ordinal, kind, payload, us(t), us(t)))
    db.commit()
    db.execute("PRAGMA journal_mode=DELETE")
    db.close()


def write_zip(path, files, zip64_dir=()):
    out = bytearray()
    central = []
    for name, data in files:
        nb = name.encode()
        comp = zlib.compressobj(9, zlib.DEFLATED, -15)
        packed = comp.compress(data) + comp.flush()
        crc = zlib.crc32(data) & 0xFFFFFFFF
        offset = len(out)
        # 本地头：标志 0x0808（UTF-8 + 数据描述符），CRC 和大小写 0，真值在后面的描述符里
        out += struct.pack("<IHHHHHIIIHH", 0x04034B50, 45, 0x0808, 8, 0, 0x21, 0, 0, 0, len(nb), 0) + nb
        out += packed
        out += struct.pack("<IIII", 0x08074B50, crc, len(packed), len(data))
        central.append((nb, crc, len(packed), len(data), offset, name in zip64_dir))
    dir_start = len(out)
    for nb, crc, packed, size, offset, z64 in central:
        extra = struct.pack("<HHQQQ", 0x0001, 24, size, packed, offset) if z64 else b""
        c_packed, c_size, c_off = (0xFFFFFFFF,) * 3 if z64 else (packed, size, offset)
        out += struct.pack("<IHHHHHHIIIHHHHHII", 0x02014B50, 45, 45, 0x0808, 8, 0, 0x21, crc, c_packed, c_size,
                           len(nb), len(extra), 0, 0, 0, 0o100644 << 16, c_off) + nb + extra
    dir_size = len(out) - dir_start
    z64_at = len(out)
    out += struct.pack("<IQHHIIQQQQ", 0x06064B50, 44, 45, 45, 0, 0, len(central), len(central), dir_size, dir_start)
    out += struct.pack("<IIQI", 0x07064B50, 0, z64_at, 1)
    out += struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, 0xFFFF, 0xFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0)
    with open(path, "wb") as f:
        f.write(out)


with tempfile.TemporaryDirectory() as tmp:
    dbp = os.path.join(tmp, "kelivo.db")
    make_db(dbp)
    db = open(dbp, "rb").read()
manifest = {"format": "kelivo-backup", "formatVersion": 3, "minimumReadableFormatVersion": 3, "payloadKind": "sqlite",
            "includeChats": True, "includeFiles": True, "secretsIncluded": True,
            "database": {"entry": "database/kelivo.db", "schemaVersion": 3, "conversationCount": 3, "messageCount": 9}}
settings = {"providers": {"openai": {"apiKey": "sk-fake-not-read"}}}
write_zip(OUT, [
    ("settings.json", json.dumps(settings).encode()),
    ("database/kelivo.db", db),
    ("upload/a.png", bytes(range(256)) * 4),
    ("manifest.json", json.dumps(manifest, ensure_ascii=False).encode()),
], zip64_dir={"database/kelivo.db"})
print("wrote", os.path.normpath(OUT), os.path.getsize(OUT), "bytes")
