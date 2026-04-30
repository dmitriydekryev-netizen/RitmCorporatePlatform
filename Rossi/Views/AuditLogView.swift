//
//  AuditLogView.swift — read-only список аудит-событий для администраторов.
//
//  Endpoint: GET /admin/audit
//    Query: actorId, action, entityType, from, to, page, limit
//    Resp:  { data: AuditEntry[], meta: { total, page, limit } }
//
//  Особенности:
//   • Группировка по дате (Сегодня / Вчера / Раньше)
//   • .searchable — фильтр по action
//   • Pull-to-refresh
//   • Тап → expandable с pretty-printed JSON metadata
//

import SwiftUI

// MARK: - Models (соответствуют реальной форме ответа API)

struct AuditActor: Codable, Hashable {
    let id: String
    let username: String?
    let firstName: String?
    let lastName: String?
    let avatarUrl: String?

    var displayName: String {
        let s = "\(firstName ?? "") \(lastName ?? "")".trimmingCharacters(in: .whitespaces)
        return s.ifEmpty(or: username ?? "")
    }
}

struct AuditEntry: Codable, Identifiable, Hashable {
    let id: String
    let action: String
    let entityType: String?
    let entityId: String?
    let ip: String?
    /// meta может быть произвольным JSON-объектом — используем JSONValue
    let meta: JSONValue?
    let createdAt: String
    let actor: AuditActor?

    var date: Date? {
        AuditEntry.isoFormatter.date(from: createdAt)
    }

    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

struct AuditListResponse: Codable {
    let data: [AuditEntry]
    let meta: PaginationMeta?
}

/// Универсальный JSON-контейнер: число / строка / bool / массив / объект / null.
/// Нужен потому что meta — произвольный объект, и Codable его иначе не съест.
enum JSONValue: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self)   { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "Не удалось распознать JSON-значение"
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:        try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a):  try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// Pretty-printed строковое представление — показываем в детальной карточке.
    func prettyString() -> String {
        let raw: Any = self.toAny()
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(
                withJSONObject: raw,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ),
              let s = String(data: data, encoding: .utf8) else {
            return String(describing: raw)
        }
        return s
    }

    fileprivate func toAny() -> Any {
        switch self {
        case .null:          return NSNull()
        case .bool(let b):   return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a):  return a.map { $0.toAny() }
        case .object(let o): return o.mapValues { $0.toAny() }
        }
    }

    var isEmpty: Bool {
        switch self {
        case .null:          return true
        case .object(let o): return o.isEmpty
        case .array(let a):  return a.isEmpty
        default:             return false
        }
    }
}

// MARK: - Filter enums

enum AuditEntityFilter: String, CaseIterable, Identifiable {
    case all, user, chat, news, task, bug, kudos, notification

    var id: String { rawValue }
    var label: String {
        switch self {
        case .all:          return "Все"
        case .user:         return "Пользователи"
        case .chat:         return "Чаты"
        case .news:         return "Новости"
        case .task:         return "Задачи"
        case .bug:          return "Баги"
        case .kudos:        return "Награды"
        case .notification: return "Уведомления"
        }
    }
    /// nil — без параметра, иначе value query-параметра entityType
    var queryValue: String? { self == .all ? nil : rawValue }
}

enum AuditActionFilter: String, CaseIterable, Identifiable {
    case all, create, update, delete, login

    var id: String { rawValue }
    var label: String {
        switch self {
        case .all:    return "Все"
        case .create: return "Создание"
        case .update: return "Изменение"
        case .delete: return "Удаление"
        case .login:  return "Логин"
        }
    }
    var queryValue: String? { self == .all ? nil : rawValue }
}

// MARK: - View

struct AuditLogView: View {
    @State private var entries: [AuditEntry] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var search = ""
    @State private var expandedId: String?

    // MARK: - Filters
    @State private var entityTypeFilter: AuditEntityFilter = .all
    @State private var actionFilter: AuditActionFilter = .all
    @State private var fromDate: Date? = nil
    @State private var toDate: Date? = nil
    @State private var datePickerPresented = false

    private let pageLimit = 100

