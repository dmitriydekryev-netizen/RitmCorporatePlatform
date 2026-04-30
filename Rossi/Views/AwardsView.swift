//
//  AwardsView.swift — модуль «Награды» (грамоты, благодарности от руководства).
//  GET /awards               — каталог
//  GET /users/:userId/awards — выданные текущему юзеру
//

import SwiftUI

// MARK: - Models

struct AwardItem: Codable, Identifiable, Hashable {
    let id: String
    let code: String
    let name: String
    let description: String?
    let level: Int?
    let iconUrl: String?
    let color: String?
    let isActive: Bool?
    let grantedCount: Int?
}

struct UserAward: Codable, Identifiable {
    let id: String
    let award: AwardItem
    let grantedAt: String
    let comment: String?
    let grantedBy: AchievementGranter?
}

// MARK: - Helpers

private func awardLevelTitle(_ level: Int) -> String {
    switch level {
    case 1:  return "Бронза"
    case 2:  return "Серебро"
    case 3:  return "Золото"
    case 4:  return "Платина"
    default: return "Уровень \(level)"
    }
}

private func awardLevelColor(_ level: Int) -> Color {
    switch level {
    case 1:  return Theme.warning
    case 2:  return Color(white: 0.7)
    case 3:  return Color.yellow
    case 4:  return Theme.purple
    default: return Theme.accent
    }
}

private func parseAwardHex(_ hex: String?) -> Color? {
    guard let hex = hex?.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: ""),
          hex.count == 6,
          let value = UInt32(hex, radix: 16) else { return nil }
    let r = Double((value >> 16) & 0xFF) / 255.0
    let g = Double((value >> 8)  & 0xFF) / 255.0
    let b = Double(value         & 0xFF) / 255.0
    return Color(red: r, green: g, blue: b)
}

private let awardCertificateGradient = LinearGradient(
    colors: [Theme.accent, Theme.purple, Theme.pink],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
)

private let awardPastelGradient = LinearGradient(
    colors: [Theme.accent.opacity(0.10), Theme.purple.opacity(0.08), Theme.pink.opacity(0.10)],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
)

// MARK: - Main view

struct AwardsView: View {
    @EnvironmentObject var auth: AuthStore

    enum Tab: Hashable { case mine, all }
    @State private var tab: Tab = .mine

    @State private var mine: [UserAward] = []
    @State private var catalog: [AwardItem] = []
    @State private var loading = true
    @State private var error: String?
    @State private var selectedYear: Int? = nil

    private var ownedIds: Set<String> {
        Set(mine.map { $0.award.id })
    }

    /// Уникальные года из grantedAt (parsed как ISO8601, fallback — первые 4 символа).
    private var availableYears: [Int] {
        var set = Set<Int>()
        let cal = Calendar(identifier: .gregorian)
        for ua in mine {
            if let d = ISO8601DateFormatter().date(from: ua.grantedAt) {
                set.insert(cal.component(.year, from: d))
            } else if ua.grantedAt.count >= 4, let y = Int(ua.grantedAt.prefix(4)) {
                set.insert(y)
            }
        }
        return set.sorted(by: >)
    }

