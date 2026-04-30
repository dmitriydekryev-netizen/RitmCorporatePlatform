//
//  SavedMessagesView.swift — мои сохранённые сообщения (звёздочки в чате).
//
//  Endpoints:
//   • GET    /saved-messages                  — лента сохранений
//   • POST   /saved-messages { messageId, note? }
//   • DELETE /saved-messages/:messageId
//   • GET    /saved-messages/:messageId/status
//

import SwiftUI

struct SavedMessage: Codable, Identifiable {
    let id: String
    let messageId: String?
    let note: String?
    let createdAt: String?
    let message: SavedMessageInfo?
}

struct SavedMessageInfo: Codable {
    let id: String
    let chatId: String?
    let content: String?
    let createdAt: String?
    let author: SavedMessageAuthor?
}

struct SavedMessageAuthor: Codable {
    let id: String
    let username: String?
    let firstName: String?
    let lastName: String?
    let avatarUrl: String?

    var displayName: String {
        let s = "\(firstName ?? "") \(lastName ?? "")".trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? (username ?? "?") : s
    }
}

struct SavedMessagesResponse: Codable {
    let data: [SavedMessage]
    let meta: PaginationMeta?
}

struct SavedMessagesView: View {
    @State private var saved: [SavedMessage] = []
    @State private var loading = true
    @State private var error: String?
    @State private var search: String = ""

    private var filteredSaved: [SavedMessage] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return saved }
        return saved.filter { item in
            (item.message?.content ?? "").lowercased().contains(q)
        }
    }

    var body: some View {
        Group {
            if loading && saved.isEmpty {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if saved.isEmpty {
                EmptyStateView(
                    icon: "book.closed",
                    title: "Сохранённых нет",
                    description: error ?? "Нажмите 🔖 на сообщении в чате, чтобы сохранить его сюда"
                )
            } else if filteredSaved.isEmpty {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "Ничего не найдено",
                    description: "Попробуйте изменить запрос"
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        DSPageTitle(text: "Сохранённые",
                                    subtitle: "\(saved.count) " + savedCountWord(saved.count))
                            .padding(.horizontal, 16)
                            .padding(.top, 4)

                        ForEach(filteredSaved) { item in
                            SavedRow(item: item)
                                .padding(.horizontal, 16)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        Task { await unsave(item) }
                                    } label: {
                                        Label("Удалить", systemImage: "trash")
                                    }
                                }
                                .contextMenu {
                                    Button(role: .destructive) {
                                        Task { await unsave(item) }
                                    } label: {
                                        Label("Удалить", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .padding(.vertical, 12)
                }
                .background(Theme.pageBackground)
            }
        }
        .navigationTitle("Сохранённые")
        .navigationBarTitleDisplayMode(.inline)
        .background(Theme.pageBackground.ignoresSafeArea())
        .searchable(text: $search, prompt: "Поиск по сообщениям")
        .refreshable { await load() }
        .task { if saved.isEmpty { await load() } }
    }

    private func savedCountWord(_ n: Int) -> String {
        let mod10 = n % 10
        let mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return "запись" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "записи" }
        return "записей"
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let resp: SavedMessagesResponse = try await APIClient.shared.get(
                "saved-messages", query: ["limit": "100"]
            )
            self.saved = resp.data
            self.error = nil
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func unsave(_ item: SavedMessage) async {
        guard let mid = item.messageId ?? item.message?.id else { return }
        do {
            try await APIClient.shared.delete("saved-messages/\(mid)")
            saved.removeAll { $0.id == item.id }
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}

private struct SavedRow: View {
    let item: SavedMessage

    var body: some View {
        DSCard(radius: Radius.xl, padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                if let author = item.message?.author {
                    HStack(spacing: 10) {
                        AvatarCircle(url: author.avatarUrl, name: author.displayName)
                            .frame(width: 28, height: 28)
                        Text(author.displayName)
                            .font(.dsBodySM.weight(.semibold))
                            .foregroundColor(Theme.textPrimary)
                        Spacer()
                        if let cs = item.message?.createdAt,
                           let d = ISO8601DateFormatter().date(from: cs) {
                            Text(relativeTime(from: d))
                                .font(.dsCaption)
                                .foregroundColor(Theme.textTertiary)
                        }
                    }
                }

                if let content = item.message?.content, !content.isEmpty {
                    Text(content)
                        .font(.dsBodyLG)
                        .foregroundColor(Theme.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("(пустое сообщение)")
                        .font(.dsBodySM)
                        .foregroundColor(Theme.textTertiary)
                }

                if let note = item.note, !note.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "note.text")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.warning)
                        Text(note)
                            .font(.dsBodySM)
                            .foregroundColor(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                            .fill(Theme.warning.opacity(0.10))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                            .strokeBorder(Theme.warning.opacity(0.25), lineWidth: 0.5)
                    )
                }
            }
        }
    }
}
