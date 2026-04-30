//
//  AnalyticsView.swift — нативная админская аналитика.
//
//  Endpoints (правильные пути из apps/api/src/modules/analytics/analytics.controller.ts):
//   • GET /analytics/overview                 — сводка
//   • GET /analytics/daily?days=14            — динамика по дням
//   • GET /analytics/inactive-users?days=7    — неактивные сотрудники
//   • GET /analytics/bug-speed                — скорость закрытия багов
//   • GET /analytics/support                  — статистика поддержки
//
//  /admin/analytics/summary в бэке НЕ СУЩЕСТВУЕТ — использовали неправильный путь.
//

import SwiftUI

// MARK: - Models

struct AnalyticsOverview: Codable {
    let users: AnalyticsUsers?
    let activity: AnalyticsActivity?
    let feedback: AnalyticsFeedback?
    let bugs: AnalyticsBugs?
    let tasks: AnalyticsTasks?
    let support: AnalyticsSupport?
}
struct AnalyticsUsers: Codable {
    let total: Int?
    let activeNow: Int?
    let weekActive: Int?
}
struct AnalyticsActivity: Codable {
    let messagesWeek: Int?
    let newsWeek: Int?
    let kudosMonth: Int?
}
struct AnalyticsFeedback: Codable {
    let open: Int?
    let approved: Int?
}
struct AnalyticsBugs: Codable {
    let open: Int?
    let closedMonth: Int?
}
struct AnalyticsTasks: Codable {
    let open: Int?
    let doneMonth: Int?
}
struct AnalyticsSupport: Codable {
    let open: Int?
    let closedMonth: Int?
}

struct AnalyticsDailyPoint: Codable, Identifiable {
    var id: String { date }
    let date: String
    let messages: Int?
    let activeUsers: Int?
    let feedbackNew: Int?
    let bugsClosed: Int?
}

struct AnalyticsInactiveUser: Codable, Identifiable {
    let id: String
    let username: String
    let firstName: String?
    let lastName: String?
    let avatarUrl: String?
    let lastSeenAt: String?

    var displayName: String {
        let s = "\(firstName ?? "") \(lastName ?? "")".trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? username : s
    }
}

private enum AnalyticsRange: Int, CaseIterable, Identifiable {
    case d7 = 7
    case d14 = 14
    case d30 = 30
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .d7: return "7 дней"
        case .d14: return "14 дней"
        case .d30: return "30 дней"
        }
    }
}

private enum AnalyticsChartMetric: String, CaseIterable, Identifiable {
    case messages, activeUsers, feedbackNew, bugsClosed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .messages: return "Сообщения"
        case .activeUsers: return "Активные"
        case .feedbackNew: return "Идеи"
        case .bugsClosed: return "Баги ▼"
        }
    }
    func value(_ p: AnalyticsDailyPoint) -> Int {
        switch self {
        case .messages: return p.messages ?? 0
        case .activeUsers: return p.activeUsers ?? 0
        case .feedbackNew: return p.feedbackNew ?? 0
        case .bugsClosed: return p.bugsClosed ?? 0
        }
    }
}

// MARK: - View

struct AnalyticsView: View {
    @State private var overview: AnalyticsOverview?
    @State private var daily: [AnalyticsDailyPoint] = []
    @State private var inactive: [AnalyticsInactiveUser] = []
    @State private var range: AnalyticsRange = .d14
    @State private var metric: AnalyticsChartMetric = .messages
    @State private var loading = true
    @State private var error: String?
    @State private var notImplemented = false

