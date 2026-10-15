import SwiftUI

/// 外观方案（10-15 Aporia：壁纸和图标也像气泡一样存成几格，点一下整套换）。
/// 一格 = 主屏壁纸 + 每个软件的图标 + 主题色。用到的图都拷一份进 Documents/look-presets/<格>/，
/// 之后把原来那张壁纸删了、图标改回原样，这一格照样还在。
struct LookPreset: Codable, Equatable {
    var name: String
    /// 内置的（plain / cloud / bg-xxx）存 id；自己导入的存 "file"，图在格子文件夹里的 bg.jpg
    var bg: String
    /// 上次换上时落在背景库里的名字（再点同一格不重复导入）
    var bgFile: String?
    var hue: Double
    var satScale: Double
    var briShift: Double
    /// 换过图标的软件（HomeApp.rawValue）；没列的用原样
    var icons: [String]
}

@MainActor
final class LookPresetStore: ObservableObject {
    static let shared = LookPresetStore()
    static let slots = 4
    private static let key = "lookPresets"
    static let defaultHue: Double = 333

    @Published private(set) var presets: [LookPreset?]

    private init() {
        let raw = UserDefaults.standard.data(forKey: Self.key)
        let list = raw.flatMap { try? JSONDecoder().decode([LookPreset?].self, from: $0) } ?? []
        presets = Array((list + Array(repeating: nil, count: Self.slots)).prefix(Self.slots))
    }

    private static func dir(_ i: Int) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("look-presets/\(i)", isDirectory: true)
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(presets) { UserDefaults.standard.set(d, forKey: Self.key) }
    }

    func thumbnail(_ i: Int) -> UIImage? {
        guard presets[i]?.bg == "file" else { return nil }
        return UIImage(contentsOfFile: Self.dir(i).appendingPathComponent("bg.jpg").path)
    }

    /// 把现在的样子存进第 i 格（空格新存 / 有名字的覆盖）
    func save(_ i: Int, name: String, theme: AppTheme, icons: AppIconStore) {
        let fm = FileManager.default, d = Self.dir(i)
        try? fm.removeItem(at: d)
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        var bg = theme.bgChoice, bgFile: String?
        let custom = AppTheme.bgDir.appendingPathComponent(theme.bgChoice)
        if theme.customBackgrounds.contains(theme.bgChoice), fm.fileExists(atPath: custom.path) {
            try? fm.copyItem(at: custom, to: d.appendingPathComponent("bg.jpg"))
            bg = "file"
            bgFile = theme.bgChoice
        }
        var saved: [String] = []
        for (app, img) in icons.images {
            if let jpg = img.jpegData(compressionQuality: 0.9) {
                try? jpg.write(to: d.appendingPathComponent("icon-\(app.rawValue).jpg"), options: .atomic)
                saved.append(app.rawValue)
            }
        }
        presets[i] = LookPreset(name: name, bg: bg, bgFile: bgFile, hue: theme.hue, satScale: theme.satScale,
                                briShift: theme.briShift, icons: saved.sorted())
        persist()
    }

    func apply(_ i: Int, theme: AppTheme, icons: AppIconStore) {
        guard var p = presets[i] else { return }
        let d = Self.dir(i)
        if p.bg == "file" {
            if let f = p.bgFile, theme.customBackgrounds.contains(f),
               FileManager.default.fileExists(atPath: AppTheme.bgDir.appendingPathComponent(f).path) {
                theme.bgChoice = f
            } else if let data = try? Data(contentsOf: d.appendingPathComponent("bg.jpg")) {
                theme.addCustomBackground(data)          // 原来那张删掉了：从格子里放回背景库
                p.bgFile = theme.bgChoice
                presets[i] = p
                persist()
            }
        } else {
            theme.bgChoice = p.bg
        }
        for app in HomeApp.allCases {
            if p.icons.contains(app.rawValue),
               let img = UIImage(contentsOfFile: d.appendingPathComponent("icon-\(app.rawValue).jpg").path) {
                icons.set(app, img)
            } else if icons.images[app] != nil {
                icons.reset(app)
            }
        }
        theme.hue = p.hue
        theme.satScale = p.satScale
        theme.briShift = p.briShift
    }

    /// 「默认」那格：纯色背景、原样图标、出厂主题色
    func applyDefault(theme: AppTheme, icons: AppIconStore) {
        theme.bgChoice = "plain"
        for app in HomeApp.allCases where icons.images[app] != nil { icons.reset(app) }
        theme.hue = Self.defaultHue
        theme.satScale = 1
        theme.briShift = 0
    }

    func isDefault(theme: AppTheme, icons: AppIconStore) -> Bool {
        theme.bgChoice == "plain" && icons.images.isEmpty && theme.hue == Self.defaultHue
            && theme.satScale == 1 && theme.briShift == 0
    }

    /// 现在的样子是不是这一格（图标只比哪几个换过，不比图）
    func matches(_ i: Int, theme: AppTheme, icons: AppIconStore) -> Bool {
        guard let p = presets[i] else { return false }
        let bgSame = p.bg == "file" ? theme.bgChoice == p.bgFile : theme.bgChoice == p.bg
        return bgSame && abs(p.hue - theme.hue) < 0.01 && abs(p.satScale - theme.satScale) < 0.001
            && abs(p.briShift - theme.briShift) < 0.001 && p.icons == icons.images.keys.map(\.rawValue).sorted()
    }

    func rename(_ i: Int, to name: String) {
        presets[i]?.name = name
        persist()
    }

    func clear(_ i: Int) {
        try? FileManager.default.removeItem(at: Self.dir(i))
        presets[i] = nil
        persist()
    }
}

