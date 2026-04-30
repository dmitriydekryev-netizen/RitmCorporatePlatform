//
//  FeedbackAdminView.swift — нативная админка фидбека (идеи/баги).
//
//  Endpoints (apps/api/src/modules/feedback/feedback.controller.ts):
//   • GET    /feedback?status=&type=        — список (бэк сам отдаёт всё для админа)
//   • GET    /feedback/counts               — счётчики
//   • GET    /feedback/:id                  — детали
//   • PATCH  /feedback/:id/status           — { status, adminComment }
//   • DELETE /feedback/:id                  — удалить
//

import SwiftUI

private struct AdminFeedbackEnvelope: Codable {
    let data: [FeedbackItem]?
}

private enum AdminFbStatus: String, CaseIterable, Identifiable {
    case all, new, in_review, in_progress, approved, rejected
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "Все"
        case .new: return "Новые"
        case .in_review: return "На рассмотр."
        case .in_progress: return "В работе"
        case .approved: return "Принято"
        case .rejected: return "Отклон."
        }
    }
    var param: String? { self == .all ? nil : rawValue }
}

private enum AdminFbType: String, CaseIterable, Identifiable {
    case all, idea, suggestion, bug
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "Все"
        case .idea: return "Идеи"
        case .suggestion: return "Предлож."
        case .bug: return "Баги"
        }
    }
    var param: String? { self == .all ? nil : rawValue }
}

private enum AdminFbSort: String, CaseIterable, Identifiable {
    case newest, oldest, votes, mostUpdated
    var id: String { rawValue }
    var title: String {
        switch self {
        case .newest: return "Сначала новые"
        case .oldest: return "Сначала старые"
        case .votes: return "По голосам"
        case .mostUpdated: return "По обновлению"
        }
    }
}

struct FeedbackAdminView: View {
    @State private var items: [FeedbackItem] = []
    @State private var loading = true
    @State private var error: String?
    @State private var statusFilter: AdminFbStatus = .all
    @State private var typeFilter: AdminFbType = .all
    @State private var sort: AdminFbSort = .newest
    @State private var search = ""

