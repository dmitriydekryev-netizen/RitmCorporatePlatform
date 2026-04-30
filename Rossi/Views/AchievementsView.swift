//
//  AchievementsView.swift — модуль «Достижения».
//  GET /achievements              — каталог
//  GET /users/:userId/achievements — выданные текущему юзеру
//

import SwiftUI

// MARK: - Models (зеркало бэка)

struct AchievementItem: Codable, Identifiable, Hashable {
    let id: String
    let code: String
    let name: String
    let description: String?
    let category: String?
    let level: Int?
    let iconUrl: String?
    let color: String?
    let isActive: Bool?
    let grantedCount: Int?
}

// Сервер отдаёт списки achievements/awards КАК МАССИВ напрямую, без обёртки {data:...}.

struct UserAchievement: Codable, Identifiable {
    let id: String
    let achievement: AchievementItem
    let grantedAt: String
    let comment: String?
    let grantedBy: AchievementGranter?
}

struct AchievementGranter: Codable, Hashable {
    let id: String
    let username: String
    let firstName: String?
    let lastName: String?
    let avatarUrl: String?

    var fullName: String {
        "\(firstName ?? "") \(lastName ?? "")"
            .trimmingCharacters(in: .whitespaces)
            .ifEmpty(or: username)
    }
}

// MARK: - Helpers

private func levelColor(_ level: Int) -> Color {
    switch level {
    case 1:  return Theme.warning
    case 2:  return Color(white: 0.7)
    case 3:  return Color.yellow
    case 4:  return Theme.purple
    default: return Theme.accent
    }
}

private func levelTitle(_ level: Int) -> String {
    switch level {
    case 1:  return "Бронза"
    case 2:  return "Серебро"
    case 3:  return "Золото"
    case 4:  return "Платина"
    default: return "Уровень \(level)"
    }
}

private func categoryTitle(_ category: String) -> String {
    switch category {
    case "onboarding":   return "Онбординг"
    case "social":       return "Социальные"
    case "performance":  return "Результаты"
    case "learning":     return "Обучение"
    case "engagement":   return "Вовлечённость"
    case "leadership":   return "Лидерство"
    case "milestone":    return "Этапы"
    default:
        return category.prefix(1).uppercased() + category.dropFirst()
    }
}

private func parseHexColor(_ hex: String?) -> Color? {
    guard let hex = hex?.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: ""),
          hex.count == 6,
          let value = UInt32(hex, radix: 16) else { return nil }
    let r = Double((value >> 16) & 0xFF) / 255.0
    let g = Double((value >> 8)  & 0xFF) / 255.0
    let b = Double(value         & 0xFF) / 255.0
    return Color(red: r, green: g, blue: b)
}

// MARK: - Main view

struct AchievementsView: View {
    @EnvironmentObject var auth: AuthStore

    enum Tab: Hashable { case mine, all }
    @State private var tab: Tab = .mine

    @State private var mine: [UserAchievement] = []
    @State private var catalog: [AchievementItem] = []
    @State private var loading = true
    @State private var error: String?
    @State private var selectedCategory: String? = nil

    private var ownedIds: Set<String> {
        Set(mine.map { $0.achievement.id })
    }

    /// Уникальные категории среди отображаемого списка (mine для tab .mine, catalog для tab .all).
    private var availableCategories: [String] {
        var set = Set<String>()
        switch tab {
        case .mine:
            for ua in mine {
                if let c = ua.achievement.category, !c.isEmpty { set.insert(c) }
            }
        case .all:
            for it in catalog {
                if let c = it.category, !c.isEmpty { set.insert(c) }
            }
        }
        return set.sorted()
    }

    private var grouped: [(String, [UserAchievement])] {
        let source: [UserAchievement]
        if let cat = selectedCategory {
            source = mine.filter { ($0.achievement.category ?? "other") == cat }
        } else {
            source = mine
        }
        let dict = Dictionary(grouping: source, by: { $0.achievement.category ?? "other" })
        return dict
            .map { (categoryTitle($0.key), $0.value.sorted { $0.grantedAt > $1.grantedAt }) }
            .sorted { $0.0 < $1.0 }
    }

    private var filteredCatalog: [AchievementItem] {
        guard let cat = selectedCategory else { return catalog }
        return catalog.filter { ($0.category ?? "other") == cat }
    }

    private let gridColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                DSPageTitle(text: "Достижения",
                            subtitle: "Коллекция ваших наград и значков")
                    .padding(.top, 4)

                Picker("", selection: $tab) {
                    Text("Мои").tag(Tab.mine)
                    Text("Все").tag(Tab.all)
                }
                .pickerStyle(.segmented)

