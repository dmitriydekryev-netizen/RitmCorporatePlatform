//
//  TeamMemberProfileView.swift — публичный профиль сотрудника.
//  GET /profiles/:userId — расширенные данные (bio, phone, telegram, dept, skills…)
//
//  Дизайн: DS-примитивы из Theme.swift, зеркальный с web (Next.js + Tailwind).
//

import SwiftUI

struct PublicProfile: Codable {
    let userId: String
    let username: String?
    let email: String?
    let firstName: String?
    let lastName: String?
    let middleName: String?
    let position: String?
    let bio: String?
    let phone: String?
    let telegram: String?
    let avatarUrl: String?
    let birthDate: String?
    let department: PublicDepartment?
    let interests: [String]?
    let skills: [String]?
    let joinedAt: String?

    var displayName: String {
        let full = "\(firstName ?? "") \(lastName ?? "")"
            .trimmingCharacters(in: .whitespaces)
        if !full.isEmpty { return full }
        return username ?? "Сотрудник"
    }
}

struct PublicDepartment: Codable {
    let id: String
    let code: String?
    let name: String
}

struct TeamMemberProfileView: View {
    let member: TeamMember
    @EnvironmentObject var auth: AuthStore
    @State private var profile: PublicProfile?
    @State private var loading = true
    @State private var error: String?

    /// «Написать сообщение» — состояние перехода в чат.
    @State private var openingChat = false
    @State private var openedChat: Chat?
    @State private var chatNavigationActive = false

    private var displayName: String {
        profile?.displayName
            ?? "\(member.firstName ?? "") \(member.lastName ?? "")"
                .trimmingCharacters(in: .whitespaces)
                .ifEmpty(or: member.username)
    }

    /// Скрываем кнопку «Написать», если пользователь смотрит свой собственный профиль.
    private var canMessage: Bool {
        guard let myId = auth.currentUser?.id else { return true }
        return member.id != myId
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header

                if canMessage {
                    writeMessageButton
                }

                if loading && profile == nil {
                    ProgressView().tint(Theme.accent).padding(.vertical, 16)
                }

                if let p = profile {
                    contactCard(profile: p)
                    if let bio = p.bio, !bio.isEmpty {
                        bioCard(bio)
                    }
                    if let skills = p.skills, !skills.isEmpty {
                        chipsCard(title: "Навыки", items: skills, color: Theme.accent)
                    }
                    if let interests = p.interests, !interests.isEmpty {
                        chipsCard(title: "Интересы", items: interests, color: Theme.purple)
                    }
                }

                if let err = error {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(Theme.danger)
                        Text(err).font(.footnote).foregroundColor(Theme.danger)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.danger.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                }
            }
            .padding(16)
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .background(
            // Скрытый NavigationLink — программный переход в ChatDetailView
            // после создания/получения direct-чата.
            NavigationLink(
                isActive: $chatNavigationActive,
                destination: {
                    if let c = openedChat {
                        ChatDetailView(chatId: c.id, initialChat: c)
                            .environmentObject(auth)
                    } else {
                        EmptyView()
                    }
                },
                label: { EmptyView() }
            )
            .hidden()
        )
        .task { await load() }
    }

    /// Кнопка «Написать сообщение» — создаёт/находит direct-чат и
    /// переходит на ChatDetailView. Сервер (POST /chats type=direct)
    /// идемпотентен: если чат уже есть, вернёт существующий.
    /// (см. apps/api/src/modules/chats/chats.service.ts create()).
    @ViewBuilder
    private var writeMessageButton: some View {
        DSPrimaryButton(
            action: { Task { await openOrCreateDirectChat() } },
            loading: openingChat,
            enabled: !openingChat
        ) {
            HStack(spacing: 8) {
                Image(systemName: "message.fill")
                Text("Написать сообщение")
            }
        }
        .padding(.horizontal, 4)
    }

    private func openOrCreateDirectChat() async {
        guard !openingChat else { return }
        openingChat = true
        defer { openingChat = false }

        struct Body: Encodable {
            let type: String
            let memberIds: [String]
        }
        do {
            let chat: Chat = try await APIClient.shared.post(
                "chats",
                body: Body(type: "direct", memberIds: [member.id])
            )
            self.openedChat = chat
            self.chatNavigationActive = true
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            AvatarCircle(
                url: profile?.avatarUrl ?? member.avatarUrl,
                name: displayName
            )
            .frame(width: 100, height: 100)
            .overlay(
                Circle()
                    .strokeBorder(Color.white.opacity(0.6), lineWidth: 2)
            )
            .shadow(color: .black.opacity(0.08), radius: 12, y: 6)

            Text(displayName)
                .font(.system(size: 26, weight: .bold))
                .tracking(-0.6)
                .foregroundColor(Theme.textPrimary)
                .multilineTextAlignment(.center)

            if let pos = profile?.position ?? member.position, !pos.isEmpty {
                Text(pos)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            if let dep = profile?.department?.name ?? member.department?.name, !dep.isEmpty {
                Text(dep)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func contactCard(profile p: PublicProfile) -> some View {
        DSCard(radius: Radius.xl, padding: 0) {
            VStack(spacing: 0) {
                let rows: [(String, String, String, Color)] = contactRows(profile: p)
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

    private func contactRows(profile p: PublicProfile) -> [(String, String, String, Color)] {
        var rows: [(String, String, String, Color)] = []
        if let u = p.username, !u.isEmpty {
            rows.append(("at", "Логин", "@\(u)", Theme.accent))
        }
        if let email = p.email, !email.isEmpty {
            rows.append(("envelope.fill", "Email", email, Theme.info))
        }
        if let phone = p.phone, !phone.isEmpty {
            rows.append(("phone.fill", "Телефон", phone, Theme.success))
        }
        if let tg = p.telegram, !tg.isEmpty {
            rows.append(("paperplane.fill", "Telegram", tg, Theme.indigo))
        }
        if let bd = p.birthDate, let parsed = ISO8601DateFormatter().date(from: bd) {
            rows.append(("gift.fill", "День рождения", formatBirthday(parsed), Theme.pink))
        }
        return rows
    }

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

    private func formatBirthday(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM"
        return f.string(from: date)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let p: PublicProfile = try await APIClient.shared.get("profiles/\(member.id)")
            self.profile = p
            self.error = nil
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}

/// Простой flow layout для тегов (заменяет недоступный на iOS 16 SwiftUI Layout API).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0
        for sv in subviews {
            let sz = sv.sizeThatFits(.unspecified)
            if x + sz.width > width {
                x = 0; y += lineH + spacing; lineH = 0
            }
            x += sz.width + spacing
            lineH = max(lineH, sz.height)
        }
        return CGSize(width: width, height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for sv in subviews {
            let sz = sv.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX {
                x = bounds.minX; y += lineH + spacing; lineH = 0
            }
            sv.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            lineH = max(lineH, sz.height)
        }
    }
}
