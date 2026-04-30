//
//  PollsView.swift — опросы (в чате и новостях).
//
//  Endpoints:
//   • GET  /polls/:id              — детальный опрос с counts, myVotes
//   • POST /polls/chat             — создать опрос для чат-сообщения
//   • POST /polls/:id/vote         — голосовать (массив option indices)
//   • POST /polls/:id/close        — закрыть (admin/author)
//

import SwiftUI

// MARK: - Models

struct PollDTO: Codable, Identifiable {
    let id: String
    let scope: String?           // "chat" | "news"
    let messageId: String?
    let newsId: String?
    let question: String
    let options: [String]
    let isAnonymous: Bool
    let allowMulti: Bool
    let closesAt: String?
    let closedAt: String?
    let createdAt: String?
    let author: PollAuthor?
    let counts: [Int]
    let totalVotes: Int
    let myVotes: [Int]

    var isClosed: Bool { closedAt != nil }
}

struct PollAuthor: Codable {
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

// MARK: - Detail view

struct PollDetailView: View {
    let pollId: String
    @State private var poll: PollDTO?
    @State private var loading = true
    @State private var error: String?
    @State private var voting = false
    /// Локальный выбор пользователя до клика «Проголосовать»
    @State private var selected: Set<Int> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let p = poll {
                    header(p)
                    optionsList(p)
                    if !canVote(p) {
                        statsFooter(p)
                    } else {
                        voteButton(p)
                    }
                } else if loading {
                    ProgressView().tint(Theme.accent).padding()
                } else if let err = error {
                    EmptyStateView(icon: "chart.bar.xaxis",
                                   title: "Не удалось загрузить опрос",
                                   description: err)
                }
            }
            .padding(16)
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("Опрос")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func canVote(_ p: PollDTO) -> Bool {
        !p.isClosed && p.myVotes.isEmpty
    }

