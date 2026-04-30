//
//  ChatView.swift — модуль чатов (личные + групповые) для портала Rossi.
//
//  Источник данных:
//   • GET    /chats                       — список моих чатов
//   • GET    /chats/self                  — self-chat (Saved Messages)
//   • GET    /chats/:id                   — детальный чат с участниками
//   • POST   /chats                       — создать
//   • PATCH  /chats/:id                   — переименовать
//   • DELETE /chats/:id/leave             — покинуть группу
//   • PATCH  /chats/:id/pin-chat          — пин чата
//
//   • GET    /chats/:chatId/messages      — история (cursor before, новые внизу)
//   • POST   /chats/:chatId/messages      — отправить
//   • POST   /chats/:chatId/read          — отметить прочитанным
//   • PATCH  /chats/:chatId/messages/:id  — редактировать
//   • DELETE /chats/:chatId/messages/:id  — удалить
//   • POST   /chats/:chatId/messages/:id/reactions — toggle реакции
//
//  iOS 16+, Swift 5.9. Все строки на русском. Polling через Combine.
//

import SwiftUI
import Combine
import UIKit
import PhotosUI
import AVKit

// MARK: - Models (зеркало бэка)

struct Chat: Codable, Identifiable, Equatable {
    let id: String
    /// Сервер шлёт `type` (см. apps/api/src/modules/chats/chats.controller.ts):
    /// "direct" | "group". Self-чат — это group с title="__self__"
    /// (см. ChatsService.getOrCreateSelfChat).
    /// В коде везде использовалось имя `kind` — маппим из любого ключа: type|kind.
    let kind: String
    let title: String?
    let avatarUrl: String?
    let lastMessage: ChatLastMessage?
    let unreadCount: Int?
    /// Бэк serializeChat() отдаёт `pinnedAt: Date | null`. Если не nil — закреплён.
    let pinnedAt: String?
    let members: [ChatMember]?
    /// Закреплённое сообщение в чате (PATCH /chats/:id/pin).
    /// Бэк отдаёт `pinnedMessage: { id, content, author }` (см. ChatsService.serializeChat).
    let pinnedMessage: PinnedMessage?

    /// Удобный геттер: чат закреплён, если pinnedAt не пустой.
    var pinned: Bool? { pinnedAt != nil ? true : nil }

    enum CodingKeys: String, CodingKey {
        case id, type, kind, title, avatarUrl, lastMessage, unreadCount, pinnedAt, members, pinnedMessage
    }

    init(id: String, kind: String, title: String?, avatarUrl: String?,
         lastMessage: ChatLastMessage?, unreadCount: Int?, pinnedAt: String?,
         members: [ChatMember]?, pinnedMessage: PinnedMessage? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.avatarUrl = avatarUrl
        self.lastMessage = lastMessage
        self.unreadCount = unreadCount
        self.pinnedAt = pinnedAt
        self.members = members
        self.pinnedMessage = pinnedMessage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        // Принимаем и `type` (новый бэк), и `kind` (легаси/socket events).
        if let t = try c.decodeIfPresent(String.self, forKey: .type) {
            self.kind = t
        } else if let k = try c.decodeIfPresent(String.self, forKey: .kind) {
            self.kind = k
        } else {
            self.kind = "group"
        }
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
        self.avatarUrl = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
        self.lastMessage = try c.decodeIfPresent(ChatLastMessage.self, forKey: .lastMessage)
        self.unreadCount = try c.decodeIfPresent(Int.self, forKey: .unreadCount)
        self.pinnedAt = try c.decodeIfPresent(String.self, forKey: .pinnedAt)
        self.members = try c.decodeIfPresent([ChatMember].self, forKey: .members)
        self.pinnedMessage = try c.decodeIfPresent(PinnedMessage.self, forKey: .pinnedMessage)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .type)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(avatarUrl, forKey: .avatarUrl)
        try c.encodeIfPresent(lastMessage, forKey: .lastMessage)
        try c.encodeIfPresent(unreadCount, forKey: .unreadCount)
        try c.encodeIfPresent(pinnedAt, forKey: .pinnedAt)
        try c.encodeIfPresent(members, forKey: .members)
        try c.encodeIfPresent(pinnedMessage, forKey: .pinnedMessage)
    }

    /// True для DM 1-1 (бэк возвращает "direct", но в legacy могло быть "private").
    var isDirect: Bool { kind == "direct" || kind == "private" }

    /// True для self-chat: бэк отдаёт type=group + title="__self__"
    /// (см. apps/api/src/modules/chats/chats.service.ts getOrCreateSelfChat).
    var isSelf: Bool { (title ?? "") == "__self__" }

    /// Унифицированное логическое представление типа.
    /// UI везде смотрит на displayKind — для self-чата возвращает "self".
    var displayKind: String { isSelf ? "self" : kind }
}

struct ChatLastMessage: Codable, Equatable {
    /// Все поля optional — на случай, если бэк перестанет отдавать какое-то поле
    /// (например для системных/forwarded/voice сообщений). Раньше `id` был
    /// обязательным, и если бэк возвращал lastMessage без id (или с null id),
    /// падал decode ВСЕГО Chat-объекта, и DM пропадал из списка ChatsListView.
    let id: String?
    let content: String?
    let authorId: String?
    let createdAt: String?
    let authorName: String?

    enum CodingKeys: String, CodingKey {
        case id, content, authorId, createdAt, authorName
    }

    init(id: String?, content: String?, authorId: String?, createdAt: String?, authorName: String?) {
        self.id = id
        self.content = content
        self.authorId = authorId
        self.createdAt = createdAt
        self.authorName = authorName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id)
        self.content = try c.decodeIfPresent(String.self, forKey: .content)
        self.authorId = try c.decodeIfPresent(String.self, forKey: .authorId)
        self.createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        self.authorName = try c.decodeIfPresent(String.self, forKey: .authorName)
    }
}

/// Закреплённое сообщение в чате (см. apps/api/src/modules/chats/chats.service.ts).
struct PinnedMessage: Codable, Equatable {
    let id: String
    let content: String
    let author: PinnedAuthor?

    struct PinnedAuthor: Codable, Equatable {
        let id: String?
        let username: String?
        let firstName: String?
        let lastName: String?
    }

    var authorDisplayName: String {
        let full = "\(author?.firstName ?? "") \(author?.lastName ?? "")"
            .trimmingCharacters(in: .whitespaces)
        return full.isEmpty ? (author?.username ?? "Сообщение") : full
    }
}

struct ChatMember: Codable, Identifiable, Equatable {
    /// `id` — обязательное поле для Identifiable. Если бэк прислал member без id —
    /// мы НЕ хотим уронить decode всего чата. Используем custom-инициализатор,
    /// и если id нет, генерируем placeholder UUID — пусть лучше будет «битый»
    /// member чем пропавший DM.
    let id: String
    let username: String?
    let firstName: String?
    let lastName: String?
    let avatarUrl: String?
    let isOnline: Bool?
    let role: String?
    let lastReadMessageId: String?

    enum CodingKeys: String, CodingKey {
        case id, username, firstName, lastName, avatarUrl, isOnline, role, lastReadMessageId
    }

    init(id: String, username: String?, firstName: String?, lastName: String?,
         avatarUrl: String?, isOnline: Bool?, role: String?, lastReadMessageId: String?) {
        self.id = id
        self.username = username
        self.firstName = firstName
        self.lastName = lastName
        self.avatarUrl = avatarUrl
        self.isOnline = isOnline
        self.role = role
        self.lastReadMessageId = lastReadMessageId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? UUID().uuidString
        self.username = try? c.decodeIfPresent(String.self, forKey: .username)
        self.firstName = try? c.decodeIfPresent(String.self, forKey: .firstName)
        self.lastName = try? c.decodeIfPresent(String.self, forKey: .lastName)
        self.avatarUrl = try? c.decodeIfPresent(String.self, forKey: .avatarUrl)
        self.isOnline = try? c.decodeIfPresent(Bool.self, forKey: .isOnline)
        self.role = try? c.decodeIfPresent(String.self, forKey: .role)
        self.lastReadMessageId = try? c.decodeIfPresent(String.self, forKey: .lastReadMessageId)
    }
}

struct ChatsListResponse: Codable {
    let data: [Chat]

    enum CodingKeys: String, CodingKey { case data }

    init(data: [Chat]) { self.data = data }

    /// Fault-tolerant decode массива чатов: если один чат decode фейлится —
    /// он пропускается, остальные приходят. Раньше один битый чат (например
    /// DM с неожиданным форматом lastMessage) убивал ВСЕ DM из списка.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let safeArr = try c.decode([SafeChat].self, forKey: .data)
        let items = safeArr.compactMap { $0.value }
        #if DEBUG
        let dropped = safeArr.count - items.count
        if dropped > 0 {
            print("[ChatsList] decoded \(items.count) chats, skipped \(dropped) bad entries")
        }
        #endif
        self.data = items
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(data, forKey: .data)
    }

    /// Враппер: пытается decode Chat, при фейле value=nil но сам декодер не ломается.
    private struct SafeChat: Decodable {
        let value: Chat?
        init(from decoder: Decoder) throws {
            do {
                self.value = try Chat(from: decoder)
            } catch {
                #if DEBUG
                print("[ChatsList] skip chat decode error:", error)
                #endif
                self.value = nil
            }
        }
    }
}

struct ChatMessage: Codable, Identifiable, Equatable, Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool { lhs.id == rhs.id }

    let id: String
    let chatId: String?
    /// Сервер не отдаёт `authorId` верхним уровнем — id живёт в `author.id`.
    /// Computed `senderId` использует author.id как fallback.
    let authorId: String?
    let content: String?
    let isEdited: Bool?
    let createdAt: String
    let updatedAt: String?
    let deletedAt: String?
    let replyToId: String?
    let replyTo: ReplyToMessage?
    let author: ChatMember?
    /// Сервер шлёт reactions как dict {emoji: count}, а не массив.
    /// Декодим как сырой словарь и преобразуем в массив через computed property.
    let reactions: [String: Int]?
    let myReactions: [String]?

    // Threads (Slack-style)
    let parentThreadId: String?
    let threadMessageCount: Int?
    let threadLastReplyAt: String?

    /// Whisper-транскрипт голосового сообщения (если расшифрован).
    let transcript: String?

    var senderId: String? { authorId ?? author?.id }
    var hasThread: Bool { (threadMessageCount ?? 0) > 0 }

    var reactionsList: [MessageReaction] {
        let mine = Set(myReactions ?? [])
        return (reactions ?? [:]).map { (emoji, count) in
            MessageReaction(emoji: emoji, count: count, myReacted: mine.contains(emoji))
        }.sorted { $0.count > $1.count }
    }
}

struct ReplyToMessage: Codable, Equatable {
    let id: String
    let content: String
    let authorName: String?
}

struct MessageReaction: Codable, Equatable {
    let emoji: String
    let count: Int
    let myReacted: Bool?
}

/// Wrapper для использования messageId как Identifiable item в .sheet
private struct RemindMessageWrapper: Identifiable {
    let id: String
}

struct MessagesResponse: Codable {
    let data: [ChatMessage]
    let hasMore: Bool?
}

// MARK: - Helpers (локальные для модуля)

private let chatISOFormatters: [ISO8601DateFormatter] = {
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let basic = ISO8601DateFormatter()
    basic.formatOptions = [.withInternetDateTime]
    return [withFraction, basic]
}()

private func parseChatDate(_ iso: String?) -> Date? {
    guard let iso else { return nil }
    for f in chatISOFormatters {
        if let d = f.date(from: iso) { return d }
    }
    return nil
}

func displayName(for member: ChatMember) -> String {
    let full = "\(member.firstName ?? "") \(member.lastName ?? "")"
        .trimmingCharacters(in: .whitespaces)
    return full.ifEmpty(or: member.username ?? "")
}

private func chatTitle(_ chat: Chat, currentUserId: String?) -> String {
    if chat.isSelf { return "Избранное" }
    if let t = chat.title, !t.isEmpty { return t }
    if chat.isDirect,
       let me = currentUserId,
       let other = chat.members?.first(where: { $0.id != me }) {
        return displayName(for: other)
    }
    if chat.kind == "group" {
        return "Группа"
    }
    return "Чат"
}

private func chatCounterpart(_ chat: Chat, currentUserId: String?) -> ChatMember? {
    guard chat.isDirect, let me = currentUserId else { return nil }
    return chat.members?.first(where: { $0.id != me })
}

// MARK: - ChatsListView

struct ChatsListView: View {
    @EnvironmentObject var auth: AuthStore

    @State private var chats: [Chat] = []
    @State private var loading = true
    @State private var error: String?
    @State private var search = ""
    @State private var showNewChatSheet = false
    @State private var openChatId: String?

    var body: some View {
        VStack(spacing: 0) {
            // Кастомный inline-header вместо NavigationBar
            chatListHeader

            Group {
                if loading && chats.isEmpty {
                    ProgressView().tint(Theme.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if chats.isEmpty {
                    EmptyStateView(
                        icon: "bubble.left.and.bubble.right",
                        title: "Чатов пока нет",
                        description: error ?? "Здесь появятся ваши личные и групповые беседы"
                    )
                } else {
                    List {
                        ForEach(filteredChats) { chat in
                            ZStack {
                                NavigationLink {
                                    ChatDetailView(chatId: chat.id, initialChat: chat)
                                        .environmentObject(auth)
                                } label: {
                                    EmptyView()
                                }
                                .opacity(0)
                                ChatRow(chat: chat, currentUserId: auth.currentUser?.id)
                            }
                            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    Task { await togglePin(chat) }
                                } label: {
                                    Label(
                                        chat.pinned == true ? "Открепить" : "Закрепить",
                                        systemImage: chat.pinned == true ? "pin.slash.fill" : "pin.fill"
                                    )
                                }
                                .tint(Theme.accent)
                            }
                        }
                        // Резервируем место под плавающий таб-бар
                        Color.clear
                            .frame(height: TabBarVisibility.reservedHeight)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Theme.pageBackground)
                }
            }
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showNewChatSheet) {
            NewChatSheet { newChat in
                chats.insert(newChat, at: 0)
                openChatId = newChat.id
            }
            .environmentObject(auth)
        }
        .refreshable { await load() }
        .task { await load() }
    }

