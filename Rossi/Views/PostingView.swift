//
//  PostingView.swift — модуль «Постинг» (админ соц. сети).
//
//  Endpoints (apps/api/src/modules/posting/posting.controller.ts):
//   • GET    /posting?status&platform&search&page&pageSize  → { data:[SocialPost], meta }
//   • GET    /posting/:id                                   → SocialPost
//   • GET    /posting/config                                → { vk, telegram, staya }
//   • GET    /posting/stats                                 → { draft, scheduled, ... }
//   • POST   /posting          body: { text, platforms, attachments?, publishNow?, scheduledAt? }
//   • PATCH  /posting/:id      body: { text?, attachments?, scheduledAt? }
//   • POST   /posting/:id/publish
//   • DELETE /posting/:id
//
//  Permissions (RequirePermissions на бэке):
//   • posting.view / posting.create / posting.update / posting.delete
//   У супер-админа в permissions есть '*' → даём всё.
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Models (точно по реальному ответу /posting)

struct SocialPostItem: Codable, Identifiable {
    let id: String
    let text: String
    let status: String          // draft | scheduled | publishing | published | partial | failed | deleted
    let platforms: [String]     // ['vk','telegram','staya']

    let vkPostUrl: String?
    let tgPostUrl: String?
    let vkError: String?
    let tgError: String?
    let stayaChatId: String?
    let stayaMessageId: String?
    let stayaError: String?

    let scheduledAt: String?
    let publishedAt: String?
    let createdAt: String?
    let updatedAt: String?

    let commentsCount: Int?
    let author: PostAuthor?

    /// attachments — Json column на бэке. Иногда [[]], иногда [{kind,url,...}].
    /// Декодируем толерантно — см. init(from:).
    let attachments: [PostAttachment]

    enum CodingKeys: String, CodingKey {
        case id, text, status, platforms
        case vkPostUrl, tgPostUrl, vkError, tgError
        case stayaChatId, stayaMessageId, stayaError
        case scheduledAt, publishedAt, createdAt, updatedAt
        case commentsCount, author, attachments
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id            = try c.decode(String.self, forKey: .id)
        text          = try c.decode(String.self, forKey: .text)
        status        = try c.decode(String.self, forKey: .status)
        platforms     = (try? c.decode([String].self, forKey: .platforms)) ?? []
        vkPostUrl     = try? c.decode(String.self, forKey: .vkPostUrl)
        tgPostUrl     = try? c.decode(String.self, forKey: .tgPostUrl)
        vkError       = try? c.decode(String.self, forKey: .vkError)
        tgError       = try? c.decode(String.self, forKey: .tgError)
        stayaChatId   = try? c.decode(String.self, forKey: .stayaChatId)
        stayaMessageId = try? c.decode(String.self, forKey: .stayaMessageId)
        stayaError    = try? c.decode(String.self, forKey: .stayaError)
        scheduledAt   = try? c.decode(String.self, forKey: .scheduledAt)
        publishedAt   = try? c.decode(String.self, forKey: .publishedAt)
        createdAt     = try? c.decode(String.self, forKey: .createdAt)
        updatedAt     = try? c.decode(String.self, forKey: .updatedAt)
        commentsCount = try? c.decode(Int.self, forKey: .commentsCount)
        author        = try? c.decode(PostAuthor.self, forKey: .author)

        // Толерантный разбор attachments: либо массив объектов, либо «мусор» (например [[]]).
        if let arr = try? c.decode([PostAttachment].self, forKey: .attachments) {
            attachments = arr
        } else {
            attachments = []
        }
    }

    // Encode не нужен (только читаем), но соответствуем Codable стабом.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(text, forKey: .text)
        try c.encode(status, forKey: .status)
        try c.encode(platforms, forKey: .platforms)
        try c.encodeIfPresent(scheduledAt, forKey: .scheduledAt)
        try c.encodeIfPresent(publishedAt, forKey: .publishedAt)
        try c.encode(attachments, forKey: .attachments)
    }
}

struct PostAttachment: Codable, Hashable {
    let kind: String?     // 'image' | 'video' | 'file'
    let url: String?
    let name: String?
    let mime: String?
    let size: Int?
}

struct PostAuthor: Codable {
    let id: String
    let username: String?
    let firstName: String?
    let lastName: String?
    let avatarUrl: String?

