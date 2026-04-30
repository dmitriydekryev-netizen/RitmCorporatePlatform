//
//  RossiGroupsModerationView.swift — модерация групп Rossi (Staya).
//
//  Бэкенд (apps/api/src/modules/admin-groups/admin-groups.controller.ts):
//   • GET    /admin/groups?search=&banned=&sort=&id=&limit=&offset=  → { groups: [...], total }
//   • GET    /admin/groups/:id/info                                  → инфо о группе
//   • GET    /admin/groups/:id/messages?limit=&before=               → последние сообщения
//   • DELETE /admin/groups/:id                                       — бан
//   • POST   /admin/groups/:id/unban                                 — разбан
//   • DELETE /admin/groups/:id/permanent                             — снос
//
//  Permission: groups.moderate.view (см. PERMISSIONS.GROUPS_MODERATE_VIEW).
//
//  Web-референс: apps/web/src/app/(app)/admin/groups/page.tsx
//                apps/web/src/app/(app)/admin/groups/[groupId]/page.tsx
//

import SwiftUI

// MARK: - Models

struct RossiModGroup: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let banned_at: String?
    let created_at: String?
    let members_count: Int?
}

private struct RossiModGroupsEnvelope: Codable {
    let groups: [RossiModGroup]?
    let total: Int?
}

// MARK: - View

struct RossiGroupsModerationView: View {
    @State private var groups: [RossiModGroup] = []
    @State private var totalCount: Int = 0
    @State private var search = ""
    @State private var bannedFilter: String = "all" // all | active | banned
    @State private var loading = true
    @State private var error: String?
    @State private var notAvailable = false

    private let webURL = URL(string: "https://rossihelp.ru/admin/groups")!

