//
//  ScheduleView.swift — график: мои смены, командный календарь, заявки.
//
//  Endpoints:
//   • GET  /schedule/entries                — мои смены (массив)
//   • GET  /schedule/calendar?year=&month=  — все участники по дням (dict YYYY-MM-DD → [{userId, type, ...}])
//   • GET  /schedule/requests               — мои заявки на изменения
//   • POST /schedule/requests               — отправить новую заявку
//   • DELETE /schedule/requests/:id         — отменить pending заявку
//
//  Дизайн: DS-примитивы из Theme.swift, зеркальный с web (Next.js + Tailwind).
//

import SwiftUI

// MARK: - Models

struct ScheduleEntry: Codable, Identifiable {
    let entryId: String?
    let date: String                 // YYYY-MM-DD or ISO with time
    let type: String                 // workday | dayoff | vacation | sick | training
    let startTime: String?
    let endTime: String?
    let comment: String?

    enum CodingKeys: String, CodingKey {
        case entryId = "id"
        case date, type, startTime, endTime, comment
    }

    var id: String { entryId ?? "\(date)-\(type)" }
    var idValue: String { id }
}

struct CalendarUserEntry: Codable, Identifiable {
    let userId: String
    let type: String
    let startTime: String?
    let endTime: String?
    let user: CalendarUserBrief?

    var id: String { userId }
}

struct CalendarUserBrief: Codable {
    let firstName: String?
    let lastName: String?
    let avatarUrl: String?
}

struct ScheduleRequestItem: Codable, Identifiable {
    let id: String
    let status: String              // pending | approved | rejected
    let comment: String?
    let createdAt: String?
    let reviewedAt: String?
    let entries: [ScheduleEntry]?
    /// Заполняется только в админ-режиме (бэк отдаёт все заявки).
    let user: ScheduleRequestUser?
    let reviewer: ScheduleRequestUser?

    /// Период по entries: (dateFrom, dateTo) в YYYY-MM-DD.
    var period: (String, String)? {
        guard let entries = entries, !entries.isEmpty else { return nil }
        let dates = entries.map { String($0.date.prefix(10)) }.sorted()
        guard let first = dates.first, let last = dates.last else { return nil }
        return (first, last)
    }
}

struct ScheduleRequestUser: Codable {
    let id: String?
    let username: String?
    let profile: ScheduleRequestUserProfile?

    var displayName: String {
        let p = profile
        let combo = "\(p?.firstName ?? "") \(p?.lastName ?? "")".trimmingCharacters(in: .whitespaces)
        return combo.isEmpty ? (username ?? "—") : combo
    }
}
struct ScheduleRequestUserProfile: Codable {
    let firstName: String?
    let lastName: String?
    let avatarUrl: String?
}

// MARK: - Status helpers

private struct StatusMeta {
    let label: String
    let color: Color
    let icon: String
}

private func statusMeta(_ status: String) -> StatusMeta {
    switch status {
    case "approved": return StatusMeta(label: "Согласовано",     color: Theme.success, icon: "checkmark.circle.fill")
    case "rejected": return StatusMeta(label: "Отклонено",       color: Theme.danger,  icon: "xmark.circle.fill")
    default:         return StatusMeta(label: "На рассмотрении", color: Theme.warning, icon: "clock.fill")
    }
}

// MARK: - Helpers

extension ScheduleEntry {
    var icon: String {
        switch type {
        case "workday":  return "briefcase.fill"
        case "dayoff":   return "house.fill"
        case "vacation": return "sun.max.fill"
        case "sick":     return "bandage.fill"
        case "training": return "graduationcap.fill"
        default:         return "calendar"
        }
    }
    var label: String {
        switch type {
        case "workday":  return "Рабочий день"
        case "dayoff":   return "Выходной"
        case "vacation": return "Отпуск"
        case "sick":     return "Больничный"
        case "training": return "Обучение"
        default:         return type.capitalized
        }
    }
    var tint: Color {
        switch type {
        case "workday":  return Theme.accent
        case "dayoff":   return Color.secondary
        case "vacation": return Theme.warning
        case "sick":     return Theme.danger
        case "training": return Theme.purple
        default:         return Color.secondary
        }
    }
}

private let yyyymmdd: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "Europe/Moscow")
    return f
}()