    /// Inline-header для chat-list — никаких UINavigationBar.
    /// Полоса с заголовком + «новый чат» + поисковое поле.
    @ViewBuilder
    private var chatListHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Text("Чаты")
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.5)
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Button {
                    showNewChatSheet = true
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Theme.accent)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Theme.surfaceBackground))
                        .overlay(Circle().strokeBorder(Theme.border, lineWidth: 0.5))
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(Theme.textTertiary)
                    .font(.system(size: 13, weight: .semibold))
                TextField("Поиск по чатам", text: $search)
                    .font(.system(size: 14))
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(Theme.textTertiary)
                            .font(.system(size: 14))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.surfaceBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 0.5)
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private func chatsCountWord(_ n: Int) -> String {
        let mod10 = n % 10
        let mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return "беседа" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "беседы" }
        return "бесед"
    }

    /// Сортировка:
    ///  1) Self-чат (Saved Messages, type == "self") — ВСЕГДА сверху.
    ///  2) Закреплённые (pinned == true).
    ///  3) Остальные — по дате последнего сообщения (новые сверху).
    private var sortedChats: [Chat] {
        chats.sorted { lhs, rhs in
            let lSelf = lhs.isSelf
            let rSelf = rhs.isSelf
            if lSelf != rSelf { return lSelf }
            let lp = lhs.pinned ?? false
            let rp = rhs.pinned ?? false
            if lp != rp { return lp && !rp }
            let ld = parseChatDate(lhs.lastMessage?.createdAt) ?? .distantPast
            let rd = parseChatDate(rhs.lastMessage?.createdAt) ?? .distantPast
            return ld > rd
        }
    }

    /// Если у пользователя ещё нет self-чата в списке — показываем виртуальную карточку
    /// «Сохранённые сообщения», которая ведёт в SavedMessagesView.
    private var hasSelfChat: Bool {
        chats.contains(where: { $0.isSelf })
    }

    /// Фильтрация по тексту поиска (по title, по author/content последнего сообщения,
    /// и по member firstName/lastName/username для private/group).
    private var filteredChats: [Chat] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return sortedChats }
        return sortedChats.filter { chat in
            let title = chatTitle(chat, currentUserId: auth.currentUser?.id).lowercased()
            if title.contains(q) { return true }
            if let last = chat.lastMessage?.content?.lowercased(), last.contains(q) { return true }
            if let last = chat.lastMessage?.authorName?.lowercased(), last.contains(q) { return true }
            for m in chat.members ?? [] {
                let n = "\(m.firstName ?? "") \(m.lastName ?? "") \(m.username ?? "")".lowercased()
                if n.contains(q) { return true }
            }
            return false
        }
    }

    /// PATCH /chats/:id/pin-chat body { pin: Bool }
    /// (см. apps/api/src/modules/chats/chats.controller.ts pinChat)
    private func togglePin(_ chat: Chat) async {
        struct Body: Encodable { let pin: Bool }
        let newPinned = !(chat.pinned ?? false)
        // Оптимистично — обновляем pinnedAt (строка ISO/“optimistic”).
        if let i = chats.firstIndex(where: { $0.id == chat.id }) {
            let c = chats[i]
            chats[i] = Chat(
                id: c.id, kind: c.kind, title: c.title, avatarUrl: c.avatarUrl,
                lastMessage: c.lastMessage, unreadCount: c.unreadCount,
                pinnedAt: newPinned ? ISO8601DateFormatter().string(from: Date()) : nil,
                members: c.members,
                pinnedMessage: c.pinnedMessage
            )
        }
        do {
            _ = try await APIClient.shared.rawRequest(
                "PATCH", "chats/\(chat.id)/pin-chat", body: Body(pin: newPinned)
            )
        } catch {
            // Откат при ошибке
            await load()
        }
    }

    private func load() async {
        if chats.isEmpty { loading = true }
        defer { loading = false }
        do {
            // Параллельно: основной список и self-чат («Избранное»),
            // который сервер исключает из /chats и отдаёт отдельным эндпоинтом.
            async let listTask: ChatsListResponse = APIClient.shared.get("chats")
            async let selfTask: Chat? = {
                do {
                    let c: Chat = try await APIClient.shared.get("chats/self")
                    return c
                } catch {
                    return nil
                }
            }()
            let resp = try await listTask
            let selfChat = await selfTask

            var merged = resp.data
            if let s = selfChat,
               !merged.contains(where: { $0.id == s.id }) {
                merged.insert(s, at: 0)
            }
            #if DEBUG
            let dmCount = merged.filter { $0.isDirect }.count
            let groupCount = merged.filter { $0.kind == "group" && !$0.isSelf }.count
            let selfCount = merged.filter { $0.isSelf }.count
            print("[ChatsList] loaded total=\(merged.count) DM=\(dmCount) group=\(groupCount) self=\(selfCount)")
            #endif
            self.chats = merged
            self.error = nil
        } catch {
            #if DEBUG
            print("[ChatsList] load failed:", error)
            #endif
            self.error = (error as? LocalizedError)?.errorDescription ?? "Не удалось загрузить чаты"
        }
    }
}

// MARK: - ChatRow

private struct ChatRow: View {
    let chat: Chat
    let currentUserId: String?

    private var title: String { chatTitle(chat, currentUserId: currentUserId) }

    private var counterpart: ChatMember? { chatCounterpart(chat, currentUserId: currentUserId) }

    private var preview: String {
        guard let last = chat.lastMessage else { return "Нет сообщений" }
        let content = last.content ?? ""
        if let name = last.authorName, !name.isEmpty, chat.kind == "group" {
            return "\(name): \(content)"
        }
        return content.isEmpty ? "Нет сообщений" : content
    }

    private var timeText: String {
        guard let date = parseChatDate(chat.lastMessage?.createdAt) else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        if Calendar.current.isDateInToday(date) {
            f.dateFormat = "HH:mm"
        } else if Calendar.current.isDateInYesterday(date) {
            return "вчера"
        } else {
            f.dateFormat = "d MMM"
        }
        return f.string(from: date)
    }

    private var hasUnread: Bool { (chat.unreadCount ?? 0) > 0 }

    /// Для групповой составной аватарки берём всех кроме текущего пользователя
    /// (если current id известен), порядок — как пришёл с бэка.
    fileprivate func filteredMembers(_ mems: [ChatMember]) -> [ChatMember] {
        guard let me = currentUserId else { return mems }
        let others = mems.filter { $0.id != me }
        return others.isEmpty ? mems : others
    }

