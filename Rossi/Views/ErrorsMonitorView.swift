//
//  ErrorsMonitorView.swift — мониторинг серверных и клиентских ошибок (admin).
//
//  Endpoint: GET /errors?resolved=&source=&search=&page=&pageSize=
//    Resp:   { data: ErrorEvent[], meta: { page, pageSize, total, totalPages, unresolvedTotal } }
//
//  Действия:
//   • POST /errors/:id/resolve   — отметить решённой (нужен ADMIN_ERRORS_MANAGE)
//
//  UI:
//   • Сегментированный picker «Не разрешённые / Все»
//   • Карточки с цветом-точкой по level, message, source, count, lastSeenAt
//   • Тап → детальный экран со stack-trace, url, user-agent, metadata
//   • Pull-to-refresh
//

import SwiftUI

// MARK: - Models (соответствуют реальной форме ответа /errors)

struct ErrorEvent: Codable, Identifiable, Hashable {
    let id: String
    let fingerprint: String?
    let level: String?            // "error" | "warn" | "fatal"
    let source: String?           // "api" | "web"
    let message: String
    let stack: String?
    let url: String?
    let userAgent: String?
    let userId: String?
    let metadata: JSONValue?
    let count: Int?
    let firstSeenAt: String?
    let lastSeenAt: String?
    let resolvedAt: String?
    let resolvedById: String?

    var isResolved: Bool { resolvedAt != nil }

    var lastSeenDate: Date? {
        lastSeenAt.flatMap { ErrorEvent.iso.date(from: $0) }
    }
    var firstSeenDate: Date? {
        firstSeenAt.flatMap { ErrorEvent.iso.date(from: $0) }
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

struct ErrorsListResponse: Codable {
    struct Meta: Codable {
        let page: Int?
        let pageSize: Int?
        let total: Int?
        let totalPages: Int?
        let unresolvedTotal: Int?
    }
    let data: [ErrorEvent]
    let meta: Meta?
}

// MARK: - View

struct ErrorsMonitorView: View {
    @EnvironmentObject var auth: AuthStore

    enum Filter: String, CaseIterable, Identifiable {
        case unresolved
        case all
        var id: String { rawValue }
        var label: String {
            switch self {
            case .unresolved: return "Не разрешённые"
            case .all:        return "Все"
            }
        }
    }

    enum SeverityFilter: String, CaseIterable, Identifiable {
        case all
        case error
        case warning
        case info

        var id: String { rawValue }
        var label: String {
            switch self {
            case .all:     return "Все"
            case .error:   return "Error"
            case .warning: return "Warning"
            case .info:    return "Info / Fatal"
            }
        }
        var icon: String {
            switch self {
            case .all:     return "line.3.horizontal.decrease.circle"
            case .error:   return "exclamationmark.triangle.fill"
            case .warning: return "exclamationmark.circle.fill"
            case .info:    return "info.circle.fill"
            }
        }
        var tint: Color {
            switch self {
            case .all:     return Theme.textSecondary
            case .error:   return Theme.danger
            case .warning: return Theme.warning
            case .info:    return Theme.info
            }
        }
        /// Список значений `level`, попадающих в этот фильтр.
        func matches(_ level: String?) -> Bool {
            let lvl = (level ?? "").lowercased()
            switch self {
            case .all:     return true
            case .error:   return lvl == "error"
            case .warning: return lvl == "warn" || lvl == "warning"
            case .info:    return lvl == "info" || lvl == "fatal"
            }
        }
    }

    @State private var items: [ErrorEvent] = []
    @State private var unresolvedTotal: Int?
    @State private var loading = true
    @State private var loadError: String?
    @State private var filter: Filter = .unresolved
    @State private var severity: SeverityFilter = .all

    private var visibleItems: [ErrorEvent] {
        guard severity != .all else { return items }
        return items.filter { severity.matches($0.level) }
    }

    /// Имеет ли пользователь право Resolve. Бэк требует ADMIN_ERRORS_MANAGE,
    /// но «*» (superadmin) тоже подходит.
    private var canResolve: Bool {
        guard let perms = auth.currentUser?.permissions else { return false }
        return perms.contains("*")
            || perms.contains("admin.errors.manage")
            || perms.contains("admin:errors:manage")
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                DSPageTitle(text: "Ошибки", subtitle: "Мониторинг сбоев API и web")
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases) { f in
                        Text(f.label).tag(f)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .onChange(of: filter) { _ in
                Task { await load() }
            }

            content
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 8) {
                    if let n = unresolvedTotal, n > 0 {
                        Text("\(n)")
                            .font(.caption.weight(.bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Theme.danger)
                            .clipShape(Capsule())
                    }
                    Menu {
                        Picker("Severity", selection: $severity) {
                            ForEach(SeverityFilter.allCases) { sf in
                                Label(sf.label, systemImage: sf.icon).tag(sf)
                            }
                        }
                    } label: {
                        Image(systemName: severity == .all
                              ? "line.3.horizontal.decrease.circle"
                              : severity.icon)
                            .foregroundColor(severity == .all ? Theme.accent : severity.tint)
                    }
                }
            }
        }
        .refreshable { await load() }
        .task { if items.isEmpty { await load() } }
    }