    private var cols: [GridItem] {
        [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
    }

    var body: some View {
        ZStack {
            Theme.pageBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    DSPageTitle(text: "Аналитика", subtitle: "Сводка по платформе")
                        .padding(.top, 4)

                    if notImplemented {
                        notImplementedCard
                    } else if loading && overview == nil {
                        ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.top, 60)
                    } else if let err = error, overview == nil {
                        EmptyStateView(icon: "exclamationmark.triangle", title: "Ошибка", description: err)
                    } else if let s = overview {
                        statsGrid(s)

                        if !daily.isEmpty {
                            chartCard
                        }

                        if !inactive.isEmpty {
                            inactiveSection
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Аналитика")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { if overview == nil && !notImplemented { await load() } }
    }

    @ViewBuilder
    private var notImplementedCard: some View {
        DSCard(radius: Radius.xl, padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    DSIconTile(systemImage: "chart.line.uptrend.xyaxis", color: Theme.accent, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Аналитика").font(.dsBodyLG.weight(.semibold)).foregroundColor(Theme.textPrimary)
                        Text("Раздел в разработке").font(.dsCaption).foregroundColor(Theme.textSecondary)
                    }
                    Spacer()
                }
                Text("Полные графики и срезы доступны в веб-версии.")
                    .font(.dsBodySM).foregroundColor(Theme.textSecondary)
                Link(destination: URL(string: "https://rossihelp.ru/admin/analytics")!) {
                    HStack(spacing: 6) {
                        Image(systemName: "safari")
                        Text("Открыть в браузере")
                    }
                    .font(.dsBodySM.weight(.semibold))
                    .foregroundColor(Theme.accent)
                }
            }
        }
    }

    @ViewBuilder
    private func statsGrid(_ s: AnalyticsOverview) -> some View {
        LazyVGrid(columns: cols, spacing: 10) {
            statCard(title: "Всего", value: s.users?.total, icon: "person.2.fill", color: Theme.accent)
            statCard(title: "Активные сейчас", value: s.users?.activeNow, icon: "circle.fill", color: Theme.success)
            statCard(title: "За неделю", value: s.users?.weekActive, icon: "person.3.fill", color: Theme.indigo)
            statCard(title: "Сообщения / нед.", value: s.activity?.messagesWeek, icon: "message.fill", color: Theme.purple)
            statCard(title: "Идеи: открыто", value: s.feedback?.open, icon: "lightbulb.fill", color: Theme.warning)
            statCard(title: "Идеи: принято", value: s.feedback?.approved, icon: "checkmark.seal.fill", color: Theme.success)
            statCard(title: "Баги: открыто", value: s.bugs?.open, icon: "ant.fill", color: Theme.danger)
            statCard(title: "Баги ▼ / мес.", value: s.bugs?.closedMonth, icon: "checkmark.circle.fill", color: Theme.success)
            statCard(title: "Задачи: открыто", value: s.tasks?.open, icon: "checkmark.square.fill", color: Theme.accent)
            statCard(title: "Задачи ▼ / мес.", value: s.tasks?.doneMonth, icon: "checkmark.circle.fill", color: Theme.success)
            statCard(title: "Поддержка: откр.", value: s.support?.open, icon: "headphones", color: Theme.warning)
            statCard(title: "Kudos / мес.", value: s.activity?.kudosMonth, icon: "hand.thumbsup.fill", color: Theme.pink)
        }
    }

    @ViewBuilder
    private func statCard(title: String, value: Int?, icon: String, color: Color) -> some View {
        DSCard(radius: Radius.lg, padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                DSIconTile(systemImage: icon, color: color, size: 30)
                if let v = value {
                    Text("\(v)").font(.dsH2).monospacedDigit().foregroundColor(Theme.textPrimary)
                } else {
                    Text("—").font(.dsH2).foregroundColor(Theme.textTertiary)
                }
                Text(title).font(.dsCaption).foregroundColor(Theme.textSecondary).lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var chartCard: some View {
        DSCard(radius: Radius.lg, padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Динамика").font(.dsBodyLG.weight(.semibold)).foregroundColor(Theme.textPrimary)
                    Spacer()
                    Picker("", selection: $range) {
                        ForEach(AnalyticsRange.allCases) { r in Text(r.title).tag(r) }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: range) { _ in Task { await loadDaily() } }
                }

                Picker("Метрика", selection: $metric) {
                    ForEach(AnalyticsChartMetric.allCases) { m in Text(m.title).tag(m) }
                }
                .pickerStyle(.segmented)

                let values = daily.map(metric.value)
                let maxV = max(1, values.max() ?? 1)

                VStack(spacing: 4) {
                    ForEach(daily.suffix(14)) { pt in
                        let v = metric.value(pt)
                        HStack(spacing: 8) {
                            Text(String(pt.date.suffix(5)))
                                .font(.dsCaption.monospacedDigit())
                                .foregroundColor(Theme.textTertiary)
                                .frame(width: 56, alignment: .leading)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 4).fill(Theme.border).frame(height: 12)
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(LinearGradient(colors: [Theme.accent, Theme.purple],
                                                             startPoint: .leading, endPoint: .trailing))
                                        .frame(width: max(2, geo.size.width * CGFloat(Double(v) / Double(maxV))),
                                               height: 12)
                                }
                            }
                            .frame(height: 12)
                            Text("\(v)")
                                .font(.dsCaption.monospacedDigit())
                                .foregroundColor(Theme.textSecondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var inactiveSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            DSSectionHeader("Неактивные сотрудники")
            DSCard(radius: Radius.lg, padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(inactive.prefix(10).enumerated()), id: \.element.id) { idx, u in
                        HStack(spacing: 10) {
                            AvatarCircle(url: u.avatarUrl, name: u.displayName).frame(width: 32, height: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(u.displayName).font(.dsBodySM.weight(.medium)).foregroundColor(Theme.textPrimary)
                                Text("@\(u.username)").font(.system(size: 11, design: .monospaced)).foregroundColor(Theme.textTertiary)
                            }
                            Spacer()
                            if let ls = u.lastSeenAt, let d = ISO8601DateFormatter().date(from: ls) {
                                Text(relativeTime(from: d))
                                    .font(.dsCaption)
                                    .foregroundColor(Theme.textTertiary)
                            } else {
                                Text("никогда").font(.dsCaption).foregroundColor(Theme.danger)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        if idx < min(inactive.count, 10) - 1 {
                            Rectangle().fill(Theme.separator).frame(height: 0.5).padding(.leading, 54)
                        }
                    }
                }
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        async let overviewTask: AnalyticsOverview = APIClient.shared.get("analytics/overview")
        async let dailyTask: [AnalyticsDailyPoint] = APIClient.shared.get(
            "analytics/daily", query: ["days": "\(range.rawValue)"]
        )
        async let inactiveTask: [AnalyticsInactiveUser] = APIClient.shared.get(
            "analytics/inactive-users", query: ["days": "7"]
        )
        do {
            let o = try await overviewTask
            self.overview = o
            self.daily = (try? await dailyTask) ?? []
            self.inactive = (try? await inactiveTask) ?? []
            self.error = nil
        } catch {
            // 404 → бэк не имеет analytics; показываем «В разработке»
            if let api = error as? APIError, case .http(let status, _) = api, status == 404 {
                self.notImplemented = true
            } else {
                self.error = apiUserMessage(error)
            }
        }
    }

    private func loadDaily() async {
        do {
            let arr: [AnalyticsDailyPoint] = try await APIClient.shared.get(
                "analytics/daily", query: ["days": "\(range.rawValue)"]
            )
            self.daily = arr
        } catch {}
    }
}

#Preview {
    NavigationStack { AnalyticsView() }
}