    var body: some View {
        DSCard(radius: Radius.xl, padding: 12, bordered: false) {
            HStack(alignment: .center, spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    avatar
                        .frame(width: 50, height: 50)
                    if counterpart?.isOnline == true && chat.isDirect {
                        Circle()
                            .fill(Theme.success)
                            .frame(width: 12, height: 12)
                            .overlay(
                                Circle().strokeBorder(Theme.surfaceBackground, lineWidth: 2)
                            )
                            .offset(x: 1, y: 1)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if chat.pinned == true {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(Theme.textTertiary)
                                .rotationEffect(.degrees(45))
                        }
                        Text(title)
                            .font(.dsH3)
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(timeText)
                            .font(.dsCaption)
                            .foregroundColor(Theme.textTertiary)
                    }

                    HStack(alignment: .center, spacing: 8) {
                        Text(preview)
                            .font(.dsBodySM)
                            .foregroundColor(hasUnread ? Theme.textPrimary : Theme.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if let unread = chat.unreadCount, unread > 0 {
                            DSBadge(text: "\(unread)", color: Theme.accent, filled: true)
                        }
                    }
                }
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var avatar: some View {
        if chat.isSelf {
            ZStack {
                Circle().fill(Theme.accent.opacity(0.15))
                Image(systemName: "bookmark.fill")
                    .foregroundColor(Theme.accent)
                    .font(.system(size: 22, weight: .semibold))
            }
        } else if chat.kind == "group" {
            if let url = chat.avatarUrl, !url.isEmpty {
                AvatarCircle(url: url, name: title)
            } else if let mems = chat.members, !mems.isEmpty {
                // Составная мозаика из аватарок 2-4 первых участников.
                GroupAvatarStack(
                    members: filteredMembers(mems),
                    size: 50
                )
            } else {
                ZStack {
                    LinearGradient(colors: [Theme.purple, Theme.pink],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "person.3.fill")
                        .foregroundColor(.white)
                        .font(.system(size: 19, weight: .semibold))
                }
                .clipShape(Circle())
            }
        } else {
            // private
            AvatarCircle(url: counterpart?.avatarUrl ?? chat.avatarUrl, name: title)
        }
    }
}

// MARK: - VirtualSavedRow (если self-чата нет в списке)

private struct VirtualSavedRow: View {
    var body: some View {
        DSCard(radius: Radius.xl, padding: 12, bordered: false) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle().fill(Theme.accent.opacity(0.15))
                    Image(systemName: "bookmark.fill")
                        .foregroundColor(Theme.accent)
                        .font(.system(size: 22, weight: .semibold))
                }
                .frame(width: 50, height: 50)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Сохранённые сообщения")
                        .font(.dsH3)
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Text("Заметки и важное только для вас")
                        .font(.dsBodySM)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - GroupAvatarStack — составная аватарка для групп без avatarUrl

struct GroupAvatarStack: View {
    let members: [ChatMember]
    /// Размер всего стэка (стороны квадрата).
    var size: CGFloat = 50

    /// Берём до 4 первых участников (исключая текущего).
    private var visible: [ChatMember] {
        Array(members.prefix(4))
    }

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                if visible.count <= 1 {
                    // Один участник — обычный аватар на весь круг.
                    AvatarCircle(
                        url: visible.first?.avatarUrl,
                        name: visible.first.map(displayName) ?? "?"
                    )
                    .frame(width: s, height: s)
                } else if visible.count == 2 {
                    HStack(spacing: 1) {
                        ForEach(visible) { m in
                            AvatarCircle(url: m.avatarUrl, name: displayName(for: m))
                                .frame(width: (s - 1) / 2, height: s)
                                .clipShape(Rectangle())
                        }
                    }
                } else {
                    // 3-4 участника — 2×2 grid (если 3, нижний правый — заглушка).
                    let cell = (s - 1) / 2
                    VStack(spacing: 1) {
                        HStack(spacing: 1) {
                            cellAvatar(at: 0, size: cell)
                            cellAvatar(at: 1, size: cell)
                        }
                        HStack(spacing: 1) {
                            cellAvatar(at: 2, size: cell)
                            cellAvatar(at: 3, size: cell)
                        }
                    }
                }
            }
            .frame(width: s, height: s)
            .clipShape(Circle())
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private func cellAvatar(at index: Int, size cell: CGFloat) -> some View {
        if index < visible.count {
            AvatarCircle(url: visible[index].avatarUrl,
                         name: displayName(for: visible[index]))
                .frame(width: cell, height: cell)
                .clipShape(Rectangle())
        } else {
            // Placeholder-четвертинка с «+N»
            ZStack {
                LinearGradient(colors: [Theme.purple, Theme.pink],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                if members.count > 4 {
                    Text("+\(members.count - 3)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    Image(systemName: "person.fill")
                        .foregroundColor(.white.opacity(0.7))
                        .font(.system(size: 12))
                }
            }
            .frame(width: cell, height: cell)
        }
    }
}

// MARK: - ChatDetailView

struct ChatDetailView: View {
    let chatId: String
    let initialChat: Chat?

    @EnvironmentObject var auth: AuthStore
    @EnvironmentObject var callManager: CallManager

    @State private var chat: Chat?
    @State private var messages: [ChatMessage] = []
    @State private var loading = true
    @State private var loadError: String?

    @State private var inputText: String = ""
    @State private var sending = false
    @State private var replyTo: ChatMessage?
    @State private var editing: ChatMessage?
    @State private var failedClientIds: Set<String> = []

    @State private var showParticipants = false
    @State private var showSettings = false
    @State private var openedThreadParent: ChatMessage?

    // Photo attachment
    @State private var pickerItem: PhotosPickerItem?
    @State private var uploading = false
    @State private var uploadError: String?

    // Voice recording
    @StateObject private var recorder = AudioRecorder.shared
    @State private var recordingTimer: Date?

    // Polls
    @State private var showPollSheet = false
    @State private var openedPollId: String?
    @State private var showAttachDialog = false
    @State private var triggerPhotoPicker = false

    // Reminder for tapped message
    @State private var remindMessageId: String?

    // Forward — выбранное сообщение для пересылки.
    @State private var forwardMessage: ChatMessage?

    // Scheduled message
    @State private var showScheduledPicker = false
    @State private var scheduledAt: Date = Date().addingTimeInterval(3600)
    @State private var sendScheduled = false

    // Realtime / fallback polling
    private let pollInterval: TimeInterval = 15
    @State private var pollCancellable: AnyCancellable?
    @State private var realtimeBag: Set<AnyCancellable> = []
    @State private var typingUsers: [String: Date] = [:]    // userId -> last-seen typing
    @State private var typingTickCancellable: AnyCancellable?
    @State private var lastTypingSent: Date?
    @StateObject private var realtime = ChatRealtime.shared

    init(chatId: String, initialChat: Chat? = nil) {
        self.chatId = chatId
        self.initialChat = initialChat
    }

    private var currentUserId: String? { auth.currentUser?.id }

    private var counterpart: ChatMember? {
        guard let chat else { return nil }
        return chatCounterpart(chat, currentUserId: currentUserId)
    }

    var body: some View {
        VStack(spacing: 0) {
            chatDetailHeader
            messagesList
            if let reply = replyTo {
                replyPreviewBar(reply)
            }
            if let edit = editing {
                editingPreviewBar(edit)
            }
            inputBar
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .hidesTabBar()
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showParticipants) {
            if let chat {
                ParticipantsSheet(chat: chat)
                    .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $showSettings) {
            if let c = chat {
                ChatSettingsSheet(
                    chat: c,
                    currentUserId: currentUserId,
                    onUpdated: { updated in self.chat = updated },
                    onLeft: { /* экран закроется через NavigationLink dismiss */ }
                )
                .environmentObject(auth)
            }
        }
        .sheet(item: $openedThreadParent) { parent in
            NavigationStack {
                ThreadView(chatId: chatId, parent: parent)
                    .environmentObject(auth)
            }
        }
        .sheet(item: Binding(
            get: { remindMessageId.map { RemindMessageWrapper(id: $0) } },
            set: { remindMessageId = $0?.id }
        )) { wrapper in
            CreateReminderSheet(messageId: wrapper.id) { /* no extra refresh needed */ }
        }
        .sheet(item: $forwardMessage) { msg in
            ForwardChatPickerSheet(
                message: msg,
                onForwarded: { /* no-op, чат-таргет сам отрефрешит */ }
            )
            .environmentObject(auth)
        }
        .task {
            if let initialChat { self.chat = initialChat }
            await loadChat()
            await loadHistory()
            // Realtime приоритетнее polling. Если Socket.IO connected — заходим в комнату
            // и слушаем события. Polling всё равно стартуем как fallback (низкая частота).
            attachRealtime()
            startPolling()
        }
        .onDisappear {
            stopPolling()
            detachRealtime()
        }
    }

    // MARK: - Calls

    /// Инициировать звонок из хедера чата.
    /// Для DM подставляем имя/аватар собеседника, чтобы UI ActiveCallView сразу
    /// показал нормальную карточку — без ожидания серверного ответа.
    private func startCall(type: CallType) {
        let cp = counterpart
        let name: String? = {
            if let cp { return displayName(for: cp) }
            return chat?.title
        }()
        let avatar: String? = cp?.avatarUrl ?? chat?.avatarUrl
        let peerId: String? = cp?.id
        callManager.startCall(
            chatId: chatId,
            type: type,
            peerName: name,
            peerAvatarUrl: avatar,
            peerUserId: peerId
        )
    }

    // MARK: - Realtime

    private func attachRealtime() {
        realtime.join(chatId: chatId)

        realtime.messageNew
            .sink { dict in
                guard let m = ChatMessage.from(socketDict: dict),
                      m.chatId == chatId || m.chatId == nil else { return }
                if !messages.contains(where: { $0.id == m.id }) {
                    messages.append(m)
                    Task { await markRead() }
                }
            }
            .store(in: &realtimeBag)

        realtime.messageEdit
            .sink { dict in
                guard let m = ChatMessage.from(socketDict: dict) else { return }
                if let i = messages.firstIndex(where: { $0.id == m.id }) {
                    messages[i] = m
                }
            }
            .store(in: &realtimeBag)

        realtime.messageDelete
            .sink { dict in
                guard let id = dict["id"] as? String else { return }
                messages.removeAll { $0.id == id }
            }
            .store(in: &realtimeBag)

        realtime.messageReact
            .sink { dict in
                guard let m = ChatMessage.from(socketDict: dict) else { return }
                if let i = messages.firstIndex(where: { $0.id == m.id }) {
                    messages[i] = m
                }
            }
            .store(in: &realtimeBag)

        realtime.typing
            .sink { dict in
                guard let userId = dict["userId"] as? String,
                      let cId = dict["chatId"] as? String,
                      cId == chatId, userId != currentUserId else { return }
                typingUsers[userId] = Date()
            }
            .store(in: &realtimeBag)

        // Online/offline презенс — патчим isOnline у соответствующего члена в chat.members.
        realtime.presence
            .sink { dict in
                guard let userId = dict["userId"] as? String,
                      let status = dict["status"] as? String else { return }
                guard var c = chat, var members = c.members else { return }
                let isOnline = (status == "online")
                if let i = members.firstIndex(where: { $0.id == userId }) {
                    let m = members[i]
                    members[i] = ChatMember(
                        id: m.id, username: m.username, firstName: m.firstName,
                        lastName: m.lastName, avatarUrl: m.avatarUrl,
                        isOnline: isOnline, role: m.role,
                        lastReadMessageId: m.lastReadMessageId
                    )
                    c = Chat(
                        id: c.id, kind: c.kind, title: c.title, avatarUrl: c.avatarUrl,
                        lastMessage: c.lastMessage, unreadCount: c.unreadCount,
                        pinnedAt: c.pinnedAt, members: members,
                        pinnedMessage: c.pinnedMessage
                    )
                    chat = c
                }
            }
            .store(in: &realtimeBag)

        // user:read — другой участник прочитал, обновляем lastReadMessageId.
        realtime.read
            .sink { dict in
                guard let userId = dict["userId"] as? String,
                      let cId = dict["chatId"] as? String,
                      cId == chatId,
                      let lastMid = dict["lastMessageId"] as? String else { return }
                guard var c = chat, var members = c.members else { return }
                if let i = members.firstIndex(where: { $0.id == userId }) {
                    let m = members[i]
                    members[i] = ChatMember(
                        id: m.id, username: m.username, firstName: m.firstName,
                        lastName: m.lastName, avatarUrl: m.avatarUrl,
                        isOnline: m.isOnline, role: m.role,
                        lastReadMessageId: lastMid
                    )
                    c = Chat(
                        id: c.id, kind: c.kind, title: c.title, avatarUrl: c.avatarUrl,
                        lastMessage: c.lastMessage, unreadCount: c.unreadCount,
                        pinnedAt: c.pinnedAt, members: members,
                        pinnedMessage: c.pinnedMessage
                    )
                    chat = c
                }
            }
            .store(in: &realtimeBag)

        // Cleanup typing — каждую секунду убираем тех кто не печатает дольше 4 сек
        typingTickCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                let now = Date()
                typingUsers = typingUsers.filter { now.timeIntervalSince($0.value) < 4 }
            }
    }

    private func detachRealtime() {
        realtime.leave(chatId: chatId)
        realtimeBag.forEach { $0.cancel() }
        realtimeBag.removeAll()
        typingTickCancellable?.cancel()
        typingTickCancellable = nil
        typingUsers.removeAll()
    }

    // MARK: - Header

    /// Кастомный inline-header вместо UINavigationBar — точно тонкий,
    /// без отступов системы, в одной строке: back / avatar+title / actions.
    @ViewBuilder
    private var chatDetailHeader: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Theme.accent)
                    .frame(width: 32, height: 32)
            }
            headerTitleView
                .frame(maxWidth: .infinity, alignment: .leading)
            if chat?.isSelf != true {
                Button { startCall(type: .audio) } label: {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.accent)
                        .frame(width: 32, height: 32)
                }
                .disabled(callManager.activeCall != nil)
                Button { startCall(type: .video) } label: {
                    Image(systemName: "video.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.accent)
                        .frame(width: 32, height: 32)
                }
                .disabled(callManager.activeCall != nil)
                Button { showSettings = true } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Theme.accent)
                        .frame(width: 32, height: 32)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Theme.surfaceBackground
                .overlay(Rectangle().fill(Theme.separator).frame(height: 0.5),
                         alignment: .bottom)
                .ignoresSafeArea(edges: .top)
        )
    }

    @Environment(\.dismiss) private var dismiss

    private var headerTitle: String {
        guard let chat else { return "Чат" }
        return chatTitle(chat, currentUserId: currentUserId)
    }

    @ViewBuilder
    private var headerAvatar: some View {
        if let chat {
            if chat.isSelf {
                ZStack {
                    Circle().fill(Theme.accent.opacity(0.15))
                    Image(systemName: "bookmark.fill")
                        .foregroundColor(Theme.accent)
                        .font(.system(size: 12, weight: .semibold))
                }
                .frame(width: 28, height: 28)
            } else if chat.kind == "group" {
                if let url = chat.avatarUrl, !url.isEmpty {
                    AvatarCircle(url: url, name: headerTitle).frame(width: 28, height: 28)
                } else if let mems = chat.members, !mems.isEmpty {
                    let me = currentUserId
                    let visible = mems.filter { $0.id != me }
                    GroupAvatarStack(members: visible.isEmpty ? mems : visible, size: 28)
                } else {
                    ZStack {
                        LinearGradient(colors: [Theme.purple, Theme.pink],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: "person.3.fill")
                            .foregroundColor(.white)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .frame(width: 28, height: 28)
                    .clipShape(Circle())
                }
            } else {
                AvatarCircle(url: counterpart?.avatarUrl ?? chat.avatarUrl,
                             name: headerTitle)
                    .frame(width: 28, height: 28)
            }
        }
    }

    private var headerTitleView: some View {
        HStack(spacing: 8) {
            headerAvatar
            VStack(spacing: 2) {
            Text(headerTitle)
                .font(.headline)
                .lineLimit(1)

            if !typingUsers.isEmpty {
                HStack(spacing: 4) {
                    typingDots
                    Text(typingLabel)
                        .font(.caption2)
                        .foregroundColor(Theme.accent)
                }
            } else if chat?.isDirect == true, let cp = counterpart {
                HStack(spacing: 4) {
                    if cp.isOnline == true {
                        Circle()
                            .fill(Theme.success)
                            .frame(width: 7, height: 7)
                        Text("в сети")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else {
                        Text("не в сети")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            } else if chat?.isSelf == true {
                Text("Заметки и важное только для вас")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else if chat?.kind == "group", let count = chat?.members?.count {
                Text("\(count) " + participantsWord(count))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            }
        }
    }

    private var typingLabel: String {
        let names: [String] = typingUsers.keys.compactMap { uid in
            guard let m = chat?.members?.first(where: { $0.id == uid }) else { return nil }
            return displayName(for: m).split(separator: " ").first.map(String.init)
        }
        if names.isEmpty { return "печатает…" }
        if names.count == 1 { return "\(names[0]) печатает…" }
        return "\(names.prefix(2).joined(separator: ", ")) печатают…"
    }

    @ViewBuilder
    private var typingDots: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(Theme.accent).frame(width: 4, height: 4)
                    .opacity(0.4)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.15), value: typingUsers.count)
            }
        }
    }

    private func participantsWord(_ count: Int) -> String {
        let mod10 = count % 10
        let mod100 = count % 100
        if mod10 == 1 && mod100 != 11 { return "участник" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "участника" }
        return "участников"
    }

    // MARK: - Messages list

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if loading && messages.isEmpty {
                        ProgressView().tint(Theme.accent)
                            .padding(.top, 80)
                    } else if messages.isEmpty {
                        EmptyStateView(
                            icon: "bubble.left",
                            title: "Сообщений пока нет",
                            description: loadError ?? "Напишите первым"
                        )
                        .padding(.top, 40)
                    } else {
                        // Pinned message bar (если в чате есть закреплённое сообщение)
                        if let pinned = chat?.pinnedMessage {
                            pinnedMessageBar(pinned)
                                .padding(.horizontal, 12)
                        }
                        // Показываем только top-level сообщения (без parentThreadId).
                        // Реплаи внутри тредов — на отдельном экране ThreadView.
                        let visibleMessages = messages.filter { $0.parentThreadId == nil }
                        ForEach(Array(visibleMessages.enumerated()), id: \.element.id) { idx, msg in
                            // Авторская «голова» (имя + аватар) показывается, если предыдущее
                            // сообщение от другого автора (или это первое сообщение).
                            let prev: ChatMessage? = idx > 0 ? visibleMessages[idx - 1] : nil
                            let sameAuthorAsPrev = prev?.senderId == msg.senderId
                            MessageBubble(
                                message: msg,
                                isMine: msg.senderId == currentUserId,
                                isGroup: chat?.kind == "group" && chat?.isSelf != true,
                                failed: failedClientIds.contains(msg.id),
                                currentUserId: currentUserId,
                                readState: readState(for: msg),
                                showAuthorHead: !sameAuthorAsPrev,
                                onReply: { replyTo = msg; editing = nil },
                                onCopy: { UIPasteboard.general.string = msg.content ?? "" },
                                onDelete: { Task { await deleteMessage(msg) } },
                                onEdit: { editing = msg; replyTo = nil; inputText = msg.content ?? "" },
                                onReact: { emoji in Task { await toggleReaction(msg, emoji: emoji) } },
                                onOpenThread: { openedThreadParent = msg },
                                onForward: { forwardMessage = msg },
                                onPin: { Task { await pinMessage(msg) } },
                                onUnpin: { Task { await unpinMessage() } },
                                isPinned: chat?.pinnedMessage?.id == msg.id,
                                onTranscribe: { mid in Task { await transcribeMessage(mid) } }
                            )
                            .id(msg.id)
                            .padding(.horizontal, 12)
                            .padding(.top, sameAuthorAsPrev ? 1 : 6)
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            .onChange(of: messages.count) { _ in
                if let last = messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onAppear {
                if let last = messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Reply / edit preview bars

    private func replyPreviewBar(_ reply: ChatMessage) -> some View {
        HStack(spacing: 10) {
            Rectangle().fill(Theme.accent).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Ответ " + (reply.author.map(displayName) ?? "сообщению"))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.accent)
                Text(reply.content ?? "")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                replyTo = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surfaceBackground)
    }

    private func editingPreviewBar(_ edit: ChatMessage) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil")
                .foregroundColor(Theme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("Редактирование")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.warning)
                Text(edit.content ?? "")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                editing = nil
                inputText = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surfaceBackground)
    }

    // MARK: - Input bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            scheduledBanner
            recordingBanner
            uploadBanner
            inputRow
        }
        .overlay(
            Rectangle()
                .fill(Theme.separator)
                .frame(height: 0.5),
            alignment: .top
        )
        .sheet(isPresented: $showScheduledPicker) {
            scheduledSheet
        }
        .sheet(isPresented: $showPollSheet) {
            CreatePollSheet { question, options, isAnonymous, allowMulti in
                await createPoll(question: question, options: options, isAnonymous: isAnonymous, allowMulti: allowMulti)
            }
        }
        .photosPicker(isPresented: $triggerPhotoPicker, selection: $pickerItem, matching: .images)
        .onChange(of: pickerItem) { newItem in
            guard let newItem else { return }
            Task { await uploadPhoto(item: newItem) }
        }
        .confirmationDialog("Прикрепить", isPresented: $showAttachDialog, titleVisibility: .hidden) {
            Button { triggerPhotoPicker = true } label: {
                Label("Фото из галереи", systemImage: "photo")
            }
            Button { showPollSheet = true } label: {
                Label("Опрос", systemImage: "chart.bar.xaxis")
            }
            Button { showScheduledPicker = true } label: {
                Label(sendScheduled ? "Изменить время" : "Отложить отправку", systemImage: "clock")
            }
            Button("Отмена", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var scheduledBanner: some View {
        if sendScheduled {
            HStack(spacing: 8) {
                Image(systemName: "clock.fill").foregroundColor(Theme.warning)
                Text("Отправить ").font(.caption) +
                Text(scheduledFmt.string(from: scheduledAt))
                    .font(.caption.weight(.semibold)).foregroundColor(Theme.warning)
                Spacer()
                Button { sendScheduled = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Theme.warning.opacity(0.1))
        }
    }

    @ViewBuilder
    private var recordingBanner: some View {
        if recorder.isRecording {
            HStack(spacing: 10) {
                Circle().fill(Theme.danger).frame(width: 10, height: 10)
                    .scaleEffect(0.85 + 0.3 * Double(recorder.meterLevel))
                Text("Запись…").font(.caption.weight(.semibold)).foregroundColor(Theme.danger)
                Text(formatRecTime(recorder.elapsed)).font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                Spacer()
                Button { recorder.cancel() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                Button { Task { await stopAndSendVoice() } } label: {
                    Image(systemName: "paperplane.circle.fill")
                        .font(.title2).foregroundColor(Theme.accent)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.danger.opacity(0.08))
        }
    }

    @ViewBuilder
    private var uploadBanner: some View {
        if uploading {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7).tint(Theme.accent)
                Text("Загрузка…").font(.caption).foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Theme.surfaceBackground.opacity(0.5))
        }
        if let err = uploadError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Theme.danger)
                Text(err).font(.caption).foregroundColor(Theme.danger)
                Spacer()
                Button { uploadError = nil } label: {
                    Image(systemName: "xmark").foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Theme.danger.opacity(0.08))
        }
    }

    @ViewBuilder
    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if !recorder.isRecording {
                Button { showAttachDialog = true } label: {
                    Image(systemName: "paperclip")
                        .foregroundColor(Theme.accent)
                        .font(.system(size: 19, weight: .medium))
                        .frame(width: 36, height: 36)
                }
                .disabled(uploading || sending)
            }

            messageTextField

            if !inputText.isEmpty {
                Button { showScheduledPicker = true } label: {
                    Image(systemName: "clock")
                        .foregroundColor(Theme.textSecondary)
                        .font(.system(size: 16))
                        .frame(width: 30, height: 30)
                }
            }

            sendOrMicButton
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.surfaceBackground)
    }

    @ViewBuilder
    private var messageTextField: some View {
        TextField("Сообщение", text: $inputText, axis: .vertical)
            .lineLimit(1...5)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Theme.pageBackground)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 0.5)
            )
            .disabled(recorder.isRecording)
            .onChange(of: inputText) { newValue in
                guard !newValue.isEmpty else { return }
                let now = Date()
                if let last = lastTypingSent, now.timeIntervalSince(last) < 2 { return }
                lastTypingSent = now
                realtime.sendTyping(chatId: chatId)
            }
    }

    @ViewBuilder
    private var sendOrMicButton: some View {
        if canSend {
            Button { Task { await send() } } label: {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [Theme.accent, Theme.accentHover],
                            startPoint: .top, endPoint: .bottom
                        ))
                        .frame(width: 36, height: 36)
                    if sending {
                        ProgressView().tint(.white).scaleEffect(0.7)
                    } else {
                        Image(systemName: sendIcon)
                            .foregroundColor(.white)
                            .font(.system(size: 14, weight: .bold))
                    }
                }
                .shadow(color: Theme.accent.opacity(0.3), radius: 6, x: 0, y: 2)
            }
            .disabled(sending)
        } else if !recorder.isRecording {
            Button { Task { await startRecording() } } label: {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [Theme.accent, Theme.accentHover],
                            startPoint: .top, endPoint: .bottom
                        ))
                        .frame(width: 36, height: 36)
                    Image(systemName: "mic.fill")
                        .foregroundColor(.white)
                        .font(.system(size: 14, weight: .bold))
                }
                .shadow(color: Theme.accent.opacity(0.3), radius: 6, x: 0, y: 2)
            }
        }
    }

    private var sendIcon: String {
        if editing != nil { return "checkmark" }
        if sendScheduled { return "clock.arrow.circlepath" }
        return "paperplane.fill"
    }

    private static let scheduledFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM, HH:mm"
        return f
    }()
    private var scheduledFmt: DateFormatter { Self.scheduledFmt }

    @ViewBuilder
    private var scheduledSheet: some View {
        NavigationStack {
            Form {
                DatePicker(
                    "Время отправки",
                    selection: $scheduledAt,
                    in: Date()...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.graphical)
                .environment(\.locale, Locale(identifier: "ru_RU"))
            }
            .navigationTitle("Отложенная отправка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { showScheduledPicker = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        sendScheduled = true
                        showScheduledPicker = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Voice messages

    // MARK: - Polls

    /// Сначала отправляем сообщение «📊 <question>», получаем messageId,
    /// затем POST /polls/chat с этим messageId и опциями.
    private func createPoll(question: String, options: [String], isAnonymous: Bool, allowMulti: Bool) async {
        let placeholderContent = "📊 \(question)"
        let clientId = UUID().uuidString
        struct MsgBody: Encodable { let content: String; let clientId: String }
        do {
            let saved: ChatMessage = try await APIClient.shared.post(
                "chats/\(chatId)/messages",
                body: MsgBody(content: placeholderContent, clientId: clientId)
            )
            // Создаём poll и привязываем к message
            struct PollBody: Encodable {
                let messageId: String
                let question: String
                let options: [String]
                let isAnonymous: Bool
                let allowMulti: Bool
            }
            _ = try await APIClient.shared.rawRequest(
                "POST", "polls/chat",
                body: PollBody(
                    messageId: saved.id,
                    question: question,
                    options: options,
                    isAnonymous: isAnonymous,
                    allowMulti: allowMulti
                )
            )
            await loadHistory()
        } catch {
            uploadError = apiUserMessage(error)
        }
    }

    private func formatRecTime(_ t: TimeInterval) -> String {
        let total = Int(t)
        let m = total / 60, s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    private func startRecording() async {
        let granted = await recorder.requestPermission()
        guard granted else {
            uploadError = "Нет разрешения на микрофон. Включите в Настройках."
            return
        }
        do { _ = try recorder.start() } catch {
            uploadError = "Не удалось начать запись: \(error.localizedDescription)"
        }
    }

    private func stopAndSendVoice() async {
        guard let url = recorder.stop() else { return }
        await uploadAndSendAudio(at: url)
    }

    private func uploadAndSendAudio(at fileURL: URL) async {
        uploading = true
        uploadError = nil
        defer { uploading = false }

        do {
            let data = try Data(contentsOf: fileURL)
            struct Up: Encodable { let kind: String; let filename: String; let mime: String; let size: Int }
            struct UpResp: Decodable { let uploadUrl: String; let fileUrl: String }
            let resp: UpResp = try await APIClient.shared.post(
                "files/upload-url",
                body: Up(kind: "message_attachment", filename: fileURL.lastPathComponent,
                         mime: "audio/m4a", size: data.count)
            )
            guard let putURL = URL(string: resp.uploadUrl) else {
                uploadError = "Некорректный uploadUrl"; return
            }
            var put = URLRequest(url: putURL)
            put.httpMethod = "PUT"
            put.setValue("audio/m4a", forHTTPHeaderField: "Content-Type")
            let (_, response) = try await URLSession.shared.upload(for: put, from: data)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                uploadError = "S3 PUT не удался (\(http.statusCode))"; return
            }

            // Отправляем сообщение в формате `__voice__{...}` (как делает web —
            // см. apps/web/src/app/(app)/chat/[chatId]/page.tsx). Бэкенд
            // (POST /messages/:id/transcribe) распознаёт ТОЛЬКО этот префикс
            // и парсит url из payload. Без него — 400 NOT_VOICE.
            let durationSec = max(0, Int(recorder.elapsed.rounded()))
            let voicePayload: [String: Any] = [
                "url": resp.fileUrl,
                "duration": durationSec,
                "mimeType": "audio/m4a",
            ]
            let voiceContent: String = {
                if let d = try? JSONSerialization.data(withJSONObject: voicePayload),
                   let s = String(data: d, encoding: .utf8) {
                    return "__voice__" + s
                }
                return resp.fileUrl
            }()
            await sendRaw(content: voiceContent, autoTranscribeFromMessageId: true)
            try? FileManager.default.removeItem(at: fileURL)
        } catch let e as APIError {
            uploadError = e.errorDescription
        } catch {
            uploadError = error.localizedDescription
        }
    }

    /// Upload selected photo to S3 (presigned), then auto-send a chat message
    /// with the image URL embedded in content. Веб точно так же отправляет
    /// картинки в чат — message содержит markdown ![](url) или просто URL,
    /// а фронт рендерит как изображение.
    private func uploadPhoto(item: PhotosPickerItem) async {
        uploading = true
        uploadError = nil
        defer {
            uploading = false
            pickerItem = nil
        }
        do {
            guard let raw = try await item.loadTransferable(type: Data.self) else {
                uploadError = "Не удалось прочитать выбранное фото"
                return
            }
            // Жмём в JPEG для предсказуемого Content-Type
            let jpegData: Data = (UIImage(data: raw)?.jpegData(compressionQuality: 0.85)) ?? raw

            struct UploadReq: Encodable {
                let kind: String
                let filename: String
                let mime: String
                let size: Int
            }
            struct UploadResp: Decodable {
                let uploadUrl: String
                let fileUrl: String
            }
            let resp: UploadResp = try await APIClient.shared.post(
                "files/upload-url",
                body: UploadReq(
                    kind: "message_attachment",
                    filename: "photo.jpg",
                    mime: "image/jpeg",
                    size: jpegData.count
                )
            )
            guard let putURL = URL(string: resp.uploadUrl) else {
                uploadError = "Некорректный uploadUrl"; return
            }
            var put = URLRequest(url: putURL)
            put.httpMethod = "PUT"
            put.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
            let (_, response) = try await URLSession.shared.upload(for: put, from: jpegData)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                uploadError = "S3 PUT не удался (\(http.statusCode))"; return
            }

            // Шлём сообщение с URL в content. На рендере бубла мы автоматически
            // распознаем image-ссылки и нарисуем картинку.
            await sendRaw(content: resp.fileUrl)
        } catch let e as APIError {
            uploadError = e.errorDescription
        } catch {
            uploadError = error.localizedDescription
        }
    }

    /// Отправить сообщение с готовым content (используется после загрузки фото / аудио).
    /// При autoTranscribeFromMessageId=true после успешной отправки запускаем
    /// POST /messages/:id/transcribe — Whisper расшифрует и закэширует transcript.
    private func sendRaw(content: String, autoTranscribeFromMessageId: Bool = false) async {
        let clientId = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())
        let optimistic = ChatMessage(
            id: clientId, chatId: chatId,
            authorId: currentUserId, content: content,
            isEdited: false, createdAt: now, updatedAt: nil, deletedAt: nil,
            replyToId: nil, replyTo: nil, author: nil,
            reactions: nil, myReactions: nil,
            parentThreadId: nil, threadMessageCount: nil, threadLastReplyAt: nil, transcript: nil
        )
        messages.append(optimistic)

        struct Body: Encodable {
            let content: String
            let clientId: String
            let scheduledAt: String?
        }
        let scheduledIso = sendScheduled
            ? ISO8601DateFormatter().string(from: scheduledAt)
            : nil
        do {
            let saved: ChatMessage = try await APIClient.shared.post(
                "chats/\(chatId)/messages",
                body: Body(content: content, clientId: clientId, scheduledAt: scheduledIso)
            )
            if let i = messages.firstIndex(where: { $0.id == clientId }) {
                messages[i] = saved
            }
            sendScheduled = false

            // Голосовое — фоном просим Whisper расшифровать
            if autoTranscribeFromMessageId {
                Task { await transcribeMessage(saved.id) }
            }
        } catch {
            failedClientIds.insert(clientId)
        }
    }

    /// POST /messages/:id/transcribe — Whisper расшифровывает голосовое.
    /// Бэкенд (apps/api/src/modules/messages/messages.controller.ts) НЕ принимает
    /// body — только messageId из URL. Контент сообщения должен быть в формате
    /// `__voice__{"url":"...","duration":N}` иначе 400 NOT_VOICE.
    private func transcribeMessage(_ messageId: String) async {
        do {
            _ = try await APIClient.shared.rawRequest("POST", "messages/\(messageId)/transcribe")
            await loadHistory()
            return
        } catch APIError.http(let status, let body) {
            if status == 404 {
                uploadError = "Расшифровка временно недоступна"
            } else if status == 400 {
                // 400 чаще всего значит NOT_VOICE — старое сообщение без обёртки __voice__.
                uploadError = body ?? "Это сообщение нельзя расшифровать (старый формат). Запишите новое голосовое."
            } else {
                uploadError = body ?? "Не удалось расшифровать (HTTP \(status))"
            }
        } catch {
            uploadError = (error as? APIError)?.errorDescription ?? "Не удалось расшифровать"
        }
    }

    // MARK: - Networking

    private func loadChat() async {
        do {
            let c: Chat = try await APIClient.shared.get("chats/\(chatId)")
            self.chat = c
        } catch {
            // не критично — оставляем initialChat
        }
    }

    private func loadHistory() async {
        loading = true
        defer { loading = false }
        do {
            let resp: MessagesResponse = try await APIClient.shared.get(
                "chats/\(chatId)/messages",
                query: ["limit": "50"]
            )
            self.messages = resp.data
            self.loadError = nil
            await markRead()
        } catch {
            self.loadError = (error as? LocalizedError)?.errorDescription ?? "Не удалось загрузить сообщения"
        }
    }

    private func markRead() async {
        guard let last = messages.last else { return }
        struct ReadBody: Encodable { let lastMessageId: String }
        do {
            _ = try await APIClient.shared.rawRequest(
                "POST",
                "chats/\(chatId)/read",
                body: ReadBody(lastMessageId: last.id)
            )
            // Дополнительно: уведомляем других через сокет (бэк отдаст user:read).
            realtime.sendRead(chatId: chatId, lastMessageId: last.id)
        } catch {
            // ignore
        }
    }

    private func send() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if let edit = editing {
            await editMessage(edit, newContent: text)
            return
        }

        let clientId = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())
        let me = currentUserId ?? ""
        let optimisticReplyTo: ReplyToMessage? = replyTo.map {
            ReplyToMessage(id: $0.id, content: $0.content ?? "", authorName: $0.author.map(displayName))
        }

        let optimistic = ChatMessage(
            id: clientId,
            chatId: chatId,
            authorId: me,
            content: text,
            isEdited: false,
            createdAt: now,
            updatedAt: nil,
            deletedAt: nil,
            replyToId: replyTo?.id,
            replyTo: optimisticReplyTo,
            author: nil,
            reactions: nil,
            myReactions: nil,
            parentThreadId: nil,
            threadMessageCount: nil,
            threadLastReplyAt: nil,
            transcript: nil
        )

        messages.append(optimistic)
        inputText = ""
        let savedReplyTo = replyTo
        replyTo = nil
        sending = true
        defer { sending = false }

        struct SendBody: Encodable {
            let content: String
            let replyToId: String?
            let clientId: String
            let scheduledAt: String?
        }
        let scheduledIso = sendScheduled
            ? ISO8601DateFormatter().string(from: scheduledAt)
            : nil

        do {
            let real: ChatMessage = try await APIClient.shared.post(
                "chats/\(chatId)/messages",
                body: SendBody(
                    content: text,
                    replyToId: savedReplyTo?.id,
                    clientId: clientId,
                    scheduledAt: scheduledIso
                )
            )
            // После успешной отправки сбросим флаг scheduled
            sendScheduled = false
            // Заменяем optimistic на реальный
            if let idx = messages.firstIndex(where: { $0.id == clientId }) {
                messages[idx] = real
            } else {
                messages.append(real)
            }
        } catch {
            failedClientIds.insert(clientId)
        }
    }

    private func editMessage(_ msg: ChatMessage, newContent: String) async {
        struct EditBody: Encodable { let content: String }
        sending = true
        defer { sending = false }
        do {
            let updated: ChatMessage = try await APIClient.shared.patch(
                "chats/\(chatId)/messages/\(msg.id)",
                body: EditBody(content: newContent)
            )
            if let idx = messages.firstIndex(where: { $0.id == msg.id }) {
                messages[idx] = updated
            }
            inputText = ""
            editing = nil
        } catch {
            // оставляем поле редактирования открытым — пользователь увидит, что ничего не отправилось
        }
    }

    /// PATCH /chats/:id/pin body { messageId } — закрепить сообщение в чате.
    private func pinMessage(_ msg: ChatMessage) async {
        struct Body: Encodable { let messageId: String? }
        do {
            _ = try await APIClient.shared.rawRequest(
                "PATCH", "chats/\(chatId)/pin", body: Body(messageId: msg.id)
            )
            await loadChat()
        } catch {
            // ignore
        }
    }

    /// PATCH /chats/:id/pin body { messageId: null } — открепить.
    private func unpinMessage() async {
        struct Body: Encodable { let messageId: String? }
        do {
            _ = try await APIClient.shared.rawRequest(
                "PATCH", "chats/\(chatId)/pin", body: Body(messageId: nil)
            )
            await loadChat()
        } catch {
            // ignore
        }
    }

    /// Карточка закреплённого сообщения (top-bar над списком).
    @ViewBuilder
    private func pinnedMessageBar(_ pinned: PinnedMessage) -> some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(Theme.accent)
                .frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 1.5))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Theme.accent)
                    Text("Закреплено · \(pinned.authorDisplayName)")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Theme.accent)
                }
                Text(pinned.content)
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                Task { await unpinMessage() }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(Theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surfaceBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 0.5)
        )
    }

    /// POST /saved-messages — добавить в сохранённые
    private func saveMessage(_ msg: ChatMessage) async {
        struct Body: Encodable { let messageId: String }
        do {
            _ = try await APIClient.shared.rawRequest(
                "POST", "saved-messages", body: Body(messageId: msg.id)
            )
        } catch {}
    }

    /// Прочитано ли сообщение msg другими участниками чата.
    /// Используем index в массиве messages: если у участника
    /// `lastReadMessageId` равен msg.id или сообщению ПОЗЖЕ него — считаем прочитанным.
    private func readState(for msg: ChatMessage) -> MessageReadState {
        guard msg.senderId == currentUserId else { return .none }
        guard let chat = chat else { return .sent }
        guard let myIdx = messages.firstIndex(where: { $0.id == msg.id }) else { return .sent }

        // Только другие участники
        let me = currentUserId ?? ""
        let others = (chat.members ?? []).filter { $0.id != me }
        if others.isEmpty { return .sent }

        // Считаем читавших — у кого lastReadMessageId находится в messages[myIdx...]
        let later = Set(messages[myIdx...].map { $0.id })
        let readers = others.filter { m in
            guard let lr = m.lastReadMessageId else { return false }
            return later.contains(lr)
        }.count

        if chat.isDirect {
            return readers >= 1 ? .readByOne : .sent
        }
        if chat.kind == "group" {
            if readers == 0 { return .sent }
            if readers == others.count { return .readByAll }
            return .partiallyRead(readers, others.count)
        }
        return .sent
    }

    private func deleteMessage(_ msg: ChatMessage) async {
        do {
            try await APIClient.shared.delete("chats/\(chatId)/messages/\(msg.id)")
            messages.removeAll { $0.id == msg.id }
        } catch {
            // ignore
        }
    }

    private func toggleReaction(_ msg: ChatMessage, emoji: String) async {
        // Бэк принимает type (см. ToggleMessageReactionDto), не сырой emoji.
        guard let type = MessageBubble.reactionType(forEmoji: emoji) else { return }
        struct ReactBody: Encodable { let type: String }
        do {
            _ = try await APIClient.shared.rawRequest(
                "POST",
                "chats/\(chatId)/messages/\(msg.id)/reactions",
                body: ReactBody(type: type)
            )
            await fetchNew()
        } catch {
            // ignore
        }
    }

    // MARK: - Polling

    private func startPolling() {
        stopPolling()
        pollCancellable = Timer.publish(every: pollInterval, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                Task { await fetchNew() }
            }
    }

    private func stopPolling() {
        pollCancellable?.cancel()
        pollCancellable = nil
    }

    private func fetchNew() async {
        do {
            let resp: MessagesResponse = try await APIClient.shared.get(
                "chats/\(chatId)/messages",
                query: ["limit": "50"]
            )
            // Сливаем: берём всё что пришло, но сохраняем optimistic-сообщения,
            // которые ещё не подтверждены/упали.
            let serverIds = Set(resp.data.map(\.id))
            let pendingLocal = messages.filter { msg in
                msg.senderId == currentUserId &&
                !serverIds.contains(msg.id) &&
                failedClientIds.contains(msg.id)
            }
            self.messages = resp.data + pendingLocal
            await markRead()
        } catch {
            // тихо игнорируем — следующий тик попробует снова
        }
    }
}

