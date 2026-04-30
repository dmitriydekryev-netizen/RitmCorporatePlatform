//
//  BugsView.swift — баг-трекер.
//
//  Полное зеркало apps/web/src/app/(app)/bugs/page.tsx:
//   • Канбан-доска с drag & drop (long-press) и реордерингом колонок
//   • Плотность (compact / normal / spacious) с zoom-контроллером
//   • Bulk-режим: множественный выбор → массовое перемещение
//   • Inline edit детальной карточки: статус, приоритет, платформа, версия, теги
//   • Комментарии: добавить / редактировать / удалить
//   • История изменений
//   • Column Manager: создать / переименовать / перекрасить / переупорядочить /
//     удалить (с миграцией багов в выбранную колонку)
//   • Вложения: фото из галереи через presigned S3 (POST /files/upload-url)
//   • Удаление и редактирование бага
//
//  Endpoints:
//   • GET    /bugs                          — список (search, platform, priority, sortBy)
//   • GET    /bugs/:id                      — детально (с комментариями)
//   • POST   /bugs                          — создать
//   • PATCH  /bugs/:id                      — частичное обновление
//   • DELETE /bugs/:id                      — удалить
//   • PATCH  /bugs/:id/move                 — { status: <columnKey> }
//   • POST   /bugs/:id/comments             — { content }
//   • PATCH  /bugs/comments/:id             — { content }
//   • DELETE /bugs/comments/:id
//   • GET    /bugs/:id/history              — { data: [...] }
//   • GET    /bug-columns                   — массив колонок
//   • POST   /bug-columns                   — { name, color }
//   • PATCH  /bug-columns/:id               — { name?, color? }
//   • PATCH  /bug-columns/reorder           — { order: [id...] }
//   • DELETE /bug-columns/:id?targetId=...
//   • POST   /files/upload-url              — presigned S3 (kind: "bug_attachment")
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AVKit

// MARK: - Models

struct BugItem: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let description: String?
    let status: String?
    let columnKey: String?
    let priority: String?       // low | medium | high | critical
    let platform: String?       // android | ios | web | backend | other
    let tags: [String]?
    let appVersion: String?
    let attachments: [String]?
    let reporter: BugUser?
    let assignee: BugUser?
    let commentsCount: Int?
    let createdAt: String?
    let updatedAt: String?

    static func == (lhs: BugItem, rhs: BugItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct BugUser: Codable, Hashable {
    let id: String
    let username: String?
    let firstName: String?
    let lastName: String?
    let avatarUrl: String?

    var displayName: String {
        let s = "\(firstName ?? "") \(lastName ?? "")".trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? (username ?? "?") : s
    }
}

struct BugsListResponse: Codable {
    let data: [BugItem]
    let meta: PaginationMeta?
}

struct BugColumn: Codable, Identifiable, Hashable {
    let id: String
    let key: String
    let name: String
    let color: String?
    let order: Int?
    let isDefault: Bool?
}

struct BugComment: Codable, Identifiable, Hashable {
    let id: String
    let content: String
    let isEdited: Bool?
    let createdAt: String?
    let author: BugUser
}

struct BugDetail: Codable, Identifiable {
    let id: String
    let title: String
    let description: String?
    let status: String?
    let columnKey: String?
    let priority: String?
    let platform: String?
    let tags: [String]?
    let appVersion: String?
    let attachments: [String]?
    let reporter: BugUser?
    let assignee: BugUser?
    let commentsCount: Int?
    let createdAt: String?
    let updatedAt: String?
    let comments: [BugComment]?
}

struct BugHistoryEntry: Codable, Identifiable {
    let id: String
    let action: String
    let createdAt: String
    let actor: BugUser?
    let meta: BugHistoryMeta?
}

/// Полу-структурированные meta-поля. Декодируем динамически — поля заранее не известны.
struct BugHistoryMeta: Codable {
    let raw: [String: AnyCodable]?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self.raw = try? c.decode([String: AnyCodable].self)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }
}

struct AnyCodable: Codable {
    let value: Any?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let i = try? c.decode(Int.self) { value = i }
        else if let d = try? c.decode(Double.self) { value = d }
        else if let b = try? c.decode(Bool.self) { value = b }
        else if let arr = try? c.decode([AnyCodable].self) { value = arr.map { $0.value } }
        else if let dict = try? c.decode([String: AnyCodable].self) { value = dict.mapValues { $0.value } }
        else if c.decodeNil() { value = nil }
        else { value = nil }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let s as String: try c.encode(s)
        case let i as Int:    try c.encode(i)
        case let d as Double: try c.encode(d)
        case let b as Bool:   try c.encode(b)
        default: try c.encodeNil()
        }
    }
}

// MARK: - Density

enum BoardDensity: String, CaseIterable {
    case compact, normal, spacious
    var columnWidth: CGFloat {
        switch self {
        case .compact: return 240
        case .normal: return 280
        case .spacious: return 320
        }
    }
    var gap: CGFloat {
        switch self {
        case .compact: return 8
        case .normal: return 12
        case .spacious: return 16
        }
    }
    var cardPadding: CGFloat {
        switch self {
        case .compact: return 8
        case .normal: return 12
        case .spacious: return 14
        }
    }
}

// MARK: - Helpers / config

private let bugColorMap: [String: Color] = [
    "sky":     Color(red: 14/255, green: 165/255, blue: 233/255),
    "amber":   Color(red: 245/255, green: 158/255, blue: 11/255),
    "violet":  Color(red: 139/255, green: 92/255, blue: 246/255),
    "emerald": Color(red: 16/255, green: 185/255, blue: 129/255),
    "rose":    Color(red: 244/255, green: 63/255, blue: 94/255),
    "pink":    Color(red: 236/255, green: 72/255, blue: 153/255),
    "slate":   Color(red: 100/255, green: 116/255, blue: 139/255),
    "cyan":    Color(red: 6/255, green: 182/255, blue: 212/255),
    "indigo":  Color(red: 99/255, green: 102/255, blue: 241/255),
    "teal":    Color(red: 20/255, green: 184/255, blue: 166/255),
    "lime":    Color(red: 132/255, green: 204/255, blue: 22/255),
    "orange":  Color(red: 249/255, green: 115/255, blue: 22/255),
]
private func columnColor(_ name: String?) -> Color {
    if let n = name, let c = bugColorMap[n] { return c }
    return Theme.accent
}

private let priorityColor: [String: Color] = [
    "low":      Color.secondary,
    "medium":   Theme.warning,
    "high":     Theme.danger,
    "critical": Color.red,
]

private let priorityLabel: [String: String] = [
    "low":      "Низкий",
    "medium":   "Средний",
    "high":     "Высокий",
    "critical": "Критич.",
]

private let priorityLabelLong: [String: String] = [
    "low":      "Низкий",
    "medium":   "Средний",
    "high":     "Высокий",
    "critical": "Критический",
]

private let platformIcon: [String: String] = [
    "ios":      "applelogo",
    "android":  "smartphone",
    "web":      "globe",
    "backend":  "server.rack",
    "other":    "gear",
]
private let platformLabel: [String: String] = [
    "ios":     "iOS",
    "android": "Android",
    "web":     "Web",
    "backend": "Backend",
    "other":   "Другое",
]
private let platformEmoji: [String: String] = [
    "ios":     "🍎",
    "android": "🤖",
    "web":     "🌐",
    "backend": "⚙️",
    "other":   "📦",
]

private let fallbackColumns: [BugColumn] = [
    BugColumn(id: "fb-open",        key: "open",        name: "Открытые",    color: "sky",     order: 0, isDefault: true),
    BugColumn(id: "fb-in_progress", key: "in_progress", name: "В работе",    color: "amber",   order: 1, isDefault: true),
    BugColumn(id: "fb-review",      key: "review",      name: "На проверке", color: "violet",  order: 2, isDefault: true),
    BugColumn(id: "fb-resolved",    key: "resolved",    name: "Решено",      color: "emerald", order: 3, isDefault: true),
    BugColumn(id: "fb-closed",      key: "closed",      name: "Закрыто",     color: "slate",   order: 4, isDefault: true),
]

private let bugColorOptions = ["sky", "amber", "violet", "emerald", "rose", "pink", "slate", "cyan", "indigo", "teal", "lime", "orange"]

// MARK: - Permissions

@MainActor
private struct BugPerms {
    let canCreate: Bool
    let canManage: Bool
    let canDelete: Bool

    init(_ auth: AuthStore) {
        let perms = auth.currentUser?.permissions ?? []
        let isAll = perms.contains("*")
        self.canCreate = isAll || perms.contains("bug.create") || perms.contains("bug.manage")
        self.canManage = isAll || perms.contains("bug.manage") || perms.contains("bug.update")
        self.canDelete = isAll || perms.contains("bug.delete") || perms.contains("bug.manage")
    }
}

// MARK: - Main view

struct BugsView: View {
    @EnvironmentObject private var auth: AuthStore