private let dayLabelFmt: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "ru_RU")
    f.dateFormat = "EEEE, d"
    return f
}()

private let monthLabelFmt: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "ru_RU")
    f.dateFormat = "LLLL yyyy"
    return f
}()

// MARK: - ScheduleView

struct ScheduleView: View {
    /// Только две вкладки: «Мой график» (просмотр + редактирование своего)
    /// и «Команда» (календарь-сетка всех сотрудников по дням).
    /// Очередь «На согласовании» убрана из обычного представления —
    /// она доступна только в админ-панели (см. требование задачи).
    enum Tab: Hashable { case mine, team }
    @EnvironmentObject var auth: AuthStore
    @State private var tab: Tab = .mine
    @State private var showCreateSheet = false
    /// Bumped after successful submit, чтобы дочерние секции перезагрузили списки.
    @State private var reloadToken: Int = 0

    var body: some View {
        ZStack {
            Theme.pageBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    DSPageTitle(text: "График")

                    Picker("", selection: $tab) {
                        Text("Мой график").tag(Tab.mine)
                        Text("Команда").tag(Tab.team)
                    }
                    .pickerStyle(.segmented)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)

                switch tab {
                case .mine: MyScheduleSection(reloadToken: reloadToken)
                case .team: TeamCalendarSection()
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                }
                .tint(Theme.accent)
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateScheduleRequestSheet(onSubmitted: {
                tab = .mine
                reloadToken &+= 1
            })
        }
    }
}

// MARK: - My schedule

struct MyScheduleSection: View {
    let reloadToken: Int

    @State private var entries: [ScheduleEntry] = []
    @State private var requests: [ScheduleRequestItem] = []
    @State private var loading = true
    @State private var error: String?

    var groupedByMonth: [(String, [ScheduleEntry])] {
        let groups = Dictionary(grouping: entries) { entry -> String in
            guard let d = yyyymmdd.date(from: String(entry.date.prefix(10))) else { return "—" }
            return monthLabelFmt.string(from: d).capitalized
        }
        return groups.sorted { $0.key > $1.key }.map { ($0.key, $0.value.sorted { $0.date > $1.date }) }
    }

    var pendingRequests: [ScheduleRequestItem] {
        requests.filter { $0.status == "pending" }
    }

    /// Все заявки в порядке убывания createdAt.
    var sortedRequests: [ScheduleRequestItem] {
        requests.sorted { (a, b) in
            (a.createdAt ?? "") > (b.createdAt ?? "")
        }
    }

