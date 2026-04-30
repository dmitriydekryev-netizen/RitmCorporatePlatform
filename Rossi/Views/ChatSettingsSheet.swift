//
//  ChatSettingsSheet.swift — настройки чата (название, участники, pin, выход).
//
//  Endpoints (см. apps/api/src/modules/chats/chats.controller.ts):
//   • PATCH  /chats/:id                       — изменить title
//   • PATCH  /chats/:id/pin-chat              — pin/unpin
//   • POST   /chats/:id/members               — добавить участника
//   • DELETE /chats/:id/members/:userId       — удалить участника (или себя)
//   • POST   /chats/:id/leave                 — покинуть чат (alias DELETE members/me)
//

import SwiftUI

struct ChatSettingsSheet: View {
    let chat: Chat
    let currentUserId: String?
    let onUpdated: (Chat) -> Void
    let onLeft: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var auth: AuthStore

    @State private var titleDraft: String
    @State private var saving = false
    @State private var error: String?
    @State private var pinned: Bool
    @State private var members: [ChatMember]
    @State private var showPickMembers = false
    @State private var confirmLeave = false

    init(chat: Chat,
         currentUserId: String?,
         onUpdated: @escaping (Chat) -> Void,
         onLeft: @escaping () -> Void) {
        self.chat = chat
        self.currentUserId = currentUserId
        self.onUpdated = onUpdated
        self.onLeft = onLeft
        _titleDraft = State(initialValue: chat.title ?? "")
        _pinned = State(initialValue: chat.pinned ?? false)
        _members = State(initialValue: chat.members ?? [])
    }

    private var isGroup: Bool { chat.kind == "group" }
    private var canEditTitle: Bool { isGroup }

