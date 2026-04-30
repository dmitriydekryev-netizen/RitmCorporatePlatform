//
//  VerificationQueueView.swift — админ-очередь заявок на верификацию.
//
//  Источник данных:
//   • GET  /admin/verification?status=pending|approved|rejected&limit&offset
//   • POST /admin/verification/:id/resolve   { action: approve|reject, reject_reason?, admin_note? }
//   • GET  /admin/verification/media/:kind/:ref   (картинка аватара / фото-доказательства)
//
//  Бэк хранит avatar_ref как UUID — реальная картинка отдаётся через media-endpoint.
//

import SwiftUI

// MARK: - Models

struct VerificationReviewer: Codable, Hashable {
    let id: String?
    let username: String?
    let firstName: String?
    let lastName: String?
    let avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case firstName  = "first_name"
        case lastName   = "last_name"
        case avatarUrl  = "avatar_url"
    }

    var displayName: String {
        let s = "\(firstName ?? "") \(lastName ?? "")".trimmingCharacters(in: .whitespaces)
        if !s.isEmpty { return s }
        return username ?? "—"
    }
}

struct VerificationRequest: Codable, Identifiable {
    let id: String
    let userId: String
    let username: String
    let name: String?
    let surname: String?
    let avatarRef: String?
    let isVerified: Bool?
    let category: String?
    let status: String      // pending | approved | rejected
    let rejectReason: String?
    let adminNote: String?
    let reviewerId: String?
    let reviewer: VerificationReviewer?
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId       = "user_id"
        case username
        case name
        case surname
        case avatarRef    = "avatar_ref"
        case isVerified   = "is_verified"
        case category
        case status
        case rejectReason = "reject_reason"
        case adminNote    = "admin_note"
        case reviewerId   = "reviewer_id"
        case reviewer
        case createdAt    = "created_at"
        case updatedAt    = "updated_at"
    }

    var fullName: String {
        let parts = [name, surname].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let joined = parts.joined(separator: " ")
        return joined.isEmpty ? "@\(username)" : joined
    }

    var displayCategory: String {
        switch category {
        case "public_figure": return "Публичная персона"
        case "business":      return "Бизнес"
        case "creator":       return "Автор / блогер"
        case "media":         return "СМИ"
        case .some(let c) where !c.isEmpty: return c.capitalized
        default:              return "—"
        }
    }
}

private struct VerificationListResponse: Codable {
    let requests: [VerificationRequest]
    let total: Int?
}

// MARK: - Filter tab

private enum VerificationFilter: String, CaseIterable, Identifiable {
    case pending
    case approved
    case rejected

    var id: String { rawValue }

    var apiValue: String { rawValue }

    var title: String {
        switch self {
        case .pending:  return "На рассмотрении"
        case .approved: return "Одобренные"
        case .rejected: return "Отклонённые"
        }
    }
}

private enum VerificationTab: String, CaseIterable, Identifiable {
    case queue
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .queue:   return "Очередь"
        case .history: return "История"
        }
    }
}

// MARK: - History row model

private struct VerificationHistoryItem: Identifiable {
    let request: VerificationRequest
    var id: String { request.id }
}

// MARK: - List screen

