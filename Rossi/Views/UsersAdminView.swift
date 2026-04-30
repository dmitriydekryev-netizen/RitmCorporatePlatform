//
//  UsersAdminView.swift — нативная админка: список пользователей.
//
//  Endpoints (правильные пути из apps/api/src/modules/users/users.controller.ts):
//   • GET    /users?search=&status=&departmentId=&limit=  — список
//   • GET    /users/:id                                    — детали
//   • PATCH  /users/:id                                    — обновление профиля (DTO: profile fields)
//   • PUT    /users/:id/roles                              — { roleCodes: string[] }
//   • PUT    /users/:id/permissions                        — { permissions: string[] }
//   • POST   /users                                        — создать (DTO: email/username/firstName/lastName/...)
//   • POST   /users/:id/deactivate                         — деактивировать
//   • POST   /users/:id/restore                            — восстановить
//   • POST   /users/:id/reset-password                     — сбросить пароль
//   • POST   /users/:id/resend-invite                      — переотправить приглашение
//   • DELETE /users/:id                                    — soft-delete
//   • GET    /admin/roles или /roles                       — список ролей
//   • GET    /team/departments                             — список отделов
//   • GET    /permissions                                  — список permissions
//

import SwiftUI

// MARK: - Models

struct AdminUserItem: Codable, Identifiable {
    let id: String
    let email: String
    let username: String
    let status: String?
    let isActive: Bool?
    let lastLoginAt: String?
    let profile: AdminUserProfile?
    let roles: [AdminUserRole]?
    let permissions: [String]?

    enum CodingKeys: String, CodingKey {
        case id, email, username, status, isActive, lastLoginAt, profile, roles, permissions
    }
}

struct AdminUserProfile: Codable {
    let firstName: String?
    let lastName: String?
    let middleName: String?
    let avatarUrl: String?
    let position: String?
    let phone: String?
    let telegram: String?
    let birthDate: String?
    let departmentId: String?
}

struct AdminUserRole: Codable, Hashable {
    let id: String?
    let code: String?
    let name: String
}

struct AdminRole: Codable, Identifiable, Hashable {
    let id: String
    let code: String?
    let name: String
    let isSystem: Bool?
    let permissions: [String]?
}

struct AdminDepartment: Codable, Identifiable, Hashable {
    let id: String
    let name: String
}

private struct AdminUsersListEnvelope: Codable {
    let data: [AdminUserItem]?
}

private struct ResetPasswordResponse: Codable {
    let temporaryPassword: String?
}

// MARK: - View

struct UsersAdminView: View {
    @EnvironmentObject var auth: AuthStore

    @State private var users: [AdminUserItem] = []
    @State private var search = ""
    @State private var statusFilter: String = "all" // all | active | deactivated | deleted
    @State private var loading = true
    @State private var error: String?
    @State private var showCreate = false

    private var canCreate: Bool {
        let perms = auth.currentUser?.permissions ?? []
        return perms.contains("*") || perms.contains("user.create") || perms.contains(where: { $0.contains("admin") })
    }

