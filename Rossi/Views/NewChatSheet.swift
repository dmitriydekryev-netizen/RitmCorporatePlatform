//
//  NewChatSheet.swift — создание нового чата (private или group).
//
//  POST /chats body { kind: "private"|"group", memberIds: [uuid], title?: string }
//  Дизайн: DS-примитивы (DSCard, DSPageTitle, DSPressScaleStyle).
//

import SwiftUI

struct NewChatSheet: View {
    let onCreated: (Chat) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var auth: AuthStore

    @State private var members: [TeamMember] = []
    @State private var loading = true
    @State private var search = ""
    @State private var selected: Set<String> = []
    @State private var groupTitle: String = ""
    @State private var creating = false
    @State private var error: String?

    private var filtered: [TeamMember] {
        let q = search.lowercased().trimmingCharacters(in: .whitespaces)
        let mine = auth.currentUser?.id
        return members
            .filter { $0.id != mine }
            .filter {
                guard !q.isEmpty else { return true }
                let s = "\($0.firstName ?? "") \($0.lastName ?? "") \($0.username) \($0.position ?? "")".lowercased()
                return s.contains(q)
            }
    }

    private var isGroup: Bool { selected.count >= 2 }
    private var canCreate: Bool {
        !selected.isEmpty && (!isGroup || !groupTitle.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Selected chips
                    if !selected.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(selected), id: \.self) { id in
                                    if let m = members.first(where: { $0.id == id }) {
                                        selectedChip(m)
                                    }
                                }
                            }
                        }
                    }

                    // Group title
                    if isGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            DSSectionHeader("Название группы")
                            DSCard(radius: Radius.md, padding: 0) {
                                HStack(spacing: 10) {
                                    DSIconTile(systemImage: "person.3.fill", color: Theme.indigo, size: 32)
                                    TextField("Например: Команда iOS", text: $groupTitle)
                                        .font(.dsBody)
                                }
                                .padding(12)
                            }
                        }
                    }

                    // Список сотрудников
                    DSSectionHeader(isGroup ? "Участники (\(selected.count))" : "Кому написать")

                    if loading && members.isEmpty {
                        ProgressView().tint(Theme.accent)
                            .frame(maxWidth: .infinity, minHeight: 200)
                    } else if filtered.isEmpty {
                        EmptyStateView(
                            icon: "person.2.slash",
                            title: "Никого не найдено",
                            description: "Попробуйте уточнить запрос"
                        )
                    } else {
                        VStack(spacing: 8) {
                            ForEach(filtered) { member in
                                Button { toggle(member.id) } label: {
                                    memberRow(member)
                                }
                                .buttonStyle(DSPressScaleStyle())
                            }
                        }
                    }

                    if let err = error {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(Theme.danger)
                            Text(err).font(.dsCaption).foregroundColor(Theme.danger)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.md)
                                .fill(Theme.danger.opacity(0.10))
                        )
                    }

                    Spacer(minLength: 12)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Theme.pageBackground.ignoresSafeArea())
            .navigationTitle(isGroup ? "Новая группа" : "Новый чат")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Поиск сотрудников")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                        .foregroundColor(Theme.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await create() }
                    } label: {
                        if creating {
                            ProgressView().tint(Theme.accent)
                        } else {
                            Text("Создать")
                                .font(.dsBody.weight(.semibold))
                                .foregroundColor(canCreate ? Theme.accent : Theme.textTertiary)
                        }
                    }
                    .disabled(!canCreate || creating)
                }
            }
            .task { await loadMembers() }
        }
    }

    @ViewBuilder
    private func memberRow(_ member: TeamMember) -> some View {
        let isSelected = selected.contains(member.id)
        DSCard(radius: Radius.md, padding: 12) {
            HStack(spacing: 12) {
                AvatarCircle(url: member.avatarUrl,
                             name: "\(member.firstName ?? "") \(member.lastName ?? "")")
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(member.firstName ?? "") \(member.lastName ?? "")"
                            .trimmingCharacters(in: .whitespaces))
                        .font(.dsBody.weight(.medium))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    if let pos = member.position, !pos.isEmpty {
                        Text(pos).font(.dsCaption).foregroundColor(Theme.textSecondary).lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? Theme.accent : Theme.textTertiary)
                    .font(.title3)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(isSelected ? Theme.accent.opacity(0.4) : Color.clear, lineWidth: 1.5)
        )
    }

    @ViewBuilder
    private func selectedChip(_ m: TeamMember) -> some View {
        HStack(spacing: 6) {
            AvatarCircle(url: m.avatarUrl, name: "\(m.firstName ?? "") \(m.lastName ?? "")")
                .frame(width: 24, height: 24)
            Text((m.firstName ?? "").prefix(8) + " " + (m.lastName ?? "").prefix(1) + ".")
                .font(.dsCaption.weight(.medium))
                .foregroundColor(Theme.textPrimary)
            Button {
                selected.remove(m.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(Theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(
            Capsule().fill(Theme.surfaceBackground)
        )
        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) }
        else { selected.insert(id) }
    }

    private func loadMembers() async {
        loading = true
        defer { loading = false }
        do {
            let resp: TeamListResponse = try await APIClient.shared.get("team", query: ["limit": "200"])
            self.members = resp.data
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func create() async {
        // Бэк (apps/api/src/modules/chats/dto/chat.dto.ts) принимает поле `type`
        // со значениями "direct" | "group". 1 участник — DM (direct), >=2 — group.
        struct Body: Encodable {
            let type: String
            let memberIds: [String]
            let title: String?
        }
        let primaryType = isGroup ? "group" : "direct"
        let title = isGroup ? groupTitle.trimmingCharacters(in: .whitespaces) : nil
        creating = true
        defer { creating = false }
        do {
            let chat: Chat = try await APIClient.shared.post(
                "chats",
                body: Body(type: primaryType, memberIds: Array(selected), title: title)
            )
            onCreated(chat)
            dismiss()
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}
