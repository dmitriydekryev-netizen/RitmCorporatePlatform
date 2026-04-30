//
//  AdminHubView.swift — лендинг админ-панели для iOS.
//  Полностью нативная админка с дизайном как в web-версии.
//

import SwiftUI
import UIKit

struct AdminHubView: View {
    @EnvironmentObject var auth: AuthStore

    @State private var unresolvedErrors: Int?
    @State private var pendingFeedback: Int?
    @State private var pendingVerification: Int?
    @State private var healthStatus: String?
    @State private var loading = true

    private var isAdmin: Bool {
        auth.currentUser?.permissions?.contains(where: { $0.contains("admin") || $0 == "*" }) ?? false
    }

    private let statColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DSPageTitle(text: "Админ-панель",
                            subtitle: "Управление и мониторинг платформы")
                    .padding(.top, 4)

                heroCard
                statsGrid

                groupSection(title: "Люди") {
                    nativeRow("Пользователи", icon: "person.2.fill", color: Theme.accent) {
                        UsersAdminView()
                    }
                    rowSeparator
                    nativeRow("Роли и права", icon: "shield.lefthalf.filled", color: Theme.indigo) {
                        RolesAdminView()
                    }
                    rowSeparator
                    nativeRow("Верификация", icon: "checkmark.seal.fill", color: Theme.success, badge: pendingVerification) {
                        VerificationQueueView()
                    }
                }

                groupSection(title: "Контент") {
                    nativeRow("Достижения", icon: "trophy.fill", color: Theme.warning) {
                        AchievementsAdminView()
                    }
                    rowSeparator
                    nativeRow("Награды", icon: "rosette", color: Theme.warning) {
                        AwardsAdminView()
                    }
                    rowSeparator
                    nativeRow("Обучение", icon: "graduationcap.fill", color: Theme.purple) {
                        LearningAdminView()
                    }
                    rowSeparator
                    nativeRow("Постинг", icon: "megaphone.fill", color: Theme.accent) {
                        PostingView()
                    }
                }

                groupSection(title: "Операции") {
                    nativeRow("Задачи", icon: "checkmark.circle.fill", color: Theme.success) {
                        TasksAdminView()
                    }
                    rowSeparator
                    nativeRow("График: согласование", icon: "calendar", color: Theme.accent) {
                        AdminScheduleApprovalsView()
                    }
                    rowSeparator
                    nativeRow("Идеи и баги", icon: "lightbulb.fill", color: Theme.warning, badge: pendingFeedback) {
                        FeedbackAdminView()
                    }
                }