    private var filteredAndSorted: [FeedbackItem] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        var out = items
        if !q.isEmpty {
            out = out.filter { item in
                let blob = "\(item.title) \(item.description ?? "") \(item.author?.fullName ?? "")".lowercased()
                return blob.contains(q)
            }
        }
        switch sort {
        case .newest:
            out.sort { $0.createdAt > $1.createdAt }
        case .oldest:
            out.sort { $0.createdAt < $1.createdAt }
        case .votes:
            out.sort { ($0.votesCount ?? 0) > ($1.votesCount ?? 0) }
        case .mostUpdated:
            out.sort { ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt) }
        }
        return out
    }

    var body: some View {
        ZStack {
            Theme.pageBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    DSPageTitle(text: "Идеи и баги",
                                subtitle: items.isEmpty ? nil : "Записей: \(items.count)")
                        .padding(.top, 4)

                    Picker("Тип", selection: $typeFilter) {
                        ForEach(AdminFbType.allCases) { t in Text(t.title).tag(t) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: typeFilter) { _ in Task { await load() } }

                    Picker("Статус", selection: $statusFilter) {
                        ForEach(AdminFbStatus.allCases) { s in Text(s.title).tag(s) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: statusFilter) { _ in Task { await load() } }

                    if loading && items.isEmpty {
                        ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.top, 60)
                    } else if let err = error, items.isEmpty {
                        EmptyStateView(icon: "exclamationmark.triangle", title: "Ошибка", description: err)
                    } else if filteredAndSorted.isEmpty {
                        EmptyStateView(icon: "lightbulb",
                                       title: search.isEmpty ? "Пусто" : "Ничего не найдено",
                                       description: search.isEmpty ? "Записей нет" : "Попробуйте другой запрос")
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(filteredAndSorted) { item in
                                NavigationLink {
                                    FeedbackAdminDetailView(item: item) { Task { await load() } }
                                } label: {
                                    AdminFeedbackCard(item: item)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Идеи и баги")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Поиск по содержимому")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Picker("Сортировка", selection: $sort) {
                        ForEach(AdminFbSort.allCases) { s in
                            Text(s.title).tag(s)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down.circle")
                        .font(.system(size: 16, weight: .semibold))
                }
                .tint(Theme.accent)
            }
        }
        .refreshable { await load() }
        .task { if items.isEmpty { await load() } }
    }

    private func load() async {
        loading = true; defer { loading = false }
        var q: [String: String] = [:]
        if let s = statusFilter.param { q["status"] = s }
        if let t = typeFilter.param { q["type"] = t }
        if let arr: [FeedbackItem] = try? await fetchList("feedback", query: q) {
            self.items = arr; self.error = nil; return
        }
        do {
            let arr: [FeedbackItem] = try await fetchList("admin/feedback", query: q)
            self.items = arr
            self.error = nil
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func fetchList(_ path: String, query: [String: String]) async throws -> [FeedbackItem] {
        if let env: AdminFeedbackEnvelope = try? await APIClient.shared.get(path, query: query),
           let arr = env.data {
            return arr
        }
        return try await APIClient.shared.get(path, query: query)
    }
}

struct AdminFeedbackCard: View {
    let item: FeedbackItem

    private var typeColor: Color {
        switch item.type {
        case "bug": return Theme.danger
        case "idea": return Theme.warning
        case "suggestion": return Theme.accent
        default: return Theme.textTertiary
        }
    }
    private var typeIcon: String {
        switch item.type {
        case "bug": return "ant.fill"
        case "idea": return "lightbulb.fill"
        case "suggestion": return "sparkles"
        default: return "doc"
        }
    }
    private var typeLabel: String {
        switch item.type {
        case "bug": return "Баг"
        case "idea": return "Идея"
        case "suggestion": return "Предложение"
        default: return item.type ?? "—"
        }
    }
    private var statusLabel: String {
        switch item.status {
        case "new": return "Новый"
        case "in_review": return "На рассмотрении"
        case "in_progress": return "В работе"
        case "approved": return "Принято"
        case "rejected": return "Отклонено"
        default: return item.status ?? "—"
        }
    }
    private var statusColor: Color {
        switch item.status {
        case "new": return Theme.accent
        case "in_review": return Theme.warning
        case "in_progress": return Theme.indigo
        case "approved": return Theme.success
        case "rejected": return Theme.danger
        default: return Theme.textTertiary
        }
    }

    var body: some View {
        DSCard(radius: Radius.lg, padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    DSIconTile(systemImage: typeIcon, color: typeColor, size: 32)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.dsBodyLG.weight(.semibold)).foregroundColor(Theme.textPrimary).lineLimit(2)
                        HStack(spacing: 6) {
                            DSBadge(text: typeLabel, color: typeColor, filled: false)
                            DSBadge(text: statusLabel, color: statusColor, filled: true)
                            if let v = item.votesCount, v > 0 {
                                HStack(spacing: 2) {
                                    Image(systemName: "arrow.up").font(.system(size: 9))
                                    Text("\(v)").font(.dsCaption.monospacedDigit())
                                }
                                .foregroundColor(Theme.textSecondary)
                            }
                        }
                    }
                    Spacer()
                }
                HStack(spacing: 6) {
                    if let a = item.author {
                        AvatarCircle(url: a.avatarUrl, name: a.fullName).frame(width: 16, height: 16)
                        Text(a.fullName).font(.dsCaption).foregroundColor(Theme.textSecondary)
                    }
                    Spacer()
                    if let d = ISO8601DateFormatter().date(from: item.createdAt) {
                        Text(relativeTime(from: d)).font(.dsCaption).foregroundColor(Theme.textTertiary)
                    }
                }
            }
        }
    }
}

// MARK: - Detail

struct FeedbackAdminDetailView: View {
    let item: FeedbackItem
    let onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var status: String
    @State private var adminComment: String
    @State private var saving = false
    @State private var error: String?
    @State private var showDeleteConfirm = false

    init(item: FeedbackItem, onChanged: @escaping () -> Void) {
        self.item = item
        self.onChanged = onChanged
        self._status = State(initialValue: item.status ?? "new")
        self._adminComment = State(initialValue: item.adminComment ?? "")
    }

    private let statusOptions: [(key: String, title: String)] = [
        ("new", "Новый"),
        ("in_review", "На рассмотрении"),
        ("in_progress", "В работе"),
        ("approved", "Принято"),
        ("rejected", "Отклонено")
    ]