/// Me 里的「外观方案」：默认 + 四格，跟气泡设置那排一样用法
struct LookPresetsCard: View {
    @EnvironmentObject private var theme: AppTheme
    @ObservedObject private var store = LookPresetStore.shared
    @ObservedObject private var icons = AppIconStore.shared
    @State private var namingSlot: Int?
    @State private var renaming = false
    @State private var nameDraft = ""
    @State private var slotMenu: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("外观方案").font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(theme.ink)
                Text("壁纸、软件图标、主题色一起存成一格，点一下整套换过去。点空格把现在的样子存进去；长按有名字的格子改名、覆盖或清空。")
                    .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim)
            }
            HStack(spacing: 8) {
                tile(name: "默认", bg: AnyView(AppTheme.plainColor), dot: Color(hue: LookPresetStore.defaultHue / 360, saturation: 0.34, brightness: 0.88),
                     selected: store.isDefault(theme: theme, icons: icons)) {
                    withAnimation(.snappy) { store.applyDefault(theme: theme, icons: icons) }
                }
                ForEach(0..<LookPresetStore.slots, id: \.self) { i in
                    if let p = store.presets[i] {
                        tile(name: p.name, bg: background(i, p),
                             dot: Color(hue: p.hue / 360, saturation: min(1, 0.34 * p.satScale), brightness: min(1, max(0.2, 0.88 + p.briShift))),
                             selected: store.matches(i, theme: theme, icons: icons)) {
                            withAnimation(.snappy) { store.apply(i, theme: theme, icons: icons) }
                        }
                        .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            slotMenu = i
                        })
                    } else {
                        emptyTile {
                            nameDraft = ""
                            renaming = false
                            namingSlot = i
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .alert(renaming ? "改个名字" : "给这一格起个名字", isPresented: Binding(
            get: { namingSlot != nil }, set: { if !$0 { namingSlot = nil } })) {
            TextField("名字", text: $nameDraft)
            Button("好") { finishNaming() }
            Button("取消", role: .cancel) { namingSlot = nil }
        } message: {
            Text(renaming ? "" : "把现在的壁纸、图标和主题色存进这一格")
        }
        .confirmationDialog(slotMenu.flatMap { store.presets[$0]?.name } ?? "",
                            isPresented: Binding(get: { slotMenu != nil }, set: { if !$0 { slotMenu = nil } }),
                            titleVisibility: .visible) {
            if let i = slotMenu {
                Button("改名") {
                    nameDraft = store.presets[i]?.name ?? ""
                    renaming = true
                    namingSlot = i
                }
                Button("用现在的样子覆盖") {
                    store.save(i, name: store.presets[i]?.name ?? "方案\(i + 1)", theme: theme, icons: icons)
                }
                Button("清空这一格", role: .destructive) { store.clear(i) }
            }
        }
    }

    private func background(_ i: Int, _ p: LookPreset) -> AnyView {
        if p.bg == "file", let img = store.thumbnail(i) {
            return AnyView(Image(uiImage: img).resizable().scaledToFill())
        }
        if p.bg == "cloud" { return AnyView(AppTheme.cloudGradient) }
        if p.bg.hasPrefix("bg-"), let img = UIImage(named: p.bg) {
            return AnyView(Image(uiImage: img).resizable().scaledToFill())
        }
        return AnyView(AppTheme.plainColor)
    }

    private func tile(name: String, bg: AnyView, dot: Color, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                bg
                    .frame(width: 36, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        Circle().fill(dot).overlay(Circle().stroke(.white, lineWidth: 1.5))
                            .frame(width: 12, height: 12).offset(x: 3, y: 3)
                    }
                Text(name)
                    .font(Typo.sans(Typo.Size.caption, .medium))
                    .foregroundStyle(selected ? theme.ink : theme.inkDim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: Radii.bubble, style: .continuous)
                    .fill(Color.white.opacity(0.35))
                RoundedRectangle(cornerRadius: Radii.bubble, style: .continuous)
                    .strokeBorder(selected ? theme.accent : .clear, lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
    }

    private func emptyTile(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(theme.inkFaint.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .frame(width: 36, height: 54)
                    .overlay(Image(systemName: "plus").font(Typo.icon(13, .semibold)).foregroundStyle(theme.inkFaint))
                Text("空").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: Radii.bubble, style: .continuous).fill(Color.white.opacity(0.2)))
        }
        .buttonStyle(.plain)
    }

    private func finishNaming() {
        guard let i = namingSlot else { return }
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = name.isEmpty ? "方案\(i + 1)" : String(name.prefix(6))
        if renaming {
            store.rename(i, to: finalName)
        } else {
            store.save(i, name: finalName, theme: theme, icons: icons)
        }
        namingSlot = nil
        renaming = false
    }
}