                groupSection(title: "Мониторинг") {
                    nativeRow("Здоровье системы", icon: "waveform.path.ecg", color: Theme.success) {
                        SystemHealthView()
                    }
                    rowSeparator
                    nativeRow("Ошибки", icon: "exclamationmark.triangle.fill", color: Theme.danger, badge: unresolvedErrors) {
                        ErrorsMonitorView()
                    }
                    rowSeparator
                    nativeRow("Аудит", icon: "doc.text.magnifyingglass", color: Theme.textSecondary) {
                        AuditLogView()
                    }
                    rowSeparator
                    nativeRow("Аналитика", icon: "chart.line.uptrend.xyaxis", color: Theme.accent) {
                        AnalyticsView()
                    }
                }
                Color.clear.frame(height: TabBarVisibility.reservedHeight)
            }
            .padding(16)
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("Админ-панель")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await loadStats() }
        .task { await loadStats() }
    }

    // MARK: - Hero

    @ViewBuilder
    private var heroCard: some View {
        ZStack(alignment: .topLeading) {
            // Base gradient
            LinearGradient(
                colors: [Theme.accent, Theme.purple, Theme.pink],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            // Blur color blob — clipped to card
            Circle()
                .fill(Theme.pink.opacity(0.45))
                .frame(width: 220, height: 220)
                .blur(radius: 60)
                .offset(x: 180, y: -40)
            Circle()
                .fill(Theme.accent.opacity(0.4))
                .frame(width: 200, height: 200)
                .blur(radius: 60)
                .offset(x: -60, y: 80)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.title2)
                        .foregroundColor(.white)
                    Text("Управление")
                        .font(.dsH2)
                        .foregroundColor(.white)
                    Spacer()
                    if let h = healthStatus {
                        HStack(spacing: 6) {
                            Circle().fill(healthColor(h)).frame(width: 8, height: 8)
                            Text(healthLabel(h))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.white.opacity(0.18))
                        .clipShape(Capsule())
                    }
                }
                Text("Сводка по платформе и быстрые ссылки на разделы админки")
                    .font(.dsCaption)
                    .foregroundColor(.white.opacity(0.92))
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Radius.xl2, style: .continuous))
        .shadow(color: Theme.purple.opacity(0.3), radius: 18, y: 8)
    }

    // MARK: - Stats grid

    @ViewBuilder
    private var statsGrid: some View {
        LazyVGrid(columns: statColumns, spacing: 10) {
            statCard(
                title: "Ошибки",
                value: unresolvedErrors,
                icon: "exclamationmark.triangle.fill",
                color: (unresolvedErrors ?? 0) > 0 ? Theme.danger : Theme.success
            )
            statCard(
                title: "Идеи",
                value: pendingFeedback,
                icon: "lightbulb.fill",
                color: Theme.warning
            )
            statCard(
                title: "Заявок",
                value: pendingVerification,
                icon: "checkmark.seal.fill",
                color: Theme.accent
            )
        }
    }

    @ViewBuilder
    private func statCard(title: String, value: Int?, icon: String, color: Color) -> some View {
        DSCard(radius: Radius.lg, padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                DSIconTile(systemImage: icon, color: color, size: 32)
                if let v = value {
                    Text("\(v)")
                        .font(.dsH1)
                        .foregroundColor(Theme.textPrimary)
                        .monospacedDigit()
                } else {
                    Text("—")
                        .font(.dsH1)
                        .foregroundColor(Theme.textTertiary)
                }
                Text(title)
                    .font(.dsCaption)
                    .foregroundColor(Theme.textSecondary)
            }
        }
    }

    // MARK: - Group section

    @ViewBuilder
    private func groupSection<Content: View>(title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            DSSectionHeader(title)
            DSCard(radius: Radius.xl, padding: 0) {
                VStack(spacing: 0) {
                    content()
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var rowSeparator: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: 0.5)
            .padding(.leading, 14 + 32 + 12)
    }

    @ViewBuilder
    private func nativeRow<Destination: View>(
        _ title: String,
        icon: String,
        color: Color,
        badge: Int? = nil,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            adminRowContent(title: title, icon: icon, color: color, badge: badge, externalIcon: false)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func webRow(_ title: String, icon: String, path: String, color: Color, badge: Int? = nil) -> some View {
        Link(destination: URL(string: "https://rossihelp.ru\(path)")!) {
            adminRowContent(title: title, icon: icon, color: color, badge: badge, externalIcon: true)
        }
    }

    @ViewBuilder
    private func adminRowContent(title: String, icon: String, color: Color, badge: Int?, externalIcon: Bool) -> some View {
        HStack(spacing: 12) {
            DSIconTile(systemImage: icon, color: color, size: 32)
            Text(title)
                .font(.dsBodyLG)
                .foregroundColor(Theme.textPrimary)
            Spacer()
            if let b = badge, b > 0 {
                DSBadge(text: "\(b)", color: color, filled: true)
            }
            Image(systemName: externalIcon ? "arrow.up.right.square" : "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    // MARK: - Loading

    private func loadStats() async {
        loading = true
        defer { loading = false }

        async let errors = fetchErrors()
        async let feedback = fetchFeedback()
        async let verification = fetchVerification()
        async let health = fetchHealth()

        let (e, f, v, h) = await (errors, feedback, verification, health)
        self.unresolvedErrors = e
        self.pendingFeedback = f
        self.pendingVerification = v
        self.healthStatus = h
    }

    private func fetchErrors() async -> Int? {
        struct R: Decodable { let count: Int? }
        return try? await (APIClient.shared.get("errors/unresolved-count") as R).count
    }

    private func fetchFeedback() async -> Int? {
        struct R: Decodable {
            let byStatus: [String: Int]?
        }
        let r: R? = try? await APIClient.shared.get("feedback/counts")
        let byStatus = r?.byStatus ?? [:]
        return (byStatus["new"] ?? 0) + (byStatus["in_review"] ?? 0)
    }

    private func fetchVerification() async -> Int? {
        struct R: Decodable {
            struct Meta: Decodable { let total: Int? }
            let meta: Meta?
        }
        let r: R? = try? await APIClient.shared.get(
            "admin/verification",
            query: ["status": "pending", "limit": "1"]
        )
        return r?.meta?.total
    }

    private func fetchHealth() async -> String? {
        struct R: Decodable { let status: String? }
        return try? await (APIClient.shared.get("admin/health/snapshot") as R).status
    }

    private func healthColor(_ status: String) -> Color {
        switch status {
        case "ok":       return Theme.success
        case "degraded": return Theme.warning
        case "down":     return Theme.danger
        default:         return Theme.textTertiary
        }
    }

    private func healthLabel(_ status: String) -> String {
        switch status {
        case "ok":       return "OK"
        case "degraded": return "Degraded"
        case "down":     return "Down"
        default:         return status.capitalized
        }
    }
}
