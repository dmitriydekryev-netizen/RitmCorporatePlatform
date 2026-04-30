//
//  ProfileView.swift — экран «Профиль» (свой собственный).
//
//  Зеркалит структуру TeamMemberProfileView (чужой профиль), плюс
//  превью разделов «Достижения» и «Награды» с переходом во внутренние
//  модули. На веб-версии Достижения/Награды живут так же — внутри
//  страницы профиля, а не в отдельном пункте меню.
//
//  Источники данных:
//   • currentUser (AuthStore) — базовые поля
//   • GET /profiles/:userId   — расширенный профиль (skills/interests/birthDate/...)
//   • GET /users/:userId/achievements
//   • GET /users/:userId/awards
//

import SwiftUI

struct ProfileView: View {
    @EnvironmentObject var auth: AuthStore

    @State private var profile: PublicProfile?
    @State private var achievements: [UserAchievement] = []
    @State private var awards: [UserAward] = []

    @State private var loadingProfile = true
    @State private var loadError: String?

    @State private var showLogoutConfirm = false
    @State private var loggingOut = false
    @State private var showEditSheet = false

    var body: some View {
        Group {
            if let user = auth.currentUser {
                content(for: user)
            } else {
                ProgressView().tint(Theme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.pageBackground.ignoresSafeArea())
            }
        }
        .navigationTitle("Профиль")
        .navigationBarTitleDisplayMode(.inline)
        .background(Theme.pageBackground.ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showEditSheet = true
                } label: {
                    Label("Редактировать", systemImage: "pencil")
                }
                .disabled(auth.currentUser == nil)
            }
        }
        .sheet(isPresented: $showEditSheet) {
            EditProfileSheet()
                .environmentObject(auth)
        }
        .task { await loadAll() }
        .refreshable { await loadAll() }
        .alert("Выйти из аккаунта?", isPresented: $showLogoutConfirm) {
            Button("Отмена", role: .cancel) {}
            Button("Выйти", role: .destructive) {
                Task {
                    loggingOut = true
                    await auth.logout()
                    loggingOut = false
                }
            }
        } message: {
            Text("Сессия будет завершена. Чтобы продолжить работу, войдите снова.")
        }
    }

    @ViewBuilder
    private func content(for user: AuthUser) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                // Hero gradient card (обложка с аватаром, ФИО, должностью)
                heroCard(user: user)

                if let err = loadError {
                    errorBanner(err)
                }

                // Контактные данные (логин/email/phone/telegram/др)
                contactCard(user: user)

                // О себе (bio)
                if let bio = bio(for: user), !bio.isEmpty {
                    bioCard(bio)
                }

                // О работе (должность / отдел / дата рождения)
                workCard(user: user)

                // Skills / Interests
                if let skills = profile?.skills, !skills.isEmpty {
                    chipsCard(title: "Навыки", items: skills, color: Theme.accent)
                }
                if let interests = profile?.interests, !interests.isEmpty {
                    chipsCard(title: "Интересы", items: interests, color: Theme.purple)
                }

                // Достижения — превью первых 4 + переход на полный экран
                achievementsSection

                // Награды — превью первых 3 + переход на полный экран
                awardsSection

                // Open on web
                if let url = URL(string: "https://rossihelp.ru/profile") {
                    DSSecondaryButton(action: {
                        UIApplication.shared.open(url)
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.right.square")
                            Text("Открыть на сайте")
                        }
                    }
                }

                // Logout — destructive
                Button {
                    showLogoutConfirm = true
                } label: {
                    HStack(spacing: 8) {
                        if loggingOut {
                            ProgressView().tint(.white).scaleEffect(0.85)
                        } else {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                        }
                        Text("Выйти из аккаунта")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundColor(.white)
                    .background(Theme.danger)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    .shadow(color: Theme.danger.opacity(0.35), radius: 14, x: 0, y: 4)
                }
                .buttonStyle(DSPressScaleStyle())
                .disabled(loggingOut)

                Text("Ритм • v\(appVersion)")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.top, 8)

                Color.clear.frame(height: TabBarVisibility.reservedHeight)
            }
            .padding(16)
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private func heroCard(user: AuthUser) -> some View {
        VStack(spacing: 12) {
            AvatarCircle(url: avatarUrl(for: user), name: user.displayName)
                .frame(width: 96, height: 96)
                .overlay(
                    Circle().strokeBorder(Color.white, lineWidth: 4)
                )
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)

            Text(user.displayName)
                .font(.dsH1)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)

            if let pos = position(for: user), !pos.isEmpty {
                Text(pos)
                    .font(.dsH3)
                    .foregroundColor(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
            }
            if let dep = departmentName(for: user), !dep.isEmpty {
                Text(dep)
                    .font(.dsCaption)
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 20)
        .background(
            LinearGradient(
                colors: [Theme.accent, Theme.purple, Theme.pink],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.xl2, style: .continuous))
        .shadow(color: Theme.purple.opacity(0.3), radius: 18, y: 8)
    }

    // MARK: - Contact card

    @ViewBuilder
    private func contactCard(user: AuthUser) -> some View {
        let rows = contactRows(user: user)
        if !rows.isEmpty {
            DSCard(radius: Radius.xl, padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { (idx, row) in
                        HStack(spacing: 12) {
                            DSIconTile(systemImage: row.0, color: row.3, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.1)
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.textTertiary)
                                Text(row.2)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(Theme.textPrimary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        if idx < rows.count - 1 {
                            Rectangle()
                                .fill(Theme.separator)
                                .frame(height: 0.5)
                                .padding(.leading, 60)
                        }
                    }
                }
            }
        }
    }

    /// Контактные строки: иконка / лейбл / значение / цвет.
    private func contactRows(user: AuthUser) -> [(String, String, String, Color)] {
        var rows: [(String, String, String, Color)] = []
        rows.append(("at", "Логин", "@\(user.username)", Theme.accent))
        if let email = user.email, !email.isEmpty {
            rows.append(("envelope.fill", "Email", email, Theme.info))
        }
        if let phone = nonEmpty(user.profile?.phone) ?? nonEmpty(profile?.phone) {
            rows.append(("phone.fill", "Телефон", phone, Theme.success))
        }
        if let tg = nonEmpty(user.profile?.telegram) ?? nonEmpty(profile?.telegram) {
            rows.append(("paperplane.fill", "Telegram", tg, Theme.indigo))
        }
        return rows
    }

    // MARK: - Bio card

    @ViewBuilder
    private func bioCard(_ bio: String) -> some View {
        DSCard(radius: Radius.xl, padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("О себе")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundColor(Theme.textTertiary)
                Text(bio)
                    .font(.system(size: 15))
                    .foregroundColor(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    // MARK: - Work card (должность / отдел / ДР)

    @ViewBuilder
    private func workCard(user: AuthUser) -> some View {
        let rows = workRows(user: user)
        if !rows.isEmpty {
            DSCard(radius: Radius.xl, padding: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("О работе")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.6)
                        .textCase(.uppercase)
                        .foregroundColor(Theme.textTertiary)

                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { (idx, row) in
                            HStack(spacing: 12) {
                                DSIconTile(systemImage: row.0, color: row.3, size: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.1)
                                        .font(.system(size: 11))
                                        .foregroundColor(Theme.textTertiary)
                                    Text(row.2)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(Theme.textPrimary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 6)
                            if idx < rows.count - 1 {
                                Rectangle()
                                    .fill(Theme.separator)
                                    .frame(height: 0.5)
                                    .padding(.leading, 42)
                            }
                        }
                    }
                }
            }
        }
    }

    private func workRows(user: AuthUser) -> [(String, String, String, Color)] {
        var rows: [(String, String, String, Color)] = []
        if let pos = position(for: user), !pos.isEmpty {
            rows.append(("briefcase.fill", "Должность", pos, Theme.accent))
        }
        if let dep = departmentName(for: user), !dep.isEmpty {
            rows.append(("building.2.fill", "Отдел", dep, Theme.indigo))
        }
        if let bd = profile?.birthDate, let parsed = ISO8601DateFormatter().date(from: bd) {
            rows.append(("gift.fill", "День рождения", formatBirthday(parsed), Theme.pink))
        }
        if let joined = profile?.joinedAt, let parsed = ISO8601DateFormatter().date(from: joined) {
            rows.append(("calendar.badge.plus", "В команде с", formatYearMonth(parsed), Theme.success))
        }
        return rows
    }

    // MARK: - Skills/Interests

    @ViewBuilder
    private func chipsCard(title: String, items: [String], color: Color) -> some View {
        DSCard(radius: Radius.xl, padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundColor(Theme.textTertiary)
                FlowLayout(spacing: 6) {
                    ForEach(items, id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(color.opacity(0.12))
                            .foregroundColor(color)
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }

    // MARK: - Achievements section

    @ViewBuilder
    private var achievementsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            DSSectionHeader(
                "Достижения",
                trailing: AnyView(
                    NavigationLink { AchievementsView() } label: {
                        HStack(spacing: 2) {
                            Text("Все")
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.accent)
                    }
                )
            )

            DSCard(radius: Radius.xl, padding: 14) {
                if achievements.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "trophy")
                            .font(.system(size: 22))
                            .foregroundColor(Theme.textTertiary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Пока нет достижений")
                                .font(.dsBodySM.weight(.semibold))
                                .foregroundColor(Theme.textPrimary)
                            Text("Получайте значки за активность")
                                .font(.dsCaption)
                                .foregroundColor(Theme.textTertiary)
                        }
                        Spacer()
                    }
                } else {
                    let preview = Array(achievements.prefix(4))
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 8),
                                  GridItem(.flexible(), spacing: 8)],
                        spacing: 8
                    ) {
                        ForEach(preview) { ua in
                            NavigationLink {
                                AchievementDetailView(
                                    achievement: ua.achievement,
                                    grantedAt: ua.grantedAt,
                                    comment: ua.comment,
                                    granter: ua.grantedBy
                                )
                            } label: {
                                AchievementGridCard(
                                    achievement: ua.achievement,
                                    grantedAt: ua.grantedAt,
                                    owned: true,
                                    showLevelBadge: false
                                )
                            }
                            .buttonStyle(DSPressScaleStyle())
                        }
                    }
                }
            }
        }
    }

    // MARK: - Awards section

    @ViewBuilder
    private var awardsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            DSSectionHeader(
                "Награды",
                trailing: AnyView(
                    NavigationLink { AwardsView() } label: {
                        HStack(spacing: 2) {
                            Text("Все")
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.accent)
                    }
                )
            )

            DSCard(radius: Radius.xl, padding: 14) {
                if awards.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "rosette")
                            .font(.system(size: 22))
                            .foregroundColor(Theme.textTertiary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Пока нет наград")
                                .font(.dsBodySM.weight(.semibold))
                                .foregroundColor(Theme.textPrimary)
                            Text("Грамоты и благодарности появятся здесь")
                                .font(.dsCaption)
                                .foregroundColor(Theme.textTertiary)
                        }
                        Spacer()
                    }
                } else {
                    VStack(spacing: 10) {
                        ForEach(awards.prefix(3)) { ua in
                            awardPreviewRow(ua)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func awardPreviewRow(_ ua: UserAward) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Theme.warning.opacity(0.18))
                Image(systemName: "rosette")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Theme.warning)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(ua.award.name)
                    .font(.dsBodySM.weight(.semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                if let d = ISO8601DateFormatter().date(from: ua.grantedAt) {
                    Text(relativeTime(from: d))
                        .font(.dsCaption)
                        .foregroundColor(Theme.textTertiary)
                }
            }
            Spacer()
        }
    }

    // MARK: - Helpers / accessors

    private func avatarUrl(for user: AuthUser) -> String? {
        user.profile?.avatarUrl ?? profile?.avatarUrl
    }

    private func position(for user: AuthUser) -> String? {
        if let p = user.profile?.position, !p.isEmpty { return p }
        return profile?.position
    }

    private func departmentName(for user: AuthUser) -> String? {
        if let d = user.profile?.department?.name, !d.isEmpty { return d }
        return profile?.department?.name
    }

    private func bio(for user: AuthUser) -> String? {
        if let b = user.profile?.bio, !b.isEmpty { return b }
        return profile?.bio
    }

    /// Возвращает строку, если она непустая после trim — иначе nil.
    private func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }

    private func formatBirthday(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM"
        return f.string(from: date)
    }

    private func formatYearMonth(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "LLLL yyyy"
        return f.string(from: date).capitalized
    }

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

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    // MARK: - Loading

    private func loadAll() async {
        guard let userId = auth.currentUser?.id else { return }
        loadingProfile = true
        loadError = nil
        defer { loadingProfile = false }

        async let profileTask: PublicProfile? = try? await APIClient.shared.get("profiles/\(userId)")
        async let achievementsTask: [UserAchievement]? =
            try? await APIClient.shared.get("users/\(userId)/achievements")
        async let awardsTask: [UserAward]? =
            try? await APIClient.shared.get("users/\(userId)/awards")

        let (p, a, w) = await (profileTask, achievementsTask, awardsTask)
        self.profile = p
        self.achievements = a ?? []
        self.awards = w ?? []
    }
}

#Preview {
    NavigationStack { ProfileView() }
        .environmentObject(AuthStore())
}
