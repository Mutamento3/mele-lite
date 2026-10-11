import PhotosUI
import SwiftUI

// MARK: - 群聊（10-11 Aporia定）：建群、群头像拼图、群设定。设计在 docs/superpowers/specs/2026-10-11-group-chat-design.md

/// 群里一个 TA 长什么样：名字、头像；退了群 / 删掉了的头像变灰
struct MemberLook: Equatable {
    var name: String
    var image: UIImage?
    var gone = false
}

extension AppModel {
    /// 群聊页用的「谁长什么样」：现在的成员 + 退过群的（它们说过的话还留着）
    func memberLooks(_ g: GroupDTO, history: [UUID: String] = [:]) -> [UUID: MemberLook] {
        var out: [UUID: MemberLook] = [:]
        for id in g.members + g.formerMembers {
            if let c = companion(id) {
                out[id] = MemberLook(name: c.name, image: avatarImages[id], gone: !g.members.contains(id))
            }
        }
        for (id, name) in history where out[id] == nil { out[id] = MemberLook(name: name, image: nil, gone: true) }
        return out
    }
}

struct MemberAvatar: View {
    @EnvironmentObject var theme: AppTheme
    let look: MemberLook?
    var size: CGFloat = 32

    var body: some View {
        Group {
            if let image = look?.image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [theme.accentSoft, theme.accent], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(Text(String((look?.name ?? "TA").prefix(1)))
                        .font(Typo.icon(size * 0.42, .semibold)).foregroundStyle(.white))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: size > 40 ? 1.5 : 1.2))
        .saturation(look?.gone == true ? 0 : 1)
        .opacity(look?.gone == true ? 0.6 : 1)
    }
}

/// 群头像：换过图用图；没换就把前四个成员的头像拼成一格（两个人左右各半，三四个人田字格）
struct GroupAvatar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var theme: AppTheme
    let group: GroupDTO
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let img = model.groupAvatars[group.id] {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                mosaic
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }

    private var mosaic: some View {
        let ids = Array(group.members.prefix(4))
        let cell = { (id: UUID) -> AnyView in
            if let img = model.avatarImages[id] {
                return AnyView(Image(uiImage: img).resizable().scaledToFill())
            }
            return AnyView(LinearGradient(colors: [theme.accentSoft, theme.accent], startPoint: .topLeading, endPoint: .bottomTrailing).overlay(
                Text(String((model.companion(id)?.name ?? "TA").prefix(1)))
                    .font(Typo.icon(size * 0.22, .semibold)).foregroundStyle(.white)))
        }
        return Group {
            if ids.count <= 2 {
                HStack(spacing: 1) { ForEach(ids, id: \.self) { cell($0).frame(maxWidth: .infinity, maxHeight: .infinity).clipped() } }
            } else {
                VStack(spacing: 1) {
                    HStack(spacing: 1) { ForEach(ids.prefix(2), id: \.self) { cell($0).frame(maxWidth: .infinity, maxHeight: .infinity).clipped() } }
                    HStack(spacing: 1) { ForEach(ids.dropFirst(2), id: \.self) { cell($0).frame(maxWidth: .infinity, maxHeight: .infinity).clipped() } }
                }
            }
        }
        .background(Color.white.opacity(0.85))          // 格子之间那 1 点的缝透出白，看得出是几个人
    }
}

/// 发起群聊：勾 TA（至少两个）、起群名
struct NewGroupSheet: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @State private var picked: [UUID] = []
    @State private var name = ""
    @State private var making = false

    private var defaultName: String {
        picked.compactMap { model.companion($0)?.name }.joined(separator: "、")
    }

    var body: some View {
        NavigationStack {
            TilePage {
                Tile {
                    TextField(defaultName.isEmpty ? String(localized: "群名（不填就用成员名字）") : defaultName, text: $name)
                        .font(Typo.sans(Typo.Size.body))
                } header: { Text("群名").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint).padding(.horizontal, 8) }
                Tile {
                    ForEach(model.companions) { c in
                        Button {
                            if let i = picked.firstIndex(of: c.id) { picked.remove(at: i) } else { picked.append(c.id) }
                        } label: {
                            HStack(spacing: 10) {
                                MemberAvatar(look: MemberLook(name: c.name, image: model.avatarImages[c.id]), size: 34)
                                Text(c.name).font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                                Spacer()
                                Image(systemName: picked.contains(c.id) ? "checkmark.circle.fill" : "circle")
                                    .font(Typo.icon(20))
                                    .foregroundStyle(picked.contains(c.id) ? theme.accent : theme.inkFaint)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("拉谁进来（至少两个）").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint).padding(.horizontal, 8)
                } footer: {
                    Text("群里每句话，每个 TA 都会先用自己的模型判断一下要不要接，会多花一点点钱；群设定里能看大概一句多少钱。")
                }
            }
            .background(AppBackground())
            .navigationTitle(String(localized: "发起群聊"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("建群") {
                        making = true
                        Task {
                            await model.createGroup(name: name, members: picked)
                            dismiss()
                        }
                    }
                    .disabled(picked.count < 2 || making)
                }
            }
        }
        .environment(\.colorScheme, .light)
    }
}