    @ViewBuilder
    private var content: some View {
        if loading && items.isEmpty {
            VStack {
                ProgressView()
                    .padding(.top, 80)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = loadError, items.isEmpty {
            EmptyStateView(
                icon: "exclamationmark.triangle",
                title: "Не удалось загрузить",
                description: err
            )
        } else if visibleItems.isEmpty {
            EmptyStateView(
                icon: "checkmark.seal.fill",
                title: severity != .all
                    ? "Нет ошибок этого уровня"
                    : (filter == .unresolved
                        ? "Ничего не сломалось"
                        : "Журнал ошибок пуст"),
                description: severity != .all
                    ? "Попробуйте сменить фильтр severity"
                    : (filter == .unresolved
                        ? "Все известные ошибки помечены решёнными"
                        : nil)
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(visibleItems) { ev in
                        NavigationLink {
                            ErrorDetailView(
                                event: ev,
                                canResolve: canResolve,
                                onResolved: { resolvedId in
                                    handleResolved(id: resolvedId)
                                }
                            )
                        } label: {
                            ErrorRow(event: ev)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
        }
    }

    // MARK: - Actions

    private func handleResolved(id: String) {
        // На фильтре «не разрешённые» уберём из списка; на «все» — отметим resolved.
        if filter == .unresolved {
            items.removeAll { $0.id == id }
        }
        if let n = unresolvedTotal { unresolvedTotal = max(0, n - 1) }
        Task { await load() }
    }

    // MARK: - Network

    private func load() async {
        loading = true
        loadError = nil
        defer { loading = false }
        var query: [String: String] = ["pageSize": "50"]
        if filter == .unresolved { query["resolved"] = "false" }
        do {
            let resp: ErrorsListResponse = try await APIClient.shared.get(
                "errors", query: query
            )
            self.items = resp.data
            self.unresolvedTotal = resp.meta?.unresolvedTotal
        } catch {
            self.loadError = apiUserMessage(error)
        }
    }
}

// MARK: - Row

private struct ErrorRow: View {
    let event: ErrorEvent

    var body: some View {
        DSCard(radius: Radius.lg, padding: 14) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(levelColor(event.level))
                    .frame(width: 10, height: 10)
                    .padding(.top, 6)

                VStack(alignment: .leading, spacing: 6) {
                    Text(event.message)
                        .font(.dsBodySM.weight(.semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 6) {
                        if let s = event.source, !s.isEmpty {
                            Text(s)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)
                        }
                        if let l = event.level, !l.isEmpty {
                            DSBadge(text: l.uppercased(), color: levelColor(l))
                        }
                        if let c = event.count, c > 1 {
                            DSBadge(text: "×\(c)", systemImage: "repeat", color: Theme.textSecondary)
                        }
                        Spacer(minLength: 4)
                        if event.isResolved {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.success)
                        }
                    }

                    HStack(spacing: 6) {
                        if let last = event.lastSeenDate {
                            Text("посл. \(relativeTime(from: last))")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textSecondary)
                        }
                        if let first = event.firstSeenDate, let last = event.lastSeenDate,
                           abs(first.timeIntervalSince(last)) > 60 {
                            Text("·")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textTertiary)
                            Text("впервые \(relativeTime(from: first))")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textTertiary)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Detail

struct ErrorDetailView: View {
    let event: ErrorEvent
    let canResolve: Bool
    let onResolved: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var resolving = false
    @State private var resolveError: String?
    @State private var locallyResolved = false

    private var isResolved: Bool { event.isResolved || locallyResolved }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let err = resolveError {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(Theme.danger)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.danger.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                section("Сообщение") {
                    DSCard(radius: Radius.md, padding: 12) {
                        Text(event.message)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(Theme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }

                if let stack = event.stack, !stack.isEmpty {
                    section("Stack trace") {
                        DSCard(radius: Radius.md, padding: 0) {
                            ScrollView(.horizontal, showsIndicators: true) {
                                Text(stack)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(Theme.textPrimary)
                                    .padding(12)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }

                section("Контекст") {
                    DSCard(radius: Radius.md, padding: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            kv("Fingerprint", event.fingerprint?.prefix(16).appending("…") ?? "—")
                            kv("Source",      event.source ?? "—")
                            kv("Level",       event.level ?? "—")
                            kv("Count",       event.count.map(String.init) ?? "—")
                            kv("URL",         event.url ?? "—")
                            kv("User-Agent",  event.userAgent ?? "—")
                            kv("User ID",     event.userId ?? "—")
                            kv("Впервые",     event.firstSeenDate.map { Self.fullDate.string(from: $0) } ?? (event.firstSeenAt ?? "—"))
                            kv("Последний",   event.lastSeenDate.map { Self.fullDate.string(from: $0) } ?? (event.lastSeenAt ?? "—"))
                            if let r = event.resolvedAt {
                                kv("Resolved", r)
                            }
                        }
                    }
                }

                if let m = event.metadata, !m.isEmpty {
                    section("Metadata") {
                        DSCard(radius: Radius.md, padding: 12) {
                            Text(m.prettyString())
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Theme.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }

                if canResolve && !isResolved {
                    Button(action: resolve) {
                        HStack(spacing: 8) {
                            if resolving {
                                ProgressView().tint(.white).scaleEffect(0.85)
                            } else {
                                Image(systemName: "checkmark.seal.fill")
                            }
                            Text(resolving ? "Отмечаем…" : "Отметить решённой")
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundColor(.white)
                        .background(Theme.danger)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                        .shadow(color: Theme.danger.opacity(0.35), radius: 14, x: 0, y: 4)
                    }
                    .disabled(resolving)
                    .buttonStyle(DSPressScaleStyle())
                }
            }
            .padding(16)
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("Ошибка")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(levelColor(event.level))
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text((event.level ?? "error").uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundColor(levelColor(event.level))
                if isResolved {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption2)
                        Text("Решена")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundColor(Theme.success)
                }
            }
            Spacer()
            if let c = event.count, c > 1 {
                HStack(spacing: 4) {
                    Image(systemName: "repeat").font(.caption2)
                    Text("\(c)").font(.caption.weight(.semibold))
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Theme.surfaceBackground)
                .clipShape(Capsule())
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    @ViewBuilder
    private func kv(_ key: String, _ val: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(val)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private func resolve() {
        resolveError = nil
        resolving = true
        Task {
            defer { Task { @MainActor in self.resolving = false } }
            do {
                _ = try await APIClient.shared.rawRequest("POST", "errors/\(event.id)/resolve")
                await MainActor.run {
                    self.locallyResolved = true
                    self.onResolved(event.id)
                    self.dismiss()
                }
            } catch {
                let msg = apiUserMessage(error)
                await MainActor.run { self.resolveError = msg }
            }
        }
    }

    private static let fullDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "dd.MM.yyyy HH:mm:ss"
        return f
    }()
}

// MARK: - Helpers

/// Цветовое кодирование level.
fileprivate func levelColor(_ level: String?) -> Color {
    switch (level ?? "").lowercased() {
    case "warn", "warning": return Theme.warning
    case "fatal":           return Color.red
    case "error":           return Theme.danger
    default:                return .secondary
    }
}

#Preview {
    NavigationStack { ErrorsMonitorView() }
        .environmentObject(AuthStore())
}
