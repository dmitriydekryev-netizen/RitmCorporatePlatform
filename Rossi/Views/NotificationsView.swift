//
//  NotificationsView.swift — экран уведомлений.
//  GET /notifications, POST /notifications/:id/read
//

import SwiftUI

struct NotificationsListResponse: Codable {
    let data: [NotificationItem]
    let meta: PaginationMeta?
}

struct NotificationItem: Codable, Identifiable {
    let id: String
    /// Сервер шлёт `type` (см. apps/api/src/modules/notifications/...).
    /// В коде используется `kind` — маппим через CodingKeys.
    let kind: String
    let title: String
    let body: String?
    let url: String?
    /// Сервер шлёт `isRead` — маппим в `read`.
    let read: Bool?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, title, body, url, createdAt
        case kind = "type"
        case read = "isRead"
    }

    var iconName: String {
        switch kind {
        case "kudos.received":     return "heart.fill"
        case "task.assigned":      return "checkmark.circle.fill"
        case "task.completed":     return "checkmark.seal.fill"
        case "news.published":     return "newspaper.fill"
        case "schedule.approved":  return "calendar.badge.checkmark"
        case "schedule.rejected":  return "calendar.badge.exclamationmark"
        case "feedback.replied":   return "lightbulb.fill"
        case "achievement.granted":return "trophy.fill"
        case "chat.message":       return "message.fill"
        case "support.message":    return "lifepreserver.fill"
        default:                   return "bell.fill"
        }
    }

    var iconColor: Color {
        switch kind {
        case "kudos.received":     return Theme.pink
        case "task.assigned":      return Theme.accent
        case "task.completed":     return Theme.success
        case "news.published":     return Theme.purple
        case "schedule.approved":  return Theme.success
        case "schedule.rejected":  return Theme.danger
        case "achievement.granted":return Theme.warning
        case "chat.message":       return Theme.info
        case "feedback.replied":   return Theme.warning
        default:                   return Theme.textSecondary
        }
    }
}

enum NotificationsTab: String, CaseIterable, Identifiable {
    case all
    case unread
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "Все"
        case .unread: return "Непрочитанные"
        }
    }
}

struct NotificationsView: View {
    @State private var items: [NotificationItem] = []
    @State private var loading = true
    @State private var error: String?
    @State private var selectedTab: NotificationsTab = .all

    /// Confirm-alert «Очистить всё».
    @State private var showClearAllConfirm = false
    @State private var clearingAll = false

    /// Список с применённым фильтром по табу.
    private var filteredItems: [NotificationItem] {
        switch selectedTab {
        case .all:    return items
        case .unread: return items.filter { $0.read != true }
        }
    }

    /// Группировка по дате для секций.
    private var groupedByDay: [(String, [NotificationItem])] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        let weekAgo = cal.date(byAdding: .day, value: -7, to: today)!

