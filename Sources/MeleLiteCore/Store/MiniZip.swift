import Compression
import Foundation

/// 只读的 zip（10-05 导入官方聊天记录用）：从目录里找一个文件拿出来，认「不压缩」和「deflate」两种。
/// 10-11 加 ZIP64（Kelivo 的备份不管多大都写 ZIP64 的目录尾），和从文件按需读（Kelivo 带图片的整包能有几百 MB，
/// 只抽里面那个数据库，不整包读进内存）。
public enum MiniZip {
    public enum Failure: Error, Equatable { case notZip, unsupported, broken }

    /// 按文件名找（只比最后一段，导出包里可能套了一层文件夹）；没有这个文件返回 nil
    public static func entry(_ name: String, in data: Data) throws -> Data? {
        try entry(in: data) { $0 == name }
    }

    /// 第一个文件名（最后一段）合条件的
    public static func entry(in data: Data, where match: (String) -> Bool) throws -> Data? {
        try scan(Bytes(data), { match(($0 as NSString).lastPathComponent) }, all: false).first?.data
    }

    /// 完整路径合条件的全部文件（Google Takeout 的文件夹名才认得出是哪个产品）
    public static func entries(in data: Data, path match: (String) -> Bool) throws -> [(path: String, data: Data)] {
        try scan(Bytes(data), match, all: true)
    }

    /// 从磁盘上的包里按完整路径拿一个文件：只读目录和这一个文件，包再大也不占内存
    public static func entry(path: String, inFileAt url: URL) throws -> Data? {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        let size = Int(try h.seekToEnd())
        let src = Bytes(count: size) { offset, n in
            try? h.seek(toOffset: UInt64(offset))
            return [UInt8]((try? h.read(upToCount: n)) ?? Data())
        }
        return try scan(src, { $0 == path }, all: false).first?.data
    }

    /// 按位置取一段字节：内存里的 Data 和磁盘上的文件走同一套
    struct Bytes {
        let count: Int
        let read: (Int, Int) -> [UInt8]
        init(count: Int, read: @escaping (Int, Int) -> [UInt8]) { self.count = count; self.read = read }
        init(_ data: Data) {
            let b = [UInt8](data)
            self.init(count: b.count) { o, n in Array(b[o..<min(b.count, o + n)]) }
        }
        func at(_ o: Int, _ n: Int) throws -> [UInt8] {
            guard o >= 0, n >= 0, o + n <= count else { throw Failure.broken }
            let got = read(o, n)
            guard got.count == n else { throw Failure.broken }
            return got
        }
    }

    static func scan(_ src: Bytes, _ match: (String) -> Bool, all: Bool) throws -> [(path: String, data: Data)] {
        // 目录尾在最后 22 字节 + 最长 65535 的注释里
        guard src.count >= 22 else { throw Failure.notZip }
        let tailStart = max(0, src.count - 22 - 0xFFFF)
        let tail = try src.at(tailStart, src.count - tailStart)
        guard let e = (0...(tail.count - 22)).reversed().first(where: { u32(tail, $0) == 0x0605_4B50 }) else { throw Failure.notZip }
        var count = Int(u16(tail, e + 10)), dirSize = Int(u32(tail, e + 12)), dirStart = Int(u32(tail, e + 16))
        // ZIP64：目录尾前面紧挨着一个定位器，指向真正的目录尾（条数、目录位置是 8 字节的）
        if count == 0xFFFF || dirSize == 0xFFFF_FFFF || dirStart == 0xFFFF_FFFF {
            guard e >= 20, u32(tail, e - 20) == 0x0706_4B50 else { throw Failure.broken }
            let at = Int(u64(tail, e - 20 + 8))
            let z = try src.at(at, 56)
            guard u32(z, 0) == 0x0606_4B50 else { throw Failure.broken }
            count = Int(u64(z, 32)); dirSize = Int(u64(z, 40)); dirStart = Int(u64(z, 48))
        }
        let b = try src.at(dirStart, dirSize)
        var found: [(path: String, data: Data)] = []
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= b.count, u32(b, p) == 0x0201_4B50 else { throw Failure.broken }
            let method = u16(b, p + 10)
            var packed = Int(u32(b, p + 20)), size = Int(u32(b, p + 24))
            let nameLen = Int(u16(b, p + 28)), extraLen = Int(u16(b, p + 30)), commentLen = Int(u16(b, p + 32))
            var local = Int(u32(b, p + 42))
            guard p + 46 + nameLen + extraLen <= b.count else { throw Failure.broken }
            let path = String(decoding: b[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            let extra = Array(b[(p + 46 + nameLen)..<(p + 46 + nameLen + extraLen)])
            p += 46 + nameLen + extraLen + commentLen
            guard match(path) else { continue }
            // ZIP64 的单个文件：顶满的那几栏按顺序（原大小、压缩后、本地头位置）放在 0x0001 附加块里
            if size == 0xFFFF_FFFF || packed == 0xFFFF_FFFF || local == 0xFFFF_FFFF {
                guard let z = zip64Field(extra) else { throw Failure.unsupported }
                var i = 0
                func next() throws -> Int { guard i + 8 <= z.count else { throw Failure.broken }; defer { i += 8 }; return Int(u64(z, i)) }
                if size == 0xFFFF_FFFF { size = try next() }
                if packed == 0xFFFF_FFFF { packed = try next() }
                if local == 0xFFFF_FFFF { local = try next() }
            }
            let head = try src.at(local, 30)
            guard u32(head, 0) == 0x0403_4B50 else { throw Failure.broken }
            let start = local + 30 + Int(u16(head, 26)) + Int(u16(head, 28))
            let raw = try src.at(start, packed)
            switch method {
            case 0: found.append((path, Data(raw)))
            case 8: found.append((path, try inflate(raw, size: size)))
            default: throw Failure.unsupported
            }
            if !all { break }
        }
        return found
    }

    static func zip64Field(_ extra: [UInt8]) -> [UInt8]? {
        var i = 0
        while i + 4 <= extra.count {
            let id = u16(extra, i), n = Int(u16(extra, i + 2))
            guard i + 4 + n <= extra.count else { return nil }
            if id == 0x0001 { return Array(extra[(i + 4)..<(i + 4 + n)]) }
            i += 4 + n
        }
        return nil
    }

    static func inflate(_ src: [UInt8], size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        var out = [UInt8](repeating: 0, count: size)
        let n = compression_decode_buffer(&out, size, src, src.count, nil, COMPRESSION_ZLIB)   // 苹果的 ZLIB = 裸 deflate
        guard n == size else { throw Failure.broken }
        return Data(out)
    }

    static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
    static func u64(_ b: [UInt8], _ i: Int) -> UInt64 { UInt64(u32(b, i)) | UInt64(u32(b, i + 4)) << 32 }
}
