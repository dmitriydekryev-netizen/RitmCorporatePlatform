//
//  RolesAdminView.swift — нативная админка: роли и права.
//
//  Endpoints:
//   • GET   /admin/roles         — список ролей (fallback /roles)
//   • GET   /admin/permissions   — список всех permissions (fallback /permissions)
//   • PATCH /admin/roles/:id     — обновить роль { name, permissions }
//

import SwiftUI

struct AdminPermission: Codable, Identifiable, Hashable {
    var id: String { code }
    let code: String
    let label: String?
    let group: String?
}

struct RolesAdminView: View {
    @State private var roles: [AdminRole] = []
    @State private var loading = true
    @State private var error: String?
    @State private var showCreateSheet = false

    var body: some View {
        ZStack {
            Theme.pageBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    DSPageTitle(text: "Роли и права",
                                subtitle: roles.isEmpty ? nil : "Ролей: \(roles.count)")
                        .padding(.top, 4)

                    if loading && roles.isEmpty {
                        ProgressView().tint(Theme.accent)
                            .frame(maxWidth: .infinity).padding(.top, 60)
                    } else if let err = error, roles.isEmpty {
                        EmptyStateView(icon: "exclamationmark.triangle", title: "Ошибка", description: err)
                    } else if roles.isEmpty {
                        EmptyStateView(icon: "shield", title: "Скоро будет", description: "Управление ролями ещё не подключено")
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(roles) { role in
                                NavigationLink {
                                    RoleAdminDetailView(role: role) { Task { await load() } }
                                } label: {
                                    RoleAdminCard(role: role)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Роли и права")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showCreateSheet = true } label: {
                    Image(systemName: "plus").font(.body.weight(.semibold))
                }
                .tint(Theme.accent)
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateRoleSheet { Task { await load() } }
        }
        .refreshable { await load() }
        .task { if roles.isEmpty { await load() } }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        if let r: [AdminRole] = try? await APIClient.shared.get("admin/roles") {
            self.roles = r; self.error = nil; return
        }
        do {
            let r: [AdminRole] = try await APIClient.shared.get("roles")
            self.roles = r
            self.error = nil
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}

struct RoleAdminCard: View {
    let role: AdminRole

    var body: some View {
        DSCard(radius: Radius.lg, padding: 12) {
            HStack(spacing: 12) {
                DSIconTile(systemImage: "shield.lefthalf.filled", color: Theme.indigo, size: 36)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(role.name)
                            .font(.dsBodyLG.weight(.semibold))
                            .foregroundColor(Theme.textPrimary)
                        if role.isSystem == true {
                            DSBadge(text: "system", color: Theme.indigo, filled: false)
                        }
                    }
                    Text("Прав: \(role.permissions?.count ?? 0)")
                        .font(.dsCaption)
                        .foregroundColor(Theme.textTertiary)
                    if let code = role.code {
                        Text("@\(code)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Theme.textTertiary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textTertiary)
            }
        }
    }
}

struct RoleAdminDetailView: View {
    let role: AdminRole
    let onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var allPerms: [AdminPermission] = []
    @State private var selected: Set<String> = []
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?

    private var grouped: [(String, [AdminPermission])] {
        let dict: [String: [AdminPermission]] = Dictionary(grouping: allPerms) { $0.group ?? "Другое" }
        var result: [(String, [AdminPermission])] = []
        for (key, value) in dict {
            let sorted = value.sorted { $0.code < $1.code }
            result.append((key, sorted))
        }
        result.sort { $0.0 < $1.0 }
        return result
    }

    var body: some View {
        ZStack {
            Theme.pageBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    DSCard(radius: Radius.xl, padding: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                DSIconTile(systemImage: "shield.lefthalf.filled", color: Theme.indigo, size: 36)
                                VStack(alignment: .leading) {
                                    Text(role.name).font(.dsH3).foregroundColor(Theme.textPrimary)
                                    if let code = role.code {
                                        Text("@\(code)").font(.system(size: 11, design: .monospaced)).foregroundColor(Theme.textTertiary)
                                    }
                                }
                                Spacer()
                                if role.isSystem == true {
                                    DSBadge(text: "system", color: Theme.indigo, filled: true)
                                }
                            }
                            TextField("Название", text: $name)
                                .padding(10)
                                .background(Theme.pageBackground)
                                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                        }
                    }

                    if loading {
                        ProgressView().tint(Theme.accent).frame(maxWidth: .infinity)
                    } else if allPerms.isEmpty {
                        EmptyStateView(icon: "lock", title: "Нет прав", description: "Список permissions недоступен")
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(grouped, id: \.0) { (group, perms) in
                                VStack(alignment: .leading, spacing: 6) {
                                    DSSectionHeader(group)
                                    DSCard(radius: Radius.lg, padding: 0) {
                                        VStack(spacing: 0) {
                                            ForEach(Array(perms.enumerated()), id: \.element.code) { idx, perm in
                                                HStack {
                                                    Image(systemName: selected.contains(perm.code) ? "checkmark.square.fill" : "square")
                                                        .foregroundColor(selected.contains(perm.code) ? Theme.accent : Theme.textTertiary)
                                                    VStack(alignment: .leading, spacing: 2) {
                                                        Text(perm.label ?? perm.code)
                                                            .font(.dsBodySM)
                                                            .foregroundColor(Theme.textPrimary)
                                                        Text(perm.code)
                                                            .font(.system(size: 10, design: .monospaced))
                                                            .foregroundColor(Theme.textTertiary)
                                                    }
                                                    Spacer()
                                                }
                                                .padding(.horizontal, 12).padding(.vertical, 9)
                                                .contentShape(Rectangle())
                                                .onTapGesture {
                                                    if selected.contains(perm.code) { selected.remove(perm.code) }
                                                    else { selected.insert(perm.code) }
                                                }
                                                if idx < perms.count - 1 {
                                                    Rectangle().fill(Theme.separator).frame(height: 0.5).padding(.leading, 36)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if let err = error {
                        Text(err).font(.dsCaption).foregroundColor(Theme.danger)
                    }

                    DSPrimaryButton(action: { Task { await save() } }, loading: saving, enabled: !saving) {
                        Text("Сохранить")
                    }
                    .padding(.top, 4)
                }
                .padding(16)
            }
        }
        .navigationTitle("Роль")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        name = role.name
        selected = Set(role.permissions ?? [])
        if let p: [AdminPermission] = try? await APIClient.shared.get("admin/permissions") {
            self.allPerms = p; return
        }
        if let p: [AdminPermission] = try? await APIClient.shared.get("permissions") {
            self.allPerms = p
        }
    }

    struct UpdateRoleBody: Encodable {
        let name: String
        let permissions: [String]
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let body = UpdateRoleBody(name: name, permissions: Array(selected))
        do {
            _ = try await APIClient.shared.rawRequest("PATCH", "admin/roles/\(role.id)", body: body)
            onChanged()
        } catch {
            do {
                _ = try await APIClient.shared.rawRequest("PATCH", "roles/\(role.id)", body: body)
                onChanged()
            } catch {
                self.error = apiUserMessage(error)
            }
        }
    }
}

// MARK: - CreateRoleSheet

struct CreateRoleSheet: View {
    let onCreated: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var code: String = ""
    @State private var name: String = ""
    @State private var description: String = ""
    @State private var saving = false
    @State private var error: String?

    private var canCreate: Bool {
        !code.trimmingCharacters(in: .whitespaces).isEmpty
        && !name.trimmingCharacters(in: .whitespaces).isEmpty
        && code.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Код (snake_case)", text: $code)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                } header: {
                    Text("Код роли")
                } footer: {
                    Text("Только латиница, цифры и подчёркивания. Начинаться с буквы. Пример: ops_lead")
                }

                Section("Название") {
                    TextField("Например: Менеджер операций", text: $name)
                }

                Section("Описание") {
                    TextField("Необязательно", text: $description, axis: .vertical)
                        .lineLimit(2...5)
                }

                if let err = error {
                    Section {
                        Text(err).font(.dsCaption).foregroundColor(Theme.danger)
                    }
                }
            }
            .navigationTitle("Новая роль")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "…" : "Создать") {
                        Task { await create() }
                    }
                    .disabled(!canCreate || saving)
                }
            }
        }
    }

    private struct CreateBody: Encodable {
        let code: String
        let name: String
        let description: String?
    }

    private func create() async {
        saving = true
        defer { saving = false }
        let body = CreateBody(
            code: code.trimmingCharacters(in: .whitespaces),
            name: name.trimmingCharacters(in: .whitespaces),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        )
        do {
            // /admin/roles → fallback /roles, как в загрузке списка
            do {
                _ = try await APIClient.shared.rawRequest("POST", "admin/roles", body: body)
            } catch {
                _ = try await APIClient.shared.rawRequest("POST", "roles", body: body)
            }
            onCreated()
            dismiss()
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

#Preview {
    NavigationStack { RolesAdminView() }
}