        let dict = Dictionary(grouping: filteredItems) { item -> String in
            guard let d = ISO8601DateFormatter().date(from: item.createdAt) else { return "Раньше" }
            if d >= today { return "Сегодня" }
            if d >= yesterday { return "Вчера" }
            if d >= weekAgo { return "На этой неделе" }
            return "Раньше"
        }
        let order = ["Сегодня", "Вчера", "На этой неделе", "Раньше"]
        return order.compactMap { key in
            guard let arr = dict[key], !arr.isEmpty else { return nil }
            return (key, arr.sorted { $0.createdAt > $1.createdAt })
        }
    }

    private var unreadCount: Int {
        items.filter { $0.read != true }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Заголовок + бейдж непрочитанных
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 10) {
                    DSPageTitle(text: "Уведомления", subtitle: pageSubtitle)
                    if unreadCount > 0 {
                        DSBadge(text: "\(unreadCount)", color: Theme.accent, filled: true)
                            .padding(.top, 6)
                    }
                }
                .padding(.top, 4)

                // Табы All / Unread
                if !items.isEmpty {
                    Picker("", selection: $selectedTab) {
                        ForEach(NotificationsTab.allCases) { tab in
                            Text(tabLabel(tab)).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            if loading && items.isEmpty {
                ProgressView()
                    .tint(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                Spacer()
            } else if items.isEmpty {
                ScrollView {
                    EmptyStateView(
                        icon: "bell.slash",
                        title: "Пусто",
                        description: error ?? "Здесь будут уведомления о задачах, kudos, новостях"
                    )
                    .padding(.top, 40)
                }
                .refreshable { await load() }
            } else if filteredItems.isEmpty {
                ScrollView {
                    EmptyStateView(
                        icon: "checkmark.circle",
                        title: "Всё прочитано",
                        description: "Нет непрочитанных уведомлений"
                    )
                    .padding(.top, 40)
                }
                .refreshable { await load() }
            } else {
                List {
                    ForEach(groupedByDay, id: \.0) { (section, list) in
                        Section {
                            ForEach(list) { item in
                                NotificationCard(
                                    item: item,
                                    onTap: { handleTap(item) },
                                    onMarkRead: { Task { await markRead(item.id) } }
                                )
                                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        Task { await deleteOne(id: item.id) }
                                    } label: {
                                        Label("Удалить", systemImage: "trash")
                                    }
                                }
                            }
                        } header: {
                            DSSectionHeader(section)
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
                                .textCase(nil)
                        }
                    }
                    Color.clear
                        .frame(height: TabBarVisibility.reservedHeight)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .refreshable { await load() }
            }
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("Уведомления")
        .navigationBarTitleDisplayMode(.inline)
        // ВАЖНО: НЕ скрываем navigation bar (.toolbar(.hidden, ...) убран),
        // иначе пропадает кнопка «Назад». Заголовок и счётчик показываем
        // как часть контента ниже (DSPageTitle), а в навбар выносим действия.
        .toolbar {
            if items.contains(where: { $0.read != true }) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await markAllRead() }
                    } label: {
                        Label("Всё прочитано", systemImage: "checkmark.circle")
                    }
                    .font(.subheadline)
                }
            }
            if !items.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        showClearAllConfirm = true
                    } label: {
                        Image(systemName: "trash.circle.fill")
                            .foregroundColor(Theme.danger)
                    }
                }
            }
        }
        .task { if items.isEmpty { await load() } }
        .alert("Удалить все уведомления?", isPresented: $showClearAllConfirm) {
            Button("Отмена", role: .cancel) {}
            Button("Удалить", role: .destructive) {
                Task { await clearAll() }
            }
        } message: {
            Text("Это действие нельзя отменить.")
        }
    }

    private var pageSubtitle: String? {
        if items.isEmpty { return nil }
        if unreadCount == 0 { return "Все прочитаны" }
        return "\(unreadCount) непрочитанных"
    }

    private func tabLabel(_ tab: NotificationsTab) -> String {
        switch tab {
        case .all:
            return "\(tab.title) (\(items.count))"
        case .unread:
            return unreadCount > 0 ? "\(tab.title) (\(unreadCount))" : tab.title
        }
    }

    private func handleTap(_ item: NotificationItem) {
        if item.read != true {
            Task { await markRead(item.id) }
        }
        if let urlStr = item.url, let url = URL(string: urlStr.hasPrefix("/") ? "https://rossihelp.ru\(urlStr)" : urlStr) {
            UIApplication.shared.open(url)
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let resp: NotificationsListResponse = try await APIClient.shared.get("notifications", query: ["limit": "50"])
            // Фильтруем те, которые юзер уже «удалил» локально (см. dismissLocally).
            let dismissed = dismissedIds()
            items = resp.data.filter { !dismissed.contains($0.id) }
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    /// Сервер: POST /notifications/read body { ids: string[] }
    /// (см. apps/api/src/modules/notifications/notifications.controller.ts)
    private struct MarkReadBody: Encodable { let ids: [String] }

    private func markRead(_ id: String) async {
        do {
            _ = try await APIClient.shared.rawRequest(
                "POST", "notifications/read",
                body: MarkReadBody(ids: [id])
            )
            if let i = items.firstIndex(where: { $0.id == id }) {
                items[i] = patch(items[i], read: true)
            }
        } catch {}
    }

    private func markAllRead() async {
        let unreadIds = items.filter { $0.read != true }.map { $0.id }
        guard !unreadIds.isEmpty else { return }
        do {
            _ = try await APIClient.shared.rawRequest(
                "POST", "notifications/read",
                body: MarkReadBody(ids: unreadIds)
            )
            items = items.map { patch($0, read: true) }
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func patch(_ item: NotificationItem, read: Bool) -> NotificationItem {
        NotificationItem(id: item.id, kind: item.kind, title: item.title,
                         body: item.body, url: item.url, read: read, createdAt: item.createdAt)
    }

    /// На бэке пока нет DELETE-эндпоинта (см. notifications.controller.ts:
    /// доступны только GET, POST /read, GET /unread-count, GET/POST/PATCH /settings).
    /// Чтобы «удаление» работало для пользователя, скрываем уведомление локально
    /// (в UserDefaults храним dismissed-id) и помечаем его прочитанным на сервере,
    /// чтобы оно не висело в счётчике непрочитанных. После рефреша оно сюда
    /// больше не вернётся (отфильтруется).
    private static let dismissedDefaultsKey = "rossi.notifications.dismissed"

    private func dismissedIds() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.dismissedDefaultsKey) ?? [])
    }

    private func saveDismissed(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids), forKey: Self.dismissedDefaultsKey)
    }

    private func dismissLocally(ids: [String]) async {
        var stored = dismissedIds()
        stored.formUnion(ids)
        saveDismissed(stored)
        // Параллельно отмечаем прочитанным на сервере (тихо, не падаем при ошибке).
        do {
            _ = try await APIClient.shared.rawRequest(
                "POST", "notifications/read",
                body: MarkReadBody(ids: ids)
            )
        } catch {
            // ignore
        }
    }

    /// Swipe-to-delete одного уведомления — серверный DELETE отсутствует,
    /// поэтому скрываем локально + mark as read.
    private func deleteOne(id: String) async {
        // Optimistic UI
        await MainActor.run {
            withAnimation { items.removeAll { $0.id == id } }
        }
        await dismissLocally(ids: [id])
    }

    /// «Очистить всё» — локальное скрытие + mark all as read.
    private func clearAll() async {
        guard !items.isEmpty else { return }
        clearingAll = true
        defer { clearingAll = false }

        let ids = items.map { $0.id }
        await MainActor.run {
            withAnimation { items = [] }
        }
        await dismissLocally(ids: ids)
    }
}

