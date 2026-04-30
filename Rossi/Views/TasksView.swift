//
//  TasksView.swift — модуль задач для текущего пользователя.
//
//  Источник данных:
//   • GET    /tasks/mine             — мои задачи (assignee = me)
//   • POST   /tasks                  — создать новую (требует task.manage)
//   • PATCH  /tasks/:id/status       — поменять статус
//   • DELETE /tasks/:id              — удалить (только cancelled/done)
//
//  iOS 16+ (без ContentUnavailableView, без iOS 17 searchable стилей).
//  Дизайн зеркальный с web (Next.js + Tailwind) — DS-примитивы из Theme.swift.
//

import SwiftUI

// MARK: - Filter

private enum TaskFilter: String, CaseIterable, Identifiable {
    case active, finished, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .active:   return "Активные"
        case .finished: return "Выполненные"
        case .all:      return "Все"
        }
    }
}

// MARK: - Status helpers

private enum TaskStatus {
    static func icon(for status: String) -> String {
        switch status {
        case "in_progress": return "play.fill"
        case "done":        return "checkmark"
        case "cancelled":   return "xmark"
        case "pending":     return "clock.fill"
        default:            return "circle"
        }
    }

    static func color(for status: String) -> Color {
        switch status {
        case "in_progress": return Theme.accent
        case "done":        return Theme.success
        case "cancelled":   return Color.secondary
        case "pending":     return Theme.warning
        default:            return .secondary
        }
    }

    static func label(for status: String) -> String {
        switch status {
        case "pending":     return "Ожидает"
        case "in_progress": return "В работе"
        case "done":        return "Выполнено"
        case "cancelled":   return "Отменено"
        default:            return status
        }
    }
}

private func formattedDueDate(_ iso: String) -> String? {
    guard let date = ISO8601DateFormatter().date(from: iso) else { return nil }
    let f = DateFormatter()
    f.locale = Locale(identifier: "ru_RU")
    f.dateFormat = "d MMM, HH:mm"
    return f.string(from: date)
}

private func creatorDisplayName(_ creator: TaskCreator) -> String {
    let first = creator.profile?.firstName ?? ""
    let last  = creator.profile?.lastName ?? ""
    let full = "\(first) \(last)".trimmingCharacters(in: .whitespaces)
    return full.ifEmpty(or: creator.username)
}

// MARK: - TasksView

struct TasksView: View {
    @EnvironmentObject var auth: AuthStore

    @State private var tasks: [TaskItem] = []
    @State private var loading = true
    @State private var lastError: String?
    @State private var filter: TaskFilter = .active

    @State private var taskToCancel: TaskItem?
    @State private var showingCreateSheet = false

    private var canManage: Bool {
        auth.currentUser?.permissions?.contains("task.manage") ?? false
    }

    private var filteredTasks: [TaskItem] {
        switch filter {
        case .active:
            return tasks.filter { $0.isActive }
        case .finished:
            return tasks.filter { !$0.isActive }
        case .all:
            return tasks
        }
    }

