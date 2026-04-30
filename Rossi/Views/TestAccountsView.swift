//
//  TestAccountsView.swift — список тестовых аккаунтов для QA.
//
//  Источник данных:
//   • GET    /test-accounts?platform&status&search
//   • POST   /test-accounts                       (создание, требует MANAGE)
//   • PATCH  /test-accounts/:id                   (обновление, MANAGE)
//   • DELETE /test-accounts/:id                   (удаление, MANAGE)
//
//  Сценарий QA: видит логин/пароль, копирует в буфер, опционально берёт под себя.
//  Полный lock-flow (take/release) оставлен веб-версии — здесь только read-only + быстрая отдача креденшалов.
//

import SwiftUI
import UIKit

// MARK: - Models

struct TestAccount: Codable, Identifiable {
    let id: String
    let label: String
    let login: String
    let password: String
    let platform: String?
    let role: String?
    let description: String?
    let notes: String?
    let isActive: Bool?
    let lockedBy: LockUser?
    let lockedUntil: String?
    let lockComment: String?
    let createdAt: String?

    struct LockUser: Codable {
        let id: String?
        let username: String?
        let firstName: String?
        let lastName: String?
        let avatarUrl: String?

        var displayName: String {
            let full = "\(firstName ?? "") \(lastName ?? "")".trimmingCharacters(in: .whitespaces)
            return full.isEmpty ? (username ?? "—") : full
        }
    }

    var platformLabel: String {
        switch platform {
        case "ios":     return "iOS"
        case "android": return "Android"
        case "web":     return "Web"
        case "backend": return "Backend"
        case "desktop": return "Desktop"
        case .some(let p) where !p.isEmpty: return p.capitalized
        default:        return "Прочее"
        }
    }

    var platformIcon: String {
        switch platform {
        case "ios":     return "apple.logo"
        case "android": return "smartphone"
        case "web":     return "globe"
        case "backend": return "server.rack"
        case "desktop": return "desktopcomputer"
        default:        return "questionmark.app.dashed"
        }
    }
}

private struct TestAccountListResponse: Codable {
    let data: [TestAccount]
}

// MARK: - List view

struct TestAccountsView: View {
    @EnvironmentObject var auth: AuthStore

    @State private var accounts: [TestAccount] = []
    @State private var loading = true
    @State private var lastError: String?
    @State private var revealedIds: Set<String> = []
    @State private var copiedToast: String?
    @State private var showCreateSheet = false
    @State private var deletingIds: Set<String> = []

    private var canManage: Bool {
        guard let perms = auth.currentUser?.permissions else { return false }
        return perms.contains("*")
            || perms.contains("testing.accounts.manage")
    }