/// Карточный дизайн уведомления — стиль веба, DSCard + DSIconTile.
struct NotificationCard: View {
    let item: NotificationItem
    let onTap: () -> Void
    let onMarkRead: () -> Void

    private var unread: Bool { item.read != true }

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .topTrailing) {
                HStack(alignment: .top, spacing: 12) {
                    DSIconTile(systemImage: item.iconName, color: item.iconColor, size: 40)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.dsH3)
                            .fontWeight(unread ? .semibold : .medium)
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let b = item.body, !b.isEmpty {
                            Text(b)
                                .font(.dsBodySM)
                                .foregroundColor(Theme.textSecondary)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        HStack(spacing: 6) {
                            if let d = ISO8601DateFormatter().date(from: item.createdAt) {
                                Text(relativeTime(from: d))
                                    .font(.dsCaption)
                                    .foregroundColor(Theme.textTertiary)
                            }
                            Spacer()
                            if item.url != nil {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(Theme.textTertiary)
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surfaceBackground)
                .clipShape(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                        .strokeBorder(unread ? Theme.accent.opacity(0.3) : Theme.border,
                                      lineWidth: unread ? 1.2 : 0.5)
                )
                .dsCardShadow()

                if unread {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 8, height: 8)
                        .padding(10)
                }
            }
        }
        .buttonStyle(DSPressScaleStyle())
        .contextMenu {
            if unread {
                Button { onMarkRead() } label: {
                    Label("Отметить прочитанным", systemImage: "checkmark.circle")
                }
            }
        }
    }
}
