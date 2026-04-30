//
//  NewsCommentsSection.swift — секция комментариев под детальной новостью.
//  GET  /news/:newsId/comments  — список (массив, без обёртки)
//  POST /news/:newsId/comments  — создать комментарий { content, parentId? }
//

import SwiftUI

struct NewsComment: Codable, Identifiable {
    let id: String
    let newsId: String?
    let parentId: String?
    let content: String
    let isEdited: Bool?
    let createdAt: String
    let updatedAt: String?
    let author: NewsCommentAuthor?
}

struct NewsCommentAuthor: Codable {
    let id: String
    let username: String?
    let firstName: String?
    let lastName: String?
    let avatarUrl: String?

    var fullName: String {
        let s = "\(firstName ?? "") \(lastName ?? "")".trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? (username ?? "?") : s
    }
}

struct NewsCommentsSection: View {
    let newsId: String

    @EnvironmentObject var auth: AuthStore
    @State private var comments: [NewsComment] = []
    @State private var loading = false
    @State private var newText = ""
    @State private var sending = false
    @State private var error: String?
    @FocusState private var inputFocused: Bool
    @State private var editingId: String? = nil
    @State private var editText: String = ""

    var body: some View {
        DSCard(radius: Radius.xl2, padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    DSIconTile(systemImage: "bubble.left.and.bubble.right.fill",
                               color: Theme.accent, size: 32)
                    Text("Комментарии")
                        .font(.dsH3.weight(.semibold))
                        .foregroundColor(Theme.textPrimary)
                    if !comments.isEmpty {
                        DSBadge(text: "\(comments.count)", color: Theme.accent)
                    }
                    Spacer()
                }

                if loading && comments.isEmpty {
                    ProgressView().tint(Theme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                } else if comments.isEmpty {
                    Text("Будьте первым, кто оставит комментарий")
                        .font(.dsBodySM)
                        .foregroundColor(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else {
                    VStack(spacing: 10) {
                        ForEach(comments) { c in
                            CommentRow(
                                comment: c,
                                isMine: c.author?.id == auth.currentUser?.id,
                                isEditing: editingId == c.id,
                                editText: $editText,
                                onStartEdit: {
                                    editingId = c.id
                                    editText = c.content
                                },
                                onCancelEdit: {
                                    editingId = nil
                                    editText = ""
                                },
                                onConfirmEdit: { Task { await confirmEdit(c) } },
                                onDelete: { Task { await deleteComment(c) } }
                            )
                            if c.id != comments.last?.id {
                                Divider().background(Theme.separator)
                            }
                        }
                    }
                }

                // Поле ввода нового комментария
                HStack(alignment: .bottom, spacing: 10) {
                    if let me = auth.currentUser {
                        AvatarCircle(url: me.profile?.avatarUrl, name: me.displayName)
                            .frame(width: 32, height: 32)
                    }
                    HStack(alignment: .bottom, spacing: 8) {
                        TextField("Написать комментарий…", text: $newText, axis: .vertical)
                            .textFieldStyle(.plain)
                            .focused($inputFocused)
                            .lineLimit(1...5)
                            .font(.dsBody)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Theme.pageBackground)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.lg))

                        Button {
                            Task { await send() }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(canSend ? Theme.accent : Theme.textTertiary.opacity(0.3))
                                    .frame(width: 36, height: 36)
                                if sending {
                                    ProgressView().tint(.white).scaleEffect(0.7)
                                } else {
                                    Image(systemName: "arrow.up")
                                        .foregroundColor(.white)
                                        .font(.subheadline.weight(.bold))
                                }
                            }
                        }
                        .disabled(!canSend || sending)
                        .buttonStyle(DSPressScaleStyle())
                    }
                }
                .padding(.top, 4)

                if let err = error {
                    Text(err)
                        .font(.dsCaption)
                        .foregroundColor(Theme.danger)
                }
            }
        }
        .task { await load() }
    }

    private var canSend: Bool {
        !newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let list: [NewsComment] = try await APIClient.shared.get("news/\(newsId)/comments")
            self.comments = list.sorted { $0.createdAt < $1.createdAt }
            self.error = nil
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func send() async {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        defer { sending = false }
        struct Body: Encodable { let content: String }
        do {
            let created: NewsComment = try await APIClient.shared.post(
                "news/\(newsId)/comments",
                body: Body(content: text)
            )
            comments.append(created)
            newText = ""
            inputFocused = false
            error = nil
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    /// PATCH /comments/:id — отредактировать (только автор).
    private func confirmEdit(_ c: NewsComment) async {
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        struct Body: Encodable { let content: String }
        do {
            let updated: NewsComment = try await APIClient.shared.patch(
                "comments/\(c.id)", body: Body(content: text)
            )
            if let i = comments.firstIndex(where: { $0.id == c.id }) {
                comments[i] = updated
            }
            editingId = nil
            editText = ""
            error = nil
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    /// DELETE /comments/:id — удалить (автор или модератор).
    private func deleteComment(_ c: NewsComment) async {
        do {
            try await APIClient.shared.delete("comments/\(c.id)")
            comments.removeAll { $0.id == c.id }
            error = nil
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}

private struct CommentRow: View {
    let comment: NewsComment
    let isMine: Bool
    let isEditing: Bool
    @Binding var editText: String
    let onStartEdit: () -> Void
    let onCancelEdit: () -> Void
    let onConfirmEdit: () -> Void
    let onDelete: () -> Void

    @State private var showDeleteConfirm = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarCircle(url: comment.author?.avatarUrl, name: comment.author?.fullName ?? "?")
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(comment.author?.fullName ?? "Аноним")
                        .font(.dsBodySM.weight(.semibold))
                        .foregroundColor(Theme.textPrimary)
                    if let d = ISO8601DateFormatter().date(from: comment.createdAt) {
                        Text("·").foregroundColor(Theme.textTertiary)
                        Text(relativeTime(from: d))
                            .font(.dsCaption)
                            .foregroundColor(Theme.textTertiary)
                    }
                    if comment.isEdited == true {
                        Text("(ред.)")
                            .font(.dsCaption)
                            .foregroundColor(Theme.textTertiary)
                    }
                    Spacer()
                    if isMine {
                        Menu {
                            Button { onStartEdit() } label: {
                                Label("Редактировать", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                showDeleteConfirm = true
                            } label: {
                                Label("Удалить", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .foregroundColor(Theme.textTertiary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                        }
                    }
                }

                if isEditing {
                    TextField("Текст комментария", text: $editText, axis: .vertical)
                        .lineLimit(1...5)
                        .font(.dsBody)
                        .padding(10)
                        .background(Theme.pageBackground)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                    HStack(spacing: 8) {
                        Button {
                            onCancelEdit()
                        } label: {
                            Text("Отмена")
                                .font(.dsCaption.weight(.semibold))
                                .foregroundColor(Theme.textSecondary)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Theme.pageBackground)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(DSPressScaleStyle())
                        Spacer()
                        Button {
                            onConfirmEdit()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                Text("Сохранить")
                                    .font(.dsCaption.weight(.semibold))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Theme.accent)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(DSPressScaleStyle())
                        .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } else {
                    Text(comment.content)
                        .font(.dsBody)
                        .foregroundColor(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 4)
        .alert("Удалить комментарий?", isPresented: $showDeleteConfirm) {
            Button("Отмена", role: .cancel) {}
            Button("Удалить", role: .destructive) { onDelete() }
        }
    }
}