    var body: some View {
        Group {
            if loading && entries.isEmpty && requests.isEmpty {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty && requests.isEmpty {
                EmptyStateView(
                    icon: "calendar.badge.exclamationmark",
                    title: "Графика нет",
                    description: error ?? "Создайте запрос на изменение или дождитесь публикации"
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !pendingRequests.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                DSSectionHeader("На рассмотрении")
                                VStack(spacing: 10) {
                                    ForEach(pendingRequests) { req in
                                        PendingRequestRow(request: req)
                                    }
                                }
                            }
                        }

                        ForEach(groupedByMonth, id: \.0) { (month, list) in
                            VStack(alignment: .leading, spacing: 8) {
                                DSSectionHeader(month)
                                VStack(spacing: 10) {
                                    ForEach(list, id: \.idValue) { entry in
                                        ScheduleRow(entry: entry)
                                    }
                                }
                            }
                        }

                        if !requests.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                DSSectionHeader("Мои заявки")
                                VStack(spacing: 10) {
                                    ForEach(sortedRequests) { req in
                                        RequestHistoryRow(request: req) {
                                            await load()
                                        }
                                    }
                                }
                            }
                        }
                        Color.clear.frame(height: TabBarVisibility.reservedHeight)
                    }
                    .padding(16)
                }
            }
        }
        .refreshable { await load() }
        .task { if entries.isEmpty { await load() } }
        .onChange(of: reloadToken) { _ in
            Task { await load() }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        async let entriesTask: [ScheduleEntry] = APIClient.shared.get("schedule/entries")
        async let requestsTask: [ScheduleRequestItem] = APIClient.shared.get("schedule/requests")
        do {
            let (e, r) = try await (entriesTask, requestsTask)
            self.entries = e
            self.requests = r
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}

// MARK: - Request history row

struct RequestHistoryRow: View {
    let request: ScheduleRequestItem
    let onChange: () async -> Void

    @State private var deleting = false

    private var meta: StatusMeta { statusMeta(request.status) }

    private var periodLabel: String? {
        guard let (from, to) = request.period else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM"
        guard let dFrom = yyyymmdd.date(from: from),
              let dTo = yyyymmdd.date(from: to) else { return "\(from) — \(to)" }
        if from == to {
            return f.string(from: dFrom)
        }
        return "\(f.string(from: dFrom)) — \(f.string(from: dTo))"
    }

    private var typeLabel: String? {
        guard let first = request.entries?.first else { return nil }
        return first.label
    }

    private var createdLabel: String? {
        guard let created = request.createdAt else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = iso.date(from: created)
            ?? ISO8601DateFormatter().date(from: created)
        guard let d = date else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM yyyy"
        return f.string(from: d)
    }

    var body: some View {
        DSCard(radius: Radius.lg, padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    DSBadge(text: meta.label, systemImage: meta.icon, color: meta.color)
                    if let typeLabel = typeLabel {
                        Text("·").foregroundColor(Theme.textTertiary).font(.system(size: 12))
                        Text(typeLabel)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Theme.textSecondary)
                    }
                    Spacer()
                    if request.status == "pending" {
                        Button {
                            Task {
                                await cancel()
                            }
                        } label: {
                            if deleting {
                                ProgressView().scaleEffect(0.7)
                            } else {
                                Image(systemName: "trash")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Theme.textTertiary)
                                    .padding(6)
                            }
                        }
                        .buttonStyle(DSPressScaleStyle())
                        .disabled(deleting)
                    }
                }

                if let period = periodLabel {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Theme.textTertiary)
                        Text(period)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Theme.textPrimary)
                        if let count = request.entries?.count, count > 1 {
                            Text("· \(count) дн.")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textTertiary)
                        }
                    }
                }

                if let comment = request.comment, !comment.isEmpty {
                    Text(comment)
                        .font(.system(size: 12).italic())
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(3)
                }

                if let created = createdLabel {
                    Text("Создано: \(created)")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                }
            }
        }
    }

    private func cancel() async {
        deleting = true
        defer { deleting = false }
        do {
            try await APIClient.shared.delete("schedule/requests/\(request.id)")
            await onChange()
        } catch {}
    }
}

struct ScheduleRow: View {
    let entry: ScheduleEntry