    private var grouped: [(String, [TestAccount])] {
        let order = ["iOS", "Android", "Web", "Backend", "Desktop", "Прочее"]
        let dict = Dictionary(grouping: accounts, by: \.platformLabel)
        return order.compactMap { key in
            guard let v = dict[key], !v.isEmpty else { return nil }
            return (key, v.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending })
        }
        // Включаем все ключи, которых нет в order (на случай экзотических платформ)
        + dict.keys.filter { !order.contains($0) }.sorted().compactMap { key in
            dict[key].map { (key, $0) }
        }
    }

    var body: some View {
        Group {
            if loading && accounts.isEmpty {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(0..<5, id: \.self) { _ in skeletonRow }
                    }
                    .padding(16)
                }
                .background(Theme.pageBackground.ignoresSafeArea())
            } else if let err = lastError, accounts.isEmpty {
                EmptyStateView(
                    icon: "exclamationmark.triangle.fill",
                    title: "Не удалось загрузить",
                    description: err
                )
            } else if accounts.isEmpty {
                EmptyStateView(
                    icon: "person.crop.rectangle.stack",
                    title: "Нет тестовых аккаунтов",
                    description: canManage
                        ? "Создайте первый аккаунт, чтобы команда QA могла им пользоваться."
                        : "Аккаунты появятся после того, как админ их добавит."
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        DSPageTitle(text: "Тестовые аккаунты",
                                    subtitle: "Креденшалы для команды QA")

                        ForEach(grouped, id: \.0) { (group, items) in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Image(systemName: items.first?.platformIcon ?? "circle")
                                        .font(.dsCaption.weight(.semibold))
                                        .foregroundColor(Theme.accent)
                                    DSSectionHeader(group)
                                }

                                VStack(spacing: 10) {
                                    ForEach(items) { acc in
                                        TestAccountCard(
                                            account: acc,
                                            isRevealed: revealedIds.contains(acc.id),
                                            canManage: canManage,
                                            onToggleReveal: { toggleReveal(acc.id) },
                                            onCopyLogin: { copy(acc.login, label: "Логин") },
                                            onCopyPassword: { copy(acc.password, label: "Пароль") },
                                            onDelete: { Task { await delete(acc) } }
                                        )
                                    }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
                .background(Theme.pageBackground.ignoresSafeArea())
            }
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if canManage {
                    Button {
                        showCreateSheet = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(Theme.accent)
                    }
                }
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateTestAccountSheet { newAccount in
                accounts.insert(newAccount, at: 0)
            }
        }
        .refreshable { await reload() }
        .task { await reload() }
        .overlay(alignment: .top) {
            if let toast = copiedToast {
                Text(toast)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Theme.accent)
                    .clipShape(Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    // MARK: - Reload / Mutate

    private func reload() async {
        loading = true
        lastError = nil
        defer { loading = false }
        do {
            let resp: TestAccountListResponse = try await APIClient.shared.get("test-accounts")
            self.accounts = resp.data
        } catch {
            self.accounts = []
            self.lastError = apiUserMessage(error)
        }
    }

    private func delete(_ account: TestAccount) async {
        deletingIds.insert(account.id)
        defer { deletingIds.remove(account.id) }
        do {
            try await APIClient.shared.delete("test-accounts/\(account.id)")
            accounts.removeAll { $0.id == account.id }
            showToast("Аккаунт удалён")
        } catch {
            lastError = apiUserMessage(error)
        }
    }

    private func toggleReveal(_ id: String) {
        if revealedIds.contains(id) {
            revealedIds.remove(id)
        } else {
            revealedIds.insert(id)
        }
    }

    private func copy(_ value: String, label: String) {
        UIPasteboard.general.string = value
        showToast("\(label) скопирован")
    }

    private func showToast(_ msg: String) {
        withAnimation { copiedToast = msg }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation { copiedToast = nil }
        }
    }

    private var skeletonRow: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Theme.surfaceBackground)
            .frame(height: 120)
            .redacted(reason: .placeholder)
            .shimmering()
    }
}

// MARK: - Card

private struct TestAccountCard: View {
    let account: TestAccount
    let isRevealed: Bool
    let canManage: Bool
    let onToggleReveal: () -> Void
    let onCopyLogin: () -> Void
    let onCopyPassword: () -> Void
    let onDelete: () -> Void

    @State private var showDeleteConfirm = false

