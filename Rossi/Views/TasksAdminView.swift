//
//  TasksAdminView.swift — нативная админка задач (всех пользователей).
//
//  Endpoints (apps/api/src/modules/tasks/tasks.controller.ts):
//   • GET    /tasks?status=         — список с фильтром
//   • GET    /tasks/mine            — мои задачи
//   • GET    /tasks/created         — созданные мной
//   • POST   /tasks                 — создать (DTO: title/description/assigneeId/dueDate)
//   • PATCH  /tasks/:id             — обновить (title/description/dueDate)
//   • PATCH  /tasks/:id/status      — изменить статус (DTO: status, comment?)
//   • DELETE /tasks/:id             — удалить
//

import SwiftUI

struct AdminTaskItem: Codable, Identifiable {
    let id: String
    let title: String
    let description: String?
    let status: String
    let statusComment: String?
    let dueDate: String?
    let createdAt: String?
    let updatedAt: String?
    let assignee: AdminTaskUser?
    let creator: AdminTaskUser?
}

struct AdminTaskUser: Codable {
    let id: String?
    let username: String?
    let firstName: String?
    let lastName: String?
    let avatarUrl: String?
    let profile: AdminTaskUserProfile?

    var displayName: String {
        let p1 = profile?.firstName ?? firstName ?? ""
        let p2 = profile?.lastName ?? lastName ?? ""
        let combo = "\(p1) \(p2)".trimmingCharacters(in: .whitespaces)
        return combo.isEmpty ? (username ?? "—") : combo
    }
    var avatar: String? { profile?.avatarUrl ?? avatarUrl }
}

struct AdminTaskUserProfile: Codable {
    let firstName: String?
    let lastName: String?
    let avatarUrl: String?
}

private struct AdminTasksEnvelope: Codable {
    let data: [AdminTaskItem]?
}

private enum AdminTaskFilter: String, CaseIterable, Identifiable {
    case all, pending, in_progress, done, cancelled
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "Все"
        case .pending: return "Ожидают"
        case .in_progress: return "В работе"
        case .done: return "Готовы"
        case .cancelled: return "Отменены"
        }
    }
    var statusParam: String? { self == .all ? nil : rawValue }
}

struct TasksAdminView: View {
    @State private var tasks: [AdminTaskItem] = []
    @State private var loading = true
    @State private var error: String?
    @State private var filter: AdminTaskFilter = .all
    @State private var showCreate = false

    var body: some View {
        ZStack {
            Theme.pageBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    DSPageTitle(text: "Задачи",
                                subtitle: tasks.isEmpty ? nil : "Всего: \(tasks.count)")
                        .padding(.top, 4)

                    Picker("Статус", selection: $filter) {
                        ForEach(AdminTaskFilter.allCases) { f in
                            Text(f.title).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: filter) { _ in Task { await load() } }

                    if loading && tasks.isEmpty {
                        ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.top, 60)
                    } else if let err = error, tasks.isEmpty {
                        EmptyStateView(icon: "exclamationmark.triangle", title: "Ошибка", description: err)
                    } else if tasks.isEmpty {
                        EmptyStateView(icon: "checkmark.circle", title: "Скоро будет", description: "Задач нет")
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(tasks) { task in
                                NavigationLink {
                                    SimpleAdminTaskDetailView(task: task) { Task { await load() } }
                                } label: {
                                    AdminTaskRow(task: task)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Задачи")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showCreate = true } label: {
                    Image(systemName: "plus").font(.system(size: 16, weight: .semibold))
                }.tint(Theme.accent)
            }
        }
        .refreshable { await load() }
        .task { if tasks.isEmpty { await load() } }
        .sheet(isPresented: $showCreate) {
            CreateAdminTaskSheet { Task { await load() } }
        }
    }

    private func load() async {
        loading = true; defer { loading = false }
        var q: [String: String] = [:]
        if let s = filter.statusParam { q["status"] = s }
        if let arr: [AdminTaskItem] = try? await fetchTasks("tasks", query: q) {
            self.tasks = arr; self.error = nil; return
        }
        do {
            let arr: [AdminTaskItem] = try await fetchTasks("admin/tasks", query: q)
            self.tasks = arr
            self.error = nil
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func fetchTasks(_ path: String, query: [String: String]) async throws -> [AdminTaskItem] {
        if let env: AdminTasksEnvelope = try? await APIClient.shared.get(path, query: query),
           let arr = env.data {
            return arr
        }
        return try await APIClient.shared.get(path, query: query)
    }
}

struct AdminTaskRow: View {
    let task: AdminTaskItem

    var body: some View {
        DSCard(radius: Radius.lg, padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.title).font(.dsBodyLG.weight(.semibold)).foregroundColor(Theme.textPrimary)
                        if let d = task.description, !d.isEmpty {
                            Text(d).font(.dsCaption).foregroundColor(Theme.textTertiary).lineLimit(2)
                        }
                    }
                    Spacer()
                    DSBadge(text: taskStatusLabel(task.status), color: taskStatusColor(task.status), filled: true)
                }
                HStack(spacing: 10) {
                    if let a = task.assignee {
                        HStack(spacing: 4) {
                            AvatarCircle(url: a.avatar, name: a.displayName).frame(width: 18, height: 18)
                            Text(a.displayName).font(.dsCaption).foregroundColor(Theme.textSecondary).lineLimit(1)
                        }
                    }
                    if let due = task.dueDate, let d = ISO8601DateFormatter().date(from: due) {
                        HStack(spacing: 3) {
                            Image(systemName: "calendar").font(.system(size: 10)).foregroundColor(Theme.textTertiary)
                            Text(formatTaskDate(d)).font(.dsCaption).foregroundColor(Theme.textTertiary)
                        }
                    }
                    Spacer()
                }
            }
        }
    }
}

