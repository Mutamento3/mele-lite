import SwiftUI

/// 聊天房间的壳：ChatStore 跟着这个窗口活（@StateObject），换窗口就换一个。
/// 名字和头像写进聊天页用的那两处（companionName、AvatarStore.ai），聊天页本身不用知道有几个联系人。
struct ChatRoom: View {
    @StateObject private var chat: ChatStore
    @EnvironmentObject private var avatars: AvatarStore
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @AppStorage("companionName") private var companionName = "Lumi"
    @AppStorage("companionRelationship") private var companionRelationship = ""
    let companion: CompanionDTO
    var onBack: (() -> Void)? = nil
    var incognito = false
    var onNewWindow: (() -> Void)? = nil
    var onIncognito: (() -> Void)? = nil
    var onSettings: (() -> Void)? = nil
    var altName = ""
    /// 群（10-11）：聊天页按 speaker 画人，⋯ 里是群设定
    var group: GroupDTO?
    @State private var groupSettings = false

    init(companion: CompanionDTO, conversation: UUID, api: APIClient, incognito: Bool = false,
         onBack: (() -> Void)? = nil, onNewWindow: (() -> Void)? = nil, onIncognito: (() -> Void)? = nil,
         onSettings: (() -> Void)? = nil, altName: String = "", group: GroupDTO? = nil) {
        self.companion = companion
        self.group = group
        self.onBack = onBack
        self.incognito = incognito
        self.onNewWindow = onNewWindow
        self.onIncognito = onIncognito
        self.onSettings = onSettings
        self.altName = altName
        _chat = StateObject(wrappedValue: ChatStore(api: api, conversation: conversation))
    }

    /// 群里谁长什么样：成员 + 退群的 + 聊天记录里出现过、已经删掉的 TA
    private var looks: [UUID: MemberLook] {
        guard let g = model.group(group?.id ?? UUID()) ?? group else { return [:] }
        return model.memberLooks(g)
    }

    var body: some View {
        let g = group.flatMap { model.group($0.id) } ?? group
        ChatView(companionID: companion.id, onBack: onBack, incognito: incognito,
                 onNewWindow: g == nil ? onNewWindow : nil, onIncognito: g == nil ? onIncognito : nil,
                 onSettings: g == nil ? onSettings : { groupSettings = true },
                 altName: altName, group: g, memberLook: looks)
            .environmentObject(chat)
            .sheet(isPresented: $groupSettings) {
                if let g {
                    GroupSettingsView(groupID: g.id)
                        .environmentObject(model)
                        .environmentObject(theme)
                        .presentationDetents([.large])
                }
            }
            .onAppear {
                companionName = g?.displayName ?? companion.name
                companionRelationship = model.companion(companion.id)?.relationship ?? companion.relationship
                avatars.ai = g == nil ? model.avatarImages[companion.id] : nil
                PushDelegate.openConversation = chat.conversation
                PushDelegate.clearDelivered()
            }
            .onReceive(model.$companions) { list in
                if let c = list.first(where: { $0.id == companion.id }) { companionRelationship = c.relationship }
            }
            .onDisappear {
                if PushDelegate.openConversation == chat.conversation { PushDelegate.openConversation = nil }
            }
    }
}
