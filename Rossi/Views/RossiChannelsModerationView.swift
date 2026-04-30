//
//  RossiChannelsModerationView.swift — модерация каналов Rossi (Staya).
//
//  Бэкенд (apps/api/src/modules/admin-channels/admin-channels.controller.ts):
//   • GET    /admin/channels?search=&banned=&limit=&offset=  → { channels: [...], total }
//   • GET    /admin/channels/:id/info                        → инфо о канале
//   • GET    /admin/channels/:id/posts?limit=&before=        → посты
//   • DELETE /admin/channels/:id                             — бан
//   • POST   /admin/channels/:id/unban                       — разбан
//   • POST   /admin/channels/:id/verify                      — верифицировать
//   • POST   /admin/channels/:id/unverify                    — снять галочку
//
//  Permission: channels.moderate.view (см. PERMISSIONS.CHANNELS_MODERATE_VIEW).
//
//  Web-референс: apps/web/src/app/(app)/admin/channels/page.tsx
//                apps/web/src/app/(app)/admin/channels/[channelId]/page.tsx
//

import SwiftUI

// MARK: - Models

struct RossiModChannel: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let is_public: Bool?
    let banned_at: String?
    let created_at: String?
    let members_count: Int?
    let is_verified: Bool?
    let avatar_url: String?
}

private struct RossiModChannelsEnvelope: Codable {
    let channels: [RossiModChannel]?
    let total: Int?
}

// MARK: - View

struct RossiChannelsModerationView: View {
    @State private var channels: [RossiModChannel] = []
    @State private var totalCount: Int = 0
    @State private var search = ""
    @State private var bannedFilter: String = "all" // all | active | banned
    @State private var loading = true
    @State private var error: String?
    @State private var notAvailable = false

    private let webURL = URL(string: "https://rossihelp.ru/admin/channels")!

    var body: some View {
        ZStack {
            Theme.pageBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    DSPageTitle(text: "Каналы Rossi",
                                subtitle: subtitleText)
                        .padding(.top, 4)

                    if !notAvailable {
                        Picker("Фильтр", selection: $bannedFilter) {
                            Text("Все").tag("all")
                            Text("Активные").tag("active")
                            Text("Забанены").tag("banned")
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: bannedFilter) { _ in Task { await load() } }
                    }

                    if loading && channels.isEmpty {
                        ProgressView().tint(Theme.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    } else if notAvailable {
                        unavailableState
                    } else if let err = error, channels.isEmpty {
                        EmptyStateView(icon: "exclamationmark.triangle",
                                       title: "Ошибка",
                                       description: err)
                    } else if channels.isEmpty {
                        EmptyStateView(icon: "dot.radiowaves.left.and.right",
                                       title: "Каналов нет",
                                       description: search.isEmpty ? "Попробуйте обновить позже." : "По запросу ничего нет.")
                    } else {
                        DSSectionHeader("Список")
                        LazyVStack(spacing: 10) {
                            ForEach(channels) { channel in
                                NavigationLink {
                                    RossiChannelModDetailView(channelId: channel.id, fallbackTitle: channel.title)
                                } label: {
                                    RossiModChannelCard(channel: channel)
                                }
                                .buttonStyle(DSPressScaleStyle())
                            }
                        }
                    }
                    Color.clear.frame(height: TabBarVisibility.reservedHeight)
                }
                .padding(16)
            }
        }
        .navigationTitle("Каналы Rossi")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Поиск каналов…")
        .onSubmit(of: .search) { Task { await load() } }
        .onChange(of: search) { newValue in
            if newValue.isEmpty { Task { await load() } }
        }
        .refreshable { await load() }
        .task { if channels.isEmpty && !notAvailable { await load() } }
    }

    private var subtitleText: String? {
        if notAvailable { return nil }
        if loading && channels.isEmpty { return nil }
        if channels.isEmpty { return nil }
        let total = totalCount > 0 ? totalCount : channels.count
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = " "
        let s = f.string(from: NSNumber(value: total)) ?? "\(total)"
        return "Всего: \(s)"
    }

    @ViewBuilder
    private var unavailableState: some View {
        VStack(spacing: 14) {
            EmptyStateView(icon: "hammer",
                           title: "В разработке",
                           description: "Раздел модерации каналов Rossi пока недоступен в приложении. Откройте его в веб-версии.")
            Link(destination: webURL) {
                HStack(spacing: 6) {
                    Image(systemName: "safari")
                    Text("Открыть в браузере")
                        .font(.dsBody.weight(.semibold))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Theme.indigo.opacity(0.12))
                .foregroundColor(Theme.indigo)
                .clipShape(Capsule())
            }
            .padding(.bottom, 24)
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        var query: [String: String] = ["limit": "100"]
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { query["search"] = q }
        switch bannedFilter {
        case "banned": query["banned"] = "true"
        case "active": query["banned"] = "false"
        default: break
        }
        do {
            let envelope: RossiModChannelsEnvelope = try await APIClient.shared.get("admin/channels", query: query)
            self.channels = envelope.channels ?? []
            self.totalCount = envelope.total ?? 0
            self.error = nil
            self.notAvailable = false
        } catch {
            if let apiErr = error as? APIError, case .http(let status, _) = apiErr, status == 404 {
                self.notAvailable = true
                self.channels = []
                return
            }
            self.error = apiUserMessage(error)
        }
    }
}

