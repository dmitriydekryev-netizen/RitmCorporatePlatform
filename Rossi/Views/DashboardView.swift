//
//  DashboardView.swift — главный экран после логина.
//
//  Источник данных: тот же что у /dashboard на вебе:
//   • GET /tasks/mine    — мои задачи
//   • GET /news?limit=5  — последние новости
//   • currentUser        — из AuthStore
//

import SwiftUI

// DateFormatter для формата YYYY-MM-DD
private let yyyymmdd: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone(secondsFromGMT: 0)
    return f
}()

struct DashboardView: View {
    @EnvironmentObject var auth: AuthStore
    @State private var tasks: [TaskItem] = []
    @State private var news: [NewsItem] = []
    @State private var teamMembers: [TeamMember] = []
    @State private var teamTotal: Int = 0
    @State private var birthdays: [BirthdayUser] = []
    @State private var todaySchedule: [ScheduleEntry] = []
    @State private var employeeOfMonth: EmployeeOfMonth?
    @State private var myStats: MyStats?
    @State private var loading = true
    @State private var lastError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header — приветствие + дата (стиль веба)
                DSPageTitle(text: greeting, subtitle: todayLabel)
                    .padding(.top, 4)

                if let err = lastError {
                    errorBanner(err)
                }

                // Today summary (overdue / today tasks count / birthdays)
                todayWidget

                // Tasks (с блоком «Сегодня рабочий день» внутри)
                tasksSection

                // Employee of month
                employeeOfMonthCard

                // Статистика месяца (если /me/stats доступен)
                monthlyStatsSection

                // Team
                teamSection

                // Birthdays
                birthdaysSection