    var displayName: String {
        let s = "\(firstName ?? "") \(lastName ?? "")".trimmingCharacters(in: .whitespaces)
        if !s.isEmpty { return s }
        return username ?? "Автор"
    }
}

struct SocialPostListResponse: Codable {
    let data: [SocialPostItem]
    let meta: PaginationMeta?
}

// MARK: - Post version history

struct PostVersionItem: Codable, Identifiable {
    let id: String
    let postId: String?
    let text: String?
    let title: String?
    let createdAt: String?
    let editor: PostAuthor?
}

struct PostVersionsResponse: Codable {
    let data: [PostVersionItem]
}

// MARK: - Status / platform helpers

private enum PostStatusFilter: String, CaseIterable, Identifiable {
    case all       = ""
    case draft     = "draft"
    case scheduled = "scheduled"
    case published = "published"
    case failed    = "failed"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .all:       return "Все"
        case .draft:     return "Черновики"
        case .scheduled: return "Запланир."
        case .published: return "Опубл."
        case .failed:    return "Ошибки"
        }
    }
}

private enum PostPlatformFilter: String, CaseIterable, Identifiable {
    case all      = ""
    case vk       = "vk"
    case telegram = "telegram"
    case staya    = "staya"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .all:      return "Все"
        case .vk:       return "VK"
        case .telegram: return "Telegram"
        case .staya:    return "Staya"
        }
    }
    var icon: String {
        switch self {
        case .all:      return "square.grid.2x2"
        case .vk:       return "person.2.circle.fill"
        case .telegram: return "paperplane.fill"
        case .staya:    return "globe"
        }
    }
    var color: Color {
        switch self {
        case .all:      return Theme.textSecondary
        case .vk:       return Color(red: 0.30, green: 0.50, blue: 0.78)
        case .telegram: return Color(red: 0.15, green: 0.61, blue: 0.91)
        case .staya:    return Theme.purple
        }
    }
}

private func statusBadge(_ status: String) -> (text: String, color: Color, icon: String) {
    switch status {
    case "draft":      return ("Черновик",    .secondary,    "doc.text")
    case "scheduled":  return ("Запланирован", Theme.warning, "clock.fill")
    case "publishing": return ("Публикуется",  Theme.accent,  "arrow.triangle.2.circlepath")
    case "published":  return ("Опубликован",  Theme.success, "checkmark.seal.fill")
    case "partial":    return ("Частично",     Theme.warning, "exclamationmark.triangle.fill")
    case "failed":     return ("Ошибка",       Theme.danger,  "xmark.octagon.fill")
    case "deleted":    return ("Удалён",       .secondary,    "trash")
    default:           return (status,         .secondary,    "circle")
    }
}

private func platformIcon(_ platform: String) -> (icon: String, label: String, color: Color) {
    switch platform {
    case "vk":       return ("person.crop.square.fill", "VK",       Color(red: 0.30, green: 0.50, blue: 0.78))
    case "telegram": return ("paperplane.fill",          "Telegram", Color(red: 0.15, green: 0.61, blue: 0.91))
    case "staya":    return ("rectangle.stack.fill",     "Стая",     Theme.purple)
    default:         return ("globe",                    platform,    .secondary)
    }
}

// MARK: - Permissions helper

private extension AuthUser {
    func hasPostingPermission(_ p: String) -> Bool {
        guard let perms = permissions else { return false }
        return perms.contains("*") || perms.contains(p)
    }
}

// MARK: - List view

struct PostingView: View {
    @EnvironmentObject var auth: AuthStore