    private var filtered: [AdminUserItem] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return users }
        return users.filter { u in
            let blob = "\(u.profile?.firstName ?? "") \(u.profile?.lastName ?? "") \(u.username) \(u.email) \(u.profile?.position ?? "")".lowercased()
            return blob.contains(q)
        }
    }

    var body: some View {
        ZStack {
            Theme.pageBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    DSPageTitle(text: "Пользователи",
                                subtitle: users.isEmpty ? nil : "Всего: \(users.count)")
                        .padding(.top, 4)

                    Picker("Статус", selection: $statusFilter) {
                        Text("Все").tag("all")
                        Text("Активные").tag("active")
                        Text("Откл.").tag("deactivated")
                        Text("Удалённые").tag("deleted")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: statusFilter) { _ in Task { await load() } }

                    if loading && users.isEmpty {
                        ProgressView().tint(Theme.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    } else if let err = error, users.isEmpty {
                        EmptyStateView(icon: "exclamationmark.triangle", title: "Ошибка", description: err)
                    } else if filtered.isEmpty {
                        EmptyStateView(icon: "person.2", title: "Никого не найдено", description: search.isEmpty ? "Создайте первого пользователя" : "Попробуйте другой запрос")
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(filtered) { user in
                                NavigationLink {
                                    UserAdminDetailView(userId: user.id) { Task { await load() } }
                                } label: {
                                    UserAdminCard(user: user)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Пользователи")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Поиск пользователей…")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if canCreate {
                    Button { showCreate = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                    }.tint(Theme.accent)
                }
            }
        }
        .refreshable { await load() }
        .task { if users.isEmpty { await load() } }
        .sheet(isPresented: $showCreate) {
            CreateAdminUserSheet { Task { await load() } }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        var query: [String: String] = ["limit": "100"]
        if statusFilter != "all" { query["status"] = statusFilter }
        // Try /admin/users first, fallback to /users
        if let list: [AdminUserItem] = try? await fetchUsers("admin/users", query: query) {
            self.users = list
            self.error = nil
            return
        }
        do {
            let list: [AdminUserItem] = try await fetchUsers("users", query: query)
            self.users = list
            self.error = nil
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func fetchUsers(_ path: String, query: [String: String]) async throws -> [AdminUserItem] {
        // Endpoint may return either bare array or {data:[...]}
        if let envelope: AdminUsersListEnvelope = try? await APIClient.shared.get(path, query: query),
           let arr = envelope.data {
            return arr
        }
        return try await APIClient.shared.get(path, query: query)
    }
}

// MARK: - Card

struct UserAdminCard: View {
    let user: AdminUserItem

    private var displayName: String {
        let combo = "\(user.profile?.firstName ?? "") \(user.profile?.lastName ?? "")"
            .trimmingCharacters(in: .whitespaces)
        return combo.isEmpty ? user.username : combo
    }

    private var statusKind: String { user.status ?? (user.isActive == false ? "deactivated" : "active") }

    var body: some View {
        DSCard(radius: Radius.lg, padding: 12) {
            HStack(spacing: 12) {
                AvatarCircle(url: user.profile?.avatarUrl, name: displayName)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(displayName)
                            .font(.dsBodyLG.weight(.semibold))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                        if statusKind != "active" {
                            DSBadge(text: statusLabel(statusKind), color: statusColor(statusKind), filled: true)
                        }
                    }
                    Text(user.email)
                        .font(.dsCaption)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                    if let roles = user.roles, !roles.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(Array(roles.prefix(3)), id: \.self) { role in
                                    DSBadge(text: role.name, color: Theme.accent, filled: false)
                                }
                                if roles.count > 3 {
                                    DSBadge(text: "+\(roles.count - 3)", color: Theme.textTertiary, filled: false)
                                }
                            }
                        }
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textTertiary)
            }
        }
    }

    private func statusLabel(_ s: String) -> String {
        switch s {
        case "active": return "Активен"
        case "deactivated": return "Откл."
        case "deleted": return "Удалён"
        default: return s
        }
    }

    private func statusColor(_ s: String) -> Color {
        switch s {
        case "active": return Theme.success
        case "deactivated": return Theme.warning
        case "deleted": return Theme.danger
        default: return Theme.textTertiary
        }
    }
}

// MARK: - Detail

struct UserAdminDetailView: View {
    let userId: String
    let onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var user: AdminUserItem?
    @State private var allRoles: [AdminRole] = []
    @State private var allDepartments: [AdminDepartment] = []
    @State private var selectedRoleCodes: Set<String> = []
    @State private var firstName: String = ""
    @State private var lastName: String = ""
    @State private var position: String = ""
    @State private var phone: String = ""
    @State private var telegram: String = ""
    @State private var departmentId: String = ""
    @State private var isActive: Bool = true
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?
    @State private var showResetPwAlert = false
    @State private var resetPwResult: String?
    @State private var showDeleteConfirm = false