    var body: some View {
        DSCard(radius: Radius.lg, padding: 12) {
            HStack(spacing: 12) {
                DSIconTile(systemImage: entry.icon, color: entry.tint, size: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text(formattedDay)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    HStack(spacing: 6) {
                        Text(entry.label)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                        if !timeRange.isEmpty {
                            Text("·").foregroundColor(Theme.textTertiary).font(.system(size: 12))
                            Text(timeRange)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                    if let c = entry.comment, !c.isEmpty {
                        Text(c)
                            .font(.system(size: 11).italic())
                            .foregroundColor(Theme.textTertiary)
                            .lineLimit(2)
                    }
                }
                Spacer()
            }
        }
    }

    private var formattedDay: String {
        guard let d = yyyymmdd.date(from: String(entry.date.prefix(10))) else { return entry.date }
        return dayLabelFmt.string(from: d).capitalized
    }

    private var timeRange: String {
        if let s = entry.startTime, let e = entry.endTime, !s.isEmpty, !e.isEmpty {
            return "\(String(s.prefix(5)))–\(String(e.prefix(5)))"
        }
        return ""
    }
}

struct PendingRequestRow: View {
    let request: ScheduleRequestItem
    @State private var deleting = false
    @State private var deleted = false

    var body: some View {
        HStack(spacing: 12) {
            DSIconTile(systemImage: "clock.arrow.circlepath", color: Theme.warning, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text("На рассмотрении: \(request.entries?.count ?? 0) дн.")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                if let cmt = request.comment, !cmt.isEmpty {
                    Text(cmt)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if !deleted {
                Button {
                    Task { await delete() }
                } label: {
                    if deleting {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(Theme.textTertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .strokeBorder(Theme.warning.opacity(0.4), lineWidth: 1)
        )
        .opacity(deleted ? 0.4 : 1)
    }

    private func delete() async {
        deleting = true
        defer { deleting = false }
        do {
            try await APIClient.shared.delete("schedule/requests/\(request.id)")
            deleted = true
        } catch {}
    }
}

// MARK: - Team calendar

struct TeamCalendarSection: View {
    @State private var month: Date = Date()
    @State private var calendar: [String: [CalendarUserEntry]] = [:]
    @State private var loading = true
    @State private var error: String?

    var monthLabel: String {
        monthLabelFmt.string(from: month).capitalized
    }

    var sortedDays: [String] {
        calendar.keys.sorted()
    }

    /// Текущий месяц == системный?
    private var isCurrentMonth: Bool {
        let cal = Calendar(identifier: .gregorian)
        let a = cal.dateComponents([.year, .month], from: month)
        let b = cal.dateComponents([.year, .month], from: Date())
        return a.year == b.year && a.month == b.month
    }

    var body: some View {
        VStack(spacing: 0) {
            // Month nav
            HStack(spacing: 8) {
                Button { shiftMonth(-1) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .frame(width: 36, height: 36)
                        .background(Theme.surfaceBackground)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(Theme.border, lineWidth: 0.5))
                }
                .buttonStyle(DSPressScaleStyle())

                Spacer()

                VStack(spacing: 2) {
                    Text(monthLabel)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    if !isCurrentMonth {
                        Button {
                            jumpToToday()
                        } label: {
                            Text("Сегодня")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(Theme.accent)
                        }
                        .buttonStyle(DSPressScaleStyle())
                    }
                }

                Spacer()

                Button { shiftMonth(1) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .frame(width: 36, height: 36)
                        .background(Theme.surfaceBackground)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(Theme.border, lineWidth: 0.5))
                }
                .buttonStyle(DSPressScaleStyle())
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            if loading && calendar.isEmpty {
                ProgressView().tint(Theme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Календарь-сетка как в вебе:
                        // 7 колонок (Пн-Вс), ячейка с числом + индикаторы
                        // (бейджи по типам смен или количество людей).
                        TeamCalendarGrid(month: month,
                                         entriesByDay: calendar,
                                         onSelect: { day in selectedDay = day })

                        // Развёрнутая инфо-секция по выбранному дню:
                        if let day = selectedDay,
                           let entries = calendar[day], !entries.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                DSSectionHeader(dayHeader(day))
                                DSCard(radius: Radius.xl, padding: 0) {
                                    VStack(spacing: 0) {
                                        ForEach(Array(entries.enumerated()), id: \.offset) { (idx, entry) in
                                            TeamMemberDayRow(entry: entry)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 10)
                                            if idx < entries.count - 1 {
                                                Rectangle()
                                                    .fill(Theme.separator)
                                                    .frame(height: 0.5)
                                                    .padding(.leading, 60)
                                            }
                                        }
                                    }
                                }
                            }
                        } else if calendar.isEmpty {
                            EmptyStateView(
                                icon: "person.3",
                                title: "Нет данных",
                                description: error ?? "В этом месяце графики ещё не заполнены"
                            )
                            .padding(.top, 8)
                        } else {
                            Text("Нажмите на день в календаре, чтобы увидеть смены сотрудников")
                                .font(.dsCaption)
                                .foregroundColor(Theme.textTertiary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 8)
                        }
                        Color.clear.frame(height: TabBarVisibility.reservedHeight)
                    }
                    .padding(16)
                }
            }
        }
        .refreshable { await load() }
        .task { if calendar.isEmpty { await load() } }
        .onChange(of: month) { _ in selectedDay = nil }
    }

    /// Какой день сейчас раскрыт в подробной секции (yyyy-MM-dd).
    /// По умолчанию — сегодняшний (если он в текущем месяце).
    @State private var selectedDay: String? = yyyymmdd.string(from: Date())

    private func shiftMonth(_ delta: Int) {
        if let next = Calendar.current.date(byAdding: .month, value: delta, to: month) {
            month = next
            Task { await load() }
        }
    }

    private func jumpToToday() {
        month = Date()
        Task { await load() }
    }

    private func dayHeader(_ day: String) -> String {
        guard let d = yyyymmdd.date(from: day) else { return day }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "EEEE, d MMMM"
        return f.string(from: d).capitalized
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month], from: month)
        let year = comps.year ?? 2026
        let m = comps.month ?? 4
        do {
            let dict: [String: [CalendarUserEntry]] = try await APIClient.shared.get(
                "schedule/calendar",
                query: ["year": "\(year)", "month": "\(m)"]
            )
            self.calendar = dict
            self.error = nil
        } catch {
            self.calendar = [:]
            self.error = apiUserMessage(error)
        }
    }
}

// MARK: - TeamCalendarGrid (как в вебе: 7 колонок Пн-Вс, ячейка с датой и
//                          индикаторами наличия смен сотрудников)

struct TeamCalendarGrid: View {
    let month: Date
    let entriesByDay: [String: [CalendarUserEntry]]
    let onSelect: (String) -> Void