    @State private var bugs: [BugItem] = []
    @State private var columns: [BugColumn] = fallbackColumns
    @State private var loading = true
    @State private var error: String?

    // Filters
    @State private var search = ""
    @State private var platformFilter: String? = nil
    @State private var priorityFilter: String? = nil
    @State private var sortBy: SortBy = .updatedDesc
    @State private var sortDir: SortDir = .desc

    // UI state
    @AppStorage("bugs_density") private var densityRaw: String = BoardDensity.normal.rawValue
    private var density: BoardDensity {
        BoardDensity(rawValue: densityRaw) ?? .normal
    }

    @State private var showCreate = false
    @State private var createInitialColumn: String = "open"
    @State private var showColumnManager = false
    @State private var showFilters = false

    // Selection
    @State private var selectMode = false
    @State private var selectedBugIds: Set<String> = []

    // Detail
    @State private var selectedBugId: String? = nil

    // Drag state
    @State private var draggingBugId: String? = nil
    @State private var dragOverColumn: String? = nil
    @State private var movingIds: Set<String> = []

    enum SortBy: String, CaseIterable, Identifiable {
        case updatedDesc = "По дате изменения"
        case createdDesc = "По дате создания"
        var id: String { rawValue }
    }
    enum SortDir: String, CaseIterable, Identifiable {
        case desc = "Сначала новые"
        case asc  = "Сначала старые"
        var id: String { rawValue }
    }

    private var perms: BugPerms { BugPerms(auth) }

    private var sortedColumns: [BugColumn] {
        columns.sorted { ($0.order ?? 0) < ($1.order ?? 0) }
    }

    private var filteredBugs: [BugItem] {
        let q = search.lowercased().trimmingCharacters(in: .whitespaces)
        var list = bugs
        if !q.isEmpty {
            list = list.filter { b in
                let s = "\(b.title) \(b.description ?? "") \((b.tags ?? []).joined(separator: " "))".lowercased()
                return s.contains(q)
            }
        }
        if let p = platformFilter { list = list.filter { ($0.platform ?? "") == p } }
        if let pri = priorityFilter { list = list.filter { ($0.priority ?? "") == pri } }
        return list
    }

    private var bugsByColumn: [String: [BugItem]] {
        var map: [String: [BugItem]] = [:]
        for c in sortedColumns { map[c.key] = [] }
        let fallbackKey = sortedColumns.first?.key ?? "open"
        for b in filteredBugs {
            let key = b.columnKey ?? b.status ?? fallbackKey
            if map[key] != nil { map[key]?.append(b) }
            else if map[fallbackKey] != nil { map[fallbackKey]?.append(b) }
        }
        // Sort within column by updatedAt/createdAt
        for k in map.keys {
            map[k]?.sort { a, b in
                let av: String, bv: String
                switch sortBy {
                case .updatedDesc:
                    av = a.updatedAt ?? a.createdAt ?? ""
                    bv = b.updatedAt ?? b.createdAt ?? ""
                case .createdDesc:
                    av = a.createdAt ?? ""
                    bv = b.createdAt ?? ""
                }
                return sortDir == .desc ? av > bv : av < bv
            }
        }
        return map
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.pageBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar
                filtersBar
                content
            }