    var body: some View {
        ZStack {
            Theme.pageBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    DSCard(radius: Radius.xl, padding: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                DSBadge(text: typeLabel, color: typeColor, filled: false)
                                DSBadge(text: currentStatusLabel, color: currentStatusColor, filled: true)
                                Spacer()
                                if let v = item.votesCount, v > 0 {
                                    HStack(spacing: 2) {
                                        Image(systemName: "arrow.up")
                                        Text("\(v)").monospacedDigit()
                                    }
                                    .font(.dsCaption)
                                    .foregroundColor(Theme.textSecondary)
                                }
                            }
                            Text(item.title).font(.dsH2).foregroundColor(Theme.textPrimary)
                            if let d = item.description, !d.isEmpty {
                                Text(d).font(.dsBodyLG).foregroundColor(Theme.textPrimary)
                            }
                            if let a = item.author {
                                HStack(spacing: 6) {
                                    AvatarCircle(url: a.avatarUrl, name: a.fullName).frame(width: 20, height: 20)
                                    Text(a.fullName).font(.dsCaption).foregroundColor(Theme.textSecondary)
                                    if let d = ISO8601DateFormatter().date(from: item.createdAt) {
                                        Text("· \(relativeTime(from: d))")
                                            .font(.dsCaption).foregroundColor(Theme.textTertiary)
                                    }
                                }
                            }
                        }
                    }

                    DSCard(radius: Radius.lg, padding: 14) {
                        VStack(alignment: .leading, spacing: 10) {
                            DSSectionHeader("Статус")
                            Picker("Статус", selection: $status) {
                                ForEach(statusOptions, id: \.key) { opt in
                                    Text(opt.title).tag(opt.key)
                                }
                            }
                            .pickerStyle(.menu)

                            DSSectionHeader("Ответ автору")
                            TextEditor(text: $adminComment)
                                .frame(minHeight: 100)
                                .padding(8)
                                .background(Theme.pageBackground)
                                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                            Text("Этот текст увидит автор заявки.")
                                .font(.dsCaption).foregroundColor(Theme.textTertiary)
                        }
                    }

                    if let err = error {
                        Text(err).font(.dsCaption).foregroundColor(Theme.danger)
                    }

                    DSPrimaryButton(action: { Task { await save() } }, loading: saving, enabled: !saving) {
                        Text("Сохранить")
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Запись")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Section("Сменить статус") {
                        ForEach(statusOptions, id: \.key) { opt in
                            Button {
                                status = opt.key
                            } label: {
                                Label(opt.title, systemImage: status == opt.key ? "checkmark" : "")
                            }
                        }
                    }
                    Divider()
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Удалить", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .tint(Theme.accent)
            }
        }
        .alert("Удалить запись?", isPresented: $showDeleteConfirm) {
            Button("Удалить", role: .destructive) { Task { await deleteItem() } }
            Button("Отмена", role: .cancel) {}
        }
    }

    private var typeColor: Color {
        switch item.type {
        case "bug": return Theme.danger
        case "idea": return Theme.warning
        case "suggestion": return Theme.accent
        default: return Theme.textTertiary
        }
    }
    private var typeLabel: String {
        switch item.type {
        case "bug": return "Баг"
        case "idea": return "Идея"
        case "suggestion": return "Предложение"
        default: return item.type ?? "—"
        }
    }
    private var currentStatusLabel: String {
        statusOptions.first { $0.key == status }?.title ?? status
    }
    private var currentStatusColor: Color {
        switch status {
        case "new": return Theme.accent
        case "in_review": return Theme.warning
        case "in_progress": return Theme.indigo
        case "approved": return Theme.success
        case "rejected": return Theme.danger
        default: return Theme.textTertiary
        }
    }

    struct UpdateBody: Encodable {
        let status: String
        let adminComment: String?
    }

    private func save() async {
        saving = true; defer { saving = false }
        let body = UpdateBody(status: status, adminComment: adminComment.isEmpty ? nil : adminComment)
        // Правильный путь — /feedback/:id/status (см. контроллер)
        do {
            _ = try await APIClient.shared.rawRequest("PATCH", "feedback/\(item.id)/status", body: body)
            onChanged()
        } catch {
            // fallbacks
            do {
                _ = try await APIClient.shared.rawRequest("PATCH", "admin/feedback/\(item.id)", body: body)
                onChanged()
            } catch {
                self.error = apiUserMessage(error)
            }
        }
    }

    private func deleteItem() async {
        do {
            _ = try await APIClient.shared.rawRequest("DELETE", "feedback/\(item.id)")
            onChanged()
            dismiss()
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}

#Preview {
    NavigationStack { FeedbackAdminView() }
}