    /// Существующие участники и текущий — отдельно. У админа показываем бейдж.
    private var sortedMembers: [ChatMember] {
        members.sorted { lhs, rhs in
            // admin наверх, потом по имени
            let la = (lhs.role ?? "") == "admin" ? 0 : 1
            let ra = (rhs.role ?? "") == "admin" ? 0 : 1
            if la != ra { return la < ra }
            return displayName(for: lhs).localizedCaseInsensitiveCompare(displayName(for: rhs)) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if isGroup {
                    Section("Название") {
                        TextField("Название группы", text: $titleDraft)
                            .font(.dsBody)
                        if (titleDraft.trimmingCharacters(in: .whitespaces) != (chat.title ?? "")) {
                            Button {
                                Task { await renameChat() }
                            } label: {
                                if saving {
                                    ProgressView()
                                } else {
                                    Label("Сохранить", systemImage: "checkmark.circle.fill")
                                }
                            }
                            .disabled(saving || titleDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }

                Section("Уведомления") {
                    Toggle(isOn: $pinned) {
                        Label("Закрепить", systemImage: "pin.fill")
                    }
                    .onChange(of: pinned) { newValue in
                        Task { await togglePin(newValue) }
                    }
                }

                Section(header: HStack {
                    Text("Участники (\(members.count))")
                    Spacer()
                    if isGroup {
                        Button {
                            showPickMembers = true
                        } label: {
                            Label("Добавить", systemImage: "person.badge.plus")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(Theme.accent)
                                .textCase(nil)
                        }
                    }
                }) {
                    ForEach(sortedMembers) { member in
                        memberRow(member)
                    }
                    .onDelete(perform: isGroup ? { indexSet in
                        Task { await deleteMembers(at: indexSet) }
                    } : nil)
                }

                if let err = error {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(Theme.danger)
                            Text(err).font(.caption).foregroundColor(Theme.danger)
                        }
                    }
                }

                if isGroup {
                    Section {
                        Button(role: .destructive) {
                            confirmLeave = true
                        } label: {
                            Label("Покинуть чат", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                }
            }
            .navigationTitle("Настройки чата")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                        .tint(Theme.accent)
                }
            }
            .sheet(isPresented: $showPickMembers) {
                PickMembersSheet(
                    excludingIds: Set(members.map(\.id)),
                    onPicked: { ids in
                        Task { await addMembers(ids) }
                    }
                )
                .environmentObject(auth)
            }
            .confirmationDialog("Покинуть чат?",
                                isPresented: $confirmLeave,
                                titleVisibility: .visible) {
                Button("Покинуть", role: .destructive) {
                    Task { await leaveChat() }
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Вы перестанете получать сообщения из этого чата.")
            }
        }
    }

    @ViewBuilder
    private func memberRow(_ member: ChatMember) -> some View {
        HStack(spacing: 12) {
            AvatarCircle(url: member.avatarUrl, name: displayName(for: member))
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(displayName(for: member))
                        .font(.body.weight(.medium))
                        .foregroundColor(Theme.textPrimary)
                    if member.id == currentUserId {
                        Text("(Вы)")
                            .font(.caption)
                            .foregroundColor(Theme.textTertiary)
                    }
                }
                if let u = member.username, !u.isEmpty {
                    Text("@" + u)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            if (member.role ?? "") == "admin" {
                Text("admin")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.accent.opacity(0.12)))
                    .foregroundColor(Theme.accent)
            } else {
                Text("участник")
                    .font(.caption2)
                    .foregroundColor(Theme.textTertiary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Actions

    private func renameChat() async {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        saving = true
        defer { saving = false }
        struct Body: Encodable { let title: String }
        do {
            let updated: Chat = try await APIClient.shared.patch(
                "chats/\(chat.id)",
                body: Body(title: trimmed)
            )
            onUpdated(updated)
            error = nil
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func togglePin(_ newValue: Bool) async {
        struct Body: Encodable { let pinned: Bool }
        do {
            _ = try await APIClient.shared.rawRequest(
                "PATCH", "chats/\(chat.id)/pin-chat", body: Body(pinned: newValue)
            )
        } catch {
            // откат UI на ошибке
            pinned = !newValue
            self.error = apiUserMessage(error)
        }
    }

    private func addMembers(_ ids: [String]) async {
        struct Body: Encodable { let memberIds: [String] }
        do {
            _ = try await APIClient.shared.rawRequest(
                "POST", "chats/\(chat.id)/members", body: Body(memberIds: ids)
            )
            // Перезагружаем chat → onUpdated
            let fresh: Chat = try await APIClient.shared.get("chats/\(chat.id)")
            members = fresh.members ?? members
            onUpdated(fresh)
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func deleteMembers(at offsets: IndexSet) async {
        let snapshot = sortedMembers
        let toRemove = offsets.compactMap { snapshot.indices.contains($0) ? snapshot[$0] : nil }
            .filter { $0.id != currentUserId }
        for m in toRemove {
            do {
                try await APIClient.shared.delete("chats/\(chat.id)/members/\(m.id)")
                members.removeAll { $0.id == m.id }
            } catch {
                self.error = apiUserMessage(error)
            }
        }
    }

    private func leaveChat() async {
        // Сначала пробуем POST /leave (актуальный endpoint), потом fallback на DELETE members/me.
        do {
            _ = try await APIClient.shared.rawRequest("POST", "chats/\(chat.id)/leave")
            onLeft()
            dismiss()
            return
        } catch APIError.http(let status, _) where status == 404 {
            // try alternative
        } catch {
            self.error = apiUserMessage(error)
            return
        }
        do {
            try await APIClient.shared.delete("chats/\(chat.id)/members/me")
            onLeft()
            dismiss()
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}

// MARK: - PickMembersSheet (выбор сотрудников для добавления)

struct PickMembersSheet: View {
    let excludingIds: Set<String>
    let onPicked: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var auth: AuthStore

    @State private var members: [TeamMember] = []
    @State private var loading = true
    @State private var search = ""
    @State private var selected: Set<String> = []
    @State private var error: String?

    private var filtered: [TeamMember] {
        let q = search.lowercased().trimmingCharacters(in: .whitespaces)
        let mine = auth.currentUser?.id
        return members
            .filter { $0.id != mine && !excludingIds.contains($0.id) }
            .filter {
                guard !q.isEmpty else { return true }
                let s = "\($0.firstName ?? "") \($0.lastName ?? "") \($0.username) \($0.position ?? "")".lowercased()
                return s.contains(q)
            }
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading && members.isEmpty {
                    ProgressView().tint(Theme.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filtered.isEmpty {
                    EmptyStateView(
                        icon: "person.2.slash",
                        title: "Никого не найдено",
                        description: error ?? "Все, кого можно добавить, уже в чате"
                    )
                } else {
                    List(filtered) { member in
                        Button { toggle(member.id) } label: {
                            HStack(spacing: 12) {
                                AvatarCircle(
                                    url: member.avatarUrl,
                                    name: "\(member.firstName ?? "") \(member.lastName ?? "")"
                                )
                                .frame(width: 36, height: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(member.firstName ?? "") \(member.lastName ?? "")"
                                            .trimmingCharacters(in: .whitespaces))
                                        .font(.body.weight(.medium))
                                        .foregroundColor(Theme.textPrimary)
                                    if let pos = member.position, !pos.isEmpty {
                                        Text(pos).font(.caption).foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: selected.contains(member.id)
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(selected.contains(member.id)
                                                     ? Theme.accent : Theme.textTertiary)
                                    .font(.title3)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Добавить участника")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Поиск")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onPicked(Array(selected))
                        dismiss()
                    } label: {
                        Text("Добавить (\(selected.count))")
                            .font(.body.weight(.semibold))
                            .foregroundColor(selected.isEmpty ? Theme.textTertiary : Theme.accent)
                    }
                    .disabled(selected.isEmpty)
                }
            }
            .task { await load() }
        }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let resp: TeamListResponse = try await APIClient.shared.get(
                "team", query: ["limit": "200"]
            )
            self.members = resp.data
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}