// MARK: - MessageBubble

enum MessageReadState {
    case none           // не моё сообщение
    case sending        // отправляется
    case sent           // отправлено, никто ещё не прочитал
    case readByOne      // прочитано хотя бы одним собеседником (private 1-1)
    case readByAll      // в группе все прочитали
    case partiallyRead(Int, Int)  // в группе X из N прочитали (исключая меня)
}

private struct MessageBubble: View {
    let message: ChatMessage
    let isMine: Bool
    let isGroup: Bool
    let failed: Bool
    var currentUserId: String? = nil

    /// URL картинки, открытой на полный экран (фуллскрин-вьюер).
    @State var fullscreenImage: URL? = nil
    var readState: MessageReadState = .none
    /// Показывать ли «голову» (имя + аватар) — true для первого сообщения в группе подряд.
    var showAuthorHead: Bool = true
    let onReply: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void
    let onEdit: () -> Void
    let onReact: (String) -> Void
    var onOpenThread: (() -> Void)? = nil
    /// Открыть sheet выбора чата для пересылки.
    var onForward: (() -> Void)? = nil
    /// Закрепить это сообщение в чате (PATCH /chats/:id/pin).
    var onPin: (() -> Void)? = nil
    /// Открепить (когда это и есть pinned).
    var onUnpin: (() -> Void)? = nil
    /// Является ли это сообщение закреплённым в чате.
    var isPinned: Bool = false
    /// Ручной запрос на расшифровку голосового. Получает messageId.
    var onTranscribe: ((String) -> Void)? = nil

