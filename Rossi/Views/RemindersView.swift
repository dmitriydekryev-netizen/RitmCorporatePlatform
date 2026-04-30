//
//  RemindersView.swift — мои напоминания на сообщения чата.
//
//  Endpoints:
//   • GET    /reminders?status=pending|fired|cancelled
//   • POST   /reminders               body { messageId, remindAt }
//   • PATCH  /reminders/:id           body { remindAt }
//   • DELETE /reminders/:id
//

import SwiftUI

// MARK: - Models

struct ReminderItem: Codable, Identifiable {
    let id: String
    let userId: String?
    let messageId: String?
    let remindAt: String
    let status: String
    let createdAt: String?
    let firedAt: String?
    /// Превью сообщения, на которое напоминание (если backend включает)
    let message: ReminderMessageInfo?
}

struct ReminderMessageInfo: Codable {
    let id: String
    let chatId: String?
    let content: String?
    let createdAt: String?
    let author: ReminderMessageAuthor?
}

struct ReminderMessageAuthor: Codable {
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

struct RemindersListResponse: Codable {
    let data: [ReminderItem]
    let meta: PaginationMeta?
}

// MARK: - Helpers

/// Парсер ISO-8601 строк, возвращает nil если не получилось.
private func parseISO(_ s: String?) -> Date? {
    guard let s, !s.isEmpty else { return nil }
    let f1 = ISO8601DateFormatter()
    f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f1.date(from: s) { return d }
    let f2 = ISO8601DateFormatter()
    f2.formatOptions = [.withInternetDateTime]
    return f2.date(from: s)
}

/// Кодирует Date в ISO-8601 для отправки на бэк.
private func formatISO(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
}

/// «Завтра в 14:30», «Сегодня в 9:00», «3 апр в 9:00», «12 мая 2027 в 14:00».
private func formatReminderTime(_ date: Date) -> String {
    var c = Calendar(identifier: .gregorian)
    c.locale = Locale(identifier: "ru_RU")

    let timeFmt = DateFormatter()
    timeFmt.locale = Locale(identifier: "ru_RU")
    timeFmt.dateFormat = "H:mm"
    let timeStr = timeFmt.string(from: date)

    if c.isDateInToday(date) {
        return "Сегодня в \(timeStr)"
    }
    if c.isDateInTomorrow(date) {
        return "Завтра в \(timeStr)"
    }
    if c.isDateInYesterday(date) {
        return "Вчера в \(timeStr)"
    }

    let now = Date()
    let nowYear  = c.component(.year, from: now)
    let dateYear = c.component(.year, from: date)

    let dateFmt = DateFormatter()
    dateFmt.locale = Locale(identifier: "ru_RU")
    if dateYear == nowYear {
        dateFmt.dateFormat = "d MMM"
    } else {
        dateFmt.dateFormat = "d MMM yyyy"
    }
    let dStr = dateFmt.string(from: date).replacingOccurrences(of: ".", with: "")
    return "\(dStr) в \(timeStr)"
}

// MARK: - Filter

private enum ReminderFilter: String, CaseIterable, Identifiable {
    case pending, fired, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pending: return "Активные"
        case .fired:   return "Сработавшие"
        case .all:     return "Все"
        }
    }
    /// Параметр status= для запроса; nil → не передавать (значит все).
    var queryStatus: String? {
        switch self {
        case .pending: return "pending"
        case .fired:   return "fired"
        case .all:     return nil
        }
    }
}

// MARK: - Main view