    @State private var posts: [SocialPostItem] = []
    @State private var status: PostStatusFilter = .all
    @State private var platform: PostPlatformFilter = .all
    @State private var loading = false
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                DSPageTitle(text: "Постинг", subtitle: "Публикации в социальных сетях")
                picker
                platformChips
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 8)

            content
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task(id: "\(status.rawValue)|\(platform.rawValue)") { await load() }
    }

    // MARK: Subviews

    private var picker: some View {
        Picker("Статус", selection: $status) {
            ForEach(PostStatusFilter.allCases) { f in
                Text(f.label).tag(f)
            }
        }
        .pickerStyle(.segmented)
    }

    private var platformChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PostPlatformFilter.allCases) { p in
                    Button {
                        platform = p
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: p.icon)
                                .font(.system(size: 11, weight: .semibold))
                            Text(p.label)
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .foregroundColor(platform == p ? .white : p.color)
                        .background(
                            Capsule().fill(platform == p ? p.color : p.color.opacity(0.12))
                        )
                    }
                    .buttonStyle(DSPressScaleStyle())
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading && posts.isEmpty {
            VStack {
                Spacer()
                ProgressView().tint(Theme.accent)
                Spacer()
            }
        } else if let err = error, posts.isEmpty {
            EmptyStateView(
                icon: "exclamationmark.bubble",
                title: "Не удалось загрузить",
                description: err
            )
        } else if posts.isEmpty && loaded {
            EmptyStateView(
                icon: "megaphone",
                title: "Постов пока нет",
                description: status == .all
                    ? "Создайте первый пост в соцсети"
                    : "В этом разделе пусто"
            )
        } else {
            list
        }
    }

    private var list: some View {
        List {
            ForEach(posts) { post in
                ZStack {
                    // Прозрачная NavigationLink, чтобы не было стрелки-шеврона
                    NavigationLink {
                        PostDetailView(id: post.id)
                    } label: { EmptyView() }
                    .opacity(0)

                    PostCardView(post: post)
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if canDelete {
                        Button(role: .destructive) {
                            Task { await delete(post) }
                        } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await load(force: true) }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if canCreate {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    CreatePostSheet()
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
    }

    // MARK: Permissions

    private var canCreate: Bool { auth.currentUser?.hasPostingPermission("posting.create") ?? false }
    private var canDelete: Bool { auth.currentUser?.hasPostingPermission("posting.delete") ?? false }

    // MARK: Networking

    private func load(force: Bool = false) async {
        if loading && !force { return }
        loading = true
        error = nil
        defer { loading = false; loaded = true }

        var query: [String: String] = ["page": "1", "pageSize": "50"]
        if !status.rawValue.isEmpty { query["status"] = status.rawValue }
        if !platform.rawValue.isEmpty { query["platform"] = platform.rawValue }

        do {
            let resp: SocialPostListResponse = try await APIClient.shared.get("posting", query: query)
            self.posts = resp.data
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func delete(_ post: SocialPostItem) async {
        do {
            try await APIClient.shared.delete("posting/\(post.id)")
            posts.removeAll { $0.id == post.id }
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}

// MARK: - Post card

private struct PostCardView: View {
    let post: SocialPostItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarCircle(url: post.author?.avatarUrl,
                         name: post.author?.displayName ?? "")
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 8) {
                // Шапка: автор + время + статус
                HStack(spacing: 8) {
                    Text(post.author?.displayName ?? "Автор")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    statusChip
                }

                // Превью текста
                Text(post.text)
                    .font(.subheadline)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Платформы + время + комменты
                HStack(spacing: 10) {
                    ForEach(post.platforms, id: \.self) { p in
                        let info = platformIcon(p)
                        Label(info.label, systemImage: info.icon)
                            .font(.caption2.weight(.medium))
                            .foregroundColor(info.color)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(info.color.opacity(0.12))
                            .clipShape(Capsule())
                    }

                    Spacer(minLength: 4)

                    if let timeStr = displayTime, let date = ISO8601DateFormatter().date(from: timeStr) {
                        Text(relativeTime(from: date))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    if let c = post.commentsCount, c > 0 {
                        Label("\(c)", systemImage: "bubble.left.fill")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Theme.surfaceBackground)
        )
    }

    private var displayTime: String? {
        post.publishedAt ?? post.scheduledAt ?? post.createdAt
    }

    private var statusChip: some View {
        let info = statusBadge(post.status)
        return Label(info.text, systemImage: info.icon)
            .font(.caption2.weight(.semibold))
            .foregroundColor(info.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(info.color.opacity(0.15))
            .clipShape(Capsule())
    }
}

// MARK: - Detail view

struct PostDetailView: View {
    let id: String
    @EnvironmentObject var auth: AuthStore

    @State private var post: SocialPostItem?
    @State private var loading = true
    @State private var error: String?
    @State private var showEdit = false
    @State private var publishing = false
    @State private var versions: [PostVersionItem] = []
    @State private var versionsUnavailable: Bool = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let p = post {
                    headerSection(p)
                    if !p.attachments.isEmpty {
                        attachmentsSection(p.attachments)
                    }
                    contentSection(p)
                    metaSection(p)
                    actionsSection(p)
                    if !versions.isEmpty {
                        historySection(versions)
                    }
                } else if loading {
                    ProgressView().tint(Theme.accent)
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else if let err = error {
                    EmptyStateView(icon: "exclamationmark.bubble",
                                   title: "Не удалось загрузить",
                                   description: err)
                }
            }
            .padding(16)
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("Пост")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load()
            await loadVersions()
        }
        .sheet(isPresented: $showEdit) {
            if let p = post {
                EditPostSheet(post: p) { updated in
                    self.post = updated
                }
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func headerSection(_ p: SocialPostItem) -> some View {
        HStack(spacing: 12) {
            AvatarCircle(url: p.author?.avatarUrl, name: p.author?.displayName ?? "")
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.author?.displayName ?? "Автор")
                    .font(.subheadline.weight(.semibold))
                if let createdStr = p.createdAt,
                   let created = ISO8601DateFormatter().date(from: createdStr) {
                    Text("Создано \(relativeTime(from: created))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            let s = statusBadge(p.status)
            Label(s.text, systemImage: s.icon)
                .font(.caption.weight(.semibold))
                .foregroundColor(s.color)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(s.color.opacity(0.15))
                .clipShape(Capsule())
        }
    }

    @ViewBuilder
    private func contentSection(_ p: SocialPostItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(p.text)
                .font(.body)
                .foregroundColor(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14).fill(Theme.surfaceBackground)
        )
    }

    @ViewBuilder
    private func attachmentsSection(_ atts: [PostAttachment]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Вложения")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(atts.indices, id: \.self) { i in
                        attachmentTile(atts[i])
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func attachmentTile(_ a: PostAttachment) -> some View {
        if a.kind == "image", let urlStr = a.url, let u = URL(string: ensureAbsolute(urlStr)) {
            AsyncImage(url: u) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                default:
                    ZStack {
                        Theme.surfaceBackground
                        ProgressView().tint(Theme.accent)
                    }
                }
            }
            .frame(width: 140, height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            VStack(spacing: 6) {
                Image(systemName: a.kind == "video" ? "play.rectangle.fill" : "doc.fill")
                    .font(.system(size: 28))
                    .foregroundColor(Theme.accent)
                Text(a.name ?? a.url ?? "Файл")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 140, height: 140)
            .background(
                RoundedRectangle(cornerRadius: 12).fill(Theme.surfaceBackground)
            )
        }
    }

    @ViewBuilder
    private func metaSection(_ p: SocialPostItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Постинг")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)

            VStack(spacing: 0) {
                metaRow(icon: "globe", title: "Платформы",
                        value: p.platforms.isEmpty
                            ? "—"
                            : p.platforms.map { platformIcon($0).label }.joined(separator: ", "))
                Divider().background(Theme.separator)
                if let scheduled = p.scheduledAt,
                   let date = ISO8601DateFormatter().date(from: scheduled) {
                    metaRow(icon: "clock", title: "Запланирован", value: formatDateTime(date))
                    Divider().background(Theme.separator)
                }
                if let published = p.publishedAt,
                   let date = ISO8601DateFormatter().date(from: published) {
                    metaRow(icon: "checkmark.seal", title: "Опубликован", value: formatDateTime(date))
                    Divider().background(Theme.separator)
                }
                if let url = p.vkPostUrl, !url.isEmpty {
                    linkRow(icon: "person.crop.square.fill", title: "VK", url: url)
                    Divider().background(Theme.separator)
                }
                if let url = p.tgPostUrl, !url.isEmpty {
                    linkRow(icon: "paperplane.fill", title: "Telegram", url: url)
                    Divider().background(Theme.separator)
                }
                if let err = p.vkError, !err.isEmpty {
                    metaRow(icon: "xmark.octagon", title: "Ошибка VK", value: err, color: Theme.danger)
                    Divider().background(Theme.separator)
                }
                if let err = p.tgError, !err.isEmpty {
                    metaRow(icon: "xmark.octagon", title: "Ошибка TG", value: err, color: Theme.danger)
                    Divider().background(Theme.separator)
                }
                if let err = p.stayaError, !err.isEmpty {
                    metaRow(icon: "xmark.octagon", title: "Ошибка Стая", value: err, color: Theme.danger)
                    Divider().background(Theme.separator)
                }
                metaRow(
                    icon: "bubble.left",
                    title: "Комментариев",
                    value: "\(p.commentsCount ?? 0)"
                )
            }
            .background(
                RoundedRectangle(cornerRadius: 12).fill(Theme.surfaceBackground)
            )
        }
    }

    @ViewBuilder
    private func metaRow(icon: String, title: String, value: String,
                         color: Color = Theme.textPrimary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 22)
                .foregroundColor(.secondary)
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundColor(color)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func linkRow(icon: String, title: String, url: String) -> some View {
        if let u = URL(string: url) {
            Link(destination: u) {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .frame(width: 22)
                        .foregroundColor(Theme.accent)
                    Text(title)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("Открыть")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(Theme.accent)
                    Image(systemName: "arrow.up.right.square")
                        .foregroundColor(Theme.accent)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
    }

    @ViewBuilder
    private func actionsSection(_ p: SocialPostItem) -> some View {
        VStack(spacing: 10) {
            if p.status == "draft" && canUpdate {
                Button {
                    showEdit = true
                } label: {
                    Label("Редактировать", systemImage: "pencil")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.accent)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
            }

            if (p.status == "scheduled" || p.status == "draft") && canCreate {
                Button {
                    Task { await publishNow(p) }
                } label: {
                    HStack {
                        if publishing {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "paperplane.fill")
                        }
                        Text(publishing ? "Публикуем…" : "Опубликовать сейчас")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.success)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .disabled(publishing)
            }

            if canDelete {
                Button(role: .destructive) {
                    Task { await delete(p) }
                } label: {
                    Label("Удалить пост", systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.danger.opacity(0.12))
                        .foregroundColor(Theme.danger)
                        .cornerRadius(12)
                }
            }
        }
    }

    @ViewBuilder
    private func historySection(_ items: [PostVersionItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("История изменений")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            DSCard(radius: Radius.lg, padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, v in
                        historyRow(v)
                        if idx < items.count - 1 {
                            Rectangle()
                                .fill(Theme.separator)
                                .frame(height: 0.5)
                                .padding(.leading, 14)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func historyRow(_ v: PostVersionItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundColor(Theme.accent)
                .frame(width: 22)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(v.editor?.displayName ?? "—")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(Theme.textPrimary)
                    Spacer(minLength: 4)
                    if let cs = v.createdAt, let d = ISO8601DateFormatter().date(from: cs) {
                        Text(relativeTime(from: d))
                            .font(.caption)
                            .foregroundColor(Theme.textTertiary)
                    }
                }
                let titleStr = (v.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let textStr  = (v.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let preview = !titleStr.isEmpty ? titleStr : textStr
                if !preview.isEmpty {
                    Text(preview)
                        .font(.caption)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Permissions

    private var canCreate: Bool { auth.currentUser?.hasPostingPermission("posting.create") ?? false }
    private var canUpdate: Bool { auth.currentUser?.hasPostingPermission("posting.update") ?? false }
    private var canDelete: Bool { auth.currentUser?.hasPostingPermission("posting.delete") ?? false }

    // MARK: Networking

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let p: SocialPostItem = try await APIClient.shared.get("posting/\(id)")
            self.post = p
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func loadVersions() async {
        // GET /posts/:id/versions — graceful skip on 404.
        do {
            let resp: PostVersionsResponse = try await APIClient.shared.get("posts/\(id)/versions")
            self.versions = resp.data
            self.versionsUnavailable = false
        } catch APIError.http(let status, _) where status == 404 {
            self.versions = []
            self.versionsUnavailable = true
        } catch {
            // Тихо игнорируем — наличие истории необязательно.
            self.versions = []
        }
    }

    private func publishNow(_ p: SocialPostItem) async {
        publishing = true
        defer { publishing = false }
        do {
            let updated: SocialPostItem = try await APIClient.shared.post("posting/\(p.id)/publish")
            self.post = updated
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func delete(_ p: SocialPostItem) async {
        do {
            try await APIClient.shared.delete("posting/\(p.id)")
            dismiss()
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}

// MARK: - Edit sheet

struct EditPostSheet: View {
    let post: SocialPostItem
    var onSaved: (SocialPostItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var scheduledAt: Date
    @State private var hasSchedule: Bool
    @State private var saving = false
    @State private var error: String?

    init(post: SocialPostItem, onSaved: @escaping (SocialPostItem) -> Void) {
        self.post = post
        self.onSaved = onSaved
        _text = State(initialValue: post.text)
        if let s = post.scheduledAt, let d = ISO8601DateFormatter().date(from: s) {
            _scheduledAt = State(initialValue: d)
            _hasSchedule = State(initialValue: true)
        } else {
            _scheduledAt = State(initialValue: Date().addingTimeInterval(3600))
            _hasSchedule = State(initialValue: false)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Текст") {
                    TextEditor(text: $text)
                        .frame(minHeight: 160)
                }
                Section {
                    Toggle("Запланировать", isOn: $hasSchedule)
                    if hasSchedule {
                        DatePicker("Когда",
                                   selection: $scheduledAt,
                                   in: Date()...,
                                   displayedComponents: [.date, .hourAndMinute])
                    }
                }
                if let err = error {
                    Section { Text(err).foregroundColor(Theme.danger).font(.footnote) }
                }
            }
            .navigationTitle("Редактирование")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if saving { ProgressView() } else { Text("Сохранить") }
                    }
                    .disabled(saving || text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private struct UpdateBody: Encodable {
        let text: String
        let scheduledAt: String?
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let scheduledIso: String? = hasSchedule
            ? ISO8601DateFormatter().string(from: scheduledAt)
            : nil
        let body = UpdateBody(text: text, scheduledAt: scheduledIso)
        do {
            let updated: SocialPostItem = try await APIClient.shared.patch("posting/\(post.id)", body: body)
            onSaved(updated)
            dismiss()
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}

// MARK: - Create sheet

struct CreatePostSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var text: String = ""
    @State private var selectedPlatforms: Set<String> = []
    @State private var hasSchedule: Bool = false
    @State private var scheduledAt: Date = Date().addingTimeInterval(3600)
    @State private var saving = false
    @State private var error: String?

    /// Прикреплённые медиа (фото/видео). Загружаются по presigned URL,
    /// бэк требует объекты `{kind, url, name?, mime?, size?}`
    /// (см. apps/api/src/modules/posting/dto/post.dto.ts PostAttachmentDto).
    @State private var attachments: [PostAttachment] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var uploading = false

    private let allPlatforms: [String] = ["vk", "telegram", "staya"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Текст") {
                    TextEditor(text: $text)
                        .frame(minHeight: 160)
                }

                Section {
                    if !attachments.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(attachments.enumerated()), id: \.offset) { idx, att in
                                    attachmentChip(att, index: idx)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    PhotosPicker(selection: $pickerItems,
                                 maxSelectionCount: 10,
                                 matching: .any(of: [.images, .videos])) {
                        HStack {
                            if uploading {
                                ProgressView().controlSize(.small)
                                Text("Загрузка медиа…")
                            } else {
                                Image(systemName: "paperclip")
                                Text(attachments.isEmpty ? "Добавить медиа" : "Добавить ещё")
                            }
                        }
                        .foregroundColor(Theme.accent)
                    }
                    .onChange(of: pickerItems) { items in
                        guard !items.isEmpty else { return }
                        Task { await uploadPicked(items) }
                    }
                } header: {
                    Text("Медиа")
                } footer: {
                    Text("Фото и видео будут опубликованы вместе с постом. Максимум 10 файлов.")
                        .font(.footnote)
                        .foregroundColor(Theme.textTertiary)
                }

                Section("Платформы") {
                    ForEach(allPlatforms, id: \.self) { p in
                        let info = platformIcon(p)
                        Button {
                            togglePlatform(p)
                        } label: {
                            HStack {
                                Image(systemName: info.icon)
                                    .foregroundColor(info.color)
                                    .frame(width: 24)
                                Text(info.label)
                                    .foregroundColor(Theme.textPrimary)
                                Spacer()
                                if selectedPlatforms.contains(p) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(Theme.accent)
                                }
                            }
                        }
                    }
                }

                Section {
                    Toggle("Запланировать публикацию", isOn: $hasSchedule)
                    if hasSchedule {
                        DatePicker("Когда",
                                   selection: $scheduledAt,
                                   in: Date()...,
                                   displayedComponents: [.date, .hourAndMinute])
                    }
                }

                if let err = error {
                    Section { Text(err).foregroundColor(Theme.danger).font(.footnote) }
                }
            }
            .navigationTitle("Новый пост")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            Task { await save(publishNow: false) }
                        } label: {
                            Label("Сохранить как черновик", systemImage: "doc.text")
                        }
                        Button {
                            Task { await save(publishNow: true) }
                        } label: {
                            Label(hasSchedule ? "Запланировать" : "Опубликовать",
                                  systemImage: hasSchedule ? "clock" : "paperplane.fill")
                        }
                        .disabled(selectedPlatforms.isEmpty)
                    } label: {
                        if saving { ProgressView() } else { Text("Готово").bold() }
                    }
                    .disabled(saving || uploading || text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private func attachmentChip(_ att: PostAttachment, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if att.kind == "image", let u = att.url, let url = URL(string: ensureAbsolute(u)) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img): img.resizable().scaledToFill()
                        default: Theme.surfaceBackground
                        }
                    }
                } else {
                    ZStack {
                        Theme.surfaceBackground
                        Image(systemName: att.kind == "video" ? "play.rectangle.fill" : "doc.fill")
                            .font(.title2)
                            .foregroundColor(Theme.textSecondary)
                    }
                }
            }
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Button {
                attachments.remove(at: index)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.white)
                    .background(Color.black.opacity(0.6))
                    .clipShape(Circle())
            }
            .padding(2)
        }
    }

    private func togglePlatform(_ p: String) {
        if selectedPlatforms.contains(p) { selectedPlatforms.remove(p) }
        else { selectedPlatforms.insert(p) }
    }

    private struct CreateBody: Encodable {
        let text: String
        let platforms: [String]
        let attachments: [PostAttachment]?
        let publishNow: Bool?
        let scheduledAt: String?
    }

    private func save(publishNow: Bool) async {
        saving = true
        error = nil
        defer { saving = false }

        let platforms = allPlatforms.filter { selectedPlatforms.contains($0) }
        let scheduledIso: String? = hasSchedule
            ? ISO8601DateFormatter().string(from: scheduledAt)
            : nil
        let body = CreateBody(
            text: text,
            platforms: platforms,
            attachments: attachments.isEmpty ? nil : attachments,
            publishNow: publishNow ? true : nil,
            scheduledAt: scheduledIso
        )

        do {
            let _: SocialPostItem = try await APIClient.shared.post("posting", body: body)
            dismiss()
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    // MARK: - Upload

    private struct UploadUrlReq: Encodable {
        let kind: String
        let filename: String
        let mime: String
        let size: Int
    }

    private struct UploadUrlResp: Decodable {
        let uploadUrl: String
        let fileUrl: String
    }

    /// Грузим выбранные фото/видео по presigned PUT-URL (см. CreateNewsSheet).
    private func uploadPicked(_ items: [PhotosPickerItem]) async {
        uploading = true
        defer {
            uploading = false
            pickerItems = []
        }
        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let isVideo = item.supportedContentTypes.contains(where: {
                    $0.conforms(to: .movie) || $0.conforms(to: .video)
                })
                let mime = isVideo ? "video/mp4" : "image/jpeg"
                let ext = isVideo ? "mp4" : "jpg"
                let kind: String = isVideo ? "video" : "image"
                let payload: Data
                if isVideo {
                    payload = data
                } else {
                    // Сжимаем фото (как в CreateNewsSheet) — экономим трафик.
                    payload = (UIImage(data: data)?.jpegData(compressionQuality: 0.85)) ?? data
                }
                let req = UploadUrlReq(
                    kind: "posting_attachment",
                    filename: "post-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).\(ext)",
                    mime: mime,
                    size: payload.count
                )
                let resp: UploadUrlResp = try await APIClient.shared.request(
                    "POST", "files/upload-url", body: req
                )
                guard let putURL = URL(string: resp.uploadUrl) else { continue }
                var put = URLRequest(url: putURL)
                put.httpMethod = "PUT"
                put.setValue(mime, forHTTPHeaderField: "Content-Type")
                let (_, response) = try await URLSession.shared.upload(for: put, from: payload)
                if let http = response as? HTTPURLResponse,
                   !(200...299).contains(http.statusCode) {
                    self.error = "Загрузка не удалась (\(http.statusCode))"
                    continue
                }
                attachments.append(PostAttachment(
                    kind: kind,
                    url: resp.fileUrl,
                    name: nil,
                    mime: mime,
                    size: payload.count
                ))
            } catch {
                self.error = apiUserMessage(error)
            }
        }
    }
}

// MARK: - Helpers

private func formatDateTime(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "ru_RU")
    f.dateStyle = .medium
    f.timeStyle = .short
    return f.string(from: date)
}

#Preview {
    NavigationStack { PostingView() }
        .environmentObject(AuthStore())
}