                // Зарезервированное место под плавающую таблетку (см. MainTabView).
                Color.clear.frame(height: TabBarVisibility.reservedHeight)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle("")
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await reload() }
        .task { await reload() }
    }

    // MARK: - Computed

    private var activeTasks: [TaskItem] {
        tasks.filter { $0.isActive }
    }

    private var overdueTasks: [TaskItem] {
        activeTasks.filter { $0.isOverdue }
    }

    private var todayTasks: [TaskItem] {
        let cal = Calendar.current
        return activeTasks.filter { task in
            guard let due = task.dueDate, let date = ISO8601DateFormatter().date(from: due) else { return false }
            return cal.isDateInToday(date)
        }
    }

    private var todayWorkShift: ScheduleEntry? {
        let today = yyyymmdd.string(from: Date())
        return todaySchedule.first { String($0.date.prefix(10)) == today && $0.type == "workday" }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let part: String
        switch h {
        case 5..<12:  part = "Доброе утро"
        case 12..<17: part = "Добрый день"
        case 17..<23: part = "Добрый вечер"
        default:      part = "Доброй ночи"
        }
        let name = auth.currentUser?.profile?.firstName ?? "коллега"
        return "\(part), \(name)"
    }

    private var todayLabel: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "EEEE, d MMMM"
        return f.string(from: Date()).capitalized
    }

    // MARK: - Reload

    private func reload() async {
        loading = true
        lastError = nil
        defer { loading = false }

        async let tasksTask: [TaskItem] = APIClient.shared.get("tasks/mine")
        async let newsTask: NewsListResponse = APIClient.shared.get("news", query: ["limit": "6"])
        async let teamTask: TeamListResponse = APIClient.shared.get("team", query: ["limit": "15"])
        async let birthdaysTask: BirthdayListResponse = APIClient.shared.get(
            "team/birthdays/upcoming",
            query: ["days": "365", "limit": "10"]
        )
        async let scheduleTask: [ScheduleEntry]? = try? await APIClient.shared.get("schedule/entries")
        async let eomTask: EmployeeOfMonth? = try? await APIClient.shared.get("kudos/employee-of-month")
        // /me/stats — может вернуть 404 на старых бэках; при этом виджет просто не показываем.
        async let statsTask: MyStats? = try? await APIClient.shared.get("me/stats")

        do {
            let (t, n, team, bdays, sched, eom, stats) = try await (
                tasksTask, newsTask, teamTask, birthdaysTask, scheduleTask, eomTask, statsTask
            )
            self.tasks = t
            self.news = n.data
            self.teamMembers = team.data
            self.teamTotal = team.meta?.total ?? team.data.count
            self.birthdays = bdays.data
            self.todaySchedule = sched ?? []
            self.employeeOfMonth = eom
            self.myStats = stats
        } catch {
            self.lastError = apiUserMessage(error)
        }
    }

    // MARK: - Quick actions

    @ViewBuilder
    private var quickActions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                quickActionChip(title: "AI", icon: "sparkles", colors: [Theme.accent, Theme.purple])
                quickActionChip(title: "Чат", icon: "message.fill", colors: [Theme.accent, Theme.info])
                quickActionChip(title: "График", icon: "calendar", colors: [Theme.warning, Theme.pink])
                quickActionChip(title: "Команда", icon: "person.3.fill", colors: [Theme.success, Theme.accent])
                quickActionChip(title: "Идеи", icon: "lightbulb.fill", colors: [Theme.warning, Theme.danger])
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func quickActionChip(title: String, icon: String, colors: [Color]) -> some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                    .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 56, height: 56)
                    .shadow(color: colors.first?.opacity(0.30) ?? .clear, radius: 10, x: 0, y: 4)
                Image(systemName: icon)
                    .foregroundColor(.white)
                    .font(.system(size: 22, weight: .semibold))
            }
            Text(title)
                .font(.dsCaption)
                .foregroundColor(Theme.textSecondary)
        }
        .frame(width: 68)
    }

    // MARK: - Today / team widgets

    @ViewBuilder
    private var todayWidget: some View {
        let birthdayToday = birthdays.first { $0.daysUntil == 0 }
        let birthdaySoon = birthdays.first { $0.daysUntil > 0 && $0.daysUntil <= 7 }
        let hasContent = !activeTasks.isEmpty || birthdayToday != nil || birthdaySoon != nil

        if hasContent {
            DSCard(radius: Radius.xl, padding: 0) {
                VStack(spacing: 0) {
                    if !overdueTasks.isEmpty {
                        TodayWidgetRow(
                            icon: "exclamationmark.bubble.fill",
                            color: Theme.danger,
                            title: "\(overdueTasks.count) просрочено",
                            subtitle: overdueTasks.prefix(2).map(\.title).joined(separator: " • "),
                            titleColor: Theme.danger
                        )
                        todayDivider
                    } else if !todayTasks.isEmpty {
                        TodayWidgetRow(
                            icon: "checklist",
                            color: Theme.warning,
                            title: "\(todayTasks.count) на сегодня",
                            subtitle: todayTasks.prefix(2).map(\.title).joined(separator: " • ")
                        )
                        todayDivider
                    } else if !activeTasks.isEmpty {
                        TodayWidgetRow(
                            icon: "checklist",
                            color: Theme.accent,
                            title: "Активных задач: \(activeTasks.count)",
                            subtitle: activeTasks.prefix(2).map(\.title).joined(separator: " • ")
                        )
                        todayDivider
                    }
                    if let b = birthdayToday {
                        TodayBirthdayRow(birthday: b, title: "🎉 У \(b.firstName ?? b.username) день рождения!", subtitle: "Не забудьте поздравить")
                    } else if let b = birthdaySoon {
                        TodayBirthdayRow(birthday: b, title: "ДР у \(b.displayName)", subtitle: "через \(b.daysUntil) дн.")
                    }
                }
            }
        }
    }

    private var todayDivider: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: 0.5)
            .padding(.leading, 56)
    }

    // MARK: - Monthly stats widget

    @ViewBuilder
    private var monthlyStatsSection: some View {
        if let s = myStats, s.hasAnyValue {
            DSCard(radius: Radius.xl, padding: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Статистика месяца")
                            .font(.dsH3)
                            .foregroundColor(Theme.textPrimary)
                        Spacer()
                    }
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 10),
                                  GridItem(.flexible(), spacing: 10)],
                        spacing: 10
                    ) {
                        MonthlyStatTile(
                            value: s.tasksCompleted ?? 0,
                            label: "Задач выполнено",
                            systemImage: "checkmark.circle.fill",
                            color: Theme.success
                        )
                        MonthlyStatTile(
                            value: s.ideasSubmitted ?? 0,
                            label: "Идей подано",
                            systemImage: "lightbulb.fill",
                            color: Theme.warning
                        )
                        MonthlyStatTile(
                            value: s.kudosReceived ?? 0,
                            label: "Kudos получено",
                            systemImage: "star.fill",
                            color: Theme.accent
                        )
                        MonthlyStatTile(
                            value: s.daysWorked ?? 0,
                            label: "Дней работы",
                            systemImage: "calendar",
                            color: Theme.info
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var employeeOfMonthCard: some View {
        if let eom = employeeOfMonth {
            NavigationLink {
                TeamMemberProfileView(member: eom.asTeamMember)
            } label: {
                EmployeeOfMonthCard(item: eom)
            }
            .buttonStyle(DSPressScaleStyle())
        }
    }

    @ViewBuilder
    private var teamSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            DSSectionHeader(
                "Команда",
                trailing: AnyView(
                    NavigationLink { TeamView() } label: {
                        HStack(spacing: 2) {
                            Text("Все")
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.accent)
                    }
                )
            )
            if loading && teamMembers.isEmpty {
                HStack(spacing: 8) {
                    ForEach(0..<8, id: \.self) { _ in
                        Circle().fill(Theme.surfaceBackground).frame(width: 48, height: 48).shimmering()
                    }
                }
            } else if !teamMembers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(teamMembers.prefix(14)) { member in
                            NavigationLink { TeamMemberProfileView(member: member) } label: {
                                TeamAvatarShortcut(member: member)
                            }
                            .buttonStyle(DSPressScaleStyle())
                        }
                        if teamTotal > 14 {
                            NavigationLink { TeamView() } label: {
                                Text("+\(teamTotal - 14)")
                                    .font(.dsCaption.weight(.semibold))
                                    .foregroundColor(Theme.textTertiary)
                                    .frame(width: 50, height: 50)
                                    .background(Theme.surfaceBackground)
                                    .clipShape(Circle())
                                    .overlay(Circle().strokeBorder(Theme.border, lineWidth: 0.5))
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder
    private var birthdaysSection: some View {
        if !birthdays.isEmpty || loading {
            VStack(alignment: .leading, spacing: 8) {
                DSSectionHeader("Дни рождения")
                DSCard(radius: Radius.xl, padding: 0) {
                    VStack(spacing: 0) {
                        if loading && birthdays.isEmpty {
                            ProgressView().tint(Theme.accent).padding(20).frame(maxWidth: .infinity)
                        } else {
                            ForEach(Array(birthdays.prefix(5).enumerated()), id: \.element.id) { idx, b in
                                BirthdayDashboardRow(birthday: b)
                                if idx < min(birthdays.count, 5) - 1 {
                                    Rectangle()
                                        .fill(Theme.separator)
                                        .frame(height: 0.5)
                                        .padding(.leading, 62)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func shiftTimeLabel(_ shift: ScheduleEntry) -> String {
        if let s = shift.startTime, let e = shift.endTime, !s.isEmpty, !e.isEmpty {
            return "Смена: \(String(s.prefix(5))) – \(String(e.prefix(5)))"
        }
        return "График"
    }

    // MARK: - Tasks section

    @ViewBuilder
    private var tasksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            DSSectionHeader(
                "Задачи",
                trailing: !activeTasks.isEmpty
                    ? AnyView(DSBadge(text: "\(activeTasks.count)", color: Theme.accent, filled: true))
                    : nil
            )

            DSCard(radius: Radius.xl, padding: 0, bordered: false) {
                VStack(spacing: 0) {
                    // Сегодня рабочий день — теперь часть карточки задач,
                    // тап ведёт в график.
                    if let shift = todayWorkShift {
                        NavigationLink {
                            ScheduleView()
                        } label: {
                            TodayWidgetRow(
                                icon: "clock.fill",
                                color: Theme.info,
                                title: "Сегодня рабочий день",
                                subtitle: shiftTimeLabel(shift)
                            )
                        }
                        .buttonStyle(.plain)
                        Divider()
                            .background(Theme.separator)
                            .padding(.leading, 60)
                    }

                    if loading && tasks.isEmpty {
                        VStack(spacing: 1) {
                            ForEach(0..<3, id: \.self) { _ in skeletonRow }
                        }
                        .padding(8)
                    } else if activeTasks.isEmpty {
                        NavigationLink {
                            TasksView()
                        } label: {
                            emptyTasksContent
                        }
                        .buttonStyle(.plain)
                    } else {
                        ForEach(Array(activeTasks.enumerated()), id: \.element.id) { idx, task in
                            NavigationLink {
                                TasksView()
                            } label: {
                                TaskRow(task: task)
                            }
                            .buttonStyle(.plain)
                            if idx < activeTasks.count - 1 {
                                Divider()
                                    .background(Theme.separator)
                                    .padding(.leading, 60)
                            }
                        }
                    }
                }
            }
        }
    }

    private var emptyTasksContent: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 28))
                .foregroundColor(Theme.success)
            VStack(alignment: .leading, spacing: 2) {
                Text("Нет активных задач")
                    .font(.dsH3)
                    .foregroundColor(Theme.textPrimary)
                Text("Новые задачи появятся здесь")
                    .font(.dsBodySM)
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(18)
    }

    // MARK: - News section

    @ViewBuilder
    private var newsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            DSSectionHeader(
                "Новости",
                trailing: AnyView(
                    NavigationLink {
                        NewsListView()
                    } label: {
                        HStack(spacing: 2) {
                            Text("Все")
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.accent)
                    }
                )
            )

            if loading && news.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(0..<3, id: \.self) { _ in skeletonNewsCard }
                    }
                }
            } else if news.isEmpty {
                Text("Пока нет новостей")
                    .font(.dsBodySM)
                    .foregroundColor(Theme.textSecondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(news.prefix(4)) { item in
                            NavigationLink {
                                NewsDetailView(slug: item.slug)
                            } label: {
                                DashboardNewsCard(item: item)
                            }
                            .buttonStyle(DSPressScaleStyle())
                        }
                    }
                    .padding(.horizontal, 1)
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Banners / skeletons

    private func errorBanner(_ msg: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(Theme.danger)
            Text(msg).font(.dsBodySM).foregroundColor(Theme.danger)
            Spacer()
        }
        .padding(12)
        .background(Theme.danger.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
    }

    private var skeletonRow: some View {
        RoundedRectangle(cornerRadius: Radius.md)
            .fill(Theme.pageBackground)
            .frame(height: 60)
            .redacted(reason: .placeholder)
            .shimmering()
    }

    private var skeletonNewsCard: some View {
        RoundedRectangle(cornerRadius: Radius.xl)
            .fill(Theme.surfaceBackground)
            .frame(width: 240, height: 220)
            .redacted(reason: .placeholder)
            .shimmering()
    }
}

// MARK: - Rows

struct TodayWidgetRow: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String
    var titleColor: Color = Theme.textPrimary

    var body: some View {
        HStack(spacing: 12) {
            DSIconTile(systemImage: icon, color: color, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.dsBodySM.weight(.semibold))
                    .foregroundColor(titleColor)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.dsCaption)
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

struct TodayBirthdayRow: View {
    let birthday: BirthdayUser
    let title: String
    let subtitle: String

    var body: some View {
        NavigationLink { TeamMemberProfileView(member: birthday.asTeamMember) } label: {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    AvatarCircle(url: birthday.avatarUrl, name: birthday.displayName)
                        .frame(width: 34, height: 34)
                    Text("🎂").font(.system(size: 12)).offset(x: 2, y: 2)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.dsBodySM.weight(.semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.dsCaption)
                        .foregroundColor(Theme.textTertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }
}

struct TeamAvatarShortcut: View {
    let member: TeamMember

    private var name: String {
        "\(member.firstName ?? "") \(member.lastName ?? "")"
            .trimmingCharacters(in: .whitespaces)
            .ifEmpty(or: member.username)
    }

    var body: some View {
        VStack(spacing: 5) {
            AvatarCircle(url: member.avatarUrl, name: name)
                .frame(width: 50, height: 50)
                .overlay(
                    Group {
                        if member.presenceStatus == "online" {
                            Circle()
                                .fill(Theme.success)
                                .frame(width: 12, height: 12)
                                .overlay(Circle().strokeBorder(Theme.surfaceBackground, lineWidth: 2))
                                .offset(x: 18, y: 18)
                        }
                    }
                )
            Text(member.firstName?.isEmpty == false ? member.firstName! : member.username)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                .frame(width: 58)
        }
    }
}

struct BirthdayDashboardRow: View {
    let birthday: BirthdayUser

    var body: some View {
        NavigationLink { TeamMemberProfileView(member: birthday.asTeamMember) } label: {
            HStack(spacing: 12) {
                AvatarCircle(url: birthday.avatarUrl, name: birthday.displayName)
                    .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(birthday.displayName)
                        .font(.dsBodySM.weight(.semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Text(birthday.position ?? "сотрудник")
                        .font(.dsCaption)
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(birthdayLabel(birthday))
                        .font(.dsCaption.weight(.semibold))
                        .foregroundColor(birthday.daysUntil == 0 ? Theme.danger : birthday.daysUntil <= 3 ? Theme.warning : Theme.accent)
                    Text("\(birthday.turningAge) \(ageSuffix(birthday.turningAge))")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    private func birthdayLabel(_ b: BirthdayUser) -> String {
        if b.daysUntil == 0 { return "Сегодня!" }
        if b.daysUntil == 1 { return "Завтра" }
        let parts = b.nextBirthday.split(separator: "-")
        guard parts.count == 3, let m = Int(parts[1]), let d = Int(parts[2]) else { return "через \(b.daysUntil) д." }
        let months = ["янв", "фев", "мар", "апр", "мая", "июн", "июл", "авг", "сен", "окт", "ноя", "дек"]
        return "\(d) \(months[max(0, min(11, m - 1))])"
    }

    private func ageSuffix(_ age: Int) -> String {
        let last = age % 10
        let lastTwo = age % 100
        if (11...14).contains(lastTwo) { return "лет" }
        if last == 1 { return "год" }
        if (2...4).contains(last) { return "года" }
        return "лет"
    }
}

// MARK: - My monthly stats

struct MyStats: Codable {
    let tasksCompleted: Int?
    let ideasSubmitted: Int?
    let kudosReceived: Int?
    let daysWorked: Int?

    /// Виджет показываем только если хотя бы одно поле пришло с сервера.
    var hasAnyValue: Bool {
        tasksCompleted != nil || ideasSubmitted != nil ||
        kudosReceived != nil || daysWorked != nil
    }
}

struct MonthlyStatTile: View {
    let value: Int
    let label: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            DSIconTile(systemImage: systemImage, color: color, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(value)")
                    .font(.dsH2)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(label)
                    .font(.dsCaption)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.pageBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }
}

struct EmployeeOfMonth: Codable, Identifiable {
    struct User: Codable {
        let id: String
        let username: String
        let firstName: String?
        let lastName: String?
        let avatarUrl: String?
        let position: String?
    }

    var id: String { "\(year)-\(month)-\(user.id)" }
    let year: Int
    let month: Int
    let user: User
    let kudosCount: Int
    let reason: String?
    let manual: Bool?

    var asTeamMember: TeamMember {
        TeamMember(
            id: user.id,
            username: user.username,
            firstName: user.firstName,
            lastName: user.lastName,
            position: user.position,
            avatarUrl: user.avatarUrl,
            department: nil,
            telegram: nil,
            roles: nil,
            presenceStatus: nil
        )
    }
}

struct EmployeeOfMonthCard: View {
    let item: EmployeeOfMonth
    private let months = ["Январь", "Февраль", "Март", "Апрель", "Май", "Июнь", "Июль", "Август", "Сентябрь", "Октябрь", "Ноябрь", "Декабрь"]

    private var name: String {
        "\(item.user.firstName ?? "") \(item.user.lastName ?? "")"
            .trimmingCharacters(in: .whitespaces)
            .ifEmpty(or: item.user.username)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(hex: 0xFBBF24), Color(hex: 0xF97316)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color.white.opacity(0.13)).frame(width: 150, height: 150).blur(radius: 35).offset(x: 220, y: -50)
            Circle().fill(Color.white.opacity(0.14)).frame(width: 120, height: 120).blur(radius: 30).offset(x: -35, y: 65)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    Image(systemName: "crown.fill")
                    Text("Сотрудник месяца · \(monthName)")
                        .font(.system(size: 11, weight: .bold))
                        .textCase(.uppercase)
                        .tracking(0.7)
                    Spacer()
                }
                .foregroundColor(.white)

                HStack(spacing: 12) {
                    AvatarCircle(url: item.user.avatarUrl, name: name)
                        .frame(width: 52, height: 52)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.45), lineWidth: 2))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name)
                            .font(.dsBodyLG.weight(.bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        if let pos = item.user.position, !pos.isEmpty {
                            Text(pos)
                                .font(.dsCaption)
                                .foregroundColor(.white.opacity(0.82))
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                }

                HStack(spacing: 6) {
                    Image(systemName: "heart.fill")
                    Text("\(item.kudosCount)").fontWeight(.bold)
                    Text("благодарностей за месяц")
                }
                .font(.dsCaption)
                .foregroundColor(.white.opacity(0.92))
            }
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
        .dsCardHoverShadow()
    }

    private var monthName: String {
        guard (1...12).contains(item.month) else { return "—" }
        return months[item.month - 1]
    }
}

extension BirthdayUser {
    var asTeamMember: TeamMember {
        TeamMember(
            id: id,
            username: username,
            firstName: firstName,
            lastName: lastName,
            position: position,
            avatarUrl: avatarUrl,
            department: department,
            telegram: nil,
            roles: nil,
            presenceStatus: nil
        )
    }
}

struct TaskRow: View {
    let task: TaskItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            DSIconTile(systemImage: statusIconName, color: statusColor, size: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.dsH3)
                    .fontWeight(.semibold)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                if let desc = task.description, !desc.isEmpty {
                    Text(desc)
                        .font(.dsBodySM)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(2)
                }
                if let due = task.dueDate, let date = ISO8601DateFormatter().date(from: due) {
                    HStack(spacing: 4) {
                        Image(systemName: task.isOverdue ? "clock.badge.exclamationmark.fill" : "clock")
                            .font(.system(size: 10, weight: .semibold))
                        Text(formattedDue(date, overdue: task.isOverdue))
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(task.isOverdue ? Theme.danger : Theme.textTertiary)
                    .padding(.top, 2)
                }
            }
            Spacer()
        }
        .padding(12)
    }

    private var statusIconName: String {
        switch task.status {
        case "in_progress": return "play.fill"
        case "done":        return "checkmark"
        default:            return "circle"
        }
    }

    private var statusColor: Color {
        switch task.status {
        case "in_progress": return Theme.accent
        case "done":        return Theme.success
        default:            return Theme.textTertiary
        }
    }

    private func formattedDue(_ date: Date, overdue: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM"
        let s = f.string(from: date)
        return overdue ? "Просрочено • \(s)" : "До \(s)"
    }
}

// MARK: - Dashboard news card (horizontal carousel)

struct DashboardNewsCard: View {
    let item: NewsItem

    private var pinned: Bool { item.isPinned == true }
    private var important: Bool { item.isImportant == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Cover
            ZStack(alignment: .topTrailing) {
                if let urlStr = item.coverUrl, let url = URL(string: ensureAbsolute(urlStr)) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .empty:
                            Theme.pageBackground
                        case .success(let img):
                            img.resizable().scaledToFill()
                        case .failure:
                            Theme.pageBackground
                        @unknown default:
                            Theme.pageBackground
                        }
                    }
                    .frame(width: 240, height: 140)
                    .clipped()
                } else {
                    LinearGradient(
                        colors: [Theme.accent.opacity(0.6), Theme.purple.opacity(0.6)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    .frame(width: 240, height: 140)
                }

                if pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(6)
                        .background(Theme.warning)
                        .clipShape(Circle())
                        .padding(8)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if important {
                        DSBadge(text: "Важно", systemImage: "exclamationmark.circle.fill",
                                color: Theme.danger, filled: true)
                    }
                    if let cat = item.category {
                        DSBadge(text: cat.name, color: parseHexColor(cat.color))
                    }
                    Spacer(minLength: 0)
                }
                Text(item.title)
                    .font(.dsH3)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(12)
            .frame(width: 240, alignment: .leading)
        }
        .frame(width: 240)
        .background(Theme.surfaceBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 0.5)
        )
        .dsCardShadow()
    }
}

struct NewsRow: View {
    let item: NewsItem

    private var unread: Bool { item.isRead != true }
    private var pinned: Bool { item.isPinned == true }
    private var important: Bool { item.isImportant == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Cover image (top, full-bleed)
            if let urlStr = item.coverUrl, let url = URL(string: ensureAbsolute(urlStr)) {
                ZStack(alignment: .topTrailing) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .empty:
                            Theme.pageBackground
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .failure:
                            Theme.pageBackground
                        @unknown default:
                            Theme.pageBackground
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .clipped()

                    if pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .padding(7)
                            .background(Theme.warning)
                            .clipShape(Circle())
                            .padding(10)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                // Badges row
                HStack(spacing: 6) {
                    if important {
                        DSBadge(text: "Важно", systemImage: "exclamationmark.circle.fill",
                                color: Theme.danger, filled: true)
                    }
                    if let cat = item.category {
                        DSBadge(text: cat.name, color: parseHexColor(cat.color))
                    }
                    Spacer(minLength: 0)
                    if unread {
                        Circle().fill(Theme.accent).frame(width: 8, height: 8)
                    }
                }

                Text(item.title)
                    .font(.dsH3)
                    .fontWeight(.bold)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)

                if let excerpt = item.excerpt, !excerpt.isEmpty {
                    Text(excerpt)
                        .font(.dsBodySM)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                // Footer — author + counters
                HStack(spacing: 8) {
                    if let author = item.author {
                        AvatarCircle(url: author.avatarUrl, name: authorName(author))
                            .frame(width: 24, height: 24)
                        Text(authorName(author))
                            .font(.dsCaption)
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                    }

                    if let pub = item.publishedAt, let date = ISO8601DateFormatter().date(from: pub) {
                        Text("·").font(.dsCaption).foregroundColor(Theme.textTertiary)
                        Text(relativeTime(from: date))
                            .font(.dsCaption)
                            .foregroundColor(Theme.textTertiary)
                    }

                    Spacer()

                    HStack(spacing: 10) {
                        counter(icon: "eye.fill", value: item.counters?.reads ?? item.readsCount, color: Theme.textTertiary)
                        counter(icon: "heart.fill", value: item.counters?.reactions ?? item.likesCount, color: Theme.pink.opacity(0.85))
                        counter(icon: "bubble.left.fill", value: item.counters?.comments ?? item.commentsCount, color: Theme.textSecondary)
                    }
                }
            }
            .padding(14)
        }
        .background(Theme.surfaceBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                .strokeBorder(important ? Theme.danger.opacity(0.4) : Theme.border, lineWidth: important ? 1.5 : 0.5)
        )
        .dsCardShadow()
    }

    @ViewBuilder
    private func counter(icon: String, value: Int?, color: Color) -> some View {
        if let v = value, v > 0 {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text("\(v)").font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            .foregroundColor(color)
        }
    }

    private func authorName(_ a: NewsAuthor) -> String {
        let first = a.firstName ?? ""
        let last = a.lastName ?? ""
        let full = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
        return full.isEmpty ? a.username : full
    }
}

// MARK: - Helpers

func parseHexColor(_ hex: String?) -> Color {
    guard let hex = hex?.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: ""),
          hex.count == 6,
          let value = UInt32(hex, radix: 16) else { return Theme.accent }
    let r = Double((value >> 16) & 0xFF) / 255.0
    let g = Double((value >> 8) & 0xFF) / 255.0
    let b = Double(value & 0xFF) / 255.0
    return Color(red: r, green: g, blue: b)
}

func ensureAbsolute(_ url: String) -> String {
    if url.hasPrefix("http") { return url }
    if url.hasPrefix("/")    { return "https://rossihelp.ru" + url }
    return "https://rossihelp.ru/" + url
}

func relativeTime(from date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = Locale(identifier: "ru_RU")
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
}

// MARK: - Shimmer modifier

extension View {
    func shimmering() -> some View {
        self.modifier(ShimmerModifier())
    }
}

struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -0.6
    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(
                    colors: [.clear, .white.opacity(0.4), .clear],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .rotationEffect(.degrees(20))
                .offset(x: phase * 400)
                .blendMode(.overlay)
            )
            .mask(content)
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1.6
                }
            }
    }
}

#Preview {
    NavigationStack { DashboardView() }
        .environmentObject(AuthStore())
}
