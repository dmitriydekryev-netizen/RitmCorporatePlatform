//
//  CreateKudosSheet.swift — модалка создания благодарности.
//
//  Endpoints:
//    GET  /team?limit=200            — список сотрудников для выбора получателя
//    POST /kudos {toUserId, message, isPublic}
//
//  UX:
//   • На входе показываем список людей с .searchable и AvatarCircle/position строками.
//   • После тапа — переходим к экрану с TextEditor, переключателем «Публичная» и кнопкой «Отправить».
//

import SwiftUI

private struct CreateKudosBody: Encodable {
    let toUserId: String
    let message: String
    let isPublic: Bool
}

struct CreateKudosSheet: View {
    /// Колбэк после успешной отправки — вызывается, чтобы родитель мог перезагрузить ленту.
    var onCreated: (() async -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    // Team list
    @State private var team: [TeamMember] = []
    @State private var loadingTeam = true
    @State private var loadError: String?
    @State private var search: String = ""

    // Selection + composing
    @State private var selected: TeamMember?
    @State private var message: String = ""
    @State private var isPublic: Bool = true

    // Send
    @State private var sending = false
    @State private var sendError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let user = selected {
                    composeView(for: user)
                } else {
                    pickerView
                }
            }
            .navigationTitle(selected == nil ? "Кому?" : "Благодарность")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                        .disabled(sending)
                }
                if selected != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            Task { await send() }
                        } label: {
                            if sending {
                                ProgressView().tint(Theme.accent)
                            } else {
                                Text("Отправить").fontWeight(.semibold)
                            }
                        }
                        .disabled(
                            sending
                            || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                    }
                }
            }
        }
        .task { if team.isEmpty { await loadTeam() } }
    }

    // MARK: - Picker

    @ViewBuilder
    private var pickerView: some View {
        Group {
            if loadingTeam {
                ProgressView().tint(Theme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                EmptyStateView(
                    icon: "person.2",
                    title: "Никого не нашли",
                    description: loadError ?? "Попробуйте изменить запрос"
                )
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(filtered) { member in
                            Button { selected = member } label: {
                                DSCard(radius: Radius.md, padding: 12) {
                                    HStack(spacing: 12) {
                                        AvatarCircle(url: member.avatarUrl, name: fullName(member))
                                            .frame(width: 42, height: 42)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(fullName(member))
                                                .font(.dsBody.weight(.semibold))
                                                .foregroundColor(Theme.textPrimary)
                                            if let pos = member.position, !pos.isEmpty {
                                                Text(pos)
                                                    .font(.dsCaption)
                                                    .foregroundColor(Theme.textSecondary)
                                                    .lineLimit(1)
                                            }
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.dsCaption.weight(.semibold))
                                            .foregroundColor(Theme.textTertiary)
                                    }
                                }
                            }
                            .buttonStyle(DSPressScaleStyle())
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .background(Theme.pageBackground)
            }
        }
        .searchable(text: $search, prompt: "Поиск сотрудника")
    }

    private var filtered: [TeamMember] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return team }
        return team.filter { m in
            fullName(m).lowercased().contains(q)
            || m.username.lowercased().contains(q)
            || (m.position?.lowercased().contains(q) ?? false)
        }
    }

    private func fullName(_ m: TeamMember) -> String {
        let f = m.firstName ?? ""
        let l = m.lastName ?? ""
        let combo = "\(f) \(l)".trimmingCharacters(in: .whitespaces)
        return combo.isEmpty ? m.username : combo
    }

    // MARK: - Compose

    @ViewBuilder
    private func composeView(for user: TeamMember) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Recipient card
                VStack(alignment: .leading, spacing: 8) {
                    DSSectionHeader("Кому")
                    DSCard(radius: Radius.xl, padding: 14) {
                        HStack(spacing: 12) {
                            AvatarCircle(url: user.avatarUrl, name: fullName(user))
                                .frame(width: 50, height: 50)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(fullName(user))
                                    .font(.dsH3.weight(.semibold))
                                    .foregroundColor(Theme.textPrimary)
                                if let pos = user.position, !pos.isEmpty {
                                    Text(pos).font(.dsCaption).foregroundColor(Theme.textSecondary)
                                }
                            }
                            Spacer()
                            Button("Изменить") {
                                selected = nil
                            }
                            .font(.dsCaption.weight(.semibold))
                            .foregroundColor(Theme.accent)
                            .disabled(sending)
                        }
                    }
                }

                // Message
                VStack(alignment: .leading, spacing: 8) {
                    DSSectionHeader("Сообщение")
                    DSCard(radius: Radius.xl, padding: 14) {
                        TextField("За что благодаришь?", text: $message, axis: .vertical)
                            .lineLimit(4...10)
                            .font(.dsBodyLG)
                            .foregroundColor(Theme.textPrimary)
                    }
                }

                // Public toggle
                VStack(alignment: .leading, spacing: 8) {
                    DSSectionHeader("Видимость")
                    DSCard(radius: Radius.xl, padding: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle(isOn: $isPublic) {
                                HStack(spacing: 10) {
                                    DSIconTile(systemImage: isPublic ? "eye.fill" : "eye.slash.fill",
                                               color: isPublic ? Theme.accent : Theme.textTertiary,
                                               size: 32)
                                    Text("Публичная")
                                        .font(.dsBody.weight(.medium))
                                        .foregroundColor(Theme.textPrimary)
                                }
                            }
                            .tint(Theme.accent)
                            Text(isPublic
                                 ? "Будет видно всем сотрудникам в ленте."
                                 : "Увидите только вы и получатель.")
                                .font(.dsCaption)
                                .foregroundColor(Theme.textTertiary)
                        }
                    }
                }

                if let err = sendError {
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
    }

    // MARK: - Networking

    private func loadTeam() async {
        loadingTeam = true
        defer { loadingTeam = false }
        do {
            let resp: TeamListResponse = try await APIClient.shared.get(
                "team", query: ["limit": "200"]
            )
            self.team = resp.data
        } catch let e as APIError {
            self.loadError = e.errorDescription
        } catch {
            self.loadError = error.localizedDescription
        }
    }

    private func send() async {
        guard let user = selected else { return }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        sending = true
        sendError = nil
        defer { sending = false }

        do {
            _ = try await APIClient.shared.rawRequest(
                "POST", "kudos",
                body: CreateKudosBody(toUserId: user.id, message: trimmed, isPublic: isPublic)
            )
            await onCreated?()
            dismiss()
        } catch let e as APIError {
            sendError = e.errorDescription
        } catch {
            sendError = error.localizedDescription
        }
    }
}

#Preview {
    CreateKudosSheet()
}