    private var filteredMine: [UserAward] {
        guard let year = selectedYear else { return mine }
        let cal = Calendar(identifier: .gregorian)
        return mine.filter { ua in
            if let d = ISO8601DateFormatter().date(from: ua.grantedAt) {
                return cal.component(.year, from: d) == year
            }
            if ua.grantedAt.count >= 4, let y = Int(ua.grantedAt.prefix(4)) {
                return y == year
            }
            return false
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                DSPageTitle(text: "Награды",
                            subtitle: "Грамоты и благодарности от руководства")
                    .padding(.top, 4)

                Picker("", selection: $tab) {
                    Text("Мои").tag(Tab.mine)
                    Text("Все").tag(Tab.all)
                }
                .pickerStyle(.segmented)

                if tab == .mine && !availableYears.isEmpty {
                    HStack {
                        yearFilterMenu
                        Spacer()
                    }
                }

                content
                Color.clear.frame(height: TabBarVisibility.reservedHeight)
            }
            .padding(16)
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("Награды")
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
    private var yearFilterMenu: some View {
        Menu {
            Button {
                selectedYear = nil
            } label: {
                if selectedYear == nil {
                    Label("Все года", systemImage: "checkmark")
                } else {
                    Text("Все года")
                }
            }
            ForEach(availableYears, id: \.self) { y in
                Button {
                    selectedYear = y
                } label: {
                    if selectedYear == y {
                        Label("\(String(y))", systemImage: "checkmark")
                    } else {
                        Text("\(String(y))")
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 12, weight: .semibold))
                Text(selectedYear.map { String($0) } ?? "Все года")
                    .font(.system(size: 13, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundColor(selectedYear == nil ? Theme.accent : .white)
            .background(
                Capsule().fill(
                    selectedYear == nil
                        ? Theme.accent.opacity(0.12)
                        : Theme.accent
                )
            )
        }
        .buttonStyle(DSPressScaleStyle())
    }

    @ViewBuilder
    private var mineList: some View {
        if mine.isEmpty {
            EmptyStateView(
                icon: "rosette",
                title: "Пока нет наград",
                description: error ?? "Здесь появятся ваши грамоты и благодарности от руководства"
            )
        } else if filteredMine.isEmpty {
            EmptyStateView(
                icon: "calendar.badge.exclamationmark",
                title: "Нет наград за \(selectedYear.map { String($0) } ?? "")",
                description: "Попробуйте сменить год"
            )
        } else {
            VStack(spacing: 16) {
                ForEach(filteredMine.sorted { $0.grantedAt > $1.grantedAt }) { ua in
                    NavigationLink {
                        AwardDetailView(
                            award: ua.award,
                            grantedAt: ua.grantedAt,
                            comment: ua.comment,
                            granter: ua.grantedBy
                        )
                    } label: {
                        AwardCertificateCard(
                            award: ua.award,
                            grantedAt: ua.grantedAt,
                            comment: ua.comment,
                            granter: ua.grantedBy
                        )
                    }
                    .buttonStyle(DSPressScaleStyle())
                }
            }
        }
    }

    @ViewBuilder
    private var allList: some View {
        if catalog.isEmpty {
            EmptyStateView(
                icon: "rosette",
                title: "Каталог пуст",
                description: error ?? "Награды ещё не настроены"
            )
        } else {
            VStack(spacing: 14) {
                ForEach(catalog) { item in
                    let owned = ownedIds.contains(item.id)
                    NavigationLink {
                        AwardDetailView(
                            award: item,
                            grantedAt: nil,
                            comment: nil,
                            granter: nil
                        )
                    } label: {
                        AwardCatalogCard(award: item, owned: owned)
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
            async let mineResp: [UserAward] =
                APIClient.shared.get("users/\(userId)/awards")
            async let allResp: [AwardItem] =
                APIClient.shared.get("awards")

            let (m, a) = try await (mineResp, allResp)
            self.mine = m
            self.catalog = a
            self.error = nil
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}

// MARK: - "Мои" — торжественная карточка-грамота (gradient)

struct AwardCertificateCard: View {
    let award: AwardItem
    let grantedAt: String?
    let comment: String?
    let granter: AchievementGranter?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.22))
                    Circle().strokeBorder(Color.white.opacity(0.6), lineWidth: 1.5)
                    iconContent
                }
                .frame(width: 60, height: 60)

                VStack(alignment: .leading, spacing: 4) {
                    Text("ГРАМОТА")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(2.5)
                        .foregroundColor(.white.opacity(0.85))
                    Text(award.name)
                        .font(.dsH2)
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }

            if let desc = award.description, !desc.isEmpty {
                Text(desc)
                    .font(.dsBody)
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }

            if let comment = comment, !comment.isEmpty {
                Text("«\(comment)»")
                    .font(.system(size: 15).italic())
                    .foregroundColor(.white)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.white.opacity(0.18))
                    )
            }

            HStack(spacing: 10) {
                if let g = granter {
                    AvatarCircle(url: g.avatarUrl, name: g.fullName)
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("От")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.75))
                        Text(g.fullName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }
                Spacer()
                if let g = grantedAt,
                   let d = ISO8601DateFormatter().date(from: g) {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .font(.system(size: 10))
                        Text(relativeTime(from: d))
                            .font(.dsCaption)
                    }
                    .foregroundColor(.white.opacity(0.85))
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(awardCertificateGradient)
        .clipShape(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: Theme.purple.opacity(0.25), radius: 12, y: 6)
    }

    @ViewBuilder
    private var iconContent: some View {
        if let urlStr = award.iconUrl,
           let u = URL(string: ensureAbsolute(urlStr)) {
            AsyncImage(url: u) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFit().padding(10)
                default:
                    Image(systemName: "rosette")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(.white)
                }
            }
        } else {
            Image(systemName: "rosette")
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(.white)
        }
    }
}

// MARK: - "Все" — каталожная карточка

struct AwardCatalogCard: View {
    let award: AwardItem
    let owned: Bool

