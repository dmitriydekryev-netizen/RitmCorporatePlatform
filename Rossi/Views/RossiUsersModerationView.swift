//
//  RossiUsersModerationView.swift — модерация пользователей сервиса Rossi (Staya).
//
//  Бэкенд (apps/api/src/modules/admin-users/admin-users.controller.ts):
//   • GET    /admin/users?search=&limit=&offset=     → { users: [...], total }
//   • GET    /admin/users/:id                        → user-профиль
//   • POST   /admin/users/:id/sanctions              — применить санкцию
//   • DELETE /admin/users/:id/sanctions/:sanctionId  — снять
//   • POST   /admin/users/:id/verify                 — верифицировать
//   • POST   /admin/users/:id/reset-password         — сбросить пароль
//
//  Permission: users.moderate.view (см. PERMISSIONS.USERS_MODERATE_VIEW).
//
//  Web-референс: apps/web/src/app/(app)/admin/rossi-users/page.tsx
//                apps/web/src/app/(app)/admin/rossi-users/[userId]/page.tsx
//

import SwiftUI

// MARK: - Models

struct RossiModUser: Codable, Identifiable, Hashable {
    let user_id: String
    let username: String?
    let name: String?
    let surname: String?
    let avatar_ref: String?
    let bio: String?
    let is_online: Bool?
    let last_seen: String?

    var id: String { user_id }

    var displayName: String {
        let combo = "\(name ?? "") \(surname ?? "")"
            .trimmingCharacters(in: .whitespaces)
        if !combo.isEmpty { return combo }
        return username ?? user_id
    }
}

private struct RossiModUsersEnvelope: Codable {
    let users: [RossiModUser]?
    let total: Int?
}

// MARK: - View

struct RossiUsersModerationView: View {
    @State private var users: [RossiModUser] = []
    @State private var totalCount: Int = 0
    @State private var search = ""
    @State private var loading = true
    @State private var error: String?
    @State private var notAvailable = false

    private let webURL = URL(string: "https://rossihelp.ru/admin/rossi-users")!