    var body: some View {
        ZStack {
            Theme.pageBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    DSPageTitle(text: "Задачи", subtitle: subtitleText)

                    Picker("Фильтр", selection: $filter) {
                        ForEach(TaskFilter.allCases) { f in
                            Text(f.title).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)

                content
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canManage {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingCreateSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                    }
                    .tint(Theme.accent)
                }
            }
        }
        .refreshable { await reload() }
        .task { if tasks.isEmpty { await reload() } }
        .sheet(item: $taskToCancel) { task in
            CancelTaskSheet(task: task) { comment in
                await changeStatus(taskId: task.id, status: "cancelled", comment: comment)
            }
        }
        .sheet(isPresented: $showingCreateSheet) {
            CreateTaskSheet { _ in
                await reload()
            }
        }
    }

    private var subtitleText: String? {
        let active = tasks.filter { $0.isActive }.count
        if tasks.isEmpty { return nil }
        return "Активных: \(active) · всего: \(tasks.count)"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if loading && tasks.isEmpty {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(0..<4, id: \.self) { _ in skeletonCard }
                }
                .padding(16)
            }
        } else if let err = lastError, tasks.isEmpty {
            EmptyStateView(
                icon: "exclamationmark.triangle",
                title: "Не удалось загрузить",
                description: err
            )
        } else if filteredTasks.isEmpty {
            emptyState
        } else {
            List {
                ForEach(filteredTasks) { task in
                    ZStack {
                        NavigationLink {
                            TaskDetailView(task: task, onChanged: { await reload() })
                        } label: { EmptyView() }
                        .opacity(0)

                        TaskCard(task: task)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        swipeButtons(for: task)
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
            .background(Theme.pageBackground)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch filter {
        case .active:
            EmptyStateView(
                icon: "checkmark.seal.fill",
                title: "Нет активных задач",
                description: "Новые задачи появятся здесь"
            )
        case .finished:
            EmptyStateView(
                icon: "tray",
                title: "Пока ничего не закрыто",
                description: "Здесь будут выполненные и отменённые задачи"
            )
        case .all:
            EmptyStateView(
                icon: "checklist",
                title: "Задач нет",
                description: "Когда вам поручат задачу, она появится здесь"
            )
        }
    }

    private var skeletonCard: some View {
        RoundedRectangle(cornerRadius: Radius.xl)
            .fill(Theme.surfaceBackground)
            .frame(height: 96)
            .redacted(reason: .placeholder)
            .shimmering()
    }

    // MARK: - Swipe actions

    @ViewBuilder
    private func swipeButtons(for task: TaskItem) -> some View {
        switch task.status {
        case "pending":
            Button {
                Task { await changeStatus(taskId: task.id, status: "in_progress", comment: nil) }
            } label: {
                Label("В работу", systemImage: "play.fill")
            }
            .tint(Theme.accent)

            Button(role: .destructive) {
                taskToCancel = task
            } label: {
                Label("Отмена", systemImage: "xmark")
            }
            .tint(Theme.danger)

        case "in_progress":
            Button {
                Task { await changeStatus(taskId: task.id, status: "done", comment: nil) }
            } label: {
                Label("Готово", systemImage: "checkmark")
            }
            .tint(Theme.success)

            Button(role: .destructive) {
                taskToCancel = task
            } label: {
                Label("Отмена", systemImage: "xmark")
            }
            .tint(Theme.danger)

        default: // done | cancelled
            Button(role: .destructive) {
                Task { await deleteTask(taskId: task.id) }
            } label: {
                Label("Удалить", systemImage: "trash")
            }
            .tint(Theme.danger)
        }
    }

    // MARK: - Networking

    private func reload() async {
        loading = true
        lastError = nil
        defer { loading = false }
        do {
            let items: [TaskItem] = try await APIClient.shared.get("tasks/mine")
            self.tasks = items
        } catch {
            self.lastError = apiUserMessage(error)
        }
    }

    private func changeStatus(taskId: String, status: String, comment: String?) async {
        struct Body: Encodable {
            let status: String
            let comment: String?
        }
        let body = Body(status: status, comment: comment?.isEmpty == true ? nil : comment)
        do {
            let updated: TaskItem = try await APIClient.shared.patch("tasks/\(taskId)/status", body: body)
            if let idx = tasks.firstIndex(where: { $0.id == updated.id }) {
                tasks[idx] = updated
            }
        } catch {
            self.lastError = apiUserMessage(error)
        }
    }

    private func deleteTask(taskId: String) async {
        do {
            try await APIClient.shared.delete("tasks/\(taskId)")
            tasks.removeAll { $0.id == taskId }
        } catch {
            self.lastError = apiUserMessage(error)
        }
    }
}

// MARK: - TaskCard

private struct TaskCard: View {
    let task: TaskItem

    var body: some View {
        DSCard(radius: Radius.xl, padding: 14) {
            HStack(alignment: .top, spacing: 12) {
                DSIconTile(
                    systemImage: TaskStatus.icon(for: task.status),
                    color: TaskStatus.color(for: task.status),
                    size: 38
                )

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(task.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        DSBadge(
                            text: TaskStatus.label(for: task.status),
                            color: TaskStatus.color(for: task.status),
                            filled: false
                        )
                    }

                    if let desc = task.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 13))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }

                    if let comment = task.statusComment, !comment.isEmpty {
                        Text(comment)
                            .font(.system(size: 12).italic())
                            .foregroundColor(Theme.textTertiary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }

                    HStack(spacing: 10) {
                        if let creator = task.creator {
                            HStack(spacing: 6) {
                                AvatarCircle(
                                    url: creator.profile?.avatarUrl,
                                    name: creatorDisplayName(creator)
                                )
                                .frame(width: 18, height: 18)
                                Text(creatorDisplayName(creator))
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.textSecondary)
                                    .lineLimit(1)
                            }
                        }

                        if let due = task.dueDate, let pretty = formattedDueDate(due) {
                            HStack(spacing: 4) {
                                Image(systemName: "clock")
                                    .font(.system(size: 11, weight: .medium))
                                Text(pretty)
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(task.isOverdue ? Theme.danger : Theme.textTertiary)
                        }
                    }
                    .padding(.top, 2)
                }

                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - TaskDetailView

struct TaskDetailView: View {
    let initialTask: TaskItem
    let onChanged: () async -> Void

    @EnvironmentObject var auth: AuthStore
    @Environment(\.dismiss) private var dismiss

    @State private var task: TaskItem
    @State private var working = false
    @State private var lastError: String?
    @State private var showingCancelSheet = false

    init(task: TaskItem, onChanged: @escaping () async -> Void) {
        self.initialTask = task
        self.onChanged = onChanged
        _task = State(initialValue: task)
    }

    private var canManage: Bool {
        auth.currentUser?.permissions?.contains("task.manage") ?? false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusHeader

                if let desc = task.description, !desc.isEmpty {
                    DSCard(radius: Radius.xl, padding: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Описание")
                                .font(.system(size: 11, weight: .semibold))
                                .tracking(0.6)
                                .textCase(.uppercase)
                                .foregroundColor(Theme.textTertiary)
                            Text(desc)
                                .font(.system(size: 15))
                                .foregroundColor(Theme.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .multilineTextAlignment(.leading)
                        }
                    }
                }

                metadataSection

                if let comment = task.statusComment, !comment.isEmpty {
                    DSCard(radius: Radius.xl, padding: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Комментарий к статусу")
                                .font(.system(size: 11, weight: .semibold))
                                .tracking(0.6)
                                .textCase(.uppercase)
                                .foregroundColor(Theme.textTertiary)
                            Text(comment)
                                .font(.system(size: 15).italic())
                                .foregroundColor(Theme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .multilineTextAlignment(.leading)
                        }
                    }
                }

                if let err = lastError {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(Theme.danger)
                        Text(err).font(.footnote).foregroundColor(Theme.danger)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.danger.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                }

                actionButtons
                    .padding(.top, 4)
            }
            .padding(16)
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("Задача")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingCancelSheet) {
            CancelTaskSheet(task: task) { comment in
                await change(status: "cancelled", comment: comment)
            }
        }
    }

    // MARK: - Subviews

    private var statusHeader: some View {
        let statusColor = TaskStatus.color(for: task.status)
        let isActive = task.status == "in_progress"
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.white.opacity(isActive ? 0.18 : 0.0))
                    Image(systemName: TaskStatus.icon(for: task.status))
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(isActive ? .white : statusColor)
                }
                .frame(width: 56, height: 56)
                .background(
                    isActive ? AnyShapeStyle(Color.clear)
                             : AnyShapeStyle(statusColor.opacity(0.12))
                )
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    Text(TaskStatus.label(for: task.status))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(isActive ? .white.opacity(0.95) : statusColor)
                    if task.isOverdue {
                        HStack(spacing: 4) {
                            Image(systemName: "clock.fill").font(.system(size: 11))
                            Text("Просрочено")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(isActive ? .white : Theme.danger)
                    }
                }
                Spacer()
            }

            Text(task.title)
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.4)
                .foregroundColor(isActive ? .white : Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Group {
                if isActive {
                    LinearGradient(
                        colors: [Theme.accent, Theme.purple, Theme.pink],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                } else {
                    Theme.surfaceBackground
                }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.xl2, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.xl2, style: .continuous)
                .strokeBorder(isActive ? Color.clear : Theme.border, lineWidth: 0.5)
        )
        .dsCardShadow()
    }

    private var metadataSection: some View {
        DSCard(radius: Radius.xl, padding: 14) {
            VStack(alignment: .leading, spacing: 14) {
                if let creator = task.creator {
                    HStack(spacing: 12) {
                        AvatarCircle(
                            url: creator.profile?.avatarUrl,
                            name: creatorDisplayName(creator)
                        )
                        .frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Поставил")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textTertiary)
                            Text(creatorDisplayName(creator))
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(Theme.textPrimary)
                        }
                        Spacer()
                    }
                }

                if let due = task.dueDate, let pretty = formattedDueDate(due) {
                    HStack(spacing: 12) {
                        DSIconTile(
                            systemImage: "clock",
                            color: task.isOverdue ? Theme.danger : Theme.accent,
                            size: 36
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Срок")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textTertiary)
                            Text(pretty)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(task.isOverdue ? Theme.danger : Theme.textPrimary)
                        }
                        Spacer()
                    }
                }

                if let createdDate = ISO8601DateFormatter().date(from: task.createdAt) {
                    HStack(spacing: 12) {
                        DSIconTile(systemImage: "calendar", color: Theme.purple, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Создана")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textTertiary)
                            Text(relativeTime(from: createdDate))
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(Theme.textPrimary)
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: 10) {
            switch task.status {
            case "pending":
                DSPrimaryButton(action: {
                    Task { await change(status: "in_progress", comment: nil) }
                }, loading: working) {
                    Label("Взять в работу", systemImage: "play.fill")
                }
                DSSecondaryButton(action: {
                    showingCancelSheet = true
                }) {
                    Label("Отменить задачу", systemImage: "xmark")
                        .foregroundColor(Theme.danger)
                }

            case "in_progress":
                DSPrimaryButton(action: {
                    Task { await change(status: "done", comment: nil) }
                }, loading: working, gradient: true) {
                    Label("Отметить выполненной", systemImage: "checkmark")
                }
                DSSecondaryButton(action: {
                    showingCancelSheet = true
                }) {
                    Label("Отменить задачу", systemImage: "xmark")
                        .foregroundColor(Theme.danger)
                }

            default:
                DSSecondaryButton(action: {
                    Task { await deleteTask() }
                }) {
                    Label("Удалить", systemImage: "trash")
                        .foregroundColor(Theme.danger)
                }
            }
        }
    }

    // MARK: - Networking

    private func change(status: String, comment: String?) async {
        struct Body: Encodable {
            let status: String
            let comment: String?
        }
        working = true
        lastError = nil
        defer { working = false }
        do {
            let body = Body(status: status, comment: comment?.isEmpty == true ? nil : comment)
            let updated: TaskItem = try await APIClient.shared.patch("tasks/\(task.id)/status", body: body)
            self.task = updated
            await onChanged()
        } catch {
            self.lastError = apiUserMessage(error)
        }
    }

    private func deleteTask() async {
        working = true
        lastError = nil
        defer { working = false }
        do {
            try await APIClient.shared.delete("tasks/\(task.id)")
            await onChanged()
            dismiss()
        } catch {
            self.lastError = apiUserMessage(error)
        }
    }
}

// MARK: - CancelTaskSheet

struct CancelTaskSheet: View {
    let task: TaskItem
    let onConfirm: (String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var comment: String = ""
    @State private var sending = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.pageBackground.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Отменить задачу")
                            .font(.system(size: 21, weight: .bold))
                            .tracking(-0.3)
                            .foregroundColor(Theme.textPrimary)
                        Text(task.title)
                            .font(.system(size: 14))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(2)
                    }

                    DSCard(radius: Radius.lg, padding: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("ПОЧЕМУ НЕ ПОЛУЧАЕТСЯ?")
                                .font(.system(size: 11, weight: .semibold))
                                .tracking(0.6)
                                .foregroundColor(Theme.textTertiary)
                            TextField("Комментарий (необязательно)", text: $comment, axis: .vertical)
                                .lineLimit(4...8)
                                .font(.system(size: 15))
                        }
                    }

                    Spacer()

                    Button {
                        Task {
                            sending = true
                            await onConfirm(comment)
                            sending = false
                            dismiss()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if sending {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "xmark.circle.fill")
                            }
                            Text("Отправить отмену")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Theme.danger)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                        .shadow(color: Theme.danger.opacity(0.35), radius: 14, x: 0, y: 4)
                    }
                    .buttonStyle(DSPressScaleStyle())
                    .disabled(sending)
                }
                .padding(20)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Закрыть") { dismiss() }
                        .tint(Theme.accent)
                }
            }
        }
    }
}