struct RemindersView: View {
    @State private var items: [ReminderItem] = []
    @State private var loading = true
    @State private var error: String?
    @State private var filter: ReminderFilter = .pending
    @State private var rescheduling: ReminderItem?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                DSPageTitle(text: "Напоминания")
                Picker("Фильтр", selection: $filter) {
                    ForEach(ReminderFilter.allCases) { f in
                        Text(f.title).tag(f)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(Theme.pageBackground)

            content
        }
        .navigationBarTitleDisplayMode(.inline)
        .background(Theme.pageBackground.ignoresSafeArea())
        .onChange(of: filter) { _ in
            Task { await load() }
        }
        .refreshable { await load() }
        .task { if items.isEmpty { await load() } }
        .sheet(item: $rescheduling) { rem in
            RescheduleReminderSheet(reminder: rem) {
                Task { await load() }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading && items.isEmpty {
            ProgressView()
                .tint(Theme.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty {
            EmptyStateView(
                icon: "alarm",
                title: "Нет напоминаний",
                description: error ?? "Чтобы создать напоминание, откройте сообщение в чате и выберите «Напомнить»."
            )
        } else {
            List {
                ForEach(items) { item in
                    ReminderRow(item: item)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                        .contentShape(Rectangle())
                        .onLongPressGesture {
                            rescheduling = item
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task { await delete(item) }
                            } label: {
                                Label("Удалить", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                rescheduling = item
                            } label: {
                                Label("Перенести", systemImage: "clock.arrow.circlepath")
                            }
                            .tint(Theme.accent)
                        }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.pageBackground)
        }
    }

    // MARK: - Network

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            var query: [String: String] = ["limit": "100"]
            if let s = filter.queryStatus { query["status"] = s }
            let resp: RemindersListResponse = try await APIClient.shared.get(
                "reminders", query: query
            )
            // Сортируем активные по возрастанию (что раньше — выше),
            // сработавшие/все — по убыванию.
            let sorted = resp.data.sorted { a, b in
                let da = parseISO(a.remindAt) ?? .distantPast
                let db = parseISO(b.remindAt) ?? .distantPast
                return filter == .pending ? da < db : da > db
            }
            self.items = sorted
            self.error = nil
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func delete(_ item: ReminderItem) async {
        do {
            try await APIClient.shared.delete("reminders/\(item.id)")
            items.removeAll { $0.id == item.id }
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}

// MARK: - Row

private struct ReminderRow: View {
    let item: ReminderItem

    private var remindAtDate: Date? { parseISO(item.remindAt) }

    private var iconColor: Color {
        switch item.status {
        case "fired":     return Theme.success
        case "cancelled": return Theme.textTertiary
        default:          return Theme.accent
        }
    }

    private var iconName: String {
        switch item.status {
        case "fired":     return "bell.badge.fill"
        case "cancelled": return "bell.slash.fill"
        default:          return "bell.fill"
        }
    }

    var body: some View {
        DSCard(radius: Radius.lg, padding: 14) {
            HStack(alignment: .top, spacing: 12) {
                DSIconTile(systemImage: iconName, color: iconColor, size: 40)

                VStack(alignment: .leading, spacing: 6) {
                    if let d = remindAtDate {
                        Text(formatReminderTime(d))
                            .font(.dsH3)
                            .fontWeight(.bold)
                            .foregroundColor(Theme.textPrimary)
                    } else {
                        Text("Без даты")
                            .font(.dsH3)
                            .foregroundColor(Theme.textSecondary)
                    }

                    if let content = item.message?.content, !content.isEmpty {
                        Text(content)
                            .font(.dsBodySM)
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(2)
                    } else {
                        Text("(сообщение недоступно)")
                            .font(.dsBodySM)
                            .foregroundColor(Theme.textTertiary)
                            .italic()
                    }

                    if let author = item.message?.author {
                        HStack(spacing: 6) {
                            AvatarCircle(url: author.avatarUrl, name: author.displayName)
                                .frame(width: 18, height: 18)
                            Text(author.displayName)
                                .font(.dsCaption)
                                .foregroundColor(Theme.textSecondary)
                                .lineLimit(1)

                            if item.status == "fired", let fs = item.firedAt, let fd = parseISO(fs) {
                                Text("·").foregroundColor(Theme.textTertiary).font(.dsCaption)
                                Text("сработало \(relativeTime(from: fd))")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.textTertiary)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Quick presets

private enum ReminderPreset: String, CaseIterable, Identifiable {
    case oneHour, tomorrow9, nextWeek
    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneHour:    return "Через час"
        case .tomorrow9:  return "Завтра в 9:00"
        case .nextWeek:   return "На следующей неделе"
        }
    }

    var icon: String {
        switch self {
        case .oneHour:   return "hourglass"
        case .tomorrow9: return "sun.max"
        case .nextWeek:  return "calendar"
        }
    }

    /// Резолвим пресет в конкретную дату от now.
    func resolve(from now: Date = Date()) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "ru_RU")
        switch self {
        case .oneHour:
            return cal.date(byAdding: .hour, value: 1, to: now) ?? now.addingTimeInterval(3600)
        case .tomorrow9:
            let tomorrow = cal.date(byAdding: .day, value: 1, to: now) ?? now
            var comps = cal.dateComponents([.year, .month, .day], from: tomorrow)
            comps.hour = 9
            comps.minute = 0
            return cal.date(from: comps) ?? tomorrow
        case .nextWeek:
            // Понедельник следующей недели в 9:00.
            let sevenDaysLater = cal.date(byAdding: .day, value: 7, to: now) ?? now
            var comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: sevenDaysLater)
            comps.weekday = 2 // понедельник
            comps.hour = 9
            comps.minute = 0
            return cal.date(from: comps) ?? sevenDaysLater
        }
    }
}

// MARK: - Create sheet

struct CreateReminderSheet: View {
    let messageId: String
    let onCreated: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var date: Date = Date().addingTimeInterval(3600)
    @State private var saving = false
    @State private var error: String?
    @State private var selectedPreset: ReminderPreset?

    var body: some View {
        NavigationStack {
            Form {
                Section("Когда напомнить") {
                    DatePicker(
                        "Дата и время",
                        selection: $date,
                        in: Date()...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.graphical)
                    .environment(\.locale, Locale(identifier: "ru_RU"))
                }

                Section("Быстрые пресеты") {
                    presetRows
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundColor(Theme.danger)
                            .font(.footnote)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.pageBackground)
            .navigationTitle("Новое напоминание")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Создать") {
                            Task { await save() }
                        }
                        .disabled(date <= Date())
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var presetRows: some View {
        ForEach(ReminderPreset.allCases) { p in
            Button {
                selectedPreset = p
                date = p.resolve()
            } label: {
                HStack {
                    Image(systemName: p.icon)
                        .foregroundColor(Theme.accent)
                        .frame(width: 24)
                    Text(p.title)
                        .foregroundColor(.primary)
                    Spacer()
                    if selectedPreset == p {
                        Image(systemName: "checkmark")
                            .foregroundColor(Theme.accent)
                    }
                }
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        struct Body: Encodable {
            let messageId: String
            let remindAt: String
        }
        do {
            let _: ReminderItem = try await APIClient.shared.post(
                "reminders",
                body: Body(messageId: messageId, remindAt: formatISO(date))
            )
            onCreated()
            dismiss()
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}

// MARK: - Reschedule sheet

struct RescheduleReminderSheet: View {
    let reminder: ReminderItem
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var date: Date = Date().addingTimeInterval(3600)
    @State private var saving = false
    @State private var error: String?
    @State private var selectedPreset: ReminderPreset?

    var body: some View {
        NavigationStack {
            Form {
                if let preview = reminder.message?.content, !preview.isEmpty {
                    Section("Сообщение") {
                        Text(preview)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(3)
                    }
                }

                Section("Перенести на") {
                    DatePicker(
                        "Дата и время",
                        selection: $date,
                        in: Date()...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.graphical)
                    .environment(\.locale, Locale(identifier: "ru_RU"))
                }

                Section("Быстрые пресеты") {
                    presetRows
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundColor(Theme.danger)
                            .font(.footnote)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.pageBackground)
            .navigationTitle("Перенести напоминание")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Сохранить") {
                            Task { await save() }
                        }
                        .disabled(date <= Date())
                    }
                }
            }
            .onAppear {
                if let d = parseISO(reminder.remindAt), d > Date() {
                    date = d
                }
            }
        }
    }

    @ViewBuilder
    private var presetRows: some View {
        ForEach(ReminderPreset.allCases) { p in
            Button {
                selectedPreset = p
                date = p.resolve()
            } label: {
                HStack {
                    Image(systemName: p.icon)
                        .foregroundColor(Theme.accent)
                        .frame(width: 24)
                    Text(p.title)
                        .foregroundColor(.primary)
                    Spacer()
                    if selectedPreset == p {
                        Image(systemName: "checkmark")
                            .foregroundColor(Theme.accent)
                    }
                }
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        struct Body: Encodable {
            let remindAt: String
        }
        do {
            let _: ReminderItem = try await APIClient.shared.patch(
                "reminders/\(reminder.id)",
                body: Body(remindAt: formatISO(date))
            )
            onSaved()
            dismiss()
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}