    var body: some View {
        DSCard(radius: Radius.xl, padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                // Header
                HStack(alignment: .top, spacing: 10) {
                    DSIconTile(systemImage: account.platformIcon, color: Theme.accent, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.label)
                            .font(.dsBody.weight(.semibold))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(2)
                        if let role = account.role, !role.isEmpty {
                            Text(role)
                                .font(.dsCaption)
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                    Spacer()
                    if account.isActive == false {
                        DSBadge(text: "OFF", color: Theme.danger, filled: true)
                    }
                    if canManage {
                        Menu {
                            Button(role: .destructive) {
                                showDeleteConfirm = true
                            } label: {
                                Label("Удалить", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.dsBody.weight(.semibold))
                                .foregroundColor(Theme.textTertiary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                        }
                    }
                }

                if let desc = account.description, !desc.isEmpty {
                    Text(desc)
                        .font(.dsBodySM)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(3)
                }

                // Login row
                credentialRow(
                    icon: "person.fill",
                    label: "Логин",
                    value: account.login,
                    isSecret: false,
                    onCopy: onCopyLogin
                )

                // Password row
                credentialRow(
                    icon: "lock.fill",
                    label: "Пароль",
                    value: isRevealed ? account.password : String(repeating: "•", count: max(8, account.password.count)),
                    isSecret: true,
                    onCopy: onCopyPassword,
                    trailing: AnyView(
                        Button(action: onToggleReveal) {
                            Image(systemName: isRevealed ? "eye.slash" : "eye")
                                .font(.dsCaption.weight(.semibold))
                                .foregroundColor(Theme.accent)
                        }
                        .buttonStyle(DSPressScaleStyle())
                    )
                )

                // Lock badge
                if let locker = account.lockedBy, locker.id != nil {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.circle.fill")
                            .foregroundColor(Theme.warning)
                        Text("Занят: \(locker.displayName)")
                            .font(.dsCaption)
                            .foregroundColor(Theme.warning)
                        if let comment = account.lockComment, !comment.isEmpty {
                            Text("· \(comment)")
                                .font(.dsCaption)
                                .foregroundColor(Theme.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Theme.warning.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                }
            }
        }
        .alert("Удалить аккаунт?", isPresented: $showDeleteConfirm) {
            Button("Отмена", role: .cancel) {}
            Button("Удалить", role: .destructive) { onDelete() }
        } message: {
            Text("«\(account.label)» будет удалён без возможности восстановления.")
        }
    }

    @ViewBuilder
    private func credentialRow(
        icon: String,
        label: String,
        value: String,
        isSecret: Bool,
        onCopy: @escaping () -> Void,
        trailing: AnyView? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.dsCaption)
                .foregroundColor(Theme.textSecondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1)
                    .foregroundColor(Theme.textTertiary)
                Text(value)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            Spacer()
            if let trailing { trailing }
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
                    .font(.dsCaption.weight(.semibold))
                    .foregroundColor(Theme.accent)
            }
            .buttonStyle(DSPressScaleStyle())
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Theme.pageBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
    }
}

// MARK: - Create sheet

struct CreateTestAccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onCreated: (TestAccount) -> Void

    @State private var label = ""
    @State private var login = ""
    @State private var password = ""
    @State private var platform = "web"
    @State private var role = ""
    @State private var description = ""
    @State private var working = false
    @State private var lastError: String?

    private static let platforms: [(String, String)] = [
        ("ios", "iOS"),
        ("android", "Android"),
        ("web", "Web"),
        ("backend", "Backend"),
        ("desktop", "Desktop"),
    ]

    private var isValid: Bool {
        !label.trimmingCharacters(in: .whitespaces).isEmpty
            && !login.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Основное") {
                    TextField("Название (например: QA iOS Demo)", text: $label)
                    Picker("Платформа", selection: $platform) {
                        ForEach(Self.platforms, id: \.0) { p in
                            Text(p.1).tag(p.0)
                        }
                    }
                    TextField("Роль (необязательно)", text: $role)
                }
                Section("Креденшалы") {
                    TextField("Логин / email", text: $login)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Пароль", text: $password)
                }
                Section("Описание") {
                    TextField("Назначение, окружение, особенности…", text: $description, axis: .vertical)
                        .lineLimit(2...6)
                }
                if let err = lastError {
                    Section {
                        Text(err)
                            .font(.footnote)
                            .foregroundColor(Theme.danger)
                    }
                }
            }
            .navigationTitle("Новый аккаунт")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                        .disabled(working)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Создать") {
                            Task { await create() }
                        }
                        .disabled(!isValid)
                    }
                }
            }
        }
    }

    private struct CreateBody: Encodable {
        let label: String
        let login: String
        let password: String
        let platform: String
        let role: String?
        let description: String?
    }

    private func create() async {
        working = true
        lastError = nil
        defer { working = false }
        let body = CreateBody(
            label: label.trimmingCharacters(in: .whitespaces),
            login: login.trimmingCharacters(in: .whitespaces),
            password: password,
            platform: platform,
            role: role.trimmingCharacters(in: .whitespaces).isEmpty ? nil : role,
            description: description.trimmingCharacters(in: .whitespaces).isEmpty ? nil : description
        )
        do {
            let created: TestAccount = try await APIClient.shared.post("test-accounts", body: body)
            onCreated(created)
            dismiss()
        } catch {
            lastError = apiUserMessage(error)
        }
    }
}

#Preview {
    NavigationStack { TestAccountsView() }
        .environmentObject(AuthStore())
}