// MARK: - CreateTaskSheet

struct CreateTaskSheet: View {
    let onCreated: (TaskItem) async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var description: String = ""
    @State private var assigneeId: String = ""
    @State private var dueDateEnabled = false
    @State private var dueDate: Date = Date().addingTimeInterval(60 * 60 * 24)

    @State private var sending = false
    @State private var lastError: String?

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !assigneeId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Название") {
                    TextField("Например: подготовить отчёт", text: $title, axis: .vertical)
                        .lineLimit(1...3)
                }

                Section("Описание") {
                    TextField("Детали и контекст (необязательно)", text: $description, axis: .vertical)
                        .lineLimit(3...8)
                }

                Section {
                    TextField("ID или username исполнителя", text: $assigneeId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                } header: {
                    Text("Исполнитель")
                } footer: {
                    Text("Укажите идентификатор пользователя или его username.")
                        .font(.caption2)
                }

                Section {
                    Toggle("Указать срок", isOn: $dueDateEnabled.animation())
                    if dueDateEnabled {
                        DatePicker(
                            "Срок выполнения",
                            selection: $dueDate,
                            in: Date()...,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .environment(\.locale, Locale(identifier: "ru_RU"))
                    }
                }

                if let err = lastError {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(Theme.danger)
                            Text(err)
                                .font(.footnote)
                                .foregroundColor(Theme.danger)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.pageBackground)
            .navigationTitle("Новая задача")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Отмена") { dismiss() }
                        .tint(Theme.accent)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await create() }
                    } label: {
                        if sending {
                            ProgressView().tint(Theme.accent)
                        } else {
                            Text("Создать").fontWeight(.semibold)
                        }
                    }
                    .disabled(!isValid || sending)
                    .tint(Theme.accent)
                }
            }
        }
    }

    private func create() async {
        struct Body: Encodable {
            let title: String
            let description: String?
            let assigneeId: String
            let dueDate: String?
        }

        sending = true
        lastError = nil
        defer { sending = false }

        let trimmedDesc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = Body(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: trimmedDesc.isEmpty ? nil : trimmedDesc,
            assigneeId: assigneeId.trimmingCharacters(in: .whitespacesAndNewlines),
            dueDate: dueDateEnabled ? ISO8601DateFormatter().string(from: dueDate) : nil
        )

        do {
            let created: TaskItem = try await APIClient.shared.post("tasks", body: body)
            await onCreated(created)
            dismiss()
        } catch {
            self.lastError = apiUserMessage(error)
        }
    }
}

#Preview {
    NavigationStack { TasksView() }
        .environmentObject(AuthStore())
}
