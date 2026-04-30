//
//  AdminScheduleApprovalsView.swift — раздел «График» в Админ-панели:
//  очередь заявок на согласование (pending) + история (approved/rejected).
//
//  Бэкенд:
//   • GET   /schedule/requests           — список (для админа — все)
//   • PATCH /schedule/requests/:id/review body { action: "approved"|"rejected", comment? }
//
//  Использует модели и helpers из ScheduleView.swift.
//

import SwiftUI

struct AdminScheduleApprovalsView: View {
    enum SubTab: String, CaseIterable, Identifiable {
        case pending, history
        var id: String { rawValue }
        var title: String { self == .pending ? "Очередь" : "История" }
    }

    @State private var subtab: SubTab = .pending
    @State private var requests: [ScheduleRequestItem] = []
    @State private var loading = true
    @State private var error: String?

    private var pendingRequests: [ScheduleRequestItem] {
        requests.filter { $0.status == "pending" }
            .sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
    }
    private var historyRequests: [ScheduleRequestItem] {
        requests.filter { $0.status != "pending" }
            .sorted { ($0.reviewedAt ?? $0.createdAt ?? "") > ($1.reviewedAt ?? $1.createdAt ?? "") }
    }

    var body: some View {
        ZStack {
            Theme.pageBackground.ignoresSafeArea()
            VStack(spacing: 12) {
                Picker("", selection: $subtab) {
                    ForEach(SubTab.allCases) { s in Text(s.title).tag(s) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)

                if loading && requests.isEmpty {
                    ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = error, requests.isEmpty {
                    EmptyStateView(icon: "exclamationmark.triangle", title: "Ошибка", description: err)
                } else {
                    let list = subtab == .pending ? pendingRequests : historyRequests
                    if list.isEmpty {
                        EmptyStateView(
                            icon: subtab == .pending ? "tray" : "clock.arrow.circlepath",
                            title: subtab == .pending ? "Очередь пуста" : "Нет истории",
                            description: subtab == .pending
                                ? "Все заявки разобраны"
                                : "Здесь будут согласованные / отклонённые"
                        )
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(list) { req in
                                    AdminScheduleRequestCard(request: req) {
                                        Task { await load() }
                                    }
                                }
                            }
                            .padding(16)
                        }
                    }
                }
            }
        }
        .navigationTitle("График: согласование")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { if requests.isEmpty { await load() } }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let arr: [ScheduleRequestItem] = try await APIClient.shared.get("schedule/requests")
            self.requests = arr
            self.error = nil
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}

// MARK: - Request card with approve/reject sheets

private struct AdminScheduleRequestCard: View {
    let request: ScheduleRequestItem
    let onChange: () -> Void

    @State private var showApprove = false
    @State private var showReject = false
    @State private var comment = ""
    @State private var working = false
    @State private var error: String?

    private var statusLabel: String {
        switch request.status {
        case "approved": return "Согласовано"
        case "rejected": return "Отклонено"
        default:         return "На рассмотрении"
        }
    }
    private var statusColor: Color {
        switch request.status {
        case "approved": return Theme.success
        case "rejected": return Theme.danger
        default:         return Theme.warning
        }
    }
    private var statusIcon: String {
        switch request.status {
        case "approved": return "checkmark.circle.fill"
        case "rejected": return "xmark.circle.fill"
        default:         return "clock.fill"
        }
    }

    private var typeLabel: String? { request.entries?.first?.label }
    private var periodLabel: String? {
        guard let (from, to) = request.period else { return nil }
        let yyyymmdd = DateFormatter()
        yyyymmdd.dateFormat = "yyyy-MM-dd"
        yyyymmdd.locale = Locale(identifier: "en_US_POSIX")
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM"
        guard let dFrom = yyyymmdd.date(from: from),
              let dTo = yyyymmdd.date(from: to) else { return "\(from) — \(to)" }
        if from == to { return f.string(from: dFrom) }
        return "\(f.string(from: dFrom)) — \(f.string(from: dTo))"
    }

    var body: some View {
        DSCard(radius: Radius.lg, padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    AvatarCircle(url: request.user?.profile?.avatarUrl,
                                 name: request.user?.displayName ?? "—")
                        .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(request.user?.displayName ?? "—")
                            .font(.dsBodyLG.weight(.semibold))
                            .foregroundColor(Theme.textPrimary)
                        if let u = request.user?.username {
                            Text("@\(u)").font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)
                        }
                    }
                    Spacer()
                    DSBadge(text: statusLabel, systemImage: statusIcon, color: statusColor)
                }

                if let p = periodLabel {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar").font(.system(size: 11))
                            .foregroundColor(Theme.textTertiary)
                        Text(p).font(.dsBodySM.weight(.medium)).foregroundColor(Theme.textPrimary)
                        if let typeLabel = typeLabel {
                            Text("· \(typeLabel)").font(.dsCaption).foregroundColor(Theme.textSecondary)
                        }
                        if let count = request.entries?.count, count > 1 {
                            Text("· \(count) дн.").font(.dsCaption).foregroundColor(Theme.textTertiary)
                        }
                    }
                }

                if let c = request.comment, !c.isEmpty {
                    Text(c).font(.dsCaption.italic()).foregroundColor(Theme.textSecondary).lineLimit(4)
                }

                if request.status == "pending" {
                    HStack(spacing: 8) {
                        Button {
                            comment = ""; showApprove = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark"); Text("Одобрить")
                            }
                            .font(.dsBodySM.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(Theme.success)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                        }
                        .buttonStyle(DSPressScaleStyle())
                        .disabled(working)

                        Button {
                            comment = ""; showReject = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "xmark"); Text("Отклонить")
                            }
                            .font(.dsBodySM.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(Theme.danger)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                        }
                        .buttonStyle(DSPressScaleStyle())
                        .disabled(working)
                    }
                }

                if let err = error {
                    Text(err).font(.dsCaption).foregroundColor(Theme.danger)
                }
            }
        }
        .sheet(isPresented: $showApprove) { reviewSheet(action: "approved") }
        .sheet(isPresented: $showReject) { reviewSheet(action: "rejected") }
    }

    @ViewBuilder
    private func reviewSheet(action: String) -> some View {
        let isReject = action == "rejected"
        NavigationStack {
            Form {
                Section {
                    TextField(isReject ? "Причина отклонения (обязательно)" : "Комментарий (необязательно)",
                              text: $comment, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text(isReject ? "Причина" : "Комментарий")
                } footer: {
                    if isReject {
                        Text("Будет показана пользователю. Поле обязательно.")
                    }
                }
            }
            .navigationTitle(isReject ? "Отклонить заявку" : "Одобрить заявку")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { showApprove = false; showReject = false }
                        .disabled(working)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(working ? "…" : (isReject ? "Отклонить" : "Одобрить")) {
                        Task { await review(action: action) }
                    }
                    .disabled(working || (isReject && comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    .foregroundColor(isReject ? Theme.danger : Theme.success)
                }
            }
        }
    }

    private struct ReviewBody: Encodable {
        let action: String
        let comment: String?
    }

    private func review(action: String) async {
        working = true
        defer { working = false }
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = ReviewBody(action: action, comment: trimmed.isEmpty ? nil : trimmed)
        do {
            _ = try await APIClient.shared.rawRequest(
                "PATCH", "schedule/requests/\(request.id)/review", body: body
            )
            showApprove = false; showReject = false
            onChange()
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}