    /// Бэкенд принимает только фиксированный список типов
    /// (см. apps/api/src/modules/messages/dto/message.dto.ts → REACTION_TYPES).
    /// В UI рисуем эмодзи, на сервер шлём короткий type.
    private static let reactionTypes: [(type: String, emoji: String)] = [
        ("like",      "👍"),
        ("fire",      "🔥"),
        ("heart",     "❤️"),
        ("star",      "⭐"),
        ("important", "❗"),
    ]
    /// Эмодзи по типу (для отображения reactions, которые приходят с сервера как type:count).
    static func emoji(forReactionType type: String) -> String {
        reactionTypes.first(where: { $0.type == type })?.emoji ?? type
    }
    /// Тип по эмодзи (если из UI пришёл эмодзи, отправляем нужный type на бэк).
    static func reactionType(forEmoji emoji: String) -> String? {
        reactionTypes.first(where: { $0.emoji == emoji })?.type
    }

    /// Русское склонение «ответ / ответа / ответов».
    fileprivate func threadCountSuffix(_ n: Int) -> String {
        let mod10 = n % 10
        let mod100 = n % 100
        if mod100 >= 11 && mod100 <= 14 { return "ов" }
        if mod10 == 1 { return "" }
        if mod10 >= 2 && mod10 <= 4 { return "а" }
        return "ов"
    }

    /// Если content — это URL/путь на картинку (jpg/jpeg/png/webp/gif/heic), возвращаем URL.
    /// Иначе nil — рендерим как текст.
    /// Поддерживаем как абсолютные `https://…`, так и серверные пути `/uploads/…`,
    /// `uploads/…`, `media/…` — всё прогоняем через ensureAbsolute.
    static func detectImageURL(in content: String?) -> URL? {
        guard let raw = content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, !raw.contains(" ") else { return nil }
        let lower = raw.lowercased()
        let imageExt = [".jpg", ".jpeg", ".png", ".webp", ".gif", ".heic"]
        let isImage = imageExt.contains { lower.hasSuffix($0) || lower.contains($0 + "?") }
        guard isImage else { return nil }
        // Принимаем http(s), абсолютные «/...» и относительные «uploads/...».
        let looksLikePath = raw.hasPrefix("http")
            || raw.hasPrefix("/")
            || raw.hasPrefix("uploads/")
            || raw.hasPrefix("media/")
            || raw.hasPrefix("static/")
        guard looksLikePath else { return nil }
        return URL(string: ensureAbsolute(raw))
    }

    /// Видео-контент по расширению. Использует те же правила, что и detectImageURL.
    static func detectVideoURL(in content: String?) -> URL? {
        guard let raw = content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, !raw.contains(" ") else { return nil }
        let lower = raw.lowercased()
        let videoExt = [".mp4", ".mov", ".m4v", ".webm"]
        let isVideo = videoExt.contains { lower.hasSuffix($0) || lower.contains($0 + "?") }
        guard isVideo else { return nil }
        let looksLikePath = raw.hasPrefix("http")
            || raw.hasPrefix("/")
            || raw.hasPrefix("uploads/")
            || raw.hasPrefix("media/")
            || raw.hasPrefix("static/")
        guard looksLikePath else { return nil }
        return URL(string: ensureAbsolute(raw))
    }