    private var tint: Color {
        parseAwardHex(award.color) ?? awardLevelColor(award.level ?? 1)
    }

    var body: some View {
        if owned {
            ownedCard
        } else {
            lockedCard
        }
    }

    private var ownedCard: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(Color.white.opacity(0.22))
                Circle().strokeBorder(Color.white.opacity(0.6), lineWidth: 1.5)
                iconContent(white: true)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(award.name)
                    .font(.dsH3)
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(award.description ?? "")
                    .font(.dsBody)
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            levelBadge(onGradient: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(awardCertificateGradient)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .shadow(color: Theme.purple.opacity(0.2), radius: 10, y: 4)
    }

    private var lockedCard: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(tint.opacity(0.12))
                Circle().strokeBorder(tint.opacity(0.3), lineWidth: 1.5)
                iconContent(white: false)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(award.name)
                    .font(.dsH3)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(award.description ?? "")
                    .font(.dsBody)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            levelBadge(onGradient: false)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(awardPastelGradient)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 0.5)
        )
        .opacity(0.85)
    }

    @ViewBuilder
    private func iconContent(white: Bool) -> some View {
        if let urlStr = award.iconUrl,
           let u = URL(string: ensureAbsolute(urlStr)) {
            AsyncImage(url: u) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFit().padding(10)
                default:
                    fallback(white: white)
                }
            }
        } else {
            fallback(white: white)
        }
    }

    private func fallback(white: Bool) -> some View {
        Image(systemName: "rosette")
            .font(.system(size: 22, weight: .bold))
            .foregroundColor(white ? .white : tint)
    }

    private func levelBadge(onGradient: Bool) -> some View {
        Text(awardLevelTitle(award.level ?? 1))
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(
                    onGradient
                        ? Color.white.opacity(0.25)
                        : awardLevelColor(award.level ?? 1)
                )
            )
    }
}

// MARK: - Detail

struct AwardDetailView: View {
    let award: AwardItem
    let grantedAt: String?
    let comment: String?
    let granter: AchievementGranter?

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                // Hero gradient certificate
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.22))
                        Circle()
                            .strokeBorder(Color.white.opacity(0.7), lineWidth: 2)
                        if let urlStr = award.iconUrl,
                           let u = URL(string: ensureAbsolute(urlStr)) {
                            AsyncImage(url: u) { phase in
                                switch phase {
                                case .success(let img):
                                    img.resizable().scaledToFit().padding(36)
                                default:
                                    Image(systemName: "rosette")
                                        .font(.system(size: 80, weight: .bold))
                                        .foregroundColor(.white)
                                }
                            }
                        } else {
                            Image(systemName: "rosette")
                                .font(.system(size: 80, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                    .frame(width: 240, height: 240)

                    Text("ГРАМОТА")
                        .font(.system(size: 12, weight: .bold))
                        .tracking(3.5)
                        .foregroundColor(.white.opacity(0.85))

                    Text(award.name)
                        .font(.dsDisplayLG)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)

                    Text(award.description ?? "")
                        .font(.dsBodyLG)
                        .foregroundColor(.white.opacity(0.92))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)

                    if let comment = comment, !comment.isEmpty {
                        Text("«\(comment)»")
                            .font(.system(size: 19).italic())
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .padding(16)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(Color.white.opacity(0.18))
                            )
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                    }

                    if let g = grantedAt,
                       let d = ISO8601DateFormatter().date(from: g) {
                        Text(longDate(d))
                            .font(.dsBodyLG.weight(.semibold))
                            .foregroundColor(.white.opacity(0.9))
                            .padding(.top, 4)
                    }

                    Text(awardLevelTitle(award.level ?? 1))
                        .font(.dsCaption.weight(.bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.25)))
                        .padding(.bottom, 8)
                }
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity)
                .background(awardCertificateGradient)
                .clipShape(RoundedRectangle(cornerRadius: Radius.xl2, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.xl2, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
                )
                .shadow(color: Theme.purple.opacity(0.3), radius: 18, y: 8)

                if let g = granter {
                    DSCard(radius: Radius.lg, padding: 14) {
                        HStack(spacing: 12) {
                            AvatarCircle(url: g.avatarUrl, name: g.fullName)
                                .frame(width: 40, height: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Награждение от")
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

                Text(award.code)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.bottom, 24)
            }
            .padding(16)
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("Награда")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func longDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM yyyy"
        return f.string(from: date)
    }
}

#Preview {
    NavigationStack { AwardsView() }
        .environmentObject(AuthStore())
}