struct VerificationQueueView: View {
    @State private var tab: VerificationTab = .queue
    @State private var filter: VerificationFilter = .pending
    @State private var items: [VerificationRequest] = []
    @State private var historyItems: [VerificationRequest] = []
    @State private var loading = true
    @State private var lastError: String?
    @State private var total: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                DSPageTitle(text: "Верификация", subtitle: "Заявки на «галочку»")
                Picker("", selection: $tab) {
                    ForEach(VerificationTab.allCases) { t in
                        Text(t.title).tag(t)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .onChange(of: tab) { _ in
                Task { await reload() }
            }

            if tab == .queue {
                queueContent
            } else {
                historyContent
            }
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
        .task { await reload() }
    }

    // MARK: - Queue tab

    @ViewBuilder
    private var queueContent: some View {
        if loading && items.isEmpty {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(0..<6, id: \.self) { _ in skeletonRow }
                }
                .padding(16)
            }
        } else if let err = lastError, items.isEmpty {
            EmptyStateView(
                icon: "exclamationmark.triangle.fill",
                title: "Не удалось загрузить",
                description: err
            )
        } else if items.isEmpty {
            EmptyStateView(
                icon: "tray",
                title: "Очередь пуста",
                description: "Все заявки разобраны"
            )
        } else {
            List {
                if total > 0 {
                    Text("Всего: \(total)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 4, trailing: 16))
                }
                ForEach(items) { req in
                    ZStack {
                        NavigationLink(destination: VerificationDetailView(initial: req)) {
                            EmptyView()
                        }
                        .opacity(0)
                        VerificationRowCard(request: req)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: - History tab

    @ViewBuilder
    private var historyContent: some View {
        if loading && historyItems.isEmpty {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(0..<6, id: \.self) { _ in skeletonRow }
                }
                .padding(16)
            }
        } else if let err = lastError, historyItems.isEmpty {
            EmptyStateView(
                icon: "exclamationmark.triangle.fill",
                title: "Не удалось загрузить",
                description: err
            )
        } else if historyItems.isEmpty {
            EmptyStateView(
                icon: "clock.arrow.circlepath",
                title: "Истории нет",
                description: "Здесь будут отображаться принятые решения"
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(historyItems) { req in
                        NavigationLink {
                            VerificationDetailView(initial: req)
                        } label: {
                            VerificationHistoryRow(request: req)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Reload

    private func reload() async {
        loading = true
        lastError = nil
        defer { loading = false }
        if tab == .queue {
            do {
                let resp: VerificationListResponse = try await APIClient.shared.get(
                    "admin/verification",
                    query: ["status": "pending", "limit": "50", "offset": "0"]
                )
                self.items = resp.requests
                self.total = resp.total ?? resp.requests.count
            } catch {
                self.items = []
                self.total = 0
                self.lastError = apiUserMessage(error)
            }
        } else {
            // Параллельно дёргаем approved + rejected и мёрджим.
            async let approvedTask: VerificationListResponse = APIClient.shared.get(
                "admin/verification",
                query: ["status": "approved", "limit": "50", "offset": "0"]
            )
            async let rejectedTask: VerificationListResponse = APIClient.shared.get(
                "admin/verification",
                query: ["status": "rejected", "limit": "50", "offset": "0"]
            )
            do {
                let (approved, rejected) = try await (approvedTask, rejectedTask)
                let merged = (approved.requests + rejected.requests)
                    .sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
                self.historyItems = merged
                self.total = merged.count
            } catch {
                self.historyItems = []
                self.total = 0
                self.lastError = apiUserMessage(error)
            }
        }
    }

    // MARK: - Skeleton + empty copy

    private var skeletonRow: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Theme.surfaceBackground)
            .frame(height: 78)
            .redacted(reason: .placeholder)
            .shimmering()
    }

    private var emptyIcon: String {
        switch filter {
        case .pending:  return "tray"
        case .approved: return "checkmark.seal"
        case .rejected: return "xmark.seal"
        }
    }

    private var emptyTitle: String {
        switch filter {
        case .pending:  return "Очередь пуста"
        case .approved: return "Нет одобренных"
        case .rejected: return "Нет отклонённых"
        }
    }

    private var emptyDescription: String? {
        switch filter {
        case .pending:  return "Все заявки разобраны"
        case .approved: return "Здесь появятся одобренные заявки"
        case .rejected: return "Здесь появятся отклонённые заявки"
        }
    }
}

// MARK: - Row

private struct VerificationRowCard: View {
    let request: VerificationRequest

    var body: some View {
        DSCard(radius: Radius.lg, padding: 14) {
            HStack(alignment: .top, spacing: 12) {
                VerificationAvatar(ref: request.avatarRef, fallbackName: request.fullName)
                    .frame(width: 50, height: 50)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(request.fullName)
                            .font(.dsH3)
                            .fontWeight(.semibold)
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                        if request.isVerified == true {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.accent)
                        }
                        Spacer(minLength: 0)
                        statusBadge
                    }
                    Text("@\(request.username)")
                        .font(.dsCaption)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Label(request.displayCategory, systemImage: "rosette")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                        Spacer()
                        if let created = request.createdAt,
                           let date = ISO8601DateFormatter().date(from: created) {
                            Text(relativeTime(from: date))
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textTertiary)
                        }
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch request.status {
        case "pending":
            DSBadge(text: "Ждёт", color: Theme.warning)
        case "approved":
            DSBadge(text: "Одобрено", systemImage: "checkmark", color: Theme.success)
        case "rejected":
            DSBadge(text: "Отклонено", systemImage: "xmark", color: Theme.danger)
        default:
            DSBadge(text: request.status, color: Theme.textSecondary)
        }
    }
}

// MARK: - History row

private struct VerificationHistoryRow: View {
    let request: VerificationRequest

    private var isApproved: Bool { request.status == "approved" }

    var body: some View {
        DSCard(radius: Radius.lg, padding: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill((isApproved ? Theme.success : Theme.danger).opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: isApproved ? "checkmark" : "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(isApproved ? Theme.success : Theme.danger)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(request.fullName)
                            .font(.dsBodyLG.weight(.semibold))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if let updated = request.updatedAt,
                           let date = ISO8601DateFormatter().date(from: updated) {
                            Text(relativeTime(from: date))
                                .font(.caption)
                                .foregroundColor(Theme.textTertiary)
                        }
                    }
                    Text("@\(request.username)")
                        .font(.dsCaption)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)

                    if let reviewer = request.reviewer {
                        HStack(spacing: 4) {
                            Image(systemName: "person.fill.checkmark")
                                .font(.caption2)
                                .foregroundColor(Theme.textTertiary)
                            Text("Решил: \(reviewer.displayName)")
                                .font(.caption)
                                .foregroundColor(Theme.textSecondary)
                                .lineLimit(1)
                        }
                    }

                    let comment = isApproved
                        ? request.adminNote
                        : (request.rejectReason ?? request.adminNote)
                    if let c = comment, !c.isEmpty {
                        Text(c)
                            .font(.caption)
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(3)
                            .padding(.top, 2)
                    }
                }
            }
        }
    }
}

// MARK: - Detail screen

struct VerificationDetailView: View {
    let initial: VerificationRequest

    @Environment(\.dismiss) private var dismiss

    @State private var current: VerificationRequest
    @State private var working = false
    @State private var actionError: String?
    @State private var showRejectSheet = false
    @State private var rejectReason: String = ""
    @State private var adminNote: String = ""
    @State private var resolvedToast: String?

    init(initial: VerificationRequest) {
        self.initial = initial
        _current = State(initialValue: initial)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                profileCard

                if current.status != "pending" {
                    historyCard
                }

                if let note = current.adminNote, !note.isEmpty {
                    infoCard(title: "Заметка администратора", text: note, color: Theme.accent)
                }

                if let reason = current.rejectReason, !reason.isEmpty, current.status == "rejected" {
                    infoCard(title: "Причина отклонения", text: reason, color: Theme.danger)
                }

                if let err = actionError {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Theme.danger)
                        Text(err).font(.footnote).foregroundColor(Theme.danger)
                        Spacer()
                    }
                    .padding(12)
                    .background(Theme.danger.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                if current.status == "pending" {
                    actionButtons
                }
            }
            .padding(16)
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("Заявка")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showRejectSheet) {
            RejectReasonSheet(
                reason: $rejectReason,
                adminNote: $adminNote,
                isWorking: working,
                onCancel: { showRejectSheet = false },
                onSubmit: {
                    Task { await resolve(action: "reject") }
                }
            )
            .presentationDetents([.medium, .large])
        }
        .overlay(alignment: .top) {
            if let toast = resolvedToast {
                Text(toast)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Theme.success)
                    .clipShape(Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private var profileCard: some View {
        DSCard(radius: Radius.xl, padding: 24) {
            VStack(spacing: 14) {
                VerificationAvatar(ref: current.avatarRef, fallbackName: current.fullName)
                    .frame(width: 96, height: 96)
                    .overlay(
                        Circle().stroke(Theme.accent.opacity(0.3), lineWidth: 2)
                    )
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Text(current.fullName)
                            .font(.dsH2)
                            .fontWeight(.bold)
                            .foregroundColor(Theme.textPrimary)
                            .multilineTextAlignment(.center)
                        if current.isVerified == true {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundColor(Theme.accent)
                        }
                    }
                    Text("@\(current.username)")
                        .font(.dsBodySM)
                        .foregroundColor(Theme.textSecondary)
                }
                HStack(spacing: 8) {
                    DSBadge(text: current.displayCategory, systemImage: "rosette", color: Theme.textSecondary)
                    DSBadge(text: statusLabel, color: statusColor)
                }
                if let created = current.createdAt,
                   let date = ISO8601DateFormatter().date(from: created) {
                    Text("Подана \(relativeTime(from: date))")
                        .font(.dsCaption)
                        .foregroundColor(Theme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("История")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 6) {
                if let updated = current.updatedAt,
                   let date = ISO8601DateFormatter().date(from: updated) {
                    HStack(spacing: 8) {
                        Image(systemName: statusIcon)
                            .foregroundColor(statusColor)
                        Text("\(statusLabel) — \(relativeTime(from: date))")
                            .font(.subheadline)
                    }
                }
                if current.reviewerId != nil {
                    HStack(spacing: 8) {
                        Image(systemName: "person.fill.checkmark")
                            .foregroundColor(.secondary)
                        Text("Решение принято модератором")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surfaceBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private func infoCard(title: String, text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            Text(text)
                .font(.subheadline)
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(color.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(color.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button {
                Task { await resolve(action: "approve") }
            } label: {
                HStack(spacing: 8) {
                    if working {
                        ProgressView().tint(.white).scaleEffect(0.85)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    Text("Одобрить")
                }
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundColor(.white)
                .background(Theme.success)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .shadow(color: Theme.success.opacity(0.35), radius: 14, x: 0, y: 4)
            }
            .disabled(working)
            .buttonStyle(DSPressScaleStyle())

            Button {
                rejectReason = ""
                adminNote = ""
                showRejectSheet = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.circle.fill")
                    Text("Отклонить")
                }
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundColor(.white)
                .background(Theme.danger)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .shadow(color: Theme.danger.opacity(0.35), radius: 14, x: 0, y: 4)
            }
            .disabled(working)
            .buttonStyle(DSPressScaleStyle())
        }
    }

    private func infoChip(icon: String, text: String, color: Color = .secondary) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundColor(color)
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundColor(color == .secondary ? .secondary : color)
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(color == .secondary ? Theme.pageBackground : color.opacity(0.12))
        .clipShape(Capsule())
    }

    // MARK: - Computed

    private var statusLabel: String {
        switch current.status {
        case "pending":  return "На рассмотрении"
        case "approved": return "Одобрено"
        case "rejected": return "Отклонено"
        default:         return current.status
        }
    }

    private var statusColor: Color {
        switch current.status {
        case "pending":  return Theme.warning
        case "approved": return Theme.success
        case "rejected": return Theme.danger
        default:         return .secondary
        }
    }

    private var statusIcon: String {
        switch current.status {
        case "approved": return "checkmark.seal.fill"
        case "rejected": return "xmark.seal.fill"
        default:         return "clock.fill"
        }
    }

    // MARK: - Actions

    private struct ResolveBody: Encodable {
        let action: String
        let reject_reason: String?
        let admin_note: String?
    }

    private func resolve(action: String) async {
        working = true
        actionError = nil
        defer { working = false }
        let trimmedReason = rejectReason.trimmingCharacters(in: .whitespacesAndNewlines)
        if action == "reject" && trimmedReason.isEmpty {
            actionError = "Укажите причину отклонения"
            return
        }
        let body = ResolveBody(
            action: action,
            reject_reason: action == "reject" ? trimmedReason : nil,
            admin_note: adminNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : adminNote
        )
        do {
            let _: EmptyResponse = try await APIClient.shared.post(
                "admin/verification/\(current.id)/resolve",
                body: body
            )
            // Локально обновляем статус, чтобы экран отрисовал результат без перезагрузки списка.
            current = VerificationRequest(
                id: current.id,
                userId: current.userId,
                username: current.username,
                name: current.name,
                surname: current.surname,
                avatarRef: current.avatarRef,
                isVerified: action == "approve",
                category: current.category,
                status: action == "approve" ? "approved" : "rejected",
                rejectReason: action == "reject" ? body.reject_reason : current.rejectReason,
                adminNote: body.admin_note ?? current.adminNote,
                reviewerId: current.reviewerId,
                reviewer: current.reviewer,
                createdAt: current.createdAt,
                updatedAt: ISO8601DateFormatter().string(from: Date())
            )
            showRejectSheet = false
            withAnimation { resolvedToast = action == "approve" ? "Заявка одобрена" : "Заявка отклонена" }
            Task {
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                withAnimation { resolvedToast = nil }
            }
        } catch {
            actionError = apiUserMessage(error)
        }
    }
}

// MARK: - Reject sheet

private struct RejectReasonSheet: View {
    @Binding var reason: String
    @Binding var adminNote: String
    let isWorking: Bool
    let onCancel: () -> Void
    let onSubmit: () -> Void

    private var trimmedReason: String {
        reason.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !trimmedReason.isEmpty && !isWorking
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Например: не соответствует критериям", text: $reason, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("Причина отклонения *")
                } footer: {
                    Text("Будет показана пользователю. Поле обязательно для заполнения.")
                }

                Section {
                    TextField("Внутренняя заметка (необязательно)", text: $adminNote, axis: .vertical)
                        .lineLimit(2...5)
                } header: {
                    Text("Заметка для модераторов")
                }
            }
            .navigationTitle("Отклонить")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена", action: onCancel)
                        .disabled(isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView()
                    } else {
                        Button("Отклонить", action: onSubmit)
                            .foregroundColor(canSubmit ? Theme.danger : Theme.textTertiary)
                            .disabled(!canSubmit)
                    }
                }
            }
        }
    }
}

// MARK: - Authenticated avatar

/// Аватар заявителя — `avatar_ref` это UUID, реальная картинка приходит через
/// `/admin/verification/media/photos/:ref` и требует Bearer-токена. Стандартный
/// `AsyncImage` не умеет добавлять заголовки, поэтому грузим вручную.
private struct VerificationAvatar: View {
    let ref: String?
    let fallbackName: String

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if failed || ref == nil {
                ZStack {
                    LinearGradient(colors: [Theme.accent, Theme.purple],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(initials)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                }
            } else {
                Theme.pageBackground
            }
        }
        .clipShape(Circle())
        .task(id: ref) {
            guard let ref, image == nil else { return }
            await load(ref: ref)
        }
    }

    private var initials: String {
        let parts = fallbackName.split(separator: " ").compactMap { $0.first.map(String.init) }
        let combo = parts.prefix(2).joined().uppercased()
        return combo.isEmpty ? "?" : combo
    }

    private func load(ref: String) async {
        do {
            let data = try await APIClient.shared.rawRequest(
                "GET", "admin/verification/media/photos/\(ref)"
            )
            if let img = UIImage(data: data) {
                self.image = img
            } else {
                self.failed = true
            }
        } catch {
            self.failed = true
        }
    }
}

#Preview {
    NavigationStack { VerificationQueueView() }
        .environmentObject(AuthStore())
}