func taskStatusLabel(_ s: String) -> String {
    switch s {
    case "pending": return "Ожидает"
    case "in_progress": return "В работе"
    case "done": return "Готово"
    case "cancelled": return "Отменена"
    default: return s
    }
}
func taskStatusColor(_ s: String) -> Color {
    switch s {
    case "pending": return Theme.warning
    case "in_progress": return Theme.accent
    case "done": return Theme.success
    case "cancelled": return Theme.danger
    default: return Theme.textTertiary
    }
}
func formatTaskDate(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "ru_RU")
    f.dateFormat = "d MMM"
    return f.string(from: d)
}

// MARK: - Detail

struct SimpleAdminTaskDetailView: View {
    let task: AdminTaskItem
    let onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var current: AdminTaskItem
    @State private var changing = false
    @State private var pendingStatus: String?
    @State private var statusComment: String = ""
    @State private var showCommentSheet = false
    @State private var error: String?
    @State private var showDeleteConfirm = false

    init(task: AdminTaskItem, onChanged: @escaping () -> Void) {
        self.task = task
        self.onChanged = onChanged
        self._current = State(initialValue: task)
    }

    private let statuses: [(String, String)] = [
        ("pending", "Ожидает"),
        ("in_progress", "В работе"),
        ("done", "Готово"),
        ("cancelled", "Отменена"),
    ]

    var body: some View {
        ZStack {
            Theme.pageBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    DSCard(radius: Radius.xl, padding: 16) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(current.title).font(.dsH2).foregroundColor(Theme.textPrimary)
                            HStack(spacing: 6) {
                                DSBadge(text: taskStatusLabel(current.status),
                                        color: taskStatusColor(current.status), filled: true)
                                if let due = current.dueDate, let d = ISO8601DateFormatter().date(from: due) {
                                    DSBadge(text: "до \(formatTaskDate(d))", color: Theme.textSecondary, filled: false)
                                }
                            }
                            if let comment = current.statusComment, !comment.isEmpty {
                                Text("💬 \(comment)")
                                    .font(.dsCaption.italic())
                                    .foregroundColor(Theme.textSecondary)
                            }
                        }
                    }

                    if let d = current.description, !d.isEmpty {
                        DSCard(radius: Radius.lg, padding: 14) {
                            VStack(alignment: .leading, spacing: 6) {
                                DSSectionHeader("Описание")
                                Text(d).font(.dsBodyLG).foregroundColor(Theme.textPrimary)
                            }
                        }
                    }

                    if let a = current.assignee {
                        userCard(title: "Исполнитель", user: a)
                    }
                    if let c = current.creator {
                        userCard(title: "Создатель", user: c)
                    }