                if !availableCategories.isEmpty {
                    HStack {
                        categoryFilterMenu
                        Spacer()
                    }
                }

                content
                Color.clear.frame(height: TabBarVisibility.reservedHeight)
            }
            .padding(16)
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("Достижения")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { if mine.isEmpty && catalog.isEmpty { await load() } }
    }

    @ViewBuilder
    private var content: some View {
        if loading && mine.isEmpty && catalog.isEmpty {
            ProgressView().tint(Theme.accent)
                .frame(maxWidth: .infinity, minHeight: 200)
        } else {
            switch tab {
            case .mine: mineList
            case .all:  allList
            }
        }
    }

    @ViewBuilder
    private var mineList: some View {
        if mine.isEmpty {
            EmptyStateView(
                icon: "trophy",
                title: "Пока нет достижений",
                description: error ?? "Получайте достижения за активность в компании"
            )
        } else if grouped.isEmpty {
            EmptyStateView(
                icon: "folder.badge.questionmark",
                title: "Нет достижений в категории",
                description: "Попробуйте сменить фильтр"
            )
        } else {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(grouped, id: \.0) { (title, items) in
                    VStack(alignment: .leading, spacing: 10) {
                        DSSectionHeader(title)

                        LazyVGrid(columns: gridColumns, spacing: 12) {
                            ForEach(items) { ua in
                                NavigationLink {
                                    AchievementDetailView(achievement: ua.achievement,
                                                          grantedAt: ua.grantedAt,
                                                          comment: ua.comment,
                                                          granter: ua.grantedBy)
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
    }

    @ViewBuilder
    private var categoryFilterMenu: some View {
        Menu {
            Button {
                selectedCategory = nil
            } label: {
                if selectedCategory == nil {
                    Label("Все категории", systemImage: "checkmark")
                } else {
                    Text("Все категории")
                }
            }
            ForEach(availableCategories, id: \.self) { c in
                Button {
                    selectedCategory = c
                } label: {
                    if selectedCategory == c {
                        Label(categoryTitle(c), systemImage: "checkmark")
                    } else {
                        Text(categoryTitle(c))
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .semibold))
                Text(selectedCategory.map(categoryTitle) ?? "Все категории")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundColor(selectedCategory == nil ? Theme.accent : .white)
            .background(
                Capsule().fill(
                    selectedCategory == nil
                        ? Theme.accent.opacity(0.12)
                        : Theme.accent
                )
            )
        }
        .buttonStyle(DSPressScaleStyle())
    }

    @ViewBuilder
    private var allList: some View {
        if catalog.isEmpty {
            EmptyStateView(
                icon: "trophy",
                title: "Каталог пуст",
                description: error ?? "Достижения ещё не настроены"
            )
        } else if filteredCatalog.isEmpty {
            EmptyStateView(
                icon: "folder.badge.questionmark",
                title: "Нет достижений в категории",
                description: "Попробуйте сменить фильтр"
            )
        } else {
            LazyVGrid(columns: gridColumns, spacing: 12) {
                ForEach(filteredCatalog) { item in
                    let owned = ownedIds.contains(item.id)
                    NavigationLink {
                        AchievementDetailView(achievement: item,
                                              grantedAt: nil,
                                              comment: nil,
                                              granter: nil)
                    } label: {
                        AchievementGridCard(
                            achievement: item,
                            grantedAt: nil,
                            owned: owned,
                            showLevelBadge: true
                        )
                        .opacity(owned ? 1.0 : 0.4)
                    }
                    .buttonStyle(DSPressScaleStyle())
                }
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        guard let userId = auth.currentUser?.id else {
            self.error = "Не удалось определить пользователя"
            return
        }
        do {
            async let mineResp: [UserAchievement] =
                APIClient.shared.get("users/\(userId)/achievements")
            async let allResp: [AchievementItem] =
                APIClient.shared.get("achievements")

            let (m, a) = try await (mineResp, allResp)
            self.mine = m
            self.catalog = a
            self.error = nil
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}

// MARK: - Grid card (2-column tile)

struct AchievementGridCard: View {
    let achievement: AchievementItem
    let grantedAt: String?
    let owned: Bool
    let showLevelBadge: Bool

    private var iconColor: Color {
        parseHexColor(achievement.color) ?? levelColor(achievement.level ?? 1)
    }

    var body: some View {
        DSCard(radius: Radius.xl, padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    iconCircle.frame(width: 60, height: 60)
                    Spacer(minLength: 0)
                    if showLevelBadge {
                        DSBadge(
                            text: levelTitle(achievement.level ?? 1),
                            color: levelColor(achievement.level ?? 1),
                            filled: true
                        )
                    }
                }

                Text(achievement.name)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(achievement.description ?? "")
                    .font(.dsCaption)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let g = grantedAt,
                   let d = ISO8601DateFormatter().date(from: g) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.success)
                        Text(relativeTime(from: d))
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textTertiary)
                    }
                }
            }
        }
    }

    private var iconCircle: some View {
        ZStack {
            Circle().fill(iconColor.opacity(owned ? 0.18 : 0.12))
            Circle()
                .strokeBorder(iconColor.opacity(owned ? 0.55 : 0.3), lineWidth: 1.5)

            if let urlStr = achievement.iconUrl,
               let u = URL(string: ensureAbsolute(urlStr)) {
                AsyncImage(url: u) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFit().padding(10)
                    default:
                        fallbackIcon
                    }
                }
            } else {
                fallbackIcon
            }
        }
    }

    private var fallbackIcon: some View {
        Image(systemName: "trophy.fill")
            .font(.system(size: 24, weight: .semibold))
            .foregroundColor(iconColor)
    }
}

// MARK: - Detail

struct AchievementDetailView: View {
    let achievement: AchievementItem
    let grantedAt: String?
    let comment: String?
    let granter: AchievementGranter?

    private var iconColor: Color {
        parseHexColor(achievement.color) ?? levelColor(achievement.level ?? 1)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                // Hero — большая иконка + градиент-фон цвета достижения
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.xl3, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [iconColor.opacity(0.35),
                                         iconColor.opacity(0.10),
                                         Theme.surfaceBackground],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                    VStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(
                                    RadialGradient(
                                        colors: [iconColor.opacity(0.45), iconColor.opacity(0.05)],
                                        center: .center, startRadius: 4, endRadius: 90
                                    )
                                )
                            Circle()
                                .strokeBorder(iconColor.opacity(0.6), lineWidth: 2)

                            if let urlStr = achievement.iconUrl,
                               let u = URL(string: ensureAbsolute(urlStr)) {
                                AsyncImage(url: u) { phase in
                                    switch phase {
                                    case .success(let img):
                                        img.resizable().scaledToFit().padding(28)
                                    default:
                                        Image(systemName: "trophy.fill")
                                            .font(.system(size: 56, weight: .bold))
                                            .foregroundColor(iconColor)
                                    }
                                }
                            } else {
                                Image(systemName: "trophy.fill")
                                    .font(.system(size: 56, weight: .bold))
                                    .foregroundColor(iconColor)
                            }
                        }
                        .frame(width: 140, height: 140)

                        DSBadge(
                            text: levelTitle(achievement.level ?? 1),
                            color: levelColor(achievement.level ?? 1),
                            filled: true
                        )

                        VStack(spacing: 6) {
                            Text(achievement.name)
                                .font(.dsH1)
                                .foregroundColor(Theme.textPrimary)
                                .multilineTextAlignment(.center)
                            Text(achievement.description ?? "")
                                .font(.dsBody)
                                .foregroundColor(Theme.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 24)
                    }
                    .padding(.vertical, 24)
                }
                .frame(maxWidth: .infinity)

                // Granter
                if let g = granter {
                    DSCard(radius: Radius.lg, padding: 14) {
                        HStack(spacing: 12) {
                            AvatarCircle(url: g.avatarUrl, name: g.fullName)
                                .frame(width: 36, height: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Выдал(а)")
                                    .font(.dsCaption)
                                    .foregroundColor(Theme.textTertiary)
                                Text(g.fullName)
                                    .font(.dsH3)
                                    .foregroundColor(Theme.textPrimary)
                            }
                            Spacer()
                            if let g = grantedAt,
                               let d = ISO8601DateFormatter().date(from: g) {
                                Text(relativeTime(from: d))
                                    .font(.dsCaption)
                                    .foregroundColor(Theme.textTertiary)
                            }
                        }
                    }
                }

                // Comment
                if let comment = comment, !comment.isEmpty {
                    DSCard(radius: Radius.lg, padding: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            DSSectionHeader("Комментарий")
                            Text(comment)
                                .font(.dsBodyLG)
                                .foregroundColor(Theme.textPrimary)
                        }
                    }
                }

                // Category + code
                HStack(spacing: 8) {
                    DSBadge(
                        text: categoryTitle(achievement.category ?? "other"),
                        systemImage: "folder.fill",
                        color: Theme.textSecondary
                    )
                    Text(achievement.code)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                    Spacer()
                }
                .padding(.bottom, 24)
            }
            .padding(16)
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("Достижение")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { AchievementsView() }
        .environmentObject(AuthStore())
}