    private let weekdays = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]

    /// Сетка 7×N: nil — пустые ячейки до 1-го числа и после последнего.
    private var days: [Date?] {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2 // понедельник
        let comps = cal.dateComponents([.year, .month], from: month)
        guard let firstDay = cal.date(from: comps),
              let range = cal.range(of: .day, in: .month, for: firstDay) else { return [] }

        // Сколько пустых ячеек до 1-го числа (Mon=0..Sun=6).
        let weekdayOfFirst = (cal.component(.weekday, from: firstDay) + 5) % 7
        var result: [Date?] = Array(repeating: nil, count: weekdayOfFirst)
        for d in range {
            if let date = cal.date(byAdding: .day, value: d - 1, to: firstDay) {
                result.append(date)
            }
        }
        // Добиваем до полной строки (кратно 7).
        while result.count % 7 != 0 { result.append(nil) }
        return result
    }

    private var todayKey: String { yyyymmdd.string(from: Date()) }

    var body: some View {
        VStack(spacing: 6) {
            // Заголовок дней недели
            HStack(spacing: 6) {
                ForEach(weekdays, id: \.self) { d in
                    Text(d)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.textTertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            // Грид
            let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(0..<days.count, id: \.self) { idx in
                    if let date = days[idx] {
                        let key = yyyymmdd.string(from: date)
                        let entries = entriesByDay[key] ?? []
                        Button { onSelect(key) } label: {
                            dayCell(date: date,
                                    key: key,
                                    entries: entries)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear.frame(height: 56)
                    }
                }
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func dayCell(date: Date, key: String, entries: [CalendarUserEntry]) -> some View {
        let isToday = key == todayKey
        VStack(spacing: 4) {
            Text("\(Calendar.current.component(.day, from: date))")
                .font(.system(size: 13, weight: isToday ? .bold : .semibold))
                .foregroundColor(isToday ? .white : Theme.textPrimary)
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(isToday ? Theme.accent : Color.clear)
                )

            // Индикаторы типов смен (до 4 точек)
            HStack(spacing: 2) {
                ForEach(uniqueTints(entries).prefix(4), id: \.description) { c in
                    Circle().fill(c).frame(width: 5, height: 5)
                }
                if entries.count > 0 && uniqueTints(entries).count > 4 {
                    Text("+").font(.system(size: 8, weight: .bold))
                        .foregroundColor(Theme.textTertiary)
                }
            }
            .frame(height: 8)

            if !entries.isEmpty {
                Text("\(entries.count)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(Theme.textTertiary)
            } else {
                Text(" ").font(.system(size: 9))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 60)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.surfaceBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 0.5)
        )
    }

    private func uniqueTints(_ entries: [CalendarUserEntry]) -> [Color] {
        var seen: Set<String> = []
        var out: [Color] = []
        for e in entries {
            if seen.insert(e.type).inserted {
                out.append(tint(for: e.type))
            }
        }
        return out
    }

    private func tint(for type: String) -> Color {
        switch type {
        case "workday":  return Theme.accent
        case "dayoff":   return .secondary
        case "vacation": return Theme.warning
        case "sick":     return Theme.danger
        case "training": return Theme.purple
        default:         return .secondary
        }
    }
}

struct TeamMemberDayRow: View {
    let entry: CalendarUserEntry

    var icon: String {
        switch entry.type {
        case "workday":  return "briefcase.fill"
        case "dayoff":   return "house.fill"
        case "vacation": return "sun.max.fill"
        case "sick":     return "bandage.fill"
        case "training": return "graduationcap.fill"
        default:         return "calendar"
        }
    }
    var tint: Color {
        switch entry.type {
        case "workday":  return Theme.accent
        case "dayoff":   return Color.secondary
        case "vacation": return Theme.warning
        case "sick":     return Theme.danger
        case "training": return Theme.purple
        default:         return Color.secondary
        }
    }
    var label: String {
        switch entry.type {
        case "workday":  return "Рабочий"
        case "dayoff":   return "Выходной"
        case "vacation": return "Отпуск"
        case "sick":     return "Больничный"
        case "training": return "Обучение"
        default:         return entry.type
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            AvatarCircle(
                url: entry.user?.avatarUrl,
                name: "\(entry.user?.firstName ?? "") \(entry.user?.lastName ?? "")"
            )
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(entry.user?.firstName ?? "") \(entry.user?.lastName ?? "")"
                        .trimmingCharacters(in: .whitespaces))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                HStack(spacing: 5) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(tint)
                    Text(label)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                    if let s = entry.startTime, let e = entry.endTime, !s.isEmpty, !e.isEmpty {
                        Text("· \(String(s.prefix(5)))–\(String(e.prefix(5)))")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
            }
            Spacer()
        }
    }
}

// MARK: - Create request sheet

struct CreateScheduleRequestSheet: View {
    /// Вызывается после успешной отправки заявки (до dismiss).
    var onSubmitted: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var startDate: Date = Date()
    @State private var endDate: Date = Date()
    @State private var type: String = "workday"
    @State private var startTime: String = "09:00"
    @State private var endTime: String = "18:00"
    @State private var comment: String = ""
    @State private var saving = false
    @State private var error: String?

    var typeOptions: [(String, String)] {
        [
            ("workday", "Рабочий день"),
            ("dayoff", "Выходной"),
            ("vacation", "Отпуск"),
            ("sick", "Больничный"),
            ("training", "Обучение"),
        ]
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Период") {
                    DatePicker("С", selection: $startDate, displayedComponents: .date)
                        .datePickerStyle(.compact)
                    DatePicker("По", selection: $endDate, in: startDate..., displayedComponents: .date)
                        .datePickerStyle(.compact)
                }

                Section("Тип") {
                    Picker("Тип", selection: $type) {
                        ForEach(typeOptions, id: \.0) { opt in
                            Text(opt.1).tag(opt.0)
                        }
                    }
                    .pickerStyle(.menu)
                }

                if type == "workday" {
                    Section("Время") {
                        TextField("Начало (HH:MM)", text: $startTime)
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled()
                        TextField("Конец (HH:MM)", text: $endTime)
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled()
                    }
                }

                Section("Комментарий") {
                    TextField("Зачем нужно изменение", text: $comment, axis: .vertical)
                        .lineLimit(2...5)
                }

                if let err = error {
                    Section {
                        Text(err).font(.footnote).foregroundColor(Theme.danger)
                    }
                }
            }
            .navigationTitle("Запрос изменения")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if saving {
                            ProgressView().tint(Theme.accent)
                        } else {
                            Text("Отправить").fontWeight(.semibold)
                        }
                    }
                    .disabled(saving)
                }
            }
        }
    }

    private struct EntryDto: Encodable {
        let date: String
        let type: String
        let startTime: String?
        let endTime: String?
    }
    private struct RequestDto: Encodable {
        let entries: [EntryDto]
        let comment: String?
    }

    private func submit() async {
        saving = true
        defer { saving = false }
        var entries: [EntryDto] = []
        var current = startDate
        let cal = Calendar(identifier: .gregorian)
        while current <= endDate {
            let dateStr = yyyymmdd.string(from: current)
            entries.append(EntryDto(
                date: dateStr,
                type: type,
                startTime: type == "workday" ? startTime : nil,
                endTime: type == "workday" ? endTime : nil
            ))
            guard let next = cal.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        let body = RequestDto(
            entries: entries,
            comment: comment.isEmpty ? nil : comment
        )
        do {
            _ = try await APIClient.shared.rawRequest("POST", "schedule/requests", body: body)
            onSubmitted?()
            dismiss()
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}