/// 群设定：群名、群头像、成员（随时加人踢人）、TA 之间最多来回几轮、新成员看不看得到之前、大概一句多少钱、删群
struct GroupSettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    let groupID: UUID
    @State private var name = ""
    @State private var rounds = 6.0
    @State private var seesHistory = true
    @State private var usd: Double?
    @State private var photo: PhotosPickerItem?
    @State private var confirmDelete = false
    @State private var error: String?

    private var group: GroupDTO? { model.group(groupID) }
    private var path: String { "groups/\(groupID.lowercased)" }

    var body: some View {
        NavigationStack {
            TilePage {
                if let error { Text(error).font(Typo.sans(Typo.Size.callout)).foregroundStyle(.red) }
                if let g = group {
                    Tile {
                        HStack(spacing: 14) {
                            GroupAvatar(group: g, size: 56)
                            VStack(alignment: .leading, spacing: 8) {
                                TextField(g.displayName, text: $name)
                                    .font(Typo.sans(Typo.Size.body))
                                    .onSubmit { Task { await patch(["name": name]) } }
                                HStack(spacing: 14) {
                                    PhotosPicker(selection: $photo, matching: .images) {
                                        Text("换群头像").font(Typo.sans(Typo.Size.callout))
                                    }
                                    if g.avatarVer > 0 {
                                        Button("用成员头像拼") { Task { await send("DELETE", "\(path)/avatar") } }
                                            .font(Typo.sans(Typo.Size.callout))
                                    }
                                }
                            }
                        }
                    }
                    Tile {
                        ForEach(g.members, id: \.self) { id in
                            HStack(spacing: 10) {
                                MemberAvatar(look: MemberLook(name: model.companion(id)?.name ?? "TA", image: model.avatarImages[id]), size: 34)
                                Text(model.companion(id)?.name ?? "TA").font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                                Spacer()
                                if g.members.count > 1 {
                                    Button("踢出") { Task { await send("DELETE", "\(path)/members/\(id.lowercased)") } }
                                        .font(Typo.sans(Typo.Size.callout))
                                        .foregroundStyle(theme.inkDim)
                                }
                            }
                        }
                        let others = model.companions.filter { !g.members.contains($0.id) }
                        if !others.isEmpty {
                            Menu {
                                ForEach(others) { c in
                                    Button(c.name) { Task { await send("POST", "\(path)/members", json: ["companion": c.id.lowercased]) } }
                                }
                            } label: {
                                Label("拉人进群", systemImage: "person.badge.plus").font(Typo.sans(Typo.Size.body))
                            }
                        }
                    } header: {
                        Text("成员（\(g.members.count)）").font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint).padding(.horizontal, 8)
                    } footer: {
                        Text("踢出去的 TA 以后看不到这个群；它说过的话还留着，它脑子里记得的也还在。")
                    }
                    Tile {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("TA 之间最多来回 \(Int(rounds)) 轮").font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                            Slider(value: $rounds, in: 1...12, step: 1) { editing in
                                if !editing { Task { await patch(["max_rounds": Int(rounds)]) } }
                            }
                        }
                        Toggle(isOn: Binding(get: { seesHistory }, set: { v in seesHistory = v; Task { await patch(["new_member_sees_history": v]) } })) {
                            Text("新成员能看到之前的聊天").font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                        }
                    } footer: {
                        Text("你说一句，TA 们互相接话，每有一个 TA 开口算一轮，到数就停下来等你。新成员开着 = 进群时看得到前面最近 30 条。")
                    }
                    Tile {
                        Text(usd.map { String(localized: "大概一句 $\(String(format: "%.4f", $0))") } ?? String(localized: "估不出来（有 TA 用的模型不在价目表里）"))
                            .font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                    } footer: {
                        Text("每个 TA 判断一次要不要接，加上平均两个 TA 开口。实际看 Me → 用量，判断那部分记成「群聊判断」。")
                    }
                    Tile {
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Text("删除这个群").font(Typo.sans(Typo.Size.body)).frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .background(AppBackground())
            .navigationTitle(String(localized: "群设定"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        Task {
                            if let g = group, name != g.name { await patch(["name": name]) }
                            dismiss()
                        }
                    }
                }
            }
            .confirmationDialog("删除这个群？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if let g = group { Task { await model.deleteGroup(g); dismiss() } }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("群里的聊天记录一起删掉，TA 们记住的不动。")
            }
        }
        .environment(\.colorScheme, .light)
        .task {
            if let g = group { name = g.name; rounds = Double(g.maxRounds); seesHistory = g.newMemberSeesHistory }
            await loadEstimate()
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                do { await model.updateGroup(try await model.api.uploadGroupAvatar(group: groupID, data: data)) }
                catch { self.error = error.localizedDescription }
                photo = nil
            }
        }
    }

    private func loadEstimate() async {
        struct Est: Decodable { let per_message_usd: Double; let known: Bool }
        if let e: Est = try? await model.api.call("GET", "\(path)/estimate") { usd = e.known ? e.per_message_usd : nil }
    }

    private func patch(_ body: [String: Any]) async { await send("PATCH", path, json: body) }

    private func send(_ method: String, _ p: String, json: [String: Any]? = nil) async {
        do {
            let g: GroupDTO = try await model.api.call(method, p, json: json)
            error = nil
            await model.updateGroup(g)
            await loadEstimate()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