    var body: some View {
        ZStack {
            Theme.pageBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    DSPageTitle(text: "Пользователи Rossi",
                                subtitle: subtitleText)
                        .padding(.top, 4)

                    if loading && users.isEmpty {
                        ProgressView().tint(Theme.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    } else if notAvailable {
                        unavailableState
                    } else if let err = error, users.isEmpty {
                        EmptyStateView(icon: "exclamationmark.triangle",
                                       title: "Ошибка",
                                       description: err)
                    } else if users.isEmpty {
                        EmptyStateView(icon: "person.2",
                                       title: "Никого не найдено",
                                       description: search.isEmpty ? "Попробуйте обновить позже." : "По запросу ничего нет.")
                    } else {
                        DSSectionHeader("Список")
                        LazyVStack(spacing: 10) {
                            ForEach(users) { user in
                                NavigationLink {
                                    RossiUserModDetailView(userId: user.user_id, fallbackName: user.displayName)
                                } label: {
                                    RossiModUserCard(user: user)
                                }
                                .buttonStyle(DSPressScaleStyle())
                            }
                        }
                    }
                    Color.clear.frame(height: TabBarVisibility.reservedHeight)
                }
                .padding(16)
            }
        }
        .navigationTitle("Пользователи Rossi")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Поиск по имени / @username…")
        .onSubmit(of: .search) { Task { await load() } }
        .onChange(of: search) { newValue in
            if newValue.isEmpty { Task { await load() } }
        }
        .refreshable { await load() }
        .task { if users.isEmpty && !notAvailable { await load() } }
    }

    private var subtitleText: String? {
        if notAvailable { return nil }
        if loading && users.isEmpty { return nil }
        if users.isEmpty { return nil }
        // Бэк отдаёт реальный `total` поверх лимита 100 из выборки.
        let total = totalCount > 0 ? totalCount : users.count
        return "Всего: \(formatCount(total))"
    }

    private func formatCount(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = " "
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    @ViewBuilder
    private var unavailableState: some View {
        VStack(spacing: 14) {
            EmptyStateView(icon: "hammer",
                           title: "В разработке",
                           description: "Раздел модерации пользователей Rossi пока недоступен в приложении. Откройте его в веб-версии.")
            Link(destination: webURL) {
                HStack(spacing: 6) {
                    Image(systemName: "safari")
                    Text("Открыть в браузере")
                        .font(.dsBody.weight(.semibold))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Theme.accent.opacity(0.12))
                .foregroundColor(Theme.accent)
                .clipShape(Capsule())
            }
            .padding(.bottom, 24)
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        var query: [String: String] = ["limit": "100"]
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { query["search"] = q }
        do {
            let envelope: RossiModUsersEnvelope = try await APIClient.shared.get("admin/users", query: query)
            self.users = envelope.users ?? []
            self.totalCount = envelope.total ?? 0
            self.error = nil
            self.notAvailable = false
        } catch {
            if let apiErr = error as? APIError, case .http(let status, _) = apiErr, status == 404 {
                self.notAvailable = true
                self.users = []
                return
            }
            self.error = apiUserMessage(error)
        }
    }
}

// MARK: - Card

private struct RossiModUserCard: View {
    let user: RossiModUser

    var body: some View {
        DSCard(radius: Radius.lg, padding: 12) {
            HStack(spacing: 12) {
                ZStack {
                    if let ref = user.avatar_ref, !ref.isEmpty {
                        AuthedAsyncImage(
                            path: "admin/users/media/photos/\(ref)",
                            content: { img in img.resizable().scaledToFill() },
                            placeholder: { AvatarCircle(url: nil, name: user.displayName) }
                        )
                    } else {
                        AvatarCircle(url: nil, name: user.displayName)
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(Circle())
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(user.displayName)
                            .font(.dsBodyLG.weight(.semibold))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                        if user.is_online == true {
                            DSBadge(text: "online", color: Theme.success, filled: true)
                        }
                    }
                    if let username = user.username {
                        Text("@\(username)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Theme.textTertiary)
                            .lineLimit(1)
                    }
                    if let bio = user.bio, !bio.isEmpty {
                        Text(bio)
                            .font(.dsCaption)
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textTertiary)
            }
        }
    }
}

// MARK: - Detail — повторяет функционал web (apps/web/src/app/(app)/admin/rossi-users/[userId])

private struct UserDetailEnvelope: Decodable {
    let user: UserProfile
    let global_sanctions: [Sanction]?
    let admin_roles: [String]?

    struct UserProfile: Decodable {
        let user_id: String
        let username: String?
        let name: String?
        let surname: String?
        let avatar_ref: String?
        let bio: String?
        let is_online: Bool?
        let is_verified: Bool?
        let is_premium: Bool?
        let badge_type: String?
        let last_seen: String?
        let user_created_at: String?
    }

    struct Sanction: Decodable, Identifiable {
        let id: String
        let sanction_type: String?
        let reason: String?
        let created_at: String?
        let expires_at: String?
        let is_active: Bool?
    }
}

private let sanctionTypes: [(String, String)] = [
    ("warn",          "Предупреждение"),
    ("mute",          "Мьют"),
    ("shadow_ban",    "Shadow-ban"),
    ("ban",           "Бан"),
    ("permanent_ban", "Перманентный бан"),
]

private let sanctionPresets: [(String, String)] = [
    ("10m",       "10 минут"),
    ("1h",        "1 час"),
    ("24h",       "1 день"),
    ("7d",        "7 дней"),
    ("30d",       "30 дней"),
    ("permanent", "Навсегда"),
]

struct RossiUserModDetailView: View {
    let userId: String
    let fallbackName: String

    @State private var detail: UserDetailEnvelope?
    @State private var loading = true
    @State private var error: String?
    @State private var working = false
    @State private var info: String?

    @State private var showSanctionSheet = false
    @State private var sanctionType: String = "warn"
    @State private var sanctionPreset: String = "24h"
    @State private var sanctionReason: String = ""

    @State private var showResetPwdSheet = false
    @State private var newPassword: String = ""

    var body: some View {
        ZStack {
            Theme.pageBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if loading {
                        ProgressView().tint(Theme.accent)
                            .frame(maxWidth: .infinity).padding(.top, 60)
                    } else if let err = error {
                        EmptyStateView(icon: "exclamationmark.triangle",
                                       title: "Не удалось загрузить",
                                       description: err)
                    } else if let d = detail {
                        header(d.user)
                        if d.admin_roles?.isEmpty == false {
                            adminRolesCard(d.admin_roles ?? [])
                        }
                        actionsCard(canModerate: d.admin_roles?.isEmpty != false)
                        sanctionsCard(d.global_sanctions ?? [])
                        if let i = info {
                            DSCard(radius: Radius.md, padding: 10) {
                                Text(i).font(.dsCaption).foregroundColor(Theme.success)
                            }
                        }
                    }
                    Color.clear.frame(height: TabBarVisibility.reservedHeight)
                }
                .padding(16)
            }
        }
        .navigationTitle("Пользователь")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $showSanctionSheet) { sanctionSheet }
        .sheet(isPresented: $showResetPwdSheet) { resetPasswordSheet }
    }

    @ViewBuilder
    private func header(_ user: UserDetailEnvelope.UserProfile) -> some View {
        DSCard(radius: Radius.lg, padding: 14) {
            HStack(spacing: 14) {
                userAvatar(ref: user.avatar_ref,
                           name: "\(user.name ?? "") \(user.surname ?? "")".trimmingCharacters(in: .whitespaces),
                           size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("\(user.name ?? "") \(user.surname ?? "")".trimmingCharacters(in: .whitespaces).ifEmpty(or: fallbackName))
                            .font(.dsBodyLG.weight(.semibold))
                            .foregroundColor(Theme.textPrimary)
                        if user.is_verified == true {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundColor(Theme.accent)
                                .font(.system(size: 14))
                        }
                        if user.is_premium == true {
                            Image(systemName: "crown.fill")
                                .foregroundColor(Theme.warning)
                                .font(.system(size: 14))
                        }
                    }
                    if let u = user.username {
                        Text("@\(u)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Theme.textTertiary)
                    }
                    if user.is_online == true {
                        DSBadge(text: "online", color: Theme.success, filled: true)
                    } else if let ls = user.last_seen {
                        Text("Был(а) \(formatDate(ls))")
                            .font(.dsCaption)
                            .foregroundColor(Theme.textTertiary)
                    }
                    if let bio = user.bio, !bio.isEmpty {
                        Text(bio).font(.dsCaption).foregroundColor(Theme.textSecondary)
                            .lineLimit(3)
                    }
                }
                Spacer(minLength: 4)
            }
        }
    }

    @ViewBuilder
    private func adminRolesCard(_ roles: [String]) -> some View {
        DSCard(radius: Radius.md, padding: 10) {
            HStack(spacing: 8) {
                Image(systemName: "shield.fill").foregroundColor(Theme.warning)
                Text("Этот пользователь является администратором: \(roles.joined(separator: ", "))")
                    .font(.dsCaption)
                    .foregroundColor(Theme.textPrimary)
            }
        }
    }

    @ViewBuilder
    private func actionsCard(canModerate: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DSSectionHeader("Действия")
            VStack(spacing: 8) {
                Button {
                    Task { await verify() }
                } label: {
                    actionRow(icon: "checkmark.seal", title: "Верифицировать", color: Theme.accent)
                }.disabled(working)

                Button {
                    sanctionType = "warn"; sanctionPreset = "24h"; sanctionReason = ""
                    showSanctionSheet = true
                } label: {
                    actionRow(icon: "exclamationmark.triangle.fill", title: "Применить санкцию", color: Theme.warning)
                }.disabled(working || !canModerate)

                Button {
                    newPassword = ""
                    showResetPwdSheet = true
                } label: {
                    actionRow(icon: "key.fill", title: "Сбросить пароль", color: Theme.danger)
                }.disabled(working || !canModerate)
            }
            if !canModerate {
                Text("Действия недоступны для администраторов")
                    .font(.dsCaption)
                    .foregroundColor(Theme.textTertiary)
            }
        }
    }

    @ViewBuilder
    private func actionRow(icon: String, title: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundColor(color)
                .frame(width: 24)
            Text(title)
                .font(.dsBody.weight(.medium))
                .foregroundColor(Theme.textPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textTertiary)
        }
        .padding(12)
        .background(Theme.surfaceBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
    }

    @ViewBuilder
    private func sanctionsCard(_ sanctions: [UserDetailEnvelope.Sanction]) -> some View {
        let active = sanctions.filter { $0.is_active != false }
        let history = sanctions.filter { $0.is_active == false }
        VStack(alignment: .leading, spacing: 8) {
            DSSectionHeader("Активные санкции (\(active.count))")
            if active.isEmpty {
                DSCard(radius: Radius.md, padding: 12) {
                    Text("Нет активных").font(.dsCaption).foregroundColor(Theme.textTertiary)
                }
            } else {
                ForEach(active) { s in
                    DSCard(radius: Radius.md, padding: 10) {
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(sanctionTypeLabel(s.sanction_type))
                                    .font(.dsBody.weight(.semibold))
                                    .foregroundColor(Theme.textPrimary)
                                if let r = s.reason {
                                    Text(r).font(.dsCaption).foregroundColor(Theme.textSecondary)
                                }
                                if let exp = s.expires_at {
                                    Text("До: \(formatDate(exp))")
                                        .font(.dsCaption).foregroundColor(Theme.textTertiary)
                                }
                            }
                            Spacer()
                            Button {
                                Task { await revoke(s.id) }
                            } label: {
                                Text("Снять").font(.dsCaption.weight(.semibold))
                                    .foregroundColor(Theme.danger)
                            }
                            .disabled(working)
                        }
                    }
                }
            }
            if !history.isEmpty {
                DSSectionHeader("История (\(history.count))")
                    .padding(.top, 6)
                ForEach(history.prefix(10)) { s in
                    DSCard(radius: Radius.md, padding: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sanctionTypeLabel(s.sanction_type))
                                .font(.dsBody.weight(.semibold))
                                .foregroundColor(Theme.textSecondary)
                            if let r = s.reason {
                                Text(r).font(.dsCaption).foregroundColor(Theme.textTertiary)
                            }
                        }
                    }
                }
            }
        }
    }

    private var sanctionSheet: some View {
        NavigationStack {
            Form {
                Section("Тип") {
                    Picker("Санкция", selection: $sanctionType) {
                        ForEach(sanctionTypes, id: \.0) { t in Text(t.1).tag(t.0) }
                    }
                }
                Section("Длительность") {
                    Picker("Пресет", selection: $sanctionPreset) {
                        ForEach(sanctionPresets, id: \.0) { p in Text(p.1).tag(p.0) }
                    }
                }
                Section("Причина") {
                    TextField("Опишите, за что", text: $sanctionReason, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .navigationTitle("Новая санкция")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { showSanctionSheet = false }.disabled(working)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(working ? "…" : "Применить") {
                        Task { await applySanction() }
                    }
                    .disabled(working || sanctionReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var resetPasswordSheet: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Минимум 8 символов", text: $newPassword)
                } header: {
                    Text("Новый пароль")
                } footer: {
                    Text("Пользователь сможет войти с этим паролем. Сообщите ему лично.")
                }
            }
            .navigationTitle("Сброс пароля")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { showResetPwdSheet = false }.disabled(working)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(working ? "…" : "Сбросить") {
                        Task { await resetPassword() }
                    }
                    .disabled(working || newPassword.count < 8)
                }
            }
        }
    }

    @ViewBuilder
    private func userAvatar(ref: String?, name: String, size: CGFloat) -> some View {
        if let ref, !ref.isEmpty {
            AuthedAsyncImage(
                path: "admin/users/media/photos/\(ref)",
                content: { img in img.resizable().scaledToFill() },
                placeholder: { AvatarCircle(url: nil, name: name) }
            )
            .frame(width: size, height: size)
            .clipShape(Circle())
        } else {
            AvatarCircle(url: nil, name: name)
                .frame(width: size, height: size)
        }
    }

    private func sanctionTypeLabel(_ type: String?) -> String {
        guard let t = type else { return "—" }
        return sanctionTypes.first(where: { $0.0 == t })?.1 ?? t
    }

    private func formatDate(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) ?? Date()
        let out = DateFormatter()
        out.locale = Locale(identifier: "ru_RU")
        out.dateStyle = .medium
        out.timeStyle = .short
        return out.string(from: date)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            self.detail = try await APIClient.shared.get("admin/users/\(userId)")
            self.error = nil
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private struct ApplySanctionBody: Encodable {
        let sanction_type: String
        let reason: String
        let duration_preset: String?
    }

    private func applySanction() async {
        working = true; defer { working = false }
        let body = ApplySanctionBody(
            sanction_type: sanctionType,
            reason: sanctionReason.trimmingCharacters(in: .whitespacesAndNewlines),
            duration_preset: sanctionType == "permanent_ban" ? nil : sanctionPreset
        )
        do {
            _ = try await APIClient.shared.rawRequest(
                "POST", "admin/users/\(userId)/sanctions", body: body
            )
            info = "Санкция применена"
            showSanctionSheet = false
            await load()
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func revoke(_ sanctionId: String) async {
        working = true; defer { working = false }
        do {
            try await APIClient.shared.delete("admin/users/\(userId)/sanctions/\(sanctionId)")
            info = "Санкция снята"
            await load()
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func verify() async {
        working = true; defer { working = false }
        struct Empty: Encodable {}
        do {
            _ = try await APIClient.shared.rawRequest(
                "POST", "admin/users/\(userId)/verify", body: Empty()
            )
            info = "Верифицирован"
            await load()
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private struct ResetPwdBody: Encodable { let new_password: String }
    private func resetPassword() async {
        working = true; defer { working = false }
        do {
            _ = try await APIClient.shared.rawRequest(
                "POST", "admin/users/\(userId)/reset-password",
                body: ResetPwdBody(new_password: newPassword)
            )
            info = "Пароль сброшен. Сообщите его пользователю."
            showResetPwdSheet = false
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}

// MARK: - AnyCodable display helper (extension к существующему типу из BugsView.swift)

extension AnyCodable {
    /// Строковое представление JSON-значения для отображения в стаб-карточках.
    var displayString: String {
        switch value {
        case let s as String: return s.isEmpty ? "—" : s
        case let b as Bool: return b ? "да" : "нет"
        case let i as Int: return "\(i)"
        case let d as Double: return "\(d)"
        case let arr as [Any]: return arr.isEmpty ? "—" : "[\(arr.count) шт.]"
        case let dict as [String: Any]: return dict.isEmpty ? "—" : "{…}"
        case nil: return "—"
        default: return "\(value ?? "—")"
        }
    }
}

#Preview {
    NavigationStack { RossiUsersModerationView() }
        .environmentObject(AuthStore())
}