// MARK: - Card

private struct RossiModChannelCard: View {
    let channel: RossiModChannel

    private var isBanned: Bool { (channel.banned_at ?? "").isEmpty == false }

    var body: some View {
        DSCard(radius: Radius.lg, padding: 12) {
            HStack(spacing: 12) {
                if let ref = channel.avatar_url, !ref.isEmpty {
                    AuthedAsyncImage(
                        path: "admin/channels/media/photos/\(ref)",
                        content: { img in img.resizable().scaledToFill() },
                        placeholder: {
                            DSIconTile(systemImage: "dot.radiowaves.left.and.right",
                                       color: Theme.indigo, size: 40)
                        }
                    )
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    DSIconTile(systemImage: "dot.radiowaves.left.and.right",
                               color: Theme.indigo, size: 40)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(channel.title.isEmpty ? "(без названия)" : channel.title)
                            .font(.dsBodyLG.weight(.semibold))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                        if channel.is_verified == true {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Theme.accent)
                        }
                        if isBanned {
                            DSBadge(text: "забанен", color: Theme.danger, filled: true)
                        } else if channel.is_public == false {
                            DSBadge(text: "приватный", color: Theme.textTertiary, filled: false)
                        }
                    }
                    HStack(spacing: 10) {
                        if let count = channel.members_count {
                            Label("\(count)", systemImage: "person.2.fill")
                                .font(.dsCaption)
                                .foregroundColor(Theme.textSecondary)
                        }
                        if let created = channel.created_at {
                            Text(created.prefix(10))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)
                        }
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textTertiary)
            }
        }
    }
}

// MARK: - Detail — повторяет функционал web admin/channels/[channelId]

private struct ChannelInfoModel: Decodable {
    let id: String
    let title: String?
    let is_public: Bool?
    let banned_at: String?
    let created_at: String?
    let members_count: Int?
    let is_verified: Bool?
    let about: String?
    let avatar_url: String?
}

private struct ChannelComment: Decodable, Identifiable {
    let id: String
    let post_id: String?
    let sender_id: String?
    let sender_name: String?
    let sender_surname: String?
    let text: String?
    let created_at: String?
}

private struct ChannelCommentsEnvelope: Decodable {
    let comments: [ChannelComment]?
}

private struct ChannelPost: Decodable, Identifiable {
    let id: String
    let channel_id: String?
    let sender_id: String?
    let sender_name: String?
    let sender_surname: String?
    let text: String?
    let media_ref: String?
    let file_ref: String?
    let created_at: String?
    let comments_count: Int?
    let views_count: Int?
}

private struct ChannelPostsEnvelope: Decodable {
    let posts: [ChannelPost]?
}

struct RossiChannelModDetailView: View {
    let channelId: String
    let fallbackTitle: String

    @State private var info: ChannelInfoModel?
    @State private var posts: [ChannelPost] = []
    @State private var loading = true
    @State private var loadingPosts = false
    @State private var working = false
    @State private var error: String?
    @State private var statusInfo: String?