    /// Сообщение содержит маркер опроса 📊 (плюс question)
    /// или web-обёртку `__poll__{...}`.
    static func isPoll(content: String?) -> Bool {
        guard let s = content?.trimmingCharacters(in: .whitespaces) else { return false }
        return s.hasPrefix("📊") || s.hasPrefix("__poll__")
    }

    /// Если контент — `__poll__{"pollId":"...","question":"..."}` — вернёт pollId.
    static func parsePollPayload(_ content: String?) -> (pollId: String, question: String)? {
        guard let s = content, s.hasPrefix("__poll__") else { return nil }
        let payload = String(s.dropFirst("__poll__".count))
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = json["pollId"] as? String else { return nil }
        return (pid, (json["question"] as? String) ?? "")
    }

    /// Разбирает web-обёртку форварда:
    ///   `__forward__{"fromName":"X","fromId":"uuid"}||<original>`
    /// Возвращает имя автора и оригинальный контент. См.
    /// apps/web/src/app/(app)/chat/[chatId]/page.tsx (parseForward).
    static func parseForward(_ content: String?) -> (fromName: String, fromId: String, inner: String)? {
        guard let s = content, s.hasPrefix("__forward__") else { return nil }
        let after = String(s.dropFirst("__forward__".count))
        guard let sepRange = after.range(of: "||") else { return nil }
        let metaStr = String(after[..<sepRange.lowerBound])
        let inner = String(after[sepRange.upperBound...])
        guard let data = metaStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return (
            fromName: (json["fromName"] as? String) ?? "",
            fromId: (json["fromId"] as? String) ?? "",
            inner: inner
        )
    }

    /// Обёртка форварда для отправки (зеркало wrapForward в web).
    static func wrapForward(fromName: String, fromId: String, original: String) -> String {
        let meta: [String: Any] = ["fromName": fromName, "fromId": fromId]
        let metaStr: String
        if let data = try? JSONSerialization.data(withJSONObject: meta),
           let s = String(data: data, encoding: .utf8) {
            metaStr = s
        } else {
            metaStr = "{}"
        }
        return "__forward__\(metaStr)||\(original)"
    }

    /// Разбирает web-формат голосового: `__voice__{"url":"…","duration":N,"mimeType":"…"}`
    static func parseVoicePayload(_ content: String?) -> URL? {
        guard let s = content, s.hasPrefix("__voice__") else { return nil }
        let payload = String(s.dropFirst("__voice__".count))
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlStr = json["url"] as? String else { return nil }
        return URL(string: ensureAbsolute(urlStr))
    }

    /// Парсит web-обёртки `__image__`/`__video__`/`__file__`/`__call__`.
    /// Web (apps/web/src/app/(app)/chat/[chatId]/page.tsx parseMsg/parseCallSys)
    /// шлёт медиа из браузера именно так — без этих парсеров iOS показывал бы
    /// сырой JSON-маркер в чате.
    struct MediaPayload {
        let url: URL
        let name: String?
    }
    struct FilePayload {
        let url: URL
        let name: String
        let size: Int?
    }
    struct CallPayload {
        let callId: String
        let callType: String   // "audio" | "video"
        let status: String     // "ended" | "missed"
        let duration: Int
        let callerId: String
    }

    static func parseImagePayload(_ content: String?) -> MediaPayload? {
        return parseMediaPayload(content, prefix: "__image__")
    }
    static func parseVideoPayload(_ content: String?) -> MediaPayload? {
        return parseMediaPayload(content, prefix: "__video__")
    }
    static func parseFilePayload(_ content: String?) -> FilePayload? {
        guard let s = content, s.hasPrefix("__file__") else { return nil }
        let payload = String(s.dropFirst("__file__".count))
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlStr = json["url"] as? String,
              let url = URL(string: ensureAbsolute(urlStr)) else { return nil }
        return FilePayload(
            url: url,
            name: (json["name"] as? String) ?? "Файл",
            size: (json["size"] as? Int) ?? (json["size"] as? Double).map(Int.init)
        )
    }
    static func parseCallPayload(_ content: String?) -> CallPayload? {
        guard let s = content, s.hasPrefix("__call__") else { return nil }
        let payload = String(s.dropFirst("__call__".count))
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return CallPayload(
            callId: (json["callId"] as? String) ?? "",
            callType: (json["callType"] as? String) ?? "audio",
            status: (json["status"] as? String) ?? "ended",
            duration: (json["duration"] as? Int) ?? Int((json["duration"] as? Double) ?? 0),
            callerId: (json["callerId"] as? String) ?? ""
        )
    }

    private static func parseMediaPayload(_ content: String?, prefix: String) -> MediaPayload? {
        guard let s = content, s.hasPrefix(prefix) else { return nil }
        let payload = String(s.dropFirst(prefix.count))
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlStr = json["url"] as? String,
              let url = URL(string: ensureAbsolute(urlStr)) else { return nil }
        return MediaPayload(url: url, name: json["name"] as? String)
    }

    /// Если content — URL на аудио (m4a/mp3/aac/ogg/wav), возвращаем URL.
    static func detectAudioURL(in content: String?) -> URL? {
        guard let raw = content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, !raw.contains(" ") else { return nil }
        let lower = raw.lowercased()
        let audioExt = [".m4a", ".mp3", ".aac", ".ogg", ".wav"]
        let isAudio = audioExt.contains { lower.hasSuffix($0) || lower.contains($0 + "?") }
        guard isAudio else { return nil }
        let looksLikePath = raw.hasPrefix("http")
            || raw.hasPrefix("/")
            || raw.hasPrefix("uploads/")
            || raw.hasPrefix("media/")
            || raw.hasPrefix("static/")
        guard looksLikePath else { return nil }
        return URL(string: ensureAbsolute(raw))
    }

    private var timeText: String {
        if let d = parseChatDate(message.createdAt) {
            return relativeTime(from: d)
        }
        return ""
    }

    var body: some View {
        // Системное сообщение о звонке — рендерим центральную «таблетку»
        // вместо обычного бабла (как делает web).
        if let call = MessageBubble.parseCallPayload(message.content) {
            CallSysPill(call: call, time: timeText, currentUserId: currentUserId)
                .frame(maxWidth: .infinity)
        } else {
            normalBubble
        }
    }

    @ViewBuilder
    private var normalBubble: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isMine { Spacer(minLength: 40) }

            // Слот под аватарку слева для group/non-mine: всегда зарезервирован,
            // но рисуем только при showAuthorHead — чтобы серии сообщений
            // от одного автора визуально слипались (как в Telegram).
            if isGroup, !isMine {
                if showAuthorHead, let author = message.author {
                    AvatarCircle(url: author.avatarUrl, name: displayName(for: author))
                        .frame(width: 28, height: 28)
                } else {
                    Color.clear.frame(width: 28, height: 28)
                }
            }

            VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
                if isGroup, !isMine, showAuthorHead, let author = message.author {
                    Text(displayName(for: author))
                        .font(.dsCaption.weight(.semibold))
                        .foregroundColor(Theme.accent)
                        .padding(.horizontal, 12)
                }

                bubble

                if !message.reactionsList.isEmpty {
                    reactionsRow(message.reactionsList)
                        .padding(.horizontal, 4)
                }

                if message.hasThread, let openThread = onOpenThread {
                    Button(action: openThread) {
                        HStack(spacing: 4) {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                                .font(.caption2)
                            Text("\(message.threadMessageCount ?? 0) ответ\(threadCountSuffix(message.threadMessageCount ?? 0))")
                                .font(.caption.weight(.medium))
                            Image(systemName: "chevron.right").font(.caption2)
                        }
                        .foregroundColor(Theme.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Theme.accent.opacity(0.10))
                        .clipShape(Capsule())
                    }
                    .padding(.horizontal, 4)
                }

                HStack(spacing: 4) {
                    if failed {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundColor(Theme.danger)
                            .font(.caption2)
                        Text("не отправлено")
                            .font(.caption2)
                            .foregroundColor(Theme.danger)
                    } else {
                        Text(timeText)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        if message.isEdited == true {
                            Text("· ред.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        if isMine {
                            readIndicator
                        }
                    }
                }
                .padding(.horizontal, 8)
            }