    @ViewBuilder
    private func header(_ p: PollDTO) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.fill").font(.dsCaption.weight(.bold))
                Text("ОПРОС").font(.system(size: 11, weight: .bold)).tracking(1.5)
            }
            .foregroundColor(Theme.accent)

            HStack(spacing: 6) {
                if p.isAnonymous {
                    DSBadge(text: "Анонимный", systemImage: "eye.slash.fill", color: Theme.textSecondary)
                }
                if p.allowMulti {
                    DSBadge(text: "Несколько", systemImage: "checkmark.circle", color: Theme.textSecondary)
                }
                Spacer()
                if p.isClosed {
                    DSBadge(text: "Закрыт", color: Theme.textSecondary, filled: true)
                }
            }

            Text(p.question)
                .font(.dsH2)
                .foregroundColor(Theme.textPrimary)

            HStack {
                if let a = p.author {
                    Text("Автор: \(a.displayName)")
                        .font(.dsCaption)
                        .foregroundColor(Theme.textSecondary)
                }
                Spacer()
                Text("\(p.totalVotes) " + voteSuffix(p.totalVotes))
                    .font(.dsCaption.weight(.semibold))
                    .foregroundColor(Theme.accent)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Theme.accent.opacity(0.10), Theme.purple.opacity(0.06), Theme.pink.opacity(0.05)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.18), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func optionsList(_ p: PollDTO) -> some View {
        VStack(spacing: 8) {
            ForEach(Array(p.options.enumerated()), id: \.offset) { (idx, label) in
                OptionRow(
                    label: label,
                    count: idx < p.counts.count ? p.counts[idx] : 0,
                    total: p.totalVotes,
                    isMine: p.myVotes.contains(idx),
                    isSelected: selected.contains(idx),
                    canVote: canVote(p),
                    onTap: {
                        if !canVote(p) { return }
                        if p.allowMulti {
                            if selected.contains(idx) { selected.remove(idx) }
                            else { selected.insert(idx) }
                        } else {
                            selected = [idx]
                        }
                    }
                )
            }
        }
    }

    @ViewBuilder
    private func voteButton(_ p: PollDTO) -> some View {
        DSPrimaryButton(
            action: { Task { await vote() } },
            loading: voting,
            enabled: !selected.isEmpty,
            gradient: !selected.isEmpty
        ) {
            Text(selected.isEmpty ? "Выберите вариант" : "Проголосовать")
        }
    }

    @ViewBuilder
    private func statsFooter(_ p: PollDTO) -> some View {
        VStack(spacing: 4) {
            if !p.myVotes.isEmpty {
                Label("Вы проголосовали", systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundColor(Theme.success)
            }
            if let closesAt = p.closesAt, let d = ISO8601DateFormatter().date(from: closesAt), !p.isClosed {
                Text("Закрытие: \(d.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let p: PollDTO = try await APIClient.shared.get("polls/\(pollId)")
            self.poll = p
            self.error = nil
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func vote() async {
        guard !selected.isEmpty else { return }
        struct Body: Encodable { let options: [Int] }
        voting = true
        defer { voting = false }
        do {
            _ = try await APIClient.shared.rawRequest(
                "POST", "polls/\(pollId)/vote",
                body: Body(options: Array(selected).sorted())
            )
            await load()
            selected.removeAll()
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func voteSuffix(_ n: Int) -> String {
        let m10 = n % 10, m100 = n % 100
        if m100 >= 11 && m100 <= 14 { return "голосов" }
        if m10 == 1 { return "голос" }
        if m10 >= 2 && m10 <= 4 { return "голоса" }
        return "голосов"
    }
}

// MARK: - Option row

private struct OptionRow: View {
    let label: String
    let count: Int
    let total: Int
    let isMine: Bool
    let isSelected: Bool
    let canVote: Bool
    let onTap: () -> Void

    var percent: Double {
        guard total > 0 else { return 0 }
        return Double(count) / Double(total)
    }

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .leading) {
                // Bar
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isMine ? Theme.accent.opacity(0.2) : Theme.surfaceBackground)
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isMine ? Theme.accent.opacity(0.35) : Theme.accent.opacity(0.12))
                        .frame(width: geo.size.width * percent)
                }

                HStack {
                    if canVote {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(isSelected ? Theme.accent : .secondary)
                    } else if isMine {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Theme.accent)
                    }
                    Text(label)
                        .font(.subheadline.weight(isMine ? .semibold : .regular))
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.leading)
                    Spacer()
                    if !canVote || total > 0 {
                        Text("\(Int(percent * 100))%")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .disabled(!canVote)
    }
}

// MARK: - Create sheet

struct CreatePollSheet: View {
    let onCreate: (String, [String], Bool, Bool) async -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var question: String = ""
    @State private var options: [String] = ["", ""]
    @State private var isAnonymous = false
    @State private var allowMulti = false
    @State private var creating = false
    @State private var error: String?

    var canCreate: Bool {
        question.trimmingCharacters(in: .whitespaces).count >= 3 &&
        options.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count >= 2
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Вопрос") {
                    TextField("О чём вопрос?", text: $question, axis: .vertical)
                        .lineLimit(2...4)
                }
                Section("Варианты") {
                    ForEach(options.indices, id: \.self) { idx in
                        HStack {
                            TextField("Вариант \(idx + 1)", text: $options[idx])
                            if options.count > 2 {
                                Button(role: .destructive) {
                                    options.remove(at: idx)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if options.count < 10 {
                        Button {
                            options.append("")
                        } label: {
                            Label("Добавить вариант", systemImage: "plus.circle")
                                .foregroundColor(Theme.accent)
                        }
                    }
                }
                Section("Настройки") {
                    Toggle("Анонимный", isOn: $isAnonymous)
                    Toggle("Несколько ответов", isOn: $allowMulti)
                }
                if let err = error {
                    Section { Text(err).font(.caption).foregroundColor(Theme.danger) }
                }
            }
            .navigationTitle("Новый опрос")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await create() }
                    } label: {
                        if creating {
                            ProgressView().tint(Theme.accent)
                        } else {
                            Text("Создать").fontWeight(.semibold)
                        }
                    }
                    .disabled(!canCreate || creating)
                }
            }
        }
    }

    private func create() async {
        let q = question.trimmingCharacters(in: .whitespaces)
        let opts = options.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        creating = true
        defer { creating = false }
        await onCreate(q, opts, isAnonymous, allowMulti)
        dismiss()
    }
}