    @State private var showBanConfirm = false
    @State private var deletingPost: ChannelPost?
    @State private var commentsForPost: ChannelPost?
    @State private var comments: [ChannelComment] = []
    @State private var loadingComments = false
    @State private var deletingComment: ChannelComment?

    private var isBanned: Bool { (info?.banned_at ?? "").isEmpty == false }
    private var isVerified: Bool { info?.is_verified == true }

    var body: some View {
        ZStack {
            Theme.pageBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if loading {
                        ProgressView().tint(Theme.accent)
                            .frame(maxWidth: .infinity).padding(.top, 60)
                    } else if let err = error, info == nil {
                        EmptyStateView(icon: "exclamationmark.triangle",
                                       title: "Не удалось загрузить",
                                       description: err)
                    } else if let info {
                        header(info)
                        actionsCard()
                        postsCard()
                        if let s = statusInfo {
                            DSCard(radius: Radius.md, padding: 10) {
                                Text(s).font(.dsCaption).foregroundColor(Theme.success)
                            }
                        }
                    }
                    Color.clear.frame(height: TabBarVisibility.reservedHeight)
                }
                .padding(16)
            }
        }
        .navigationTitle("Канал")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .alert("Забанить канал?", isPresented: $showBanConfirm) {
            Button("Отмена", role: .cancel) {}
            Button("Забанить", role: .destructive) { Task { await ban() } }
        } message: {
            Text("Канал будет скрыт для пользователей. Вы сможете снять бан позже.")
        }
        .alert("Удалить пост?",
               isPresented: Binding(get: { deletingPost != nil }, set: { if !$0 { deletingPost = nil } })) {
            Button("Отмена", role: .cancel) {}
            Button("Удалить", role: .destructive) {
                if let p = deletingPost { Task { await deletePost(p) } }
            }
        } message: {
            Text("Пост будет удалён без возможности восстановления.")
        }
        .sheet(item: $commentsForPost) { post in
            commentsSheet(for: post)
        }
        .alert("Удалить комментарий?",
               isPresented: Binding(get: { deletingComment != nil }, set: { if !$0 { deletingComment = nil } })) {
            Button("Отмена", role: .cancel) {}
            Button("Удалить", role: .destructive) {
                if let c = deletingComment { Task { await deleteComment(c) } }
            }
        }
    }

    @ViewBuilder
    private func commentsSheet(for post: ChannelPost) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let text = post.text, !text.isEmpty {
                        DSCard(radius: Radius.md, padding: 10) {
                            Text(text).font(.dsCaption).foregroundColor(Theme.textSecondary)
                                .lineLimit(4)
                        }
                    }
                    DSSectionHeader("Комментарии (\(comments.count))")
                    if loadingComments && comments.isEmpty {
                        ProgressView().tint(Theme.accent)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    } else if comments.isEmpty {
                        Text("Нет комментариев")
                            .font(.dsCaption).foregroundColor(Theme.textTertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else {
                        LazyVStack(spacing: 6) {
                            ForEach(comments) { c in
                                DSCard(radius: Radius.md, padding: 10) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(commentSenderName(c))
                                                .font(.dsCaption.weight(.semibold))
                                                .foregroundColor(Theme.textPrimary)
                                            Spacer()
                                            if let cr = c.created_at {
                                                Text(cr.prefix(16))
                                                    .font(.system(size: 10, design: .monospaced))
                                                    .foregroundColor(Theme.textTertiary)
                                            }
                                            Button {
                                                deletingComment = c
                                            } label: {
                                                Image(systemName: "trash")
                                                    .foregroundColor(Theme.danger)
                                                    .font(.system(size: 12))
                                            }
                                        }
                                        if let t = c.text, !t.isEmpty {
                                            Text(t).font(.dsCaption).foregroundColor(Theme.textPrimary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.pageBackground.ignoresSafeArea())
            .navigationTitle("Комментарии")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { commentsForPost = nil }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func commentSenderName(_ c: ChannelComment) -> String {
        let combo = "\(c.sender_name ?? "") \(c.sender_surname ?? "")"
            .trimmingCharacters(in: .whitespaces)
        return combo.isEmpty ? "—" : combo
    }

    private func loadComments(for postId: String) async {
        loadingComments = true
        defer { loadingComments = false }
        do {
            if let env: ChannelCommentsEnvelope = try? await APIClient.shared.get(
                "admin/channels/posts/\(postId)/comments", query: ["limit": "100"]
            ), let arr = env.comments {
                self.comments = arr
            } else if let arr: [ChannelComment] = try? await APIClient.shared.get(
                "admin/channels/posts/\(postId)/comments", query: ["limit": "100"]
            ) {
                self.comments = arr
            } else {
                self.comments = []
            }
        }
    }

    private func deleteComment(_ c: ChannelComment) async {
        working = true; defer { working = false }
        do {
            try await APIClient.shared.delete("admin/channels/comments/\(c.id)")
            comments.removeAll(where: { $0.id == c.id })
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    @ViewBuilder
    private func header(_ c: ChannelInfoModel) -> some View {
        DSCard(radius: Radius.lg, padding: 14) {
            HStack(spacing: 14) {
                channelAvatar(ref: c.avatar_url, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text((c.title ?? fallbackTitle).ifEmpty(or: "(без названия)"))
                            .font(.dsBodyLG.weight(.semibold))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(2)
                        if isVerified {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundColor(Theme.accent)
                                .font(.system(size: 14))
                        }
                        if isBanned {
                            DSBadge(text: "забанен", color: Theme.danger, filled: true)
                        } else if c.is_public == false {
                            DSBadge(text: "приватный", color: Theme.textTertiary, filled: false)
                        }
                    }
                    if let m = c.members_count {
                        Label("\(m) подписчиков", systemImage: "person.2.fill")
                            .font(.dsCaption)
                            .foregroundColor(Theme.textSecondary)
                    }
                    if let cr = c.created_at {
                        Text("Создан: " + String(cr.prefix(10)))
                            .font(.dsCaption)
                            .foregroundColor(Theme.textTertiary)
                    }
                    if let a = c.about, !a.isEmpty {
                        Text(a).font(.dsCaption).foregroundColor(Theme.textSecondary).lineLimit(4)
                    }
                }
                Spacer(minLength: 4)
            }
        }
    }

    @ViewBuilder
    private func actionsCard() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DSSectionHeader("Действия")
            if isVerified {
                Button { Task { await unverify() } } label: {
                    actionRow(icon: "seal", title: "Снять верификацию", color: Theme.warning)
                }.disabled(working)
            } else {
                Button { Task { await verify() } } label: {
                    actionRow(icon: "checkmark.seal", title: "Верифицировать", color: Theme.accent)
                }.disabled(working)
            }
            if isBanned {
                Button { Task { await unban() } } label: {
                    actionRow(icon: "checkmark.circle.fill", title: "Разбанить", color: Theme.success)
                }.disabled(working)
            } else {
                Button { showBanConfirm = true } label: {
                    actionRow(icon: "nosign", title: "Забанить", color: Theme.danger)
                }.disabled(working)
            }
        }
    }

    @ViewBuilder
    private func postsCard() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                DSSectionHeader("Посты")
                Spacer()
                if loadingPosts { ProgressView().controlSize(.small) }
            }
            if posts.isEmpty {
                DSCard(radius: Radius.md, padding: 10) {
                    Text(loadingPosts ? "Загрузка…" : "Нет постов")
                        .font(.dsCaption).foregroundColor(Theme.textTertiary)
                }
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(posts) { p in
                        postRow(p)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func postRow(_ p: ChannelPost) -> some View {
        DSCard(radius: Radius.md, padding: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(senderName(p))
                        .font(.dsCaption.weight(.semibold))
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    if let c = p.created_at {
                        Text(c.prefix(16))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Theme.textTertiary)
                    }
                    Button {
                        deletingPost = p
                    } label: {
                        Image(systemName: "trash").foregroundColor(Theme.danger)
                            .font(.system(size: 13))
                    }
                    .disabled(working)
                }
                if let t = p.text, !t.isEmpty {
                    Text(t).font(.dsCaption).foregroundColor(Theme.textPrimary)
                        .lineLimit(8)
                }
                // Inline-превью медиа поста (фото / видео thumbnail)
                if let ref = p.media_ref, !ref.isEmpty {
                    AuthedAsyncImage(
                        path: "admin/channels/media/photos/\(ref)",
                        content: { img in img.resizable().scaledToFill() },
                        placeholder: {
                            Color.secondary.opacity(0.1)
                                .overlay(
                                    Image(systemName: "photo")
                                        .foregroundColor(.secondary)
                                )
                        }
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: 160)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                HStack(spacing: 12) {
                    Button {
                        commentsForPost = p
                        Task { await loadComments(for: p.id) }
                    } label: {
                        Label("\(p.comments_count ?? 0)", systemImage: "bubble.left")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    if let v = p.views_count, v > 0 {
                        Label("\(v)", systemImage: "eye")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textTertiary)
                    }
                    Spacer()
                }
            }
        }
    }

    private func mediaURL(ref: String, kind: String) -> URL? {
        if ref.hasPrefix("http") { return URL(string: ref) }
        return URL(string: "https://rossihelp.ru/api/v1/admin/channels/media/\(kind)/\(ref)")
    }

    @ViewBuilder
    private func actionRow(icon: String, title: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundColor(color)
                .frame(width: 24)
            Text(title)
                .font(.dsBody.weight(.medium))
                .foregroundColor(Theme.textPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textTertiary)
        }
        .padding(12)
        .background(Theme.surfaceBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
    }

    @ViewBuilder
    private func channelAvatar(ref: String?, size: CGFloat) -> some View {
        if let ref, !ref.isEmpty {
            AuthedAsyncImage(
                path: "admin/channels/media/photos/\(ref)",
                content: { img in img.resizable().scaledToFill() },
                placeholder: {
                    DSIconTile(systemImage: "dot.radiowaves.left.and.right",
                               color: Theme.indigo, size: size)
                }
            )
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else {
            DSIconTile(systemImage: "dot.radiowaves.left.and.right",
                       color: Theme.indigo, size: size)
        }
    }

    private func senderName(_ p: ChannelPost) -> String {
        let combo = "\(p.sender_name ?? "") \(p.sender_surname ?? "")"
            .trimmingCharacters(in: .whitespaces)
        return combo.isEmpty ? "—" : combo
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            self.info = try await APIClient.shared.get("admin/channels/\(channelId)/info")
            self.error = nil
            await loadPosts()
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func loadPosts() async {
        loadingPosts = true
        defer { loadingPosts = false }
        do {
            let env: ChannelPostsEnvelope = try await APIClient.shared.get(
                "admin/channels/\(channelId)/posts", query: ["limit": "50"]
            )
            self.posts = env.posts ?? []
        } catch {
            // не фатально
        }
    }

    private func ban() async {
        working = true; defer { working = false }
        do {
            try await APIClient.shared.delete("admin/channels/\(channelId)")
            statusInfo = "Канал забанен"
            await load()
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func unban() async {
        working = true; defer { working = false }
        struct Empty: Encodable {}
        do {
            _ = try await APIClient.shared.rawRequest(
                "POST", "admin/channels/\(channelId)/unban", body: Empty()
            )
            statusInfo = "Канал разбанен"
            await load()
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func verify() async {
        working = true; defer { working = false }
        struct Empty: Encodable {}
        do {
            _ = try await APIClient.shared.rawRequest(
                "POST", "admin/channels/\(channelId)/verify", body: Empty()
            )
            statusInfo = "Канал верифицирован"
            await load()
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func unverify() async {
        working = true; defer { working = false }
        struct Empty: Encodable {}
        do {
            _ = try await APIClient.shared.rawRequest(
                "POST", "admin/channels/\(channelId)/unverify", body: Empty()
            )
            statusInfo = "Верификация снята"
            await load()
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func deletePost(_ p: ChannelPost) async {
        working = true; defer { working = false }
        do {
            try await APIClient.shared.delete("admin/channels/posts/\(p.id)")
            posts.removeAll(where: { $0.id == p.id })
            statusInfo = "Пост удалён"
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}

#Preview {
    NavigationStack { RossiChannelsModerationView() }
        .environmentObject(AuthStore())
}