    private var filtered: [AuditEntry] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter { e in
            e.action.lowercased().contains(q) ||
            (e.entityType?.lowercased().contains(q) ?? false) ||
            (e.actor?.displayName.lowercased().contains(q) ?? false) ||
            (e.actor?.username?.lowercased().contains(q) ?? false)
        }
    }

    /// Группируем уже отсортированный с сервера список (по убыванию createdAt)
    /// в три бакета: «Сегодня», «Вчера», «Раньше» — порядок сохраняется.
    private var grouped: [(label: String, items: [AuditEntry])] {
        var today: [AuditEntry] = []
        var yesterday: [AuditEntry] = []
        var earlier: [AuditEntry] = []
        let cal = Calendar.current
        for e in filtered {
            guard let d = e.date else { earlier.append(e); continue }
            if cal.isDateInToday(d) { today.append(e) }
            else if cal.isDateInYesterday(d) { yesterday.append(e) }
            else { earlier.append(e) }
        }
        var out: [(String, [AuditEntry])] = []
        if !today.isEmpty     { out.append(("Сегодня", today)) }
        if !yesterday.isEmpty { out.append(("Вчера", yesterday)) }
        if !earlier.isEmpty   { out.append(("Раньше", earlier)) }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                DSPageTitle(text: "Аудит", subtitle: "Журнал действий администраторов")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(Theme.pageBackground)

            filterBar
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .background(Theme.pageBackground)

            Group {
                if loading && entries.isEmpty {
                    loadingView
                } else if let err = loadError, entries.isEmpty {
                    EmptyStateView(
                        icon: "exclamationmark.triangle",
                        title: "Не удалось загрузить",
                        description: err
                    )
                } else if filtered.isEmpty {
                    EmptyStateView(
                        icon: "doc.text.magnifyingglass",
                        title: search.isEmpty ? "Записей нет" : "Ничего не найдено",
                        description: search.isEmpty
                            ? "Аудит-лог пуст или фильтр слишком узкий"
                            : "Попробуйте другой запрос"
                    )
                } else {
                    listView
                }
            }
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Фильтр по action / актору")
        .refreshable { await load() }
        .task { if entries.isEmpty { await load() } }
    }

    @ViewBuilder
    private var listView: some View {
        ScrollView {
            LazyVStack(spacing: 14, pinnedViews: []) {
                ForEach(grouped, id: \.label) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        DSSectionHeader(group.label)
                            .padding(.horizontal, 4)
                        VStack(spacing: 8) {
                            ForEach(group.items) { entry in
                                AuditRowView(
                                    entry: entry,
                                    expanded: expandedId == entry.id
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        expandedId = (expandedId == entry.id) ? nil : entry.id
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var loadingView: some View {
        VStack {
            ProgressView()
                .padding(.top, 80)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Network

    private func load() async {
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            var query: [String: String] = ["limit": "\(pageLimit)"]
            if let v = entityTypeFilter.queryValue { query["entityType"] = v }
            if let v = actionFilter.queryValue     { query["action"]     = v }
            if let f = fromDate { query["from"] = Self.dateOnlyFormatter.string(from: f) }
            if let t = toDate   { query["to"]   = Self.dateOnlyFormatter.string(from: t) }

            let resp: AuditListResponse = try await APIClient.shared.get(
                "admin/audit",
                query: query
            )
            self.entries = resp.data
        } catch {
            self.loadError = apiUserMessage(error)
        }
    }

    private static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    // MARK: - Filter bar

    private var hasActiveFilters: Bool {
        entityTypeFilter != .all ||
        actionFilter != .all ||
        fromDate != nil ||
        toDate != nil
    }

    @ViewBuilder
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(AuditEntityFilter.allCases) { opt in
                        Button {
                            entityTypeFilter = opt
                            Task { await load() }
                        } label: {
                            if opt == entityTypeFilter {
                                Label(opt.label, systemImage: "checkmark")
                            } else {
                                Text(opt.label)
                            }
                        }
                    }
                } label: {
                    AuditFilterChip(
                        title: entityTypeFilter == .all ? "Объект" : entityTypeFilter.label,
                        systemImage: "square.grid.2x2",
                        active: entityTypeFilter != .all
                    )
                }

                Menu {
                    ForEach(AuditActionFilter.allCases) { opt in
                        Button {
                            actionFilter = opt
                            Task { await load() }
                        } label: {
                            if opt == actionFilter {
                                Label(opt.label, systemImage: "checkmark")
                            } else {
                                Text(opt.label)
                            }
                        }
                    }
                } label: {
                    AuditFilterChip(
                        title: actionFilter == .all ? "Действие" : actionFilter.label,
                        systemImage: "bolt",
                        active: actionFilter != .all
                    )
                }

                Button {
                    datePickerPresented = true
                } label: {
                    AuditFilterChip(
                        title: dateRangeLabel,
                        systemImage: "calendar",
                        active: fromDate != nil || toDate != nil
                    )
                }
                .sheet(isPresented: $datePickerPresented) {
                    AuditDateRangePopover(
                        fromDate: $fromDate,
                        toDate: $toDate,
                        onApply: {
                            datePickerPresented = false
                            Task { await load() }
                        }
                    )
                    .presentationDetents([.medium])
                }

                if hasActiveFilters {
                    Button {
                        entityTypeFilter = .all
                        actionFilter = .all
                        fromDate = nil
                        toDate = nil
                        Task { await load() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Сбросить фильтры")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .foregroundColor(Theme.danger)
                        .background(Theme.danger.opacity(0.1))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var dateRangeLabel: String {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        f.locale = Locale(identifier: "ru_RU")
        switch (fromDate, toDate) {
        case (nil, nil):
            return "Период"
        case (let from?, nil):
            return "от \(f.string(from: from))"
        case (nil, let to?):
            return "до \(f.string(from: to))"
        case (let from?, let to?):
            return "\(f.string(from: from)) – \(f.string(from: to))"
        }
    }
}

// MARK: - Filter chip

private struct AuditFilterChip: View {
    let title: String
    let systemImage: String
    let active: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .opacity(0.7)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundColor(active ? .white : Theme.textPrimary)
        .background(active ? Theme.accent : Theme.surfaceBackground)
        .clipShape(Capsule())
        .overlay(
            Capsule().strokeBorder(active ? Color.clear : Theme.border, lineWidth: 0.5)
        )
    }
}

// MARK: - Date range popover

private struct AuditDateRangePopover: View {
    @Binding var fromDate: Date?
    @Binding var toDate: Date?
    let onApply: () -> Void

    @State private var fromEnabled: Bool = false
    @State private var toEnabled: Bool = false
    @State private var fromValue: Date = Date()
    @State private var toValue: Date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Период")
                .font(.dsH3)
                .foregroundColor(Theme.textPrimary)

            VStack(spacing: 12) {
                HStack {
                    Toggle("От", isOn: $fromEnabled)
                        .toggleStyle(.switch)
                        .frame(width: 80, alignment: .leading)
                    Spacer()
                    DatePicker("",
                               selection: $fromValue,
                               displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .disabled(!fromEnabled)
                        .opacity(fromEnabled ? 1 : 0.4)
                }
                HStack {
                    Toggle("До", isOn: $toEnabled)
                        .toggleStyle(.switch)
                        .frame(width: 80, alignment: .leading)
                    Spacer()
                    DatePicker("",
                               selection: $toValue,
                               displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .disabled(!toEnabled)
                        .opacity(toEnabled ? 1 : 0.4)
                }
            }

            HStack(spacing: 8) {
                Button {
                    fromEnabled = false
                    toEnabled = false
                    fromDate = nil
                    toDate = nil
                    onApply()
                } label: {
                    Text("Сбросить")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundColor(Theme.textPrimary)
                        .background(Theme.surfaceBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.md)
                                .strokeBorder(Theme.borderStrong, lineWidth: 0.5)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                }
                .buttonStyle(.plain)

                DSPrimaryButton(action: {
                    fromDate = fromEnabled ? fromValue : nil
                    toDate   = toEnabled   ? toValue   : nil
                    onApply()
                }) {
                    Text("Применить")
                }
            }
        }
        .padding(20)
        .frame(minWidth: 320)
        .background(Theme.surfaceBackground)
        .onAppear {
            if let f = fromDate { fromEnabled = true; fromValue = f }
            if let t = toDate   { toEnabled = true;   toValue = t }
        }
    }
}

// MARK: - Row

private struct AuditRowView: View {
    let entry: AuditEntry
    let expanded: Bool

    var body: some View {
        DSCard(radius: Radius.lg, padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    actionIcon
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(entry.action)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundColor(Theme.accent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            if let d = entry.date {
                                Text(relativeTime(from: d))
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.textTertiary)
                            }
                        }
                        HStack(spacing: 6) {
                            if let actor = entry.actor {
                                AvatarCircle(url: actor.avatarUrl, name: actor.displayName)
                                    .frame(width: 18, height: 18)
                                Text(actor.displayName.ifEmpty(or: actor.username ?? "—"))
                                    .font(.dsCaption)
                                    .foregroundColor(Theme.textSecondary)
                                    .lineLimit(1)
                            } else {
                                Image(systemName: "questionmark.circle")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.textTertiary)
                                Text("система / без актора")
                                    .font(.dsCaption)
                                    .foregroundColor(Theme.textSecondary)
                            }
                        }
                        if entry.entityType != nil || entry.entityId != nil {
                            HStack(spacing: 4) {
                                if let t = entry.entityType {
                                    Text(t)
                                        .font(.system(size: 11, design: .monospaced))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Theme.accent.opacity(0.12))
                                        .foregroundColor(Theme.accent)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                                if let id = entry.entityId {
                                    Text(id.prefix(8) + "…")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(Theme.textTertiary)
                                }
                            }
                        }
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.textTertiary)
                }

                if expanded {
                    detailBlock
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    @ViewBuilder
    private var detailBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            kv("ID",        entry.id)
            kv("Action",    entry.action)
            kv("Entity",    [entry.entityType, entry.entityId].compactMap { $0 }.joined(separator: " / ").ifEmpty(or: "—"))
            kv("IP",        entry.ip ?? "—")
            kv("Время",     entry.date.map { Self.fullDate.string(from: $0) } ?? entry.createdAt)
            if let actor = entry.actor {
                kv("Актор",  "\(actor.displayName) (@\(actor.username ?? "?"))")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Metadata")
                    .font(.dsCaption.weight(.semibold))
                    .foregroundColor(Theme.textSecondary)
                if let m = entry.meta, !m.isEmpty {
                    Text(m.prettyString())
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Theme.pageBackground)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                        .textSelection(.enabled)
                } else {
                    Text("—")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                }
            }
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private func kv(_ key: String, _ val: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(.dsCaption.weight(.semibold))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 70, alignment: .leading)
            Text(val)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private static let fullDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "dd.MM.yyyy HH:mm:ss"
        return f
    }()

    // MARK: - Action icon mapping

    @ViewBuilder
    private var actionIcon: some View {
        let (sf, color) = Self.iconFor(action: entry.action)
        DSIconTile(systemImage: sf, color: color, size: 36)
    }

    /// Маппим начало action-строки на SF Symbol + цвет.
    /// Бэкенд использует точечные коды вроде "auth.login", "user.update", "task.delete".
    static func iconFor(action: String) -> (String, Color) {
        let a = action.lowercased()
        if a.contains("login")    { return ("person.fill",                Theme.accent) }
        if a.contains("logout")   { return ("rectangle.portrait.and.arrow.right", .secondary) }
        if a.contains("create") || a.hasSuffix(".add") {
            return ("plus.circle.fill", Theme.success)
        }
        if a.contains("update") || a.contains("edit") || a.contains("patch") {
            return ("pencil.circle.fill", Theme.warning)
        }
        if a.contains("delete") || a.contains("remove") {
            return ("trash.circle.fill", Theme.danger)
        }
        if a.contains("resolve") || a.contains("approve") {
            return ("checkmark.circle.fill", Theme.success)
        }
        if a.contains("reject") || a.contains("deny") {
            return ("xmark.circle.fill", Theme.danger)
        }
        if a.contains("permission") || a.contains("role") {
            return ("shield.lefthalf.filled", Theme.purple)
        }
        if a.contains("error") || a.contains("fail") {
            return ("exclamationmark.triangle.fill", Theme.danger)
        }
        return ("circle.fill", .secondary)
    }
}

#Preview {
    NavigationStack { AuditLogView() }
}