                    if let err = error {
                        Text(err).font(.dsCaption).foregroundColor(Theme.danger)
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Задача")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Section("Изменить статус") {
                        ForEach(statuses, id: \.0) { s in
                            Button {
                                pendingStatus = s.0
                                statusComment = ""
                                showCommentSheet = true
                            } label: {
                                Label(s.1, systemImage: current.status == s.0 ? "checkmark" : "")
                            }
                            .disabled(current.status == s.0)
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
                        .font(.system(size: 16, weight: .semibold))
                }
                .tint(Theme.accent)
                .disabled(changing)
            }
        }
        .alert("Удалить задачу?", isPresented: $showDeleteConfirm) {
            Button("Удалить", role: .destructive) { Task { await deleteTask() } }
            Button("Отмена", role: .cancel) {}
        }
        .sheet(isPresented: $showCommentSheet) {
            statusCommentSheet
        }
    }

    @ViewBuilder
    private var statusCommentSheet: some View {
        NavigationStack {
            Form {
                Section("Комментарий (необязательно)") {
                    TextField("Например: причина смены статуса", text: $statusComment, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .navigationTitle("Сменить статус")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { showCommentSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(changing ? "…" : "Применить") {
                        Task { await changeStatus() }
                    }
                    .disabled(changing)
                }
            }
        }
    }

    @ViewBuilder
    private func userCard(title: String, user: AdminTaskUser) -> some View {
        DSCard(radius: Radius.lg, padding: 14) {
            HStack(spacing: 12) {
                AvatarCircle(url: user.avatar, name: user.displayName).frame(width: 36, height: 36)
                VStack(alignment: .leading) {
                    Text(title).font(.dsCaption).foregroundColor(Theme.textTertiary)
                    Text(user.displayName).font(.dsBodyLG.weight(.medium)).foregroundColor(Theme.textPrimary)
                    if let u = user.username {
                        Text("@\(u)").font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.textTertiary)
                    }
                }
                Spacer()
            }
        }
    }

    struct StatusBody: Encodable {
        let status: String
        let comment: String?
    }

    private func changeStatus() async {
        guard let new = pendingStatus else { return }
        changing = true
        defer { changing = false }
        let body = StatusBody(status: new, comment: statusComment.isEmpty ? nil : statusComment)
        do {
            _ = try await APIClient.shared.rawRequest("PATCH", "tasks/\(current.id)/status", body: body)
            current = AdminTaskItem(
                id: current.id, title: current.title, description: current.description,
                status: new, statusComment: statusComment.isEmpty ? current.statusComment : statusComment,
                dueDate: current.dueDate, createdAt: current.createdAt,
                updatedAt: ISO8601DateFormatter().string(from: Date()),
                assignee: current.assignee, creator: current.creator
            )
            showCommentSheet = false
            onChanged()
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func deleteTask() async {
        do {
            _ = try await APIClient.shared.rawRequest("DELETE", "tasks/\(current.id)")
            onChanged()
            dismiss()
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}

// MARK: - Create Sheet

struct CreateAdminTaskSheet: View {
    let onCreated: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var description = ""
    @State private var assigneeId = ""
    @State private var hasDueDate = false
    @State private var dueDate: Date = Date().addingTimeInterval(86400)
    @State private var users: [AdminUserItem] = []
    @State private var userSearch = ""
    @State private var saving = false
    @State private var error: String?

    private var filteredUsers: [AdminUserItem] {
        let q = userSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return users }
        return users.filter { u in
            "\(u.profile?.firstName ?? "") \(u.profile?.lastName ?? "") \(u.username) \(u.email)".lowercased().contains(q)
        }
    }

    private var canSubmit: Bool {
        title.trimmingCharacters(in: .whitespaces).count >= 3 && !assigneeId.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Задача") {
                    TextField("Заголовок (мин. 3 символа)", text: $title)
                    TextField("Описание", text: $description, axis: .vertical).lineLimit(3...8)
                }
                Section("Срок") {
                    Toggle("Установить срок", isOn: $hasDueDate)
                    if hasDueDate {
                        DatePicker("Срок", selection: $dueDate, displayedComponents: [.date, .hourAndMinute])
                    }
                }
                Section("Исполнитель") {
                    TextField("Поиск по имени или логину", text: $userSearch)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if users.isEmpty {
                        HStack { ProgressView(); Text("Загрузка…").foregroundColor(Theme.textTertiary) }
                    } else {
                        ForEach(filteredUsers.prefix(20)) { u in
                            Button {
                                assigneeId = u.id
                            } label: {
                                HStack(spacing: 10) {
                                    AvatarCircle(url: u.profile?.avatarUrl,
                                                 name: "\(u.profile?.firstName ?? "") \(u.profile?.lastName ?? "")")
                                        .frame(width: 28, height: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(u.profile?.firstName ?? "") \(u.profile?.lastName ?? "")".trimmingCharacters(in: .whitespaces).ifEmpty(or: u.username))
                                            .foregroundColor(Theme.textPrimary)
                                        Text("@\(u.username)")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(Theme.textTertiary)
                                    }
                                    Spacer()
                                    if assigneeId == u.id {
                                        Image(systemName: "checkmark").foregroundColor(Theme.accent)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if let err = error {
                    Section { Text(err).font(.dsCaption).foregroundColor(Theme.danger) }
                }
            }
            .navigationTitle("Новая задача")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Создаю…" : "Создать") { Task { await create() } }
                        .disabled(saving || !canSubmit)
                }
            }
            .task { await loadUsers() }
        }
    }

    private struct UsersEnv: Codable { let data: [AdminUserItem]? }

    private func loadUsers() async {
        if let arr: [AdminUserItem] = try? await APIClient.shared.get("users", query: ["limit": "200", "status": "active"]) {
            self.users = arr; return
        }
        if let env: UsersEnv = try? await APIClient.shared.get("users", query: ["limit": "200", "status": "active"]) {
            self.users = env.data ?? []
        }
    }

    struct CreateBody: Encodable {
        let title: String
        let description: String?
        let assigneeId: String
        let dueDate: String?
    }

    private func create() async {
        saving = true; defer { saving = false }
        let body = CreateBody(
            title: title,
            description: description.isEmpty ? nil : description,
            assigneeId: assigneeId,
            dueDate: hasDueDate ? ISO8601DateFormatter().string(from: dueDate) : nil
        )
        do {
            _ = try await APIClient.shared.rawRequest("POST", "tasks", body: body)
            onCreated()
            dismiss()
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}

#Preview {
    NavigationStack { TasksAdminView() }
}