    var body: some View {
        ZStack {
            Theme.pageBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let u = user {
                        headerCard(u)
                        profileSection
                        rolesSection
                        statusSection
                        if let err = error {
                            Text(err).font(.dsCaption).foregroundColor(Theme.danger)
                        }
                        DSPrimaryButton(action: { Task { await save() } }, loading: saving, enabled: !saving) {
                            Text("Сохранить")
                        }
                        .padding(.top, 4)
                    } else if loading {
                        ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.top, 60)
                    } else if let err = error {
                        EmptyStateView(icon: "exclamationmark.triangle", title: "Ошибка", description: err)
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Пользователь")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if user != nil {
                    Menu {
                        Button {
                            isActive.toggle()
                            Task { await toggleActive() }
                        } label: {
                            Label(isActive ? "Деактивировать" : "Активировать",
                                  systemImage: isActive ? "person.fill.xmark" : "person.fill.checkmark")
                        }
                        Button {
                            Task { await resetPassword() }
                        } label: {
                            Label("Сбросить пароль", systemImage: "key.fill")
                        }
                        Button {
                            Task { await resendInvite() }
                        } label: {
                            Label("Переотправить приглашение", systemImage: "envelope.fill")
                        }
                        Divider()
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .tint(Theme.accent)
                }
            }
        }
        .alert("Удалить пользователя?", isPresented: $showDeleteConfirm) {
            Button("Удалить", role: .destructive) { Task { await deleteUser() } }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Действие необратимо.")
        }
        .alert("Временный пароль", isPresented: .constant(resetPwResult != nil)) {
            Button("OK") { resetPwResult = nil }
        } message: {
            if let p = resetPwResult { Text(p) }
        }
        .task { await load() }
    }

    @ViewBuilder
    private func headerCard(_ u: AdminUserItem) -> some View {
        DSCard(radius: Radius.xl, padding: 16) {
            HStack(spacing: 14) {
                AvatarCircle(url: u.profile?.avatarUrl, name: displayName(u))
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName(u))
                        .font(.dsH2)
                        .foregroundColor(Theme.textPrimary)
                    Text(u.email)
                        .font(.dsCaption)
                        .foregroundColor(Theme.textSecondary)
                    Text("@\(u.username)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                    HStack(spacing: 6) {
                        DSBadge(text: isActive ? "Активен" : "Деактивирован",
                                color: isActive ? Theme.success : Theme.warning, filled: true)
                    }
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            DSSectionHeader("Профиль")
            DSCard(radius: Radius.lg, padding: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    field("Имя", text: $firstName)
                    field("Фамилия", text: $lastName)
                    field("Должность", text: $position)
                    field("Телефон", text: $phone)
                    field("Telegram", text: $telegram)
                    if !allDepartments.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Отдел").font(.dsCaption).foregroundColor(Theme.textSecondary)
                            Picker("Отдел", selection: $departmentId) {
                                Text("— Без отдела —").tag("")
                                ForEach(allDepartments) { d in
                                    Text(d.name).tag(d.id)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.dsCaption).foregroundColor(Theme.textSecondary)
            TextField(label, text: text)
                .padding(10)
                .background(Theme.pageBackground)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        }
    }

    @ViewBuilder
    private var rolesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            DSSectionHeader("Роли")
            DSCard(radius: Radius.lg, padding: 0) {
                VStack(spacing: 0) {
                    if allRoles.isEmpty {
                        Text("Нет ролей").font(.dsCaption).foregroundColor(Theme.textTertiary).padding(12)
                    } else {
                        ForEach(Array(allRoles.enumerated()), id: \.element.id) { idx, role in
                            let key = role.code ?? role.id
                            HStack(spacing: 10) {
                                Image(systemName: selectedRoleCodes.contains(key) ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(selectedRoleCodes.contains(key) ? Theme.accent : Theme.textTertiary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(role.name).font(.dsBodySM).foregroundColor(Theme.textPrimary)
                                    if let code = role.code {
                                        Text("@\(code)").font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.textTertiary)
                                    }
                                }
                                Spacer()
                                if role.isSystem == true {
                                    DSBadge(text: "system", color: Theme.indigo, filled: false)
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if selectedRoleCodes.contains(key) { selectedRoleCodes.remove(key) }
                                else { selectedRoleCodes.insert(key) }
                            }
                            if idx < allRoles.count - 1 {
                                Rectangle().fill(Theme.separator).frame(height: 0.5).padding(.leading, 38)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            DSSectionHeader("Статус")
            DSCard(radius: Radius.lg, padding: 12) {
                Toggle(isOn: $isActive) {
                    Text(isActive ? "Активен" : "Деактивирован")
                        .font(.dsBodySM)
                        .foregroundColor(Theme.textPrimary)
                }
                .tint(Theme.accent)
            }
        }
    }

    private func displayName(_ u: AdminUserItem) -> String {
        let combo = "\(u.profile?.firstName ?? "") \(u.profile?.lastName ?? "")"
            .trimmingCharacters(in: .whitespaces)
        return combo.isEmpty ? u.username : combo
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            // User
            if let u: AdminUserItem = try? await APIClient.shared.get("admin/users/\(userId)") {
                self.user = u
            } else {
                self.user = try await APIClient.shared.get("users/\(userId)")
            }
            // Roles
            if let r: [AdminRole] = try? await APIClient.shared.get("admin/roles") {
                self.allRoles = r
            } else if let r: [AdminRole] = try? await APIClient.shared.get("roles") {
                self.allRoles = r
            }
            // Departments
            if let d: [AdminDepartment] = try? await APIClient.shared.get("team/departments") {
                self.allDepartments = d
            }
            if let u = user {
                self.firstName = u.profile?.firstName ?? ""
                self.lastName = u.profile?.lastName ?? ""
                self.position = u.profile?.position ?? ""
                self.phone = u.profile?.phone ?? ""
                self.telegram = u.profile?.telegram ?? ""
                self.departmentId = u.profile?.departmentId ?? ""
                self.isActive = (u.status ?? "active") == "active" && (u.isActive ?? true)
                let codes = Set((u.roles ?? []).compactMap { $0.code ?? $0.id })
                self.selectedRoleCodes = codes
            }
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    struct UpdateProfileBody: Encodable {
        let firstName: String?
        let lastName: String?
        let position: String?
        let phone: String?
        let telegram: String?
        let departmentId: String?
    }
    struct UpdateRolesBody: Encodable {
        let roleCodes: [String]
    }

    private func save() async {
        saving = true
        defer { saving = false }
        // middleName / birthDate не поддерживаются бэком (UpdateUserDto, forbidNonWhitelisted=true).
        let profileBody = UpdateProfileBody(
            firstName: firstName.isEmpty ? nil : firstName,
            lastName: lastName.isEmpty ? nil : lastName,
            position: position.isEmpty ? nil : position,
            phone: phone.isEmpty ? nil : phone,
            telegram: telegram.isEmpty ? nil : telegram,
            departmentId: departmentId.isEmpty ? nil : departmentId
        )
        do {
            _ = try await APIClient.shared.rawRequest("PATCH", "users/\(userId)", body: profileBody)
            // Roles separately via PUT
            let rolesBody = UpdateRolesBody(roleCodes: Array(selectedRoleCodes))
            _ = try? await APIClient.shared.rawRequest("PUT", "users/\(userId)/roles", body: rolesBody)
            onChanged()
            self.error = nil
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func toggleActive() async {
        let path = isActive ? "users/\(userId)/restore" : "users/\(userId)/deactivate"
        do {
            _ = try await APIClient.shared.rawRequest("POST", path)
            onChanged()
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func resetPassword() async {
        do {
            let data = try await APIClient.shared.rawRequest("POST", "users/\(userId)/reset-password")
            if let resp = try? JSONDecoder().decode(ResetPasswordResponse.self, from: data),
               let pw = resp.temporaryPassword {
                resetPwResult = pw
            } else {
                resetPwResult = "Пароль сброшен"
            }
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func resendInvite() async {
        do {
            _ = try await APIClient.shared.rawRequest("POST", "users/\(userId)/resend-invite")
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func deleteUser() async {
        do {
            _ = try await APIClient.shared.rawRequest("DELETE", "users/\(userId)")
            onChanged()
            dismiss()
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}

// MARK: - Create Sheet

struct CreateAdminUserSheet: View {
    let onCreated: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var firstName = ""
    @State private var lastName = ""
    @State private var email = ""
    @State private var username = ""
    @State private var position = ""
    @State private var phone = ""
    @State private var telegram = ""
    @State private var departmentId = ""
    @State private var initialPassword = ""
    @State private var selectedRoleCodes: Set<String> = []

    @State private var allRoles: [AdminRole] = []
    @State private var allDepartments: [AdminDepartment] = []
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("ФИО") {
                    TextField("Имя", text: $firstName)
                    TextField("Фамилия", text: $lastName)
                }
                Section("Аккаунт") {
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Логин", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Начальный пароль (необязательно)", text: $initialPassword)
                }
                Section("Должность") {
                    TextField("Должность", text: $position)
                    if !allDepartments.isEmpty {
                        Picker("Отдел", selection: $departmentId) {
                            Text("— Без отдела —").tag("")
                            ForEach(allDepartments) { d in
                                Text(d.name).tag(d.id)
                            }
                        }
                    }
                }
                Section("Контакты") {
                    TextField("Телефон", text: $phone)
                        .keyboardType(.phonePad)
                    TextField("Telegram", text: $telegram)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Роли") {
                    if allRoles.isEmpty {
                        Text("Загрузка ролей…").font(.dsCaption).foregroundColor(Theme.textTertiary)
                    } else {
                        ForEach(allRoles) { role in
                            let key = role.code ?? role.id
                            Button {
                                if selectedRoleCodes.contains(key) {
                                    selectedRoleCodes.remove(key)
                                } else {
                                    selectedRoleCodes.insert(key)
                                }
                            } label: {
                                HStack {
                                    Image(systemName: selectedRoleCodes.contains(key) ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(selectedRoleCodes.contains(key) ? Theme.accent : Theme.textTertiary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(role.name).foregroundColor(Theme.textPrimary)
                                        if let c = role.code {
                                            Text("@\(c)").font(.system(size: 11, design: .monospaced))
                                                .foregroundColor(Theme.textTertiary)
                                        }
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if let err = error {
                    Section { Text(err).font(.dsCaption).foregroundColor(Theme.danger) }
                }
            }
            .navigationTitle("Новый сотрудник")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Создаю…" : "Создать") { Task { await create() } }
                        .disabled(saving || !valid)
                }
            }
            .task { await loadMeta() }
        }
    }

    private var valid: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty &&
        !username.trimmingCharacters(in: .whitespaces).isEmpty &&
        !firstName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !lastName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !selectedRoleCodes.isEmpty
    }

    struct CreateBody: Encodable {
        let email: String
        let username: String
        let firstName: String
        let lastName: String
        let position: String?
        let phone: String?
        let telegram: String?
        let departmentId: String?
        let initialPassword: String?
        let roleCodes: [String]
        // Поля middleName / birthDate / sendWelcomeEmail не поддерживаются бэком
        // (см. apps/api/src/modules/users/dto/create-user.dto.ts с forbidNonWhitelisted).
    }

    private func loadMeta() async {
        if let r: [AdminRole] = try? await APIClient.shared.get("admin/roles") {
            self.allRoles = r
        } else if let r: [AdminRole] = try? await APIClient.shared.get("roles") {
            self.allRoles = r
        }
        if let d: [AdminDepartment] = try? await APIClient.shared.get("team/departments") {
            self.allDepartments = d
        }
    }

    private func create() async {
        saving = true
        defer { saving = false }
        let body = CreateBody(
            email: email.trimmingCharacters(in: .whitespaces),
            username: username.trimmingCharacters(in: .whitespaces),
            firstName: firstName,
            lastName: lastName,
            position: position.isEmpty ? nil : position,
            phone: phone.isEmpty ? nil : phone,
            telegram: telegram.isEmpty ? nil : telegram,
            departmentId: departmentId.isEmpty ? nil : departmentId,
            initialPassword: initialPassword.isEmpty ? nil : initialPassword,
            roleCodes: Array(selectedRoleCodes)
        )
        do {
            _ = try await APIClient.shared.rawRequest("POST", "users", body: body)
            onCreated()
            dismiss()
        } catch {
            // fallback /admin/users
            do {
                _ = try await APIClient.shared.rawRequest("POST", "admin/users", body: body)
                onCreated()
                dismiss()
            } catch {
                self.error = apiUserMessage(error)
            }
        }
    }
}

#Preview {
    NavigationStack { UsersAdminView() }
        .environmentObject(AuthStore())
}