    var body: some View {
        ZStack {
            Theme.pageBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    DSPageTitle(text: "Группы Rossi",
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

                    if loading && groups.isEmpty {
                        ProgressView().tint(Theme.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    } else if notAvailable {
                        unavailableState
                    } else if let err = error, groups.isEmpty {
                        EmptyStateView(icon: "exclamationmark.triangle",
                                       title: "Ошибка",
                                       description: err)
                    } else if groups.isEmpty {
                        EmptyStateView(icon: "person.3",
                                       title: "Групп нет",
                                       description: search.isEmpty ? "Попробуйте обновить позже." : "По запросу ничего нет.")
                    } else {
                        DSSectionHeader("Список")
                        LazyVStack(spacing: 10) {
                            ForEach(groups) { group in
                                NavigationLink {
                                    RossiGroupModDetailView(groupId: group.id, fallbackTitle: group.title)
                                } label: {
                                    RossiModGroupCard(group: group)
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
        .navigationTitle("Группы Rossi")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Поиск групп…")
        .onSubmit(of: .search) { Task { await load() } }
        .onChange(of: search) { newValue in
            if newValue.isEmpty { Task { await load() } }
        }
        .refreshable { await load() }
        .task { if groups.isEmpty && !notAvailable { await load() } }
    }

    private var subtitleText: String? {
        if notAvailable { return nil }
        if loading && groups.isEmpty { return nil }
        if groups.isEmpty { return nil }
        let total = totalCount > 0 ? totalCount : groups.count
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
                           description: "Раздел модерации групп Rossi пока недоступен в приложении. Откройте его в веб-версии.")
            Link(destination: webURL) {
                HStack(spacing: 6) {
                    Image(systemName: "safari")
                    Text("Открыть в браузере")
                        .font(.dsBody.weight(.semibold))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Theme.purple.opacity(0.12))
                .foregroundColor(Theme.purple)
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
            let envelope: RossiModGroupsEnvelope = try await APIClient.shared.get("admin/groups", query: query)
            self.groups = envelope.groups ?? []
            self.totalCount = envelope.total ?? 0
            self.error = nil
            self.notAvailable = false
        } catch {
            if let apiErr = error as? APIError, case .http(let status, _) = apiErr, status == 404 {
                self.notAvailable = true
                self.groups = []
                return
            }
            self.error = apiUserMessage(error)
        }
    }
}

// MARK: - Card

private struct RossiModGroupCard: View {
    let group: RossiModGroup

    private var isBanned: Bool { (group.banned_at ?? "").isEmpty == false }

    var body: some View {
        DSCard(radius: Radius.lg, padding: 12) {
            HStack(spacing: 12) {
                DSIconTile(systemImage: "person.3.fill", color: Theme.purple, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(group.title.isEmpty ? "(без названия)" : group.title)
                            .font(.dsBodyLG.weight(.semibold))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                        if isBanned {
                            DSBadge(text: "забанена", color: Theme.danger, filled: true)
                        }
                    }
                    HStack(spacing: 10) {
                        if let count = group.members_count {
                            Label("\(count)", systemImage: "person.2.fill")
                                .font(.dsCaption)
                                .foregroundColor(Theme.textSecondary)
                        }
                        if let created = group.created_at {
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

// MARK: - Detail — функционал как в вебе (info + messages + ban/unban)

private struct GroupInfoModel: Decodable {
    let id: String
    let title: String?
    let banned_at: String?
    let created_at: String?
    let members_count: Int?
    let about: String?
    let avatar_ref: String?
}

private struct GroupMessage: Decodable, Identifiable {
    let id: String
    let chat_id: String?
    let sender_id: String?
    let text: String?
    let created_at: String?
    let media_kind: String?
    let media_ref: String?
    let sender_username: String?
    let sender_name: String?
    let sender_surname: String?
}

private struct GroupMessagesEnvelope: Decodable {
    let messages: [GroupMessage]?
    let no_access: Bool?
    let message: String?
}

struct RossiGroupModDetailView: View {
    let groupId: String
    let fallbackTitle: String

    @State private var info: GroupInfoModel?
    @State private var messages: [GroupMessage] = []
    @State private var noAccessReason: String?
    @State private var loading = true
    @State private var loadingMessages = false
    @State private var working = false
    @State private var error: String?
    @State private var statusInfo: String?

    @State private var showBanConfirm = false

    private var isBanned: Bool { (info?.banned_at ?? "").isEmpty == false }

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
                        messagesCard()
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
        .navigationTitle("Группа")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .alert("Забанить группу?",
               isPresented: $showBanConfirm) {
            Button("Отмена", role: .cancel) {}
            Button("Забанить", role: .destructive) { Task { await ban() } }
        } message: {
            Text("Группа будет скрыта от пользователей. Вы сможете её разбанить позже.")
        }
    }

    @ViewBuilder
    private func header(_ g: GroupInfoModel) -> some View {
        DSCard(radius: Radius.lg, padding: 14) {
            HStack(spacing: 14) {
                DSIconTile(systemImage: "person.3.fill", color: Theme.purple, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text((g.title ?? fallbackTitle).ifEmpty(or: "(без названия)"))
                            .font(.dsBodyLG.weight(.semibold))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(2)
                        if isBanned {
                            DSBadge(text: "забанена", color: Theme.danger, filled: true)
                        }
                    }
                    if let m = g.members_count {
                        Label("\(m) участников", systemImage: "person.2.fill")
                            .font(.dsCaption)
                            .foregroundColor(Theme.textSecondary)
                    }
                    if let c = g.created_at {
                        Text("Создана: " + String(c.prefix(10)))
                            .font(.dsCaption)
                            .foregroundColor(Theme.textTertiary)
                    }
                    if let a = g.about, !a.isEmpty {
                        Text(a).font(.dsCaption).foregroundColor(Theme.textSecondary)
                            .lineLimit(4)
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
    private func messagesCard() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                DSSectionHeader("Сообщения")
                Spacer()
                if loadingMessages { ProgressView().controlSize(.small) }
            }
            if let r = noAccessReason {
                DSCard(radius: Radius.md, padding: 10) {
                    Text(r).font(.dsCaption).foregroundColor(Theme.textSecondary)
                }
            } else if messages.isEmpty {
                DSCard(radius: Radius.md, padding: 10) {
                    Text(loadingMessages ? "Загрузка…" : "Нет сообщений")
                        .font(.dsCaption).foregroundColor(Theme.textTertiary)
                }
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(messages) { m in
                        messageRow(m)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ m: GroupMessage) -> some View {
        DSCard(radius: Radius.md, padding: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(senderName(m))
                        .font(.dsCaption.weight(.semibold))
                        .foregroundColor(Theme.textPrimary)
                    if let c = m.created_at {
                        Text(c.prefix(16))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Theme.textTertiary)
                    }
                }
                if let t = m.text, !t.isEmpty {
                    Text(t).font(.dsCaption).foregroundColor(Theme.textPrimary)
                }
                if let kind = m.media_kind {
                    Label("Медиа: \(kind)", systemImage: "paperclip")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)
                }
            }
        }
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

    private func senderName(_ m: GroupMessage) -> String {
        let combo = "\(m.sender_name ?? "") \(m.sender_surname ?? "")"
            .trimmingCharacters(in: .whitespaces)
        if !combo.isEmpty { return combo }
        return m.sender_username ?? (m.sender_id?.prefix(8).description ?? "—")
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            self.info = try await APIClient.shared.get("admin/groups/\(groupId)/info")
            self.error = nil
            await loadMessages()
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func loadMessages() async {
        loadingMessages = true
        defer { loadingMessages = false }
        do {
            // Ответ может прийти и envelope’ом, и плоским массивом — пробуем оба.
            if let env: GroupMessagesEnvelope = try? await APIClient.shared.get(
                "admin/groups/\(groupId)/messages", query: ["limit": "100"]
            ), let arr = env.messages {
                self.messages = arr
                self.noAccessReason = nil
            } else if let arr: [GroupMessage] = try? await APIClient.shared.get(
                "admin/groups/\(groupId)/messages", query: ["limit": "100"]
            ) {
                self.messages = arr
                self.noAccessReason = nil
            }
        } catch let APIError.http(_, body) {
            // Если бэк ответил кодом NO_ACCESS — показываем подсказку.
            self.noAccessReason = body ?? "Нет доступа к сообщениям"
        } catch {
            self.noAccessReason = apiUserMessage(error)
        }
    }

    private func ban() async {
        working = true; defer { working = false }
        do {
            try await APIClient.shared.delete("admin/groups/\(groupId)")
            statusInfo = "Группа забанена"
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
                "POST", "admin/groups/\(groupId)/unban", body: Empty()
            )
            statusInfo = "Группа разбанена"
            await load()
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}

#Preview {
    NavigationStack { RossiGroupsModerationView() }
        .environmentObject(AuthStore())
}