            if selectMode && !selectedBugIds.isEmpty {
                bulkActionBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 8)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .refreshable { await load() }
        .task { if bugs.isEmpty { await load() } }
        .sheet(isPresented: $showCreate) {
            CreateBugSheet(columns: sortedColumns, initialStatus: createInitialColumn) { _ in
                Task { await load() }
            }
        }
        .sheet(isPresented: $showColumnManager) {
            ColumnManagerSheet(initial: sortedColumns) { reload in
                if reload { Task { await load() } }
            }
        }
        .sheet(item: Binding(
            get: { selectedBugId.map { BugDetailRoute(id: $0) } },
            set: { selectedBugId = $0?.id }
        )) { route in
            BugDetailSheet(
                bugId: route.id,
                columns: sortedColumns,
                canManage: perms.canManage,
                canDelete: perms.canDelete,
                currentUserId: auth.currentUser?.id ?? ""
            ) { needsReload in
                if needsReload { Task { await load() } }
            }
        }
    }

    private struct BugDetailRoute: Identifiable { let id: String }

    // MARK: Header

    @ViewBuilder
    private var headerBar: some View {
        HStack(alignment: .firstTextBaseline) {
            DSPageTitle(text: "Баг-трекер",
                        subtitle: bugs.isEmpty ? nil : "\(filteredBugs.count) из \(bugs.count)")
            Spacer()
            if perms.canCreate {
                Button {
                    createInitialColumn = sortedColumns.first?.key ?? "open"
                    showCreate = true
                } label: {
                    Label("Новый", systemImage: "plus.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(Theme.accent)
                        .clipShape(Capsule())
                        .shadow(color: Theme.accent.opacity(0.3), radius: 6, x: 0, y: 2)
                }
                .buttonStyle(DSPressScaleStyle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    // MARK: Filters

    @ViewBuilder
    private var filtersBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                // Search
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.textTertiary)
                    TextField("Поиск багов…", text: $search)
                        .font(.system(size: 13))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !search.isEmpty {
                        Button { search = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundColor(Theme.textTertiary)
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Theme.surfaceBackground)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))

                // Filters popover (Menu)
                Menu {
                    Section("Платформа") {
                        Button {
                            platformFilter = nil
                        } label: {
                            Label("Все", systemImage: platformFilter == nil ? "checkmark" : "globe")
                        }
                        ForEach(["ios", "android", "web", "backend", "other"], id: \.self) { p in
                            Button {
                                platformFilter = (platformFilter == p) ? nil : p
                            } label: {
                                Label("\(platformEmoji[p] ?? "") \(platformLabel[p] ?? p)",
                                      systemImage: platformFilter == p ? "checkmark" : "")
                            }
                        }
                    }
                    Section("Приоритет") {
                        Button { priorityFilter = nil } label: {
                            Label("Любой", systemImage: priorityFilter == nil ? "checkmark" : "flag")
                        }
                        ForEach(["critical", "high", "medium", "low"], id: \.self) { p in
                            Button {
                                priorityFilter = (priorityFilter == p) ? nil : p
                            } label: {
                                Label(priorityLabelLong[p] ?? p,
                                      systemImage: priorityFilter == p ? "checkmark" : "flag.fill")
                            }
                        }
                    }
                    Section("Сортировка") {
                        ForEach(SortBy.allCases) { s in
                            Button { sortBy = s } label: {
                                Label(s.rawValue, systemImage: sortBy == s ? "checkmark" : "arrow.up.arrow.down")
                            }
                        }
                        Divider()
                        ForEach(SortDir.allCases) { d in
                            Button { sortDir = d } label: {
                                Label(d.rawValue, systemImage: sortDir == d ? "checkmark" : (d == .desc ? "arrow.down" : "arrow.up"))
                            }
                        }
                    }
                    if hasActiveFilters {
                        Divider()
                        Button(role: .destructive) {
                            search = ""; platformFilter = nil; priorityFilter = nil
                        } label: {
                            Label("Сбросить фильтры", systemImage: "xmark.circle")
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 12, weight: .semibold))
                        if filterBadgeCount > 0 {
                            Text("\(filterBadgeCount)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Theme.accent)
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(filterBadgeCount > 0 ? Theme.accent.opacity(0.12) : Theme.surfaceBackground)
                    .foregroundColor(filterBadgeCount > 0 ? Theme.accent : Theme.textSecondary)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(filterBadgeCount > 0 ? Theme.accent.opacity(0.3) : Theme.border, lineWidth: 0.5))
                }

                // Density / zoom
                HStack(spacing: 0) {
                    densityButton(.compact, icon: "rectangle.compress.vertical")
                    densityButton(.normal,  icon: "rectangle")
                    densityButton(.spacious, icon: "rectangle.expand.vertical")
                }
                .padding(2)
                .background(Theme.surfaceBackground)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var hasActiveFilters: Bool {
        !search.isEmpty || platformFilter != nil || priorityFilter != nil
    }
    private var filterBadgeCount: Int {
        (platformFilter != nil ? 1 : 0) + (priorityFilter != nil ? 1 : 0)
    }

    @ViewBuilder
    private func densityButton(_ d: BoardDensity, icon: String) -> some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                densityRaw = d.rawValue
            }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(density == d ? Theme.accent : Theme.textTertiary)
                .frame(width: 28, height: 24)
                .background(density == d ? Theme.accent.opacity(0.12) : .clear)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if perms.canManage {
                    Button {
                        selectMode.toggle()
                        if !selectMode { selectedBugIds.removeAll() }
                    } label: {
                        Label(selectMode ? "Выйти из выбора" : "Выбрать несколько",
                              systemImage: selectMode ? "xmark.circle" : "checkmark.circle")
                    }
                    Button {
                        showColumnManager = true
                    } label: {
                        Label("Управление колонками", systemImage: "rectangle.split.3x1")
                    }
                    Divider()
                }
                Button {
                    Task { await load() }
                } label: {
                    Label("Обновить", systemImage: "arrow.clockwise")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundColor(Theme.accent)
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if loading && bugs.isEmpty {
            ProgressView().tint(Theme.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = error, bugs.isEmpty {
            EmptyStateView(icon: "exclamationmark.triangle",
                           title: "Не удалось загрузить",
                           description: err)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Двухосевая прокрутка: горизонтально — между колонками канбана,
            // вертикально — по карточкам внутри колонки. Раньше тут была
            // только `.horizontal` ScrollView, из-за чего длинные колонки
            // обрезались по высоте экрана и нижние карточки были недоступны.
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                HStack(alignment: .top, spacing: density.gap) {
                    ForEach(sortedColumns) { col in
                        KanbanColumnView(
                            column: col,
                            items: bugsByColumn[col.key] ?? [],
                            density: density,
                            isDragOver: dragOverColumn == col.key,
                            isDragging: draggingBugId != nil,
                            movingIds: movingIds,
                            allColumns: sortedColumns,
                            selectMode: selectMode,
                            selectedIds: selectedBugIds,
                            canManage: perms.canManage,
                            canCreate: perms.canCreate,
                            onCardTap: { id in
                                if selectMode { toggleSelect(id) }
                                else { selectedBugId = id }
                            },
                            onCardLongPressMove: { bug, target in
                                Task { await move(bug, to: target) }
                            },
                            onAddInColumn: {
                                createInitialColumn = col.key
                                showCreate = true
                            },
                            onDragStart: { id in draggingBugId = id },
                            onDragEnd: {
                                draggingBugId = nil
                                dragOverColumn = nil
                            },
                            onDropInColumn: { id in
                                handleDrop(bugId: id, toColumn: col)
                            },
                            onDragOverColumn: {
                                if dragOverColumn != col.key { dragOverColumn = col.key }
                            }
                        )
                        .frame(width: density.columnWidth)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
    }

    // MARK: Bulk action bar

    @ViewBuilder
    private var bulkActionBar: some View {
        HStack(spacing: 12) {
            Text("Выбрано: \(selectedBugIds.count)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.textSecondary)

            Menu {
                ForEach(sortedColumns) { col in
                    Button {
                        Task { await bulkMove(to: col) }
                    } label: {
                        Label(col.name, systemImage: "arrow.right.circle")
                    }
                }
            } label: {
                Label("Переместить", systemImage: "arrow.right.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .foregroundColor(.white)
                    .background(Theme.accent)
                    .clipShape(Capsule())
            }

            Button {
                selectedBugIds.removeAll()
                selectMode = false
            } label: {
                Text("Отмена")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .foregroundColor(Theme.textSecondary)
                    .background(Theme.surfaceBackground)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 0.5)
        )
        .dsModalShadow()
        .padding(.horizontal, 16)
    }

    // MARK: Actions

    private func toggleSelect(_ id: String) {
        if selectedBugIds.contains(id) { selectedBugIds.remove(id) }
        else { selectedBugIds.insert(id) }
    }

    private func handleDrop(bugId: String, toColumn col: BugColumn) {
        defer { draggingBugId = nil; dragOverColumn = nil }
        guard let bug = bugs.first(where: { $0.id == bugId }) else { return }
        if (bug.columnKey ?? bug.status) == col.key { return }
        Task { await move(bug, to: col) }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        async let bugsTask: BugsListResponse = APIClient.shared.get("bugs", query: bugsQuery())
        async let colsTask: [BugColumn] = APIClient.shared.get("bug-columns")
        do {
            let (b, c) = try await (bugsTask, colsTask)
            bugs = b.data
            columns = c.isEmpty ? fallbackColumns : c
            error = nil
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func bugsQuery() -> [String: String] {
        var q: [String: String] = ["limit": "200"]
        if !search.isEmpty { q["search"] = search }
        if let p = platformFilter { q["platform"] = p }
        if let p = priorityFilter { q["priority"] = p }
        q["sortBy"] = sortBy == .updatedDesc ? "updatedAt" : "createdAt"
        return q
    }

    private func move(_ bug: BugItem, to target: BugColumn) async {
        guard (bug.columnKey ?? bug.status) != target.key else { return }
        movingIds.insert(bug.id)
        defer { movingIds.remove(bug.id) }

        // Optimistic
        if let i = bugs.firstIndex(where: { $0.id == bug.id }) {
            let old = bugs[i]
            bugs[i] = BugItem(
                id: old.id, title: old.title, description: old.description,
                status: target.key, columnKey: target.key,
                priority: old.priority, platform: old.platform, tags: old.tags,
                appVersion: old.appVersion, attachments: old.attachments,
                reporter: old.reporter, assignee: old.assignee,
                commentsCount: old.commentsCount, createdAt: old.createdAt,
                updatedAt: old.updatedAt
            )
        }
        struct Body: Encodable { let status: String }
        do {
            _ = try await APIClient.shared.rawRequest(
                "PATCH", "bugs/\(bug.id)/move", body: Body(status: target.key)
            )
        } catch {
            await load()
            self.error = apiUserMessage(error)
        }
    }

    private func bulkMove(to col: BugColumn) async {
        let ids = selectedBugIds
        struct Body: Encodable { let status: String }
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask {
                    _ = try? await APIClient.shared.rawRequest(
                        "PATCH", "bugs/\(id)/move", body: Body(status: col.key)
                    )
                }
            }
        }
        selectedBugIds.removeAll()
        selectMode = false
        await load()
    }
}

// MARK: - Kanban column

private struct KanbanColumnView: View {
    let column: BugColumn
    let items: [BugItem]
    let density: BoardDensity
    let isDragOver: Bool
    let isDragging: Bool
    let movingIds: Set<String>
    let allColumns: [BugColumn]
    let selectMode: Bool
    let selectedIds: Set<String>
    let canManage: Bool
    let canCreate: Bool
    let onCardTap: (String) -> Void
    let onCardLongPressMove: (BugItem, BugColumn) -> Void
    let onAddInColumn: () -> Void
    let onDragStart: (String) -> Void
    let onDragEnd: () -> Void
    let onDropInColumn: (String) -> Void
    let onDragOverColumn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(spacing: 8) {
                Circle()
                    .fill(columnColor(column.color))
                    .frame(width: 9, height: 9)
                Text(column.name)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(columnColor(column.color))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(items.count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(columnColor(column.color))
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(columnColor(column.color).opacity(0.15))
                    .clipShape(Capsule())
                if canCreate {
                    Button { onAddInColumn() } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(Theme.textTertiary)
                            .frame(width: 22, height: 22)
                            .background(Theme.surfaceBackground)
                            .clipShape(Circle())
                            .overlay(Circle().strokeBorder(Theme.border, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)

            // Cards / drop zone
            VStack(spacing: density.gap - 4) {
                if items.isEmpty {
                    emptyPlaceholder
                } else {
                    ForEach(items) { bug in
                        BugCardView(
                            bug: bug,
                            density: density,
                            isMoving: movingIds.contains(bug.id),
                            selectMode: selectMode,
                            isSelected: selectedIds.contains(bug.id),
                            allColumns: allColumns,
                            currentKey: column.key,
                            canManage: canManage,
                            onTap: { onCardTap(bug.id) },
                            onLongPressMove: { col in onCardLongPressMove(bug, col) }
                        )
                        .opacity(movingIds.contains(bug.id) ? 0.45 : 1)
                        .onDrag {
                            onDragStart(bug.id)
                            return NSItemProvider(object: bug.id as NSString)
                        }
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, minHeight: 160, alignment: .top)
            .background(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(isDragOver && isDragging ? Theme.accent.opacity(0.06) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .strokeBorder(
                        isDragOver && isDragging ? Theme.accent.opacity(0.4) : Color.clear,
                        style: StrokeStyle(lineWidth: 1.5, dash: [5])
                    )
            )
            .onDrop(of: [UTType.text], delegate: ColumnDropDelegate(
                onDrop: onDropInColumn,
                onEnter: onDragOverColumn,
                onExit: onDragEnd
            ))
        }
        .padding(8)
        .background(
            LinearGradient(
                colors: [columnColor(column.color).opacity(0.07),
                         columnColor(column.color).opacity(0.015)],
                startPoint: .top, endPoint: .bottom
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .strokeBorder(columnColor(column.color).opacity(0.16), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    }

    @ViewBuilder
    private var emptyPlaceholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "ladybug")
                .font(.system(size: 22, weight: .light))
                .foregroundColor(Theme.textTertiary.opacity(0.4))
            Text("Пусто")
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

private struct ColumnDropDelegate: DropDelegate {
    let onDrop: (String) -> Void
    let onEnter: () -> Void
    let onExit: () -> Void

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [UTType.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { (item, _) in
            if let id = item as? String {
                Task { @MainActor in onDrop(id) }
            }
        }
        return true
    }
    func dropEntered(info: DropInfo) { onEnter() }
    func dropExited(info: DropInfo)  { onExit() }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [UTType.text]) }
}

// MARK: - Bug card

private struct BugCardView: View {
    let bug: BugItem
    let density: BoardDensity
    let isMoving: Bool
    let selectMode: Bool
    let isSelected: Bool
    let allColumns: [BugColumn]
    let currentKey: String
    let canManage: Bool
    let onTap: () -> Void
    let onLongPressMove: (BugColumn) -> Void

    private var isCompact: Bool { density == .compact }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: isCompact ? 4 : 6) {
                // Top row — platform + version + priority
                HStack(spacing: 6) {
                    if let p = bug.platform {
                        Text(platformEmoji[p] ?? "📦")
                            .font(.system(size: 11))
                        if !isCompact {
                            Text(platformLabel[p] ?? p)
                                .font(.system(size: 10))
                                .foregroundColor(Theme.textTertiary)
                        }
                    }
                    if !isCompact, let v = bug.appVersion, !v.isEmpty {
                        Text("v\(v)")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .foregroundColor(Theme.textTertiary)
                            .background(Theme.pageBackground)
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.border, lineWidth: 0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    Spacer(minLength: 0)
                    if let p = bug.priority, let c = priorityColor[p] {
                        Circle().fill(c).frame(width: 6, height: 6)
                        if !isCompact {
                            Text(priorityLabel[p] ?? p)
                                .font(.system(size: 10))
                                .foregroundColor(Theme.textTertiary)
                        }
                    }
                }

                // Title
                Text(bug.title)
                    .font(.system(size: isCompact ? 13 : 13.5, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(isCompact ? 3 : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !isCompact, let d = bug.description, !d.isEmpty {
                    Text(d)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                if !isCompact, let tags = bug.tags, !tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(tags.prefix(3), id: \.self) { t in
                                Text(t)
                                    .font(.system(size: 9, weight: .medium))
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .foregroundColor(Theme.textSecondary)
                                    .background(Theme.pageBackground)
                                    .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
                                    .clipShape(Capsule())
                            }
                            if tags.count > 3 {
                                Text("+\(tags.count - 3)")
                                    .font(.system(size: 9))
                                    .foregroundColor(Theme.textTertiary)
                            }
                        }
                    }
                }

                // Footer — автор + (если есть) исполнитель
                HStack(spacing: 4) {
                    if let r = bug.reporter {
                        AvatarCircle(url: r.avatarUrl, name: r.displayName)
                            .frame(width: 18, height: 18)
                        Text(r.displayName)
                            .font(.system(size: isCompact ? 10 : 11, weight: .medium))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if let a = bug.assignee, a.id != bug.reporter?.id {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 8))
                            .foregroundColor(Theme.textTertiary)
                        AvatarCircle(url: a.avatarUrl, name: a.displayName)
                            .frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(Theme.success, lineWidth: 1))
                        if !isCompact {
                            Text(a.displayName)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Theme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    Spacer(minLength: 0)
                    if let c = bug.commentsCount, c > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "bubble.left.fill").font(.system(size: 9))
                            Text("\(c)").font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(Theme.textTertiary)
                    }
                    if let createdAt = bug.createdAt,
                       let d = ISO8601DateFormatter().date(from: createdAt) {
                        Text(relativeTime(from: d))
                            .font(.system(size: 9))
                            .foregroundColor(Theme.textTertiary)
                    }
                }
            }
            .padding(density.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surfaceBackground)
            .overlay(
                Rectangle()
                    .fill(priorityColor[bug.priority ?? "low"] ?? Theme.textTertiary)
                    .frame(width: 3),
                alignment: .leading
            )
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent.opacity(0.5) : Theme.border, lineWidth: isSelected ? 1.5 : 0.5)
            )
            .overlay(alignment: .topTrailing) {
                if selectMode {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundColor(isSelected ? Theme.accent : Theme.textTertiary)
                        .background(Theme.surfaceBackground.clipShape(Circle()))
                        .padding(6)
                }
            }
            .dsCardShadow()
        }
        .buttonStyle(DSPressScaleStyle())
        .contextMenu {
            if canManage {
                Section("Переместить в…") {
                    ForEach(allColumns) { col in
                        if col.key != currentKey {
                            Button {
                                onLongPressMove(col)
                            } label: {
                                Label(col.name, systemImage: "arrow.right.circle")
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Detail sheet

private struct BugDetailSheet: View {
    let bugId: String
    let columns: [BugColumn]
    let canManage: Bool
    let canDelete: Bool
    let currentUserId: String
    let onChange: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var bug: BugDetail?
    @State private var loading = true
    @State private var error: String?

    // Edit mode
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @State private var descDraft = ""
    @State private var versionDraft: String? = nil
    @State private var tagsDraft: String? = nil

    // Comments
    @State private var commentDraft = ""
    @State private var posting = false
    @State private var editingCommentId: String? = nil
    @State private var editingCommentText: String = ""

    // Misc
    @State private var showHistory = false
    @State private var history: [BugHistoryEntry] = []
    @State private var historyLoading = false
    @State private var confirmDelete = false
    @State private var savingMeta = false

    // Полноэкранный просмотр вложений (фото/видео).
    @State fileprivate var fullscreenMedia: BugFullscreenMedia? = nil

    var body: some View {
        NavigationStack {
            content
                .background(Theme.pageBackground.ignoresSafeArea())
                .navigationTitle("Баг")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            if let b = bug, (canManage || b.reporter?.id == currentUserId) {
                                Button {
                                    titleDraft = b.title
                                    descDraft = b.description ?? ""
                                    editingTitle = true
                                } label: {
                                    Label("Редактировать", systemImage: "pencil")
                                }
                            }
                            if canDelete || bug?.reporter?.id == currentUserId {
                                Button(role: .destructive) {
                                    confirmDelete = true
                                } label: {
                                    Label("Удалить", systemImage: "trash")
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundColor(Theme.accent)
                        }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(Theme.textTertiary)
                        }
                    }
                }
        }
        .task { await load() }
        .alert("Удалить баг?", isPresented: $confirmDelete) {
            Button("Удалить", role: .destructive) { Task { await deleteBug() } }
            Button("Отмена", role: .cancel) { }
        } message: {
            Text("Действие нельзя отменить.")
        }
        .fullScreenCover(item: $fullscreenMedia) { media in
            BugFullscreenMediaViewer(media: media) { fullscreenMedia = nil }
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading && bug == nil {
            ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let b = bug {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    titleSection(b)
                    metaGrid(b)
                    if let attachments = b.attachments, !attachments.isEmpty {
                        attachmentsSection(attachments)
                    }
                    tagsSection(b)
                    historySection(b)
                    commentsSection(b)
                }
                .padding(16)
            }
        } else {
            EmptyStateView(icon: "exclamationmark.triangle",
                           title: "Не удалось загрузить",
                           description: error ?? "Попробуйте ещё раз")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func titleSection(_ b: BugDetail) -> some View {
        DSCard(radius: Radius.xl, padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                if editingTitle {
                    TextField("Заголовок", text: $titleDraft, axis: .vertical)
                        .font(.system(size: 18, weight: .bold))
                        .lineLimit(1...3)
                    TextField("Описание", text: $descDraft, axis: .vertical)
                        .font(.system(size: 14))
                        .lineLimit(3...10)
                        .padding(8)
                        .background(Theme.pageBackground)
                        .overlay(RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(Theme.border, lineWidth: 0.5))
                        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                    HStack {
                        Button {
                            Task { await saveEdits() }
                        } label: {
                            Text("Сохранить")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .foregroundColor(.white)
                                .background(Theme.accent)
                                .clipShape(Capsule())
                        }
                        .disabled(titleDraft.trimmingCharacters(in: .whitespaces).isEmpty || savingMeta)
                        Button { editingTitle = false } label: {
                            Text("Отмена")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .foregroundColor(Theme.textSecondary)
                                .background(Theme.surfaceBackground)
                                .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
                                .clipShape(Capsule())
                        }
                    }
                } else {
                    Text(b.title)
                        .font(.system(size: 19, weight: .bold))
                        .tracking(-0.3)
                        .foregroundColor(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let d = b.description, !d.isEmpty {
                        Text(d)
                            .font(.system(size: 14))
                            .foregroundColor(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func metaGrid(_ b: BugDetail) -> some View {
        let canEdit = canManage || b.reporter?.id == currentUserId
        DSCard(radius: Radius.xl, padding: 0) {
            VStack(spacing: 0) {
                // Status
                metaRow("Статус") {
                    if canManage {
                        Menu {
                            ForEach(columns) { col in
                                Button {
                                    Task { await quickUpdate(["status": col.key]) }
                                } label: {
                                    Label(col.name, systemImage: (b.columnKey ?? b.status) == col.key ? "checkmark" : "")
                                }
                            }
                        } label: {
                            statusBadge(b)
                        }
                    } else {
                        statusBadge(b)
                    }
                }
                divider
                // Priority
                metaRow("Приоритет") {
                    if canEdit {
                        Menu {
                            ForEach(["critical", "high", "medium", "low"], id: \.self) { p in
                                Button {
                                    Task { await quickUpdate(["priority": p]) }
                                } label: {
                                    Label(priorityLabelLong[p] ?? p,
                                          systemImage: b.priority == p ? "checkmark" : "flag.fill")
                                }
                            }
                        } label: {
                            priorityChip(b.priority)
                        }
                    } else {
                        priorityChip(b.priority)
                    }
                }
                divider
                // Platform
                metaRow("Платформа") {
                    if canEdit {
                        Menu {
                            ForEach(["ios", "android", "web", "backend", "other"], id: \.self) { p in
                                Button {
                                    Task { await quickUpdate(["platform": p]) }
                                } label: {
                                    Label("\(platformEmoji[p] ?? "") \(platformLabel[p] ?? p)",
                                          systemImage: b.platform == p ? "checkmark" : "")
                                }
                            }
                        } label: {
                            platformChip(b.platform)
                        }
                    } else {
                        platformChip(b.platform)
                    }
                }
                divider
                // Reporter
                if let r = b.reporter {
                    metaRow("Автор") {
                        HStack(spacing: 6) {
                            AvatarCircle(url: r.avatarUrl, name: r.displayName)
                                .frame(width: 22, height: 22)
                            Text(r.displayName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(Theme.textPrimary)
                        }
                    }
                    divider
                }
                // Assignee
                metaRow("Исполнитель") {
                    if let a = b.assignee {
                        HStack(spacing: 6) {
                            AvatarCircle(url: a.avatarUrl, name: a.displayName)
                                .frame(width: 22, height: 22)
                            Text(a.displayName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(Theme.textPrimary)
                        }
                    } else {
                        Text("Не назначен")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.textTertiary)
                            .italic()
                    }
                }
                divider
                // Version
                metaRow("Версия") {
                    if canEdit {
                        VersionInlineEditor(
                            value: b.appVersion,
                            onSave: { v in Task { await quickUpdate(["appVersion": v ?? NSNull()]) } }
                        )
                    } else {
                        Text(b.appVersion ?? "—")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
                divider
                // Created
                metaRow("Создан") {
                    if let s = b.createdAt, let d = ISO8601DateFormatter().date(from: s) {
                        Text(formatFullDate(d))
                            .font(.system(size: 13))
                            .foregroundColor(Theme.textSecondary)
                    } else {
                        Text("—").font(.system(size: 13)).foregroundColor(Theme.textTertiary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var divider: some View {
        Rectangle().fill(Theme.separator).frame(height: 0.5)
    }

    @ViewBuilder
    private func metaRow<T: View>(_ label: String, @ViewBuilder _ value: () -> T) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
            Spacer()
            value()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func statusBadge(_ b: BugDetail) -> some View {
        let key = b.columnKey ?? b.status ?? ""
        let col = columns.first { $0.key == key }
        HStack(spacing: 4) {
            Circle().fill(columnColor(col?.color)).frame(width: 6, height: 6)
            Text(col?.name ?? key)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            if canManage {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(columnColor(col?.color).opacity(0.12))
        .clipShape(Capsule())
    }

    @ViewBuilder
    private func priorityChip(_ p: String?) -> some View {
        HStack(spacing: 4) {
            Circle().fill(priorityColor[p ?? ""] ?? Theme.textTertiary).frame(width: 6, height: 6)
            Text(priorityLabelLong[p ?? ""] ?? "—")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textPrimary)
        }
    }

    @ViewBuilder
    private func platformChip(_ p: String?) -> some View {
        HStack(spacing: 4) {
            Text(platformEmoji[p ?? ""] ?? "📦")
            Text(platformLabel[p ?? ""] ?? "—")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textPrimary)
        }
    }

    @ViewBuilder
    private func attachmentsSection(_ urls: [String]) -> some View {
        DSCard(radius: Radius.xl, padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Вложения")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundColor(Theme.textTertiary)

                let images = urls.filter { isImageURL($0) }
                let videos = urls.filter { isVideoURL($0) }
                let files  = urls.filter { !isImageURL($0) && !isVideoURL($0) }

                if !images.isEmpty {
                    // Подготавливаем массив абсолютных URL для свайпа в полноэкранном режиме.
                    let imageURLs: [URL] = images.compactMap { URL(string: ensureAbsolute($0)) }
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                        ForEach(Array(images.enumerated()), id: \.offset) { idx, url in
                            if let u = URL(string: ensureAbsolute(url)) {
                                Button {
                                    // Открываем все изображения с возможностью свайпа,
                                    // стартуя с тапнутого индекса (после фильтрации).
                                    let startIndex = imageURLs.firstIndex(of: u) ?? idx
                                    fullscreenMedia = .images(urls: imageURLs, startIndex: startIndex)
                                } label: {
                                    AsyncImage(url: u) { phase in
                                        switch phase {
                                        case .success(let i): i.resizable().scaledToFill()
                                        default: Theme.pageBackground
                                        }
                                    }
                                    .frame(height: 80)
                                    .frame(maxWidth: .infinity)
                                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                                    .overlay(RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(Theme.border, lineWidth: 0.5))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                // Видеовложения — превью с play-иконкой, тап → нативный AVKit player.
                if !videos.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                        ForEach(videos, id: \.self) { url in
                            if let u = URL(string: ensureAbsolute(url)) {
                                Button {
                                    fullscreenMedia = .video(u)
                                } label: {
                                    ZStack {
                                        Theme.pageBackground
                                        Image(systemName: "play.circle.fill")
                                            .font(.system(size: 36))
                                            .foregroundColor(.white.opacity(0.95))
                                            .shadow(color: .black.opacity(0.4), radius: 4)
                                        VStack {
                                            Spacer()
                                            HStack {
                                                Image(systemName: "video.fill")
                                                    .font(.system(size: 10, weight: .bold))
                                                Text(url.split(separator: "/").last.map(String.init) ?? "видео")
                                                    .font(.system(size: 11, weight: .medium))
                                                    .lineLimit(1)
                                                Spacer()
                                            }
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(LinearGradient(
                                                colors: [.clear, .black.opacity(0.6)],
                                                startPoint: .top, endPoint: .bottom
                                            ))
                                        }
                                    }
                                    .frame(height: 110)
                                    .frame(maxWidth: .infinity)
                                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                                    .overlay(RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(Theme.border, lineWidth: 0.5))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                ForEach(files, id: \.self) { url in
                    if let u = URL(string: ensureAbsolute(url)) {
                        Link(destination: u) {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.fill")
                                    .foregroundColor(Theme.textTertiary)
                                    .font(.system(size: 14))
                                Text(url.split(separator: "/").last.map(String.init) ?? "файл")
                                    .font(.system(size: 13))
                                    .foregroundColor(Theme.textPrimary)
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "arrow.down.circle")
                                    .foregroundColor(Theme.textTertiary)
                                    .font(.system(size: 14))
                            }
                            .padding(10)
                            .background(Theme.pageBackground)
                            .overlay(RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(Theme.border, lineWidth: 0.5))
                            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tagsSection(_ b: BugDetail) -> some View {
        let canEdit = canManage || b.reporter?.id == currentUserId
        DSCard(radius: Radius.xl, padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Теги")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.6)
                        .textCase(.uppercase)
                        .foregroundColor(Theme.textTertiary)
                    Spacer()
                    if canEdit && tagsDraft == nil {
                        Button {
                            tagsDraft = (b.tags ?? []).joined(separator: ", ")
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.accent)
                        }
                    }
                }
                if let draft = tagsDraft {
                    HStack(spacing: 6) {
                        TextField("crash, login...", text: Binding(get: { draft }, set: { tagsDraft = $0 }))
                            .font(.system(size: 13))
                            .padding(8)
                            .background(Theme.pageBackground)
                            .overlay(RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(Theme.accent.opacity(0.5), lineWidth: 0.5))
                            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                        Button {
                            let arr = draft.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                            Task { await quickUpdate(["tags": arr]) }
                            tagsDraft = nil
                        } label: {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 22))
                                .foregroundColor(Theme.accent)
                        }
                        Button { tagsDraft = nil } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 22))
                                .foregroundColor(Theme.textTertiary)
                        }
                    }
                } else {
                    BugsFlowLayout(spacing: 6) {
                        ForEach(b.tags ?? [], id: \.self) { t in
                            Text("#\(t)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(Theme.accent)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Theme.accent.opacity(0.10))
                                .clipShape(Capsule())
                        }
                        if (b.tags ?? []).isEmpty {
                            Text("нет тегов")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textTertiary).italic()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func historySection(_ b: BugDetail) -> some View {
        DSCard(radius: Radius.xl, padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation { showHistory.toggle() }
                    if showHistory && history.isEmpty {
                        Task { await loadHistory() }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 12))
                        Text("История изменений")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .rotationEffect(.degrees(showHistory ? 180 : 0))
                    }
                    .foregroundColor(Theme.textSecondary)
                }
                .buttonStyle(.plain)

                if showHistory {
                    if historyLoading && history.isEmpty {
                        ProgressView().tint(Theme.accent)
                    } else if history.isEmpty {
                        Text("История пуста")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textTertiary).italic()
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(history) { e in
                                HStack(alignment: .top, spacing: 8) {
                                    if let actor = e.actor {
                                        AvatarCircle(url: actor.avatarUrl, name: actor.displayName)
                                            .frame(width: 22, height: 22)
                                    } else {
                                        Circle().fill(Theme.pageBackground).frame(width: 22, height: 22)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(e.actor?.displayName ?? "Система")
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundColor(Theme.textPrimary)
                                            if let d = ISO8601DateFormatter().date(from: e.createdAt) {
                                                Text(relativeTime(from: d))
                                                    .font(.system(size: 10))
                                                    .foregroundColor(Theme.textTertiary)
                                            }
                                        }
                                        Text(historyText(for: e))
                                            .font(.system(size: 11))
                                            .foregroundColor(Theme.textSecondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func commentsSection(_ b: BugDetail) -> some View {
        DSCard(radius: Radius.xl, padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Комментарии")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    if let c = b.commentsCount, c > 0 {
                        Text("\(c)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Theme.textTertiary)
                    }
                    Spacer()
                }

                ForEach(b.comments ?? []) { c in
                    commentRow(c)
                }

                if (b.comments ?? []).isEmpty {
                    Text("Комментариев пока нет")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textTertiary).italic()
                }

                // Input
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Оставить комментарий…", text: $commentDraft, axis: .vertical)
                        .lineLimit(1...4)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(Theme.pageBackground)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                        .overlay(RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(Theme.border, lineWidth: 0.5))
                    Button {
                        Task { await postComment() }
                    } label: {
                        ZStack {
                            Circle().fill(Theme.accent).frame(width: 36, height: 36)
                            if posting {
                                ProgressView().tint(.white).scaleEffect(0.7)
                            } else {
                                Image(systemName: "arrow.up")
                                    .foregroundColor(.white)
                                    .font(.system(size: 14, weight: .bold))
                            }
                        }
                        .shadow(color: Theme.accent.opacity(0.3), radius: 6, x: 0, y: 2)
                    }
                    .buttonStyle(DSPressScaleStyle())
                    .disabled(commentDraft.trimmingCharacters(in: .whitespaces).isEmpty || posting)
                }
            }
        }
    }

    @ViewBuilder
    private func commentRow(_ c: BugComment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            AvatarCircle(url: c.author.avatarUrl, name: c.author.displayName)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(c.author.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    if let s = c.createdAt, let d = ISO8601DateFormatter().date(from: s) {
                        Text(relativeTime(from: d))
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textTertiary)
                    }
                    if c.isEdited == true {
                        Text("ред.")
                            .font(.system(size: 9))
                            .italic()
                            .foregroundColor(Theme.textTertiary)
                    }
                    Spacer()
                    if canManage || c.author.id == currentUserId {
                        Menu {
                            Button {
                                editingCommentId = c.id
                                editingCommentText = c.content
                            } label: { Label("Редактировать", systemImage: "pencil") }
                            Button(role: .destructive) {
                                Task { await deleteComment(c.id) }
                            } label: { Label("Удалить", systemImage: "trash") }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textTertiary)
                        }
                    }
                }
                if editingCommentId == c.id {
                    TextField("Комментарий", text: $editingCommentText, axis: .vertical)
                        .font(.system(size: 13))
                        .lineLimit(1...6)
                        .padding(8)
                        .background(Theme.pageBackground)
                        .overlay(RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(Theme.accent.opacity(0.5), lineWidth: 0.5))
                        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                    HStack(spacing: 6) {
                        Button {
                            Task { await editComment(c.id, text: editingCommentText) }
                        } label: {
                            Text("Сохранить")
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .foregroundColor(.white)
                                .background(Theme.accent)
                                .clipShape(Capsule())
                        }
                        Button {
                            editingCommentId = nil
                            editingCommentText = ""
                        } label: {
                            Text("Отмена")
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .foregroundColor(Theme.textSecondary)
                                .background(Theme.pageBackground)
                                .clipShape(Capsule())
                        }
                    }
                } else {
                    Text(c.content)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: Detail actions

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let b: BugDetail = try await APIClient.shared.get("bugs/\(bugId)")
            self.bug = b
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func loadHistory() async {
        historyLoading = true
        defer { historyLoading = false }
        struct Resp: Decodable { let data: [BugHistoryEntry] }
        do {
            let r: Resp = try await APIClient.shared.get("bugs/\(bugId)/history")
            self.history = r.data
        } catch { /* silent */ }
    }

    private func quickUpdate(_ fields: [String: Any]) async {
        savingMeta = true
        defer { savingMeta = false }
        do {
            _ = try await APIClient.shared.rawRequest("PATCH", "bugs/\(bugId)", body: AnyJSONBody(fields))
            await load()
            onChange(true)
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func saveEdits() async {
        let payload: [String: Any] = [
            "title": titleDraft.trimmingCharacters(in: .whitespaces),
            "description": descDraft.trimmingCharacters(in: .whitespaces),
        ]
        await quickUpdate(payload)
        editingTitle = false
    }

    private func postComment() async {
        let text = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        struct Body: Encodable { let content: String }
        posting = true
        defer { posting = false }
        do {
            _ = try await APIClient.shared.rawRequest("POST", "bugs/\(bugId)/comments", body: Body(content: text))
            commentDraft = ""
            await load()
            onChange(true)
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func editComment(_ id: String, text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        struct Body: Encodable { let content: String }
        do {
            _ = try await APIClient.shared.rawRequest("PATCH", "bugs/comments/\(id)", body: Body(content: trimmed))
            editingCommentId = nil
            editingCommentText = ""
            await load()
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func deleteComment(_ id: String) async {
        do {
            try await APIClient.shared.delete("bugs/comments/\(id)")
            await load()
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func deleteBug() async {
        do {
            try await APIClient.shared.delete("bugs/\(bugId)")
            onChange(true)
            dismiss()
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func historyText(for e: BugHistoryEntry) -> String {
        let fieldRu: [String: String] = [
            "status": "статус", "priority": "приоритет", "platform": "платформу",
            "assignee": "исполнителя", "title": "заголовок"
        ]
        let statusRu: [String: String] = [
            "open": "Открыт", "in_progress": "В работе", "review": "На проверке",
            "resolved": "Решено", "closed": "Закрыто"
        ]
        let priorityRu = priorityLabelLong

        switch e.action {
        case "bug.created": return "создал(а) баг"
        case "bug.deleted": return "удалил(а) баг"
        case "bug.updated": return "обновил(а) баг"
        case "bug.field.changed":
            guard let dict = e.meta?.raw else { return "изменил(а) поля" }
            let parts = dict.compactMap { (key, anyVal) -> String? in
                guard let inner = anyVal.value as? [String: Any] else { return nil }
                let from = inner["from"] as? String ?? "—"
                let to = inner["to"] as? String ?? "—"
                let label = fieldRu[key] ?? key
                let fromLabel = key == "status" ? (statusRu[from] ?? from)
                              : key == "priority" ? (priorityRu[from] ?? from)
                              : from
                let toLabel = key == "status" ? (statusRu[to] ?? to)
                            : key == "priority" ? (priorityRu[to] ?? to)
                            : to
                return "\(label): \(fromLabel) → \(toLabel)"
            }
            return parts.joined(separator: " · ").isEmpty ? "изменил(а) поля" : parts.joined(separator: " · ")
        default: return e.action
        }
    }
}

// MARK: - Inline editors

private struct VersionInlineEditor: View {
    let value: String?
    let onSave: (String?) -> Void
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        if editing {
            HStack(spacing: 4) {
                TextField("1.2.3", text: $draft)
                    .font(.system(size: 13, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(maxWidth: 80)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(Theme.pageBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.accent.opacity(0.5)))
                Button {
                    let t = draft.trimmingCharacters(in: .whitespaces)
                    onSave(t.isEmpty ? nil : t)
                    editing = false
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Theme.accent)
                }
                Button {
                    editing = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Theme.textTertiary)
                }
            }
        } else {
            Button {
                draft = value ?? ""
                editing = true
            } label: {
                Text(value ?? "не указана")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(value == nil ? Theme.textTertiary : Theme.textSecondary)
                    .italic(value == nil)
            }
        }
    }
}

// MARK: - Create sheet

struct CreateBugSheet: View {
    let columns: [BugColumn]
    let initialStatus: String
    let onCreated: (BugItem) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var description = ""
    @State private var priority = "medium"
    @State private var platform = "ios"
    @State private var statusKey = ""
    @State private var tags = ""
    @State private var appVersion = ""
    @State private var attachments: [String] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var uploadingCount = 0
    @State private var working = false
    @State private var lastError: String?

    private static let priorities: [(String, String)] = [
        ("low", "Низкий"), ("medium", "Средний"),
        ("high", "Высокий"), ("critical", "Критический"),
    ]
    private static let platforms: [(String, String)] = [
        ("ios", "iOS"), ("android", "Android"),
        ("web", "Web"), ("backend", "Backend"), ("other", "Другое"),
    ]

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Заголовок") {
                    TextField("Краткое описание проблемы…", text: $title, axis: .vertical)
                        .lineLimit(1...3)
                }
                Section("Описание") {
                    TextField("Шаги воспроизведения, ожидаемый и фактический результат…",
                              text: $description, axis: .vertical)
                        .lineLimit(3...8)
                }
                Section("Параметры") {
                    Picker("Приоритет", selection: $priority) {
                        ForEach(Self.priorities, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    Picker("Платформа", selection: $platform) {
                        ForEach(Self.platforms, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    if !columns.isEmpty {
                        Picker("Колонка", selection: $statusKey) {
                            ForEach(columns) { col in Text(col.name).tag(col.key) }
                        }
                    }
                    TextField("Версия приложения (опц.)", text: $appVersion)
                    TextField("Теги через запятую (опц.)", text: $tags)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    PhotosPicker(selection: $photoItems, maxSelectionCount: 5,
                                 matching: .any(of: [.images, .videos])) {
                        Label(uploadingCount > 0
                              ? "Загружаю \(uploadingCount)…"
                              : "Прикрепить фото или видео",
                              systemImage: "paperclip")
                    }
                    .onChange(of: photoItems) { items in
                        Task { await handleAttachments(items) }
                    }
                    if !attachments.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(attachments.enumerated()), id: \.offset) { _, url in
                                    if let u = URL(string: ensureAbsolute(url)) {
                                        ZStack(alignment: .topTrailing) {
                                            AsyncImage(url: u) { phase in
                                                switch phase {
                                                case .success(let i): i.resizable().scaledToFill()
                                                default: Theme.pageBackground
                                                }
                                            }
                                            .frame(width: 70, height: 70)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            Button {
                                                attachments.removeAll { $0 == url }
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .foregroundColor(.white)
                                                    .background(Color.black.opacity(0.5).clipShape(Circle()))
                                                    .font(.system(size: 16))
                                            }
                                            .offset(x: 4, y: -4)
                                        }
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Вложения (\(attachments.count))")
                }
                if let err = lastError {
                    Section {
                        Text(err).font(.footnote).foregroundColor(Theme.danger)
                    }
                }
            }
            .navigationTitle("Новый баг-репорт")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }.disabled(working)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Создать") {
                            Task { await create() }
                        }
                        .disabled(!isValid || uploadingCount > 0)
                    }
                }
            }
            .onAppear {
                if statusKey.isEmpty {
                    statusKey = columns.first(where: { $0.key == initialStatus })?.key
                              ?? columns.first?.key
                              ?? "open"
                }
            }
        }
    }

    private struct CreateBody: Encodable {
        let title: String
        let description: String?
        let priority: String
        let platform: String
        let status: String
        let tags: [String]
        let appVersion: String?
        let attachments: [String]
    }

    private func create() async {
        let tagsArray = tags.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let body = CreateBody(
            title: title.trimmingCharacters(in: .whitespaces),
            description: description.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil
                : description.trimmingCharacters(in: .whitespaces),
            priority: priority,
            platform: platform,
            status: statusKey,
            tags: tagsArray,
            appVersion: appVersion.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil
                : appVersion.trimmingCharacters(in: .whitespaces),
            attachments: attachments
        )
        working = true
        lastError = nil
        defer { working = false }
        do {
            let created: BugItem = try await APIClient.shared.post("bugs", body: body)
            onCreated(created)
            dismiss()
        } catch {
            lastError = apiUserMessage(error)
        }
    }

    private func handleAttachments(_ items: [PhotosPickerItem]) async {
        for item in items {
            uploadingCount += 1
            defer { uploadingCount -= 1 }
            do {
                guard let raw = try await item.loadTransferable(type: Data.self) else { continue }
                let mime: String
                let ext: String
                if let img = UIImage(data: raw), let _ = img.jpegData(compressionQuality: 0.85) {
                    mime = "image/jpeg"
                    ext = "jpg"
                } else {
                    mime = "application/octet-stream"
                    ext = "bin"
                }
                let outData: Data = (UIImage(data: raw)?.jpegData(compressionQuality: 0.85)) ?? raw
                let req = BugUploadUrlRequest(
                    kind: "bug_attachment",
                    filename: "attachment-\(Int(Date().timeIntervalSince1970)).\(ext)",
                    mime: mime,
                    size: outData.count
                )
                let resp: BugUploadUrlResponse = try await APIClient.shared.request("POST", "files/upload-url", body: req)
                guard let putURL = URL(string: resp.uploadUrl) else { continue }
                var putReq = URLRequest(url: putURL)
                putReq.httpMethod = "PUT"
                putReq.setValue(mime, forHTTPHeaderField: "Content-Type")
                let (_, response) = try await URLSession.shared.upload(for: putReq, from: outData)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    lastError = "S3 PUT не удался (\(http.statusCode))"
                    continue
                }
                attachments.append(resp.fileUrl)
            } catch {
                lastError = apiUserMessage(error)
            }
        }
        photoItems.removeAll()
    }
}

private struct BugUploadUrlRequest: Encodable {
    let kind: String
    let filename: String
    let mime: String
    let size: Int
}
private struct BugUploadUrlResponse: Decodable {
    let uploadUrl: String
    let fileId: String?
    let storageKey: String?
    let fileUrl: String
}

// MARK: - Column manager

struct ColumnManagerSheet: View {
    let initial: [BugColumn]
    let onClose: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var list: [BugColumn] = []
    @State private var working = false
    @State private var error: String?
    @State private var deletingIdx: Int? = nil
    @State private var deleteTargetKey = ""
    @State private var changed = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(list.enumerated()), id: \.element.id) { idx, col in
                        ColumnRow(
                            column: col,
                            onRename: { name in
                                list[idx] = BugColumn(id: col.id, key: col.key, name: name,
                                                      color: col.color, order: col.order, isDefault: col.isDefault)
                            },
                            onRenameCommit: { name in
                                Task { await rename(col, name: name) }
                            },
                            onColor: { color in
                                list[idx] = BugColumn(id: col.id, key: col.key, name: col.name,
                                                      color: color, order: col.order, isDefault: col.isDefault)
                                Task { await recolor(col, color: color) }
                            },
                            onDelete: list.count > 1 ? {
                                deletingIdx = idx
                                deleteTargetKey = list.first(where: { $0.id != col.id })?.key ?? ""
                            } : nil
                        )
                    }
                    .onMove { indices, newIdx in
                        list.move(fromOffsets: indices, toOffset: newIdx)
                        Task { await reorder() }
                    }
                } header: {
                    Text("Перетащите для изменения порядка. При удалении баги переносятся в выбранную колонку.")
                        .font(.caption)
                        .foregroundColor(Theme.textTertiary)
                        .textCase(.none)
                }
                if let e = error {
                    Section { Text(e).foregroundColor(Theme.danger).font(.footnote) }
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Колонки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Готово") {
                        onClose(changed)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await addColumn() }
                    } label: {
                        if working { ProgressView() }
                        else { Image(systemName: "plus.circle.fill") }
                    }
                    .disabled(working)
                }
            }
            .onAppear { list = initial }
            .alert("Удалить колонку «\(deletingIdx.flatMap { list[safe: $0]?.name } ?? "")»?",
                   isPresented: Binding(get: { deletingIdx != nil }, set: { if !$0 { deletingIdx = nil } })) {
                Button("Удалить", role: .destructive) {
                    Task { await deleteColumn() }
                }
                Button("Отмена", role: .cancel) { deletingIdx = nil }
            } message: {
                Text("Баги будут перенесены. Выберите целевую колонку в подменю списка.")
            }
            .sheet(isPresented: Binding(get: { deletingIdx != nil }, set: { if !$0 { deletingIdx = nil } })) {
                if let idx = deletingIdx, let col = list[safe: idx] {
                    DeleteColumnSheet(
                        column: col,
                        targets: list.filter { $0.id != col.id },
                        targetKey: $deleteTargetKey,
                        onConfirm: {
                            Task { await deleteColumn() }
                        }
                    )
                    .presentationDetents([.medium])
                }
            }
        }
    }

    private func addColumn() async {
        struct Body: Encodable { let name: String; let color: String }
        working = true
        defer { working = false }
        do {
            let new: BugColumn = try await APIClient.shared.post("bug-columns",
                                                                  body: Body(name: "Новая колонка", color: "sky"))
            list.append(new)
            changed = true
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func rename(_ col: BugColumn, name: String) async {
        guard !col.id.hasPrefix("fb-") else { return }
        guard col.name != name else { return }
        struct Body: Encodable { let name: String }
        do {
            _ = try await APIClient.shared.rawRequest("PATCH", "bug-columns/\(col.id)", body: Body(name: name))
            changed = true
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func recolor(_ col: BugColumn, color: String) async {
        guard !col.id.hasPrefix("fb-") else { return }
        struct Body: Encodable { let color: String }
        do {
            _ = try await APIClient.shared.rawRequest("PATCH", "bug-columns/\(col.id)", body: Body(color: color))
            changed = true
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func reorder() async {
        let ids = list.map { $0.id }
        guard ids.allSatisfy({ !$0.hasPrefix("fb-") }) else { return }
        struct Body: Encodable { let order: [String] }
        do {
            _ = try await APIClient.shared.rawRequest("PATCH", "bug-columns/reorder", body: Body(order: ids))
            changed = true
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func deleteColumn() async {
        guard let idx = deletingIdx, let col = list[safe: idx] else { return }
        guard let target = list.first(where: { $0.key == deleteTargetKey }) else { return }
        do {
            _ = try await APIClient.shared.rawRequest("DELETE", "bug-columns/\(col.id)?targetId=\(target.id)")
            list.remove(at: idx)
            deletingIdx = nil
            changed = true
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}

private struct ColumnRow: View {
    let column: BugColumn
    let onRename: (String) -> Void
    let onRenameCommit: (String) -> Void
    let onColor: (String) -> Void
    let onDelete: (() -> Void)?
    @State private var name: String = ""
    @State private var color: String = "sky"

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(columnColor(color)).frame(width: 12, height: 12)
            TextField("Название", text: $name)
                .font(.system(size: 14))
                .onChange(of: name) { v in onRename(v) }
                .onSubmit { onRenameCommit(name) }
            Spacer()
            Menu {
                ForEach(bugColorOptions, id: \.self) { c in
                    Button {
                        color = c
                        onColor(c)
                    } label: {
                        Label(c, systemImage: c == color ? "checkmark" : "circle.fill")
                    }
                }
            } label: {
                Image(systemName: "paintpalette.fill")
                    .foregroundColor(columnColor(color))
            }
            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundColor(Theme.danger)
                }
                .buttonStyle(.borderless)
            }
        }
        .onAppear {
            name = column.name
            color = column.color ?? "sky"
        }
        .onChange(of: column) { c in
            if c.name != name { name = c.name }
            if (c.color ?? "sky") != color { color = c.color ?? "sky" }
        }
    }
}

private struct DeleteColumnSheet: View {
    let column: BugColumn
    let targets: [BugColumn]
    @Binding var targetKey: String
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Куда перенести баги") {
                    Picker("Колонка", selection: $targetKey) {
                        ForEach(targets) { Text($0.name).tag($0.key) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            .navigationTitle("Удалить «\(column.name)»")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Удалить", role: .destructive) {
                        onConfirm()
                        dismiss()
                    }
                    .disabled(targetKey.isEmpty)
                }
            }
        }
    }
}

// MARK: - Helpers

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private func isImageURL(_ s: String) -> Bool {
    let lower = s.lowercased()
    return [".jpg", ".jpeg", ".png", ".webp", ".gif", ".svg", ".heic", ".heif"].contains { lower.contains($0) }
}

private func isVideoURL(_ s: String) -> Bool {
    let lower = s.lowercased()
    return [".mp4", ".mov", ".m4v", ".webm", ".avi", ".mkv"].contains { lower.contains($0) }
}

// MARK: - Fullscreen media viewer for bug attachments

/// Тип вложения, открытого на весь экран.
/// Для изображений поддерживается листание свайпом между несколькими URL —
/// `images([URL], startIndex: Int)`. Видео по-прежнему открывается одиночно.
enum BugFullscreenMedia: Identifiable, Equatable {
    case images(urls: [URL], startIndex: Int)
    case video(URL)

    /// Удобный конструктор для одиночного изображения (legacy call-sites).
    static func image(_ url: URL) -> BugFullscreenMedia {
        .images(urls: [url], startIndex: 0)
    }

    var id: String {
        switch self {
        case .images(let urls, let idx):
            // ID должен меняться при открытии другого набора —
            // включаем урлы и стартовый индекс.
            return "imgs:\(idx):" + urls.map { $0.absoluteString }.joined(separator: "|")
        case .video(let u):
            return "vid:\(u.absoluteString)"
        }
    }
}

/// Полноэкранный просмотр изображений (свайп + zoom/pan) или видео (AVKit player).
private struct BugFullscreenMediaViewer: View {
    let media: BugFullscreenMedia
    let onClose: () -> Void

    /// Текущий индекс страницы — нужен, чтобы корректно показывать индикатор
    /// и переоткрывать первое изображение, если пользователь свайпал.
    @State private var pageIndex: Int = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            switch media {
            case .images(let urls, _):
                if urls.count <= 1, let only = urls.first {
                    ZoomableAsyncImage(url: only)
                } else {
                    TabView(selection: $pageIndex) {
                        ForEach(Array(urls.enumerated()), id: \.offset) { idx, url in
                            ZoomableAsyncImage(url: url)
                                .tag(idx)
                                // ZoomableAsyncImage сам читает GeometryReader,
                                // поэтому жесты zoom/pan не конфликтуют с TabView swipe
                                // пока scale == 1 (drag блокируется внутри жеста).
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: urls.count > 1 ? .always : .never))
                    .indexViewStyle(.page(backgroundDisplayMode: .always))
                    .ignoresSafeArea()
                }
            case .video(let url):
                VideoPlayer(player: AVPlayer(url: url))
                    .ignoresSafeArea()
            }

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white, .black.opacity(0.5))
            }
            .padding(.top, 12)
            .padding(.trailing, 12)
            .accessibilityLabel("Закрыть")
        }
        .statusBarHidden(true)
        .onAppear {
            if case .images(_, let start) = media {
                pageIndex = start
            }
        }
    }
}

/// Pinch-to-zoom + drag-to-pan для AsyncImage.
/// Двойной тап — переключение zoom 1× ↔ 2.5×.
private struct ZoomableAsyncImage: View {
    let url: URL

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    ProgressView().tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .success(let img):
                    img.resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(
                            SimultaneousGesture(
                                MagnificationGesture()
                                    .onChanged { value in
                                        scale = max(1, min(5, lastScale * value))
                                    }
                                    .onEnded { _ in
                                        lastScale = scale
                                        if scale < 1.05 {
                                            withAnimation(.spring()) {
                                                scale = 1; lastScale = 1
                                                offset = .zero; lastOffset = .zero
                                            }
                                        }
                                    },
                                DragGesture()
                                    .onChanged { value in
                                        guard scale > 1.05 else { return }
                                        offset = CGSize(
                                            width: lastOffset.width + value.translation.width,
                                            height: lastOffset.height + value.translation.height
                                        )
                                    }
                                    .onEnded { _ in lastOffset = offset }
                            )
                        )
                        .onTapGesture(count: 2) {
                            withAnimation(.spring()) {
                                if scale > 1.05 {
                                    scale = 1; lastScale = 1
                                    offset = .zero; lastOffset = .zero
                                } else {
                                    scale = 2.5; lastScale = 2.5
                                }
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                case .failure:
                    VStack(spacing: 10) {
                        Image(systemName: "photo")
                            .font(.system(size: 48))
                            .foregroundColor(.white.opacity(0.5))
                        Text("Не удалось загрузить изображение")
                            .font(.footnote)
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                @unknown default:
                    Color.black
                }
            }
        }
    }
}

private func formatFullDate(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "ru_RU")
    f.dateFormat = "d MMM yyyy"
    return f.string(from: d)
}

/// Encodable для произвольного JSON-объекта (используется в quickUpdate с
/// разнотипными значениями — String / Array / NSNull).
private struct AnyJSONBody: Encodable {
    let payload: [String: Any]
    init(_ payload: [String: Any]) { self.payload = payload }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        for (k, v) in payload {
            let key = DynamicKey(stringValue: k)!
            switch v {
            case is NSNull:
                try c.encodeNil(forKey: key)
            case let s as String:
                try c.encode(s, forKey: key)
            case let i as Int:
                try c.encode(i, forKey: key)
            case let d as Double:
                try c.encode(d, forKey: key)
            case let b as Bool:
                try c.encode(b, forKey: key)
            case let arr as [String]:
                try c.encode(arr, forKey: key)
            case let arr as [Any]:
                try c.encode(arr.compactMap { $0 as? String }, forKey: key)
            default:
                try c.encodeNil(forKey: key)
            }
        }
    }
    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

// MARK: - Flow layout for tags

private struct BugsFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > maxWidth {
                x = 0; y += lineHeight + spacing; lineHeight = 0
            }
            x += s.width + spacing
            lineHeight = max(lineHeight, s.height)
        }
        return CGSize(width: maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, lineHeight: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX {
                x = bounds.minX; y += lineHeight + spacing; lineHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineHeight = max(lineHeight, s.height)
        }
    }
}