            if !isMine { Spacer(minLength: 40) }
        }
        .fullScreenCover(item: Binding(
            get: { fullscreenImage.map { ImageURLBox(url: $0) } },
            set: { fullscreenImage = $0?.url }
        )) { box in
            FullscreenImageView(url: box.url) { fullscreenImage = nil }
        }
    }

    @ViewBuilder
    private func webImageBubble(_ img: MessageBubble.MediaPayload) -> some View {
        Button {
            fullscreenImage = img.url
        } label: {
            AsyncImage(url: img.url) { phase in
                switch phase {
                case .empty:
                    Color.secondary.opacity(0.1).frame(height: 200)
                case .success(let image):
                    image.resizable().scaledToFit()
                case .failure:
                    ZStack {
                        Color.secondary.opacity(0.1)
                        VStack(spacing: 6) {
                            Image(systemName: "photo")
                                .foregroundColor(.secondary)
                            Text(img.name ?? "Изображение")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(height: 160)
                @unknown default:
                    Color.secondary.opacity(0.1).frame(height: 160)
                }
            }
            .frame(maxWidth: 260)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func webFileBubble(_ f: MessageBubble.FilePayload) -> some View {
        Link(destination: f.url) {
            HStack(spacing: 10) {
                Image(systemName: "doc.fill")
                    .font(.title2)
                    .foregroundColor(isMine ? .white : Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.name)
                        .font(.dsBody.weight(.semibold))
                        .foregroundColor(isMine ? .white : Theme.textPrimary)
                        .lineLimit(1)
                    if let size = f.size {
                        Text(formatBytes(size))
                            .font(.caption)
                            .foregroundColor(isMine ? .white.opacity(0.8) : Theme.textTertiary)
                    }
                }
                Spacer()
                Image(systemName: "arrow.down.circle")
                    .foregroundColor(isMine ? .white.opacity(0.85) : Theme.accent)
            }
            .padding(.vertical, 4)
            .frame(minWidth: 200)
        }
    }

    private func formatBytes(_ b: Int) -> String {
        if b < 1024 { return "\(b) Б" }
        if b < 1024 * 1024 { return String(format: "%.1f КБ", Double(b) / 1024) }
        return String(format: "%.1f МБ", Double(b) / 1024 / 1024)
    }

    @ViewBuilder
    private var pollPreview: some View {
        let raw = message.content ?? ""
        let question = raw.replacingOccurrences(of: "📊", with: "")
            .trimmingCharacters(in: .whitespaces)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.xaxis")
                Text("ОПРОС").font(.caption2.weight(.bold)).tracking(1.5)
            }
            .foregroundColor(isMine ? .white.opacity(0.85) : Theme.accent)

            Text(question)
                .font(.body)
                .foregroundColor(isMine ? .white : Theme.textPrimary)

            Link(destination: URL(string: "https://rossihelp.ru/chat")!) {
                HStack {
                    Text("Голосовать на сайте")
                        .font(.caption.weight(.semibold))
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption2)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isMine ? Color.white.opacity(0.2) : Theme.accent.opacity(0.12))
                .foregroundColor(isMine ? .white : Theme.accent)
                .clipShape(Capsule())
            }
        }
    }

    @ViewBuilder
    private var readIndicator: some View {
        switch readState {
        case .none, .sending:
            EmptyView()
        case .sent:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Theme.textTertiary)
        case .readByOne, .readByAll:
            HStack(spacing: -3) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundColor(Theme.accent)
        case .partiallyRead(let read, let total):
            Text("✓ \(read)/\(total)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.textTertiary)
        }
    }

    private var bubble: some View {
        // Если сообщение — форвард, разворачиваем обёртку и показываем
        // оригинальный контент с серой полосой слева + лейблом.
        let forward = MessageBubble.parseForward(message.content)
        let effectiveContent = forward?.inner ?? message.content
        return VStack(alignment: .leading, spacing: 6) {
            if let f = forward {
                forwardHeader(fromName: f.fromName)
            }
            if let reply = message.replyTo {
                replyQuote(reply)
            }
            // Опрос. Web-формат `__poll__{...}` — pollId внутри.
            // Legacy `📊 question` — pollId находим по messageId на бэке
            // (см. /polls/by-message/:messageId).
            if let p = MessageBubble.parsePollPayload(effectiveContent) {
                PollBubble(pollId: p.pollId,
                           messageId: nil,
                           initialQuestion: p.question,
                           isMine: isMine)
            } else if MessageBubble.isPoll(content: effectiveContent) {
                let q = (effectiveContent ?? "")
                    .replacingOccurrences(of: "📊", with: "")
                    .trimmingCharacters(in: .whitespaces)
                PollBubble(pollId: nil,
                           messageId: message.id,
                           initialQuestion: q,
                           isMine: isMine)
            }
            // Web-обёртка `__image__{...}` — рендерим картинку.
            else if let img = MessageBubble.parseImagePayload(effectiveContent) {
                webImageBubble(img)
            }
            // Web-обёртка `__video__{...}` — нативный плеер.
            else if let vid = MessageBubble.parseVideoPayload(effectiveContent) {
                VideoPlayer(player: AVPlayer(url: vid.url))
                    .frame(maxWidth: 260, minHeight: 160, maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            // Web-обёртка `__file__{...}` — карточка файла.
            else if let f = MessageBubble.parseFilePayload(effectiveContent) {
                webFileBubble(f)
            }
            // Голосовое из __voice__{...} (web-формат) — извлекаем url.
            else if let voice = MessageBubble.parseVoicePayload(effectiveContent) {
                VoiceBubbleContent(
                    url: voice,
                    isMine: isMine,
                    transcript: message.transcript,
                    messageId: message.id,
                    onTranscribe: onTranscribe
                )
            }
            // Аудио (голосовое) — плеер + транскрипт + кнопка ручной расшифровки
            else if let audioURL = MessageBubble.detectAudioURL(in: effectiveContent) {
                VoiceBubbleContent(
                    url: audioURL,
                    isMine: isMine,
                    transcript: message.transcript,
                    messageId: message.id,
                    onTranscribe: onTranscribe
                )
            }
            // Видео — нативный AVKit-плеер.
            else if let videoURL = MessageBubble.detectVideoURL(in: effectiveContent) {
                VideoPlayer(player: AVPlayer(url: videoURL))
                    .frame(maxWidth: 260, minHeight: 160, maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            // Если контент сообщения — это URL картинки (присланной через
            // PhotosPicker → /files/upload-url → отправлено как URL в content),
            // рендерим её inline. Иначе — обычный текст.
            else if let imageURL = MessageBubble.detectImageURL(in: effectiveContent) {
                Button {
                    fullscreenImage = imageURL
                } label: {
                    AsyncImage(url: imageURL) { phase in
                        switch phase {
                        case .empty:
                            Color.secondary.opacity(0.1).frame(height: 200)
                        case .success(let img):
                            img.resizable().scaledToFit()
                        case .failure:
                            Text(effectiveContent ?? "")
                                .font(.dsBodyLG)
                                .foregroundColor(isMine ? .white : Theme.textPrimary)
                        @unknown default:
                            Text(effectiveContent ?? "")
                        }
                    }
                    .frame(maxWidth: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            } else {
                Text(effectiveContent ?? "")
                    .font(.dsBodyLG)
                    .foregroundColor(isMine ? .white : Theme.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            Group {
                if isMine {
                    LinearGradient(
                        colors: [Theme.accent, Theme.accentHover],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                } else {
                    Theme.surfaceBackground
                }
            }
        )
        .clipShape(ChatBubbleShape(isMine: isMine))
        .overlay(
            ChatBubbleShape(isMine: isMine)
                .stroke(isMine ? Color.clear : Theme.border, lineWidth: 0.5)
        )
        .contextMenu {
            Button {
                onReply()
            } label: {
                Label("Ответить", systemImage: "arrowshape.turn.up.left")
            }
            if let fwd = onForward {
                Button {
                    fwd()
                } label: {
                    Label("Переслать", systemImage: "arrowshape.turn.up.right")
                }
            }
            Menu {
                ForEach(Self.reactionTypes, id: \.type) { item in
                    Button(item.emoji) { onReact(item.emoji) }
                }
            } label: {
                Label("Реакция", systemImage: "face.smiling")
            }
            Button {
                onCopy()
            } label: {
                Label("Скопировать", systemImage: "doc.on.doc")
            }
            // Pin/unpin сообщения в чате (см. PATCH /chats/:id/pin)
            if isPinned, let unpin = onUnpin {
                Button {
                    unpin()
                } label: {
                    Label("Открепить", systemImage: "pin.slash")
                }
            } else if let pin = onPin {
                Button {
                    pin()
                } label: {
                    Label("Закрепить", systemImage: "pin")
                }
            }
            if isMine {
                Button {
                    onEdit()
                } label: {
                    Label("Редактировать", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Удалить", systemImage: "trash")
                }
            }
        }
    }

    /// Карточка-«шапка» переслан-сообщения. Серая полоса слева + лейбл «Переслано от …».
    private func forwardHeader(fromName: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrowshape.turn.up.right.fill")
                .font(.system(size: 10, weight: .semibold))
            Text("Переслано от \(fromName.isEmpty ? "неизвестного" : fromName)")
                .font(.system(size: 11, weight: .semibold))
            Spacer(minLength: 0)
        }
        .foregroundColor(isMine ? .white.opacity(0.85) : Theme.accent)
        .padding(.bottom, 4)
        .overlay(
            Rectangle()
                .fill(isMine ? Color.white.opacity(0.25) : Theme.accent.opacity(0.25))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    private func replyQuote(_ reply: ReplyToMessage) -> some View {
        // Тугая компактная цитата: однострочный текст, минимальный паддинг,
        // ширина по содержимому. Раньше блок раздувался до полной ширины
        // бабла из-за Spacer'а — теперь сжимается под контент.
        HStack(alignment: .center, spacing: 6) {
            Rectangle()
                .fill(isMine ? Color.white.opacity(0.85) : Theme.accent)
                .frame(width: 2)
                .clipShape(RoundedRectangle(cornerRadius: 1))
            VStack(alignment: .leading, spacing: 0) {
                Text(reply.authorName ?? "Сообщение")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(isMine ? .white.opacity(0.95) : Theme.accent)
                    .lineLimit(1)
                Text(reply.content)
                    .font(.system(size: 11))
                    .foregroundColor(isMine ? .white.opacity(0.85) : Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: 200, alignment: .leading)
        }
        .fixedSize(horizontal: true, vertical: true)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isMine ? Color.white.opacity(0.18) : Theme.accent.opacity(0.08))
        )
    }

    private func reactionsRow(_ reactions: [MessageReaction]) -> some View {
        HStack(spacing: 4) {
            ForEach(reactions, id: \.emoji) { r in
                Button {
                    // r.emoji здесь — это TYPE с бэка (like/fire/...). Передаём emoji в onReact:
                    onReact(MessageBubble.emoji(forReactionType: r.emoji))
                } label: {
                    HStack(spacing: 4) {
                        Text(MessageBubble.emoji(forReactionType: r.emoji))
                            .font(.system(size: 13))
                        if r.count > 1 {
                            Text("\(r.count)")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(r.myReacted == true
                                  ? Theme.accent.opacity(0.15)
                                  : Theme.surfaceBackground)
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            r.myReacted == true ? Theme.accent : Theme.border,
                            lineWidth: 0.5
                        )
                    )
                    .foregroundColor(Theme.textPrimary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - ParticipantsSheet

struct ParticipantsSheet: View {
    let chat: Chat

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(chat.members ?? []) { member in
                        HStack(spacing: 12) {
                            AvatarCircle(url: member.avatarUrl, name: displayName(for: member))
                                .frame(width: 40, height: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(displayName(for: member))
                                    .font(.body.weight(.medium))
                                if let u = member.username, !u.isEmpty {
                                    Text("@" + u)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            if member.isOnline == true {
                                Circle()
                                    .fill(Theme.success)
                                    .frame(width: 8, height: 8)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Участники (\(chat.members?.count ?? 0))")
                }
            }
            .navigationTitle(chat.title?.ifEmpty(or: "Группа") ?? "Группа")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                        .tint(Theme.accent)
                }
            }
        }
    }
}

// MARK: - ForwardChatPickerSheet
//
// Sheet «Куда переслать?» — список чатов из /chats + поиск.
// При выборе шлём POST /chats/<targetId>/messages с обёрткой
// __forward__{...}||<original>, как делает web (apps/web/src/app/(app)/chat).
//
struct ForwardChatPickerSheet: View {
    let message: ChatMessage
    let onForwarded: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var auth: AuthStore

    @State private var chats: [Chat] = []
    @State private var loading = true
    @State private var search = ""
    @State private var sending = false
    @State private var error: String?

    private var filtered: [Chat] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return chats }
        return chats.filter { c in
            chatTitle(c, currentUserId: auth.currentUser?.id).lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading && chats.isEmpty {
                    ProgressView().tint(Theme.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filtered.isEmpty {
                    EmptyStateView(
                        icon: "bubble.left",
                        title: "Чатов не найдено",
                        description: error ?? "Попробуйте уточнить запрос"
                    )
                } else {
                    List {
                        ForEach(filtered) { c in
                            Button {
                                Task { await forward(to: c) }
                            } label: {
                                HStack(spacing: 12) {
                                    avatarFor(c)
                                        .frame(width: 40, height: 40)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(chatTitle(c, currentUserId: auth.currentUser?.id))
                                            .font(.body.weight(.medium))
                                            .foregroundColor(Theme.textPrimary)
                                            .lineLimit(1)
                                        Text(c.kind == "group" ? "Группа" : "Личный чат")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Переслать")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Поиск чата")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                        .disabled(sending)
                }
                ToolbarItem(placement: .principal) {
                    if sending {
                        ProgressView().tint(Theme.accent)
                    }
                }
            }
            .background(Theme.pageBackground.ignoresSafeArea())
            .task { await load() }
        }
    }

    @ViewBuilder
    private func avatarFor(_ c: Chat) -> some View {
        if c.isSelf {
            ZStack {
                Circle().fill(Theme.accent.opacity(0.15))
                Image(systemName: "bookmark.fill")
                    .foregroundColor(Theme.accent)
                    .font(.system(size: 16, weight: .semibold))
            }
        } else if c.kind == "group" {
            if let url = c.avatarUrl, !url.isEmpty {
                AvatarCircle(url: url, name: c.title ?? "Группа")
            } else if let mems = c.members, !mems.isEmpty {
                let me = auth.currentUser?.id
                let visible = mems.filter { $0.id != me }
                GroupAvatarStack(members: visible.isEmpty ? mems : visible, size: 40)
            } else {
                ZStack {
                    LinearGradient(colors: [Theme.purple, Theme.pink],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "person.3.fill").foregroundColor(.white)
                }
                .clipShape(Circle())
            }
        } else {
            let cp = chatCounterpart(c, currentUserId: auth.currentUser?.id)
            AvatarCircle(url: cp?.avatarUrl ?? c.avatarUrl,
                         name: chatTitle(c, currentUserId: auth.currentUser?.id))
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            async let listTask: ChatsListResponse = APIClient.shared.get("chats")
            async let selfTask: Chat? = {
                do {
                    let c: Chat = try await APIClient.shared.get("chats/self")
                    return c
                } catch {
                    return nil
                }
            }()
            let resp = try await listTask
            let s = await selfTask
            var merged = resp.data
            if let s = s, !merged.contains(where: { $0.id == s.id }) {
                merged.insert(s, at: 0)
            }
            self.chats = merged
            self.error = nil
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? "Не удалось загрузить чаты"
        }
    }

    /// Шлём в targetChat сообщение с обёрткой __forward__{...}||<original>.
    /// Если сообщение уже было форвардом — снимаем обёртку и сохраняем
    /// оригинального автора (как делает web).
    private func forward(to targetChat: Chat) async {
        sending = true
        defer { sending = false }

        // Снимаем существующий форвард если есть.
        let existing = MessageBubble.parseForward(message.content)
        let originalContent = existing?.inner ?? (message.content ?? "")
        let originalAuthorName: String = {
            if let e = existing, !e.fromName.isEmpty { return e.fromName }
            if let a = message.author { return displayName(for: a) }
            return "неизвестного"
        }()
        let originalAuthorId: String = {
            if let e = existing, !e.fromId.isEmpty { return e.fromId }
            return message.author?.id ?? message.authorId ?? ""
        }()
        let wrapped = MessageBubble.wrapForward(
            fromName: originalAuthorName,
            fromId: originalAuthorId,
            original: originalContent
        )

        struct Body: Encodable {
            let content: String
            let clientId: String
        }
        do {
            _ = try await APIClient.shared.rawRequest(
                "POST",
                "chats/\(targetChat.id)/messages",
                body: Body(content: wrapped, clientId: UUID().uuidString)
            )
            onForwarded()
            dismiss()
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? "Не удалось переслать"
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack { ChatsListView() }
        .environmentObject(AuthStore())
}

// MARK: - Fullscreen image viewer (тап по картинке в чате).

private struct ImageURLBox: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct FullscreenImageView: View {
    let url: URL
    let onClose: () -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var dragOffsetForDismiss: CGFloat = 0

    var body: some View {
        ZStack {
            // Фон чёрный, на весь экран
            Color.black.ignoresSafeArea()

            // Картинка по центру с pinch/pan/double-tap зумом
            GeometryReader { geo in
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFit()
                    case .empty:
                        ProgressView().tint(.white)
                    case .failure:
                        Image(systemName: "photo.badge.exclamationmark")
                            .foregroundColor(.white.opacity(0.6))
                            .font(.system(size: 60))
                    @unknown default:
                        EmptyView()
                    }
                }
                // Полностью занимает геометрию, scaledToFit центрирует
                // картинку в этом фрейме.
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(scale)
                .offset(x: offset.width, y: offset.height + dragOffsetForDismiss)
                .gesture(
                    SimultaneousGesture(
                        // Pinch-zoom
                        MagnificationGesture()
                            .onChanged { v in
                                scale = max(1, min(5, lastScale * v))
                            }
                            .onEnded { _ in
                                lastScale = scale
                                if scale <= 1 {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                        offset = .zero
                                        lastOffset = .zero
                                    }
                                }
                            },
                        // Drag — pan когда zoomed; swipe-down to dismiss когда не zoomed
                        DragGesture()
                            .onChanged { v in
                                if scale > 1 {
                                    offset = CGSize(
                                        width: lastOffset.width + v.translation.width,
                                        height: lastOffset.height + v.translation.height
                                    )
                                } else {
                                    // Swipe down to close
                                    dragOffsetForDismiss = max(0, v.translation.height)
                                }
                            }
                            .onEnded { v in
                                if scale > 1 {
                                    lastOffset = offset
                                } else {
                                    if v.translation.height > 100 {
                                        onClose()
                                    } else {
                                        withAnimation(.spring()) { dragOffsetForDismiss = 0 }
                                    }
                                }
                            }
                    )
                )
                .onTapGesture(count: 2) {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        if scale > 1 {
                            scale = 1; lastScale = 1
                            offset = .zero; lastOffset = .zero
                        } else {
                            scale = 2.5; lastScale = 2.5
                        }
                    }
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .padding(10)
                    .background(Circle().fill(Color.black.opacity(0.55)))
            }
            .padding(.top, 12)
            .padding(.trailing, 14)
        }
        .statusBarHidden(true)
    }
}

// MARK: - PollBubble — интерактивный виджет голосования по `__poll__{json}`.
//        Зеркалит web (apps/web/src/components/chat/PollWidget.tsx).

private struct PollData: Decodable {
    let id: String
    let question: String
    let options: [String]
    let counts: [Int]
    let totalVotes: Int
    let myVotes: [Int]
    let allowMulti: Bool?
    let isAnonymous: Bool?
    let closedAt: String?
}

private struct PollBubble: View {
    /// Прямой pollId (web-формат `__poll__{pollId}`).
    let pollId: String?
    /// Альтернативно: messageId — для legacy `📊 question`, где pollId
    /// не вшит. Тогда фетч идёт через GET /polls/by-message/:messageId.
    let messageId: String?
    let initialQuestion: String
    let isMine: Bool

    @State private var poll: PollData?
    @State private var voting = false
    @State private var error: String?

    private var canVote: Bool {
        poll?.closedAt == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.xaxis")
                Text("ОПРОС").font(.caption2.weight(.bold)).tracking(1.5)
                if poll?.closedAt != nil {
                    Text("· закрыт").font(.caption2)
                }
            }
            .foregroundColor(isMine ? .white.opacity(0.85) : Theme.accent)

            Text(poll?.question ?? initialQuestion)
                .font(.body.weight(.semibold))
                .foregroundColor(isMine ? .white : Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if let p = poll {
                ForEach(Array(p.options.enumerated()), id: \.offset) { (idx, opt) in
                    optionRow(idx: idx, label: opt, poll: p)
                }
                Text("\(p.totalVotes) " + plural(p.totalVotes, ["голос","голоса","голосов"]))
                    .font(.caption2)
                    .foregroundColor(isMine ? .white.opacity(0.7) : Theme.textTertiary)
            } else if let err = error {
                Text(err).font(.caption).foregroundColor(Theme.danger)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(minWidth: 200)
        .task { await load() }
    }

    @ViewBuilder
    private func optionRow(idx: Int, label: String, poll: PollData) -> some View {
        let count = poll.counts.indices.contains(idx) ? poll.counts[idx] : 0
        let percent: Double = poll.totalVotes > 0 ? Double(count) / Double(poll.totalVotes) : 0
        let voted = poll.myVotes.contains(idx)
        Button {
            Task { await vote(option: idx) }
        } label: {
            ZStack(alignment: .leading) {
                // Прогресс-фон
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isMine ? Color.white.opacity(0.18) : Theme.accent.opacity(0.12))
                        .frame(width: max(8, geo.size.width * percent))
                }
                .allowsHitTesting(false)

                HStack(spacing: 8) {
                    Image(systemName: voted ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(voted ? Theme.accent : (isMine ? .white.opacity(0.85) : Theme.textTertiary))
                        .font(.system(size: 14))
                    Text(label)
                        .font(.caption)
                        .foregroundColor(isMine ? .white : Theme.textPrimary)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Text("\(count)")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(isMine ? .white.opacity(0.85) : Theme.textSecondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .frame(minHeight: 30)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isMine ? Color.white.opacity(0.25) : Theme.border, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(voting || !canVote)
    }

    private func plural(_ n: Int, _ forms: [String]) -> String {
        let mod10 = n % 10, mod100 = n % 100
        if mod100 >= 11, mod100 <= 14 { return forms[2] }
        if mod10 == 1 { return forms[0] }
        if (2...4).contains(mod10) { return forms[1] }
        return forms[2]
    }

    private func load() async {
        do {
            if let pid = pollId {
                self.poll = try await APIClient.shared.get("polls/\(pid)")
            } else if let mid = messageId {
                self.poll = try await APIClient.shared.get("polls/by-message/\(mid)")
            }
            self.error = nil
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private struct VoteBody: Encodable { let options: [Int] }

    private func vote(option: Int) async {
        guard let p = poll, !voting, canVote else { return }
        let pid = p.id
        voting = true
        defer { voting = false }
        // Если уже проголосован за этот вариант и не allowMulti — ничего не делаем.
        var newOptions: [Int]
        if p.allowMulti == true {
            if p.myVotes.contains(option) {
                newOptions = p.myVotes.filter { $0 != option }
            } else {
                newOptions = p.myVotes + [option]
            }
        } else {
            newOptions = [option]
        }
        do {
            self.poll = try await APIClient.shared.post(
                "polls/\(pid)/vote",
                body: VoteBody(options: newOptions)
            )
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}

// MARK: - CallSysPill — централизованная «таблетка» для системных сообщений
//        о звонках (web шлёт их как `__call__{json}`, см. parseCallPayload).

private struct CallSysPill: View {
    let call: MessageBubble.CallPayload
    let time: String
    let currentUserId: String?

    private var isMissed: Bool { call.status == "missed" }
    private var iAmCaller: Bool {
        guard let me = currentUserId else { return false }
        return call.callerId == me
    }

    private var icon: String {
        if call.callType == "video" { return "video.fill" }
        return isMissed ? "phone.down.fill" : "phone.fill"
    }

    private var label: String {
        if isMissed {
            return iAmCaller ? "Вы отменили вызов" : "Пропущенный вызов"
        }
        let kind = call.callType == "video" ? "Видеозвонок" : "Звонок"
        return "\(kind) · \(formatDuration(call.duration))"
    }

    private var tint: Color { isMissed ? Theme.danger : Theme.accent }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(label)
                .font(.caption.weight(.medium))
            if !time.isEmpty {
                Text("· \(time)")
                    .font(.caption)
                    .foregroundColor(Theme.textTertiary)
            }
        }
        .foregroundColor(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(tint.opacity(0.12))
        .overlay(Capsule().strokeBorder(tint.opacity(0.3), lineWidth: 0.5))
        .clipShape(Capsule())
    }

    private func formatDuration(_ sec: Int) -> String {
        let m = sec / 60
        let s = sec % 60
        return "\(m):\(String(format: "%02d", s))"
    }
}

// MARK: - ChatBubbleShape (asymmetric corners для tail-эффекта)

private struct ChatBubbleShape: Shape {
    let isMine: Bool

    func path(in rect: CGRect) -> Path {
        let big: CGFloat = 18
        let small: CGFloat = 4
        let tl: CGFloat = big
        let tr: CGFloat = big
        let bl: CGFloat = isMine ? big : small
        let br: CGFloat = isMine ? small : big

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr),
                    radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br),
                    radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl),
                    radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl),
                    radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}

// MARK: - VoiceBubbleContent

private struct VoiceBubbleContent: View {
    let url: URL
    let isMine: Bool
    let transcript: String?
    var messageId: String? = nil
    var onTranscribe: ((String) -> Void)? = nil

    @State private var requestedTranscribe = false

    @ObservedObject private var player = AudioPlayer.shared

    private var isCurrent: Bool { player.currentURL == url }
    private var isPlaying: Bool { isCurrent && player.isPlaying }

    private var progress: Double {
        guard isCurrent, player.duration > 0 else { return 0 }
        return player.progress
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    player.toggle(url: url)
                } label: {
                    ZStack {
                        Circle()
                            .fill(isMine ? .white.opacity(0.2) : Theme.accent.opacity(0.15))
                            .frame(width: 36, height: 36)
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.subheadline.weight(.bold))
                            .foregroundColor(isMine ? .white : Theme.accent)
                    }
                }
                .buttonStyle(.plain)

                // Псевдо-волнограмма (статичные бары) с прогресс-маской
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        HStack(spacing: 2) {
                            ForEach(0..<24, id: \.self) { i in
                                Capsule()
                                    .fill((isMine ? Color.white.opacity(0.5) : Theme.accent.opacity(0.4)))
                                    .frame(width: 2, height: barHeight(i))
                            }
                        }
                        HStack(spacing: 2) {
                            ForEach(0..<24, id: \.self) { i in
                                Capsule()
                                    .fill(isMine ? Color.white : Theme.accent)
                                    .frame(width: 2, height: barHeight(i))
                            }
                        }
                        .mask(
                            HStack {
                                Rectangle()
                                    .frame(width: geo.size.width * progress)
                                Spacer(minLength: 0)
                            }
                        )
                    }
                }
                .frame(width: 110, height: 24)

                Text(formatDuration(isCurrent ? player.current : 0,
                                    total: isCurrent ? player.duration : 0))
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(isMine ? .white.opacity(0.85) : .secondary)
            }

            if let t = transcript, !t.isEmpty {
                Text("«\(t)»")
                    .font(.caption.italic())
                    .foregroundColor(isMine ? .white.opacity(0.85) : .secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            } else {
                HStack(spacing: 8) {
                    Text("Голосовое сообщение")
                        .font(.caption2)
                        .foregroundColor(isMine ? .white.opacity(0.7) : .tertiary)
                    Spacer(minLength: 4)
                    if let mid = messageId, let onT = onTranscribe {
                        if requestedTranscribe {
                            ProgressView()
                                .scaleEffect(0.7)
                                .tint(isMine ? .white : Theme.accent)
                        } else {
                            Button {
                                requestedTranscribe = true
                                onT(mid)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "waveform")
                                        .font(.system(size: 10, weight: .semibold))
                                    Text("Расшифровать")
                                        .font(.caption2.weight(.semibold))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule().fill(isMine
                                                   ? Color.white.opacity(0.18)
                                                   : Theme.accent.opacity(0.12))
                                )
                                .foregroundColor(isMine ? .white : Theme.accent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func barHeight(_ i: Int) -> CGFloat {
        // Псевдо-случайные высоты для волнограммы — детерминированные по индексу
        let h: [CGFloat] = [10, 18, 12, 22, 8, 16, 20, 14, 11, 24, 9, 17, 13, 19, 15, 21, 10, 14, 18, 12, 23, 16, 11, 19]
        return h[i % h.count]
    }

    private func formatDuration(_ current: TimeInterval, total: TimeInterval) -> String {
        if total <= 0 { return "0:00" }
        let cur = Int(current); let tot = Int(total)
        let cm = cur / 60, cs = cur % 60
        let tm = tot / 60, ts = tot % 60
        return String(format: "%d:%02d / %d:%02d", cm, cs, tm, ts)
    }
}

// MARK: - ThreadView (Slack-style тред)

struct ThreadView: View {
    let chatId: String
    let parent: ChatMessage

    @EnvironmentObject var auth: AuthStore
    @State private var replies: [ChatMessage] = []
    @State private var loading = true
    @State private var error: String?
    @State private var inputText: String = ""
    @State private var sending = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    // Parent message — закреплённое сверху
                    parentCard

                    Divider().padding(.horizontal, 16)

                    if loading && replies.isEmpty {
                        ProgressView().tint(Theme.accent).padding()
                    } else if replies.isEmpty {
                        Text("Будьте первым, кто ответит в этом треде")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 24)
                    } else {
                        ForEach(replies) { reply in
                            HStack(alignment: .top, spacing: 8) {
                                AvatarCircle(
                                    url: reply.author?.avatarUrl,
                                    name: reply.author.map(displayName) ?? "?"
                                )
                                .frame(width: 28, height: 28)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(reply.author.map(displayName) ?? "?")
                                            .font(.caption.weight(.semibold))
                                            .foregroundColor(Theme.accent)
                                        if let d = parseChatDate(reply.createdAt) {
                                            Text(relativeTime(from: d))
                                                .font(.caption2)
                                                .foregroundColor(.tertiary)
                                        }
                                        Spacer()
                                    }
                                    Text(reply.content ?? "")
                                        .font(.body)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }
                .padding(.vertical, 12)
            }

            if let err = error {
                Text(err).font(.caption).foregroundColor(Theme.danger)
                    .padding(.horizontal, 16).padding(.bottom, 4)
            }

            // Input
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ответить в треде", text: $inputText, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Theme.surfaceBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                Button { Task { await sendReply() } } label: {
                    ZStack {
                        Circle().fill(canSend ? Theme.accent : Theme.accent.opacity(0.3))
                            .frame(width: 36, height: 36)
                        if sending {
                            ProgressView().tint(.white).scaleEffect(0.7)
                        } else {
                            Image(systemName: "paperplane.fill")
                                .foregroundColor(.white)
                                .font(.system(size: 14, weight: .semibold))
                        }
                    }
                }
                .disabled(!canSend || sending)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.cardBackground)
            .overlay(Rectangle().fill(Theme.separator).frame(height: 0.5), alignment: .top)
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("Тред")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var parentCard: some View {
        HStack(alignment: .top, spacing: 8) {
            AvatarCircle(url: parent.author?.avatarUrl, name: parent.author.map(displayName) ?? "?")
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(parent.author.map(displayName) ?? "?")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.accent)
                Text(parent.content ?? "")
                    .font(.body)
                    .foregroundColor(Theme.textPrimary)
            }
            Spacer()
        }
        .padding(12)
        .background(Theme.surfaceBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            // Бэк: GET /messages/:id/thread (без префикса chats/)
            let resp: MessagesResponse = try await APIClient.shared.get(
                "messages/\(parent.id)/thread",
                query: ["limit": "100"]
            )
            self.replies = resp.data.sorted { $0.createdAt < $1.createdAt }
            self.error = nil
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func sendReply() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        defer { sending = false }
        struct Body: Encodable {
            let content: String
            let parentThreadId: String
            let clientId: String
        }
        do {
            let saved: ChatMessage = try await APIClient.shared.post(
                "chats/\(chatId)/messages",
                body: Body(content: text, parentThreadId: parent.id, clientId: UUID().uuidString)
            )
            replies.append(saved)
            inputText = ""
            error = nil
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}
