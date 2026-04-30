//
//  FeedbackView.swift — модуль идей и багрепортов.
//
//  Источник данных:
//   • GET    /feedback?status=&category=&page=&limit=
//   • GET    /feedback/counts
//   • GET    /feedback/:id
//   • POST   /feedback                   — создать (idea | bug | improvement | question)
//   • PATCH  /feedback/:id/status        — поменять статус (только feedback.manage)
//   • DELETE /feedback/:id               — удалить (свою или админ)
//
//  iOS 16+ (без ContentUnavailableView, без iOS 17 searchable стилей).
//  Дизайн зеркальный с web (Next.js + Tailwind) — DS-примитивы из Theme.swift.
//

import SwiftUI
import PhotosUI
import UIKit

// MARK: - Models

struct FeedbackItem: Codable, Identifiable {
    let id: String
    let title: String
    let description: String?
    /// Сервер использует поле `type` (см. apps/api/src/modules/feedback/feedback.service.ts):
    ///   "idea" | "suggestion" | "bug"
    let type: String?
    /// "new" | "in_review" | "in_progress" | "approved" | "rejected"
    let status: String?
    let attachments: [String]?
    let votesCount: Int?
    let myVote: Int?
    let createdAt: String
    let updatedAt: String?
    let resolvedAt: String?
    /// Сервер шлёт adminComment (не resolverComment).
    let adminComment: String?
    let author: FeedbackAuthor?
    let resolver: FeedbackAuthor?

    /// Совместимость со старым кодом — мапим в category для UI-фильтров.
    var category: String { type ?? "idea" }
    /// Старое имя для UI.
    var resolverComment: String? { adminComment }
}

struct FeedbackAuthor: Codable {
    let id: String
    let username: String
    let firstName: String?
    let lastName: String?
    let avatarUrl: String?

    var fullName: String {
        "\(firstName ?? "") \(lastName ?? "")"
            .trimmingCharacters(in: .whitespaces)
            .ifEmpty(or: username)
    }
}

struct FeedbackListResponse: Codable {
    let data: [FeedbackItem]
    let meta: PaginationMeta?
}

// MARK: - Filter

private enum FeedbackFilter: String, CaseIterable, Identifiable {
    case all, idea, suggestion, bug
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:        return "Все"
        case .idea:       return "Идеи"
        case .suggestion: return "Предложения"
        case .bug:        return "Баги"
        }
    }

    var categoryParam: String? {
        switch self {
        case .all:        return nil
        case .idea:       return "idea"
        case .suggestion: return "suggestion"
        case .bug:        return "bug"
        }
    }
}

/// Фильтр по статусу заявки. Сервер использует значения:
///   "new" | "in_review" | "in_progress" | "approved" | "rejected"
private enum FeedbackStatusFilter: String, CaseIterable, Identifiable {
    case all, new, inReview = "in_review", inProgress = "in_progress", approved, rejected
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:        return "Любой статус"
        case .new:        return "Новые"
        case .inReview:   return "На рассмотрении"
        case .inProgress: return "В работе"
        case .approved:   return "Одобрено"
        case .rejected:   return "Отклонено"
        }
    }

    var statusParam: String? {
        self == .all ? nil : rawValue
    }
}

// MARK: - Category / Status helpers

private enum FeedbackCategory {
    static func icon(for category: String) -> String {
        switch category {
        case "idea":        return "lightbulb.fill"
        case "bug":         return "ladybug.fill"
        case "improvement": return "sparkles"
        case "suggestion":  return "sparkles"
        case "question":    return "questionmark.circle.fill"
        default:            return "bubble.left.fill"
        }
    }

    static func color(for category: String) -> Color {
        switch category {
        case "idea":        return Theme.warning
        case "bug":         return Theme.danger
        case "improvement": return Theme.purple
        case "suggestion":  return Theme.purple
        case "question":    return Theme.info
        default:            return Theme.accent
        }
    }

    static func label(for category: String) -> String {
        switch category {
        case "idea":        return "Идея"
        case "bug":         return "Баг"
        case "improvement": return "Улучшение"
        case "suggestion":  return "Предложение"
        case "question":    return "Вопрос"
        default:            return category
        }
    }
}

private enum FeedbackStatus {
    static func color(for status: String) -> Color {
        switch status {
        case "new":         return Theme.accent
        case "in_review":   return Theme.warning
        case "in_progress": return Theme.info
        case "approved":    return Theme.success
        case "accepted":    return Theme.success
        case "rejected":    return Theme.danger
        case "implemented": return Theme.success
        case "done":        return Theme.success
        default:            return Color.secondary
        }
    }

    static func label(for status: String) -> String {
        switch status {
        case "new":         return "Новое"
        case "in_review":   return "На рассмотрении"
        case "in_progress": return "В работе"
        case "approved":    return "Одобрено"
        case "accepted":    return "Принято"
        case "rejected":    return "Отклонено"
        case "implemented": return "Реализовано"
        case "done":        return "Готово"
        default:            return status
        }
    }
}

// MARK: - FeedbackView

struct FeedbackView: View {
    @State private var items: [FeedbackItem] = []
    @State private var loading = true
    @State private var lastError: String?
    @State private var filter: FeedbackFilter = .all
    @State private var statusFilter: FeedbackStatusFilter = .all

    @State private var showingCreateSheet = false

    var body: some View {
        ZStack {
            Theme.pageBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    DSPageTitle(text: "Идеи и баги", subtitle: "Что улучшим вместе")

                    Picker("Категория", selection: $filter) {
                        ForEach(FeedbackFilter.allCases) { f in
                            Text(f.title).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: filter) { _ in
                        Task { await reload() }
                    }

                    // Фильтр по статусу через Menu
                    HStack(spacing: 8) {
                        Menu {
                            ForEach(FeedbackStatusFilter.allCases) { s in
                                Button {
                                    statusFilter = s
                                    Task { await reload() }
                                } label: {
                                    HStack {
                                        Text(s.title)
                                        if s == statusFilter {
                                            Spacer()
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "line.3.horizontal.decrease.circle")
                                    .font(.system(size: 12, weight: .semibold))
                                Text(statusFilter.title)
                                    .font(.system(size: 12, weight: .semibold))
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .foregroundColor(statusFilter == .all ? Theme.textSecondary : .white)
                            .background(
                                Capsule()
                                    .fill(statusFilter == .all ? Theme.surfaceBackground : Theme.accent)
                            )
                            .overlay(
                                Capsule().strokeBorder(
                                    statusFilter == .all ? Theme.border : Color.clear,
                                    lineWidth: 0.5
                                )
                            )
                        }

                        if statusFilter != .all {
                            Button {
                                statusFilter = .all
                                Task { await reload() }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(Theme.textTertiary)
                                    .font(.system(size: 16))
                            }
                            .buttonStyle(.plain)
                        }

                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)

                content
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                }
                .tint(Theme.accent)
            }
        }
        .refreshable { await reload() }
        .task { if items.isEmpty { await reload() } }
        .sheet(isPresented: $showingCreateSheet) {
            CreateFeedbackSheet { _ in
                await reload()
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if loading && items.isEmpty {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(0..<4, id: \.self) { _ in skeletonCard }
                }
                .padding(16)
            }
        } else if let err = lastError, items.isEmpty {
            ScrollView {
                EmptyStateView(
                    icon: "exclamationmark.triangle",
                    title: "Не удалось загрузить",
                    description: err
                )
            }
        } else if items.isEmpty {
            ScrollView {
                emptyState
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(items) { item in
                        NavigationLink {
                            FeedbackDetailView(id: item.id, onChanged: { await reload() })
                        } label: {
                            FeedbackCard(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                    Color.clear.frame(height: TabBarVisibility.reservedHeight)
                }
                .padding(16)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch filter {
        case .all:
            EmptyStateView(
                icon: "bubble.left.and.bubble.right",
                title: "Пока нет предложений",
                description: statusFilter == .all
                    ? "Поделитесь идеей или сообщите о баге — нажмите «+» в углу"
                    : "Под выбранный статус ничего не нашлось"
            )
        case .idea:
            EmptyStateView(
                icon: "lightbulb",
                title: "Нет идей",
                description: "Будьте первым, кто предложит улучшение"
            )
        case .bug:
            EmptyStateView(
                icon: "ladybug",
                title: "Багов не обнаружено",
                description: "Если что-то сломалось — расскажите команде"
            )
        case .suggestion:
            EmptyStateView(
                icon: "sparkles",
                title: "Нет предложений",
                description: "Здесь появятся идеи по улучшению существующих фич"
            )
        }
    }

    private var skeletonCard: some View {
        RoundedRectangle(cornerRadius: Radius.xl)
            .fill(Theme.surfaceBackground)
            .frame(height: 120)
            .redacted(reason: .placeholder)
            .shimmering()
    }

    // MARK: - Networking

    private func reload() async {
        loading = true
        lastError = nil
        defer { loading = false }

        var query: [String: String] = ["limit": "50"]
        if let cat = filter.categoryParam {
            query["category"] = cat
            // Сервер использует поле `type` — шлём оба для совместимости.
            query["type"] = cat
        }
        if let st = statusFilter.statusParam {
            query["status"] = st
        }

        do {
            let resp: FeedbackListResponse = try await APIClient.shared.get("feedback", query: query)
            self.items = resp.data
        } catch {
            self.lastError = apiUserMessage(error)
        }
    }
}

// MARK: - FeedbackCard

private struct FeedbackCard: View {
    let item: FeedbackItem

    var body: some View {
        DSCard(radius: Radius.xl, padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                // Header: иконка категории + title + статус
                HStack(alignment: .top, spacing: 12) {
                    DSIconTile(
                        systemImage: FeedbackCategory.icon(for: item.category),
                        color: FeedbackCategory.color(for: item.category),
                        size: 36
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(FeedbackCategory.label(for: item.category))
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textTertiary)
                    }

                    Spacer(minLength: 8)

                    StatusBadge(status: item.status ?? "new")
                }

                // Description
                if (item.description?.isEmpty == false) {
                    Text(item.description ?? "")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Footer
                HStack(spacing: 8) {
                    if let author = item.author {
                        AvatarCircle(url: author.avatarUrl, name: author.fullName)
                            .frame(width: 22, height: 22)
                        Text(author.fullName)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                    }

                    if let date = ISO8601DateFormatter().date(from: item.createdAt) {
                        Text("·")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textTertiary)
                        Text(relativeTime(from: date))
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textTertiary)
                    }

                    Spacer(minLength: 0)

                    if let v = item.votesCount, v > 0 {
                        DSBadge(text: "\(v)", systemImage: "hand.thumbsup.fill", color: Theme.accent, filled: false)
                    }
                }
            }
        }
    }
}

// MARK: - StatusBadge

private struct StatusBadge: View {
    let status: String

    var body: some View {
        DSBadge(
            text: FeedbackStatus.label(for: status),
            color: FeedbackStatus.color(for: status),
            filled: false
        )
    }
}

// MARK: - FeedbackDetailView

struct FeedbackDetailView: View {
    let id: String
    let onChanged: () async -> Void

    @State private var item: FeedbackItem?
    @State private var loading = true
    @State private var lastError: String?

    var body: some View {
        ZStack {
            Theme.pageBackground.ignoresSafeArea()

            if loading && item == nil {
                ProgressView().tint(Theme.accent)
            } else if let item {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // Header card
                        DSCard(radius: Radius.xl2, padding: 18) {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(alignment: .top, spacing: 12) {
                                    DSIconTile(
                                        systemImage: FeedbackCategory.icon(for: item.category),
                                        color: FeedbackCategory.color(for: item.category),
                                        size: 44
                                    )

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(FeedbackCategory.label(for: item.category))
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(FeedbackCategory.color(for: item.category))
                                        Text(item.title)
                                            .font(.system(size: 21, weight: .bold))
                                            .tracking(-0.3)
                                            .foregroundColor(Theme.textPrimary)
                                            .multilineTextAlignment(.leading)
                                    }
                                    Spacer(minLength: 0)
                                }

                                HStack(spacing: 8) {
                                    StatusBadge(status: item.status ?? "new")
                                    if let date = ISO8601DateFormatter().date(from: item.createdAt) {
                                        Text(relativeTime(from: date))
                                            .font(.system(size: 12))
                                            .foregroundColor(Theme.textTertiary)
                                    }
                                    Spacer()
                                }
                            }
                        }

                        // Поздравление при done/implemented
                        if item.status == "done" || item.status == "implemented" {
                            doneBanner
                        }

                        // Author
                        if let author = item.author {
                            DSCard(radius: Radius.lg, padding: 12) {
                                HStack(spacing: 10) {
                                    AvatarCircle(url: author.avatarUrl, name: author.fullName)
                                        .frame(width: 36, height: 36)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Автор")
                                            .font(.system(size: 11))
                                            .foregroundColor(Theme.textTertiary)
                                        Text(author.fullName)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(Theme.textPrimary)
                                    }
                                    Spacer()
                                }
                            }
                        }

                        // Description
                        if (item.description?.isEmpty == false) {
                            DSCard(radius: Radius.xl, padding: 14) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Описание")
                                        .font(.system(size: 11, weight: .semibold))
                                        .tracking(0.6)
                                        .textCase(.uppercase)
                                        .foregroundColor(Theme.textTertiary)
                                    Text(item.description ?? "")
                                        .font(.system(size: 15))
                                        .foregroundColor(Theme.textPrimary)
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }

                        // Attachments
                        if let atts = item.attachments, !atts.isEmpty {
                            DSCard(radius: Radius.xl, padding: 14) {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Вложения (\(atts.count))")
                                        .font(.system(size: 11, weight: .semibold))
                                        .tracking(0.6)
                                        .textCase(.uppercase)
                                        .foregroundColor(Theme.textTertiary)
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 8) {
                                            ForEach(Array(atts.enumerated()), id: \.offset) { _, raw in
                                                if let u = URL(string: ensureAbsolute(raw)) {
                                                    AsyncImage(url: u) { phase in
                                                        switch phase {
                                                        case .success(let img):
                                                            img.resizable().scaledToFill()
                                                        default:
                                                            Theme.pageBackground
                                                        }
                                                    }
                                                    .frame(width: 110, height: 110)
                                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: 10)
                                                            .strokeBorder(Theme.border, lineWidth: 0.5)
                                                    )
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // Admin / resolver comment — отрисовываем как «Ответ модератора»
                        // в жёлтом DSCard (Theme.warning).
                        if let comment = item.adminComment, !comment.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 6) {
                                    Image(systemName: "shield.lefthalf.filled")
                                        .foregroundColor(Theme.warning)
                                    Text("Ответ модератора")
                                        .font(.system(size: 11, weight: .semibold))
                                        .tracking(0.6)
                                        .textCase(.uppercase)
                                        .foregroundColor(Theme.warning)
                                }
                                Text(comment)
                                    .font(.system(size: 15))
                                    .foregroundColor(Theme.textPrimary)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                if let resolved = item.resolvedAt,
                                   let d = ISO8601DateFormatter().date(from: resolved) {
                                    Text(relativeTime(from: d))
                                        .font(.system(size: 11))
                                        .foregroundColor(Theme.textTertiary)
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.warning.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                                    .strokeBorder(Theme.warning.opacity(0.35), lineWidth: 1)
                            )
                        }

                        // Поддержка через web
                        if let url = URL(string: "https://rossihelp.ru/feedback") {
                            Link(destination: url) {
                                HStack(spacing: 8) {
                                    Image(systemName: "hand.thumbsup.fill")
                                    Text(supportButtonLabel(votes: item.votesCount ?? 0))
                                }
                            }
                            .buttonStyle(.plain)
                            .modifier(SecondaryLinkStyle())
                        }

                        if let err = lastError {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(Theme.danger)
                                Text(err)
                                    .font(.footnote)
                                    .foregroundColor(Theme.danger)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.danger.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                        }
                    }
                    .padding(16)
                }
            } else if let err = lastError {
                EmptyStateView(
                    icon: "exclamationmark.triangle",
                    title: "Не удалось загрузить",
                    description: err
                )
            } else {
                EmptyStateView(
                    icon: "tray",
                    title: "Запись не найдена",
                    description: nil
                )
            }
        }
        .navigationTitle("Предложение")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { if item == nil { await load() } }
    }

    private func supportButtonLabel(votes: Int) -> String {
        if votes > 0 {
            return "Поддержать на сайте · \(votes)"
        }
        return "Поддержать на сайте"
    }

    private var doneBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "party.popper.fill")
                .font(.system(size: 24))
                .foregroundColor(Theme.success)
            VStack(alignment: .leading, spacing: 2) {
                Text("Спасибо за вклад!")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text("Это предложение реализовано — благодаря таким идеям продукт становится лучше.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.leading)
            }
            Spacer()
        }
        .padding(14)
        .background(
            LinearGradient(
                colors: [Theme.success.opacity(0.18), Theme.accent.opacity(0.08)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
    }

    // MARK: - Networking

    private func load() async {
        loading = true
        lastError = nil
        defer { loading = false }
        do {
            let fetched: FeedbackItem = try await APIClient.shared.get("feedback/\(id)")
            self.item = fetched
        } catch {
            self.lastError = apiUserMessage(error)
        }
    }
}

private struct SecondaryLinkStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 14, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundColor(Theme.textPrimary)
            .background(Theme.surfaceBackground)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md)
                    .strokeBorder(Theme.borderStrong, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }
}

// MARK: - CreateFeedbackSheet

struct CreateFeedbackSheet: View {
    let onCreated: (FeedbackItem) async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var category: String = "idea"
    @State private var title: String = ""
    @State private var description: String = ""

    @State private var attachments: [String] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var uploadingCount = 0

    @State private var sending = false
    @State private var lastError: String?

    private let categories: [(value: String, label: String, icon: String)] = [
        ("idea",        "Идея",       "lightbulb.fill"),
        ("bug",         "Баг",        "ladybug.fill"),
        ("improvement", "Улучшение",  "sparkles"),
        ("question",    "Вопрос",     "questionmark.circle.fill")
    ]

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValid: Bool {
        !trimmedTitle.isEmpty && trimmedTitle.count <= 120
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Категория") {
                    Picker("Категория", selection: $category) {
                        ForEach(categories, id: \.value) { c in
                            Label(c.label, systemImage: c.icon).tag(c.value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Section {
                    TextField("Краткое название", text: $title, axis: .vertical)
                        .lineLimit(1...3)
                } header: {
                    Text("Заголовок")
                } footer: {
                    HStack {
                        if title.count > 120 {
                            Text("Слишком длинно (макс. 120)")
                                .foregroundColor(Theme.danger)
                        } else {
                            Text("Чем короче и понятнее — тем лучше")
                        }
                        Spacer()
                        Text("\(title.count)/120")
                            .foregroundColor(title.count > 120 ? Theme.danger : .secondary)
                            .monospacedDigit()
                    }
                    .font(.caption2)
                }

                Section("Описание") {
                    ZStack(alignment: .topLeading) {
                        if description.isEmpty {
                            Text("Опишите подробнее: что предлагаете или что сломалось, как воспроизвести и что вы ожидали увидеть.")
                                .font(.body)
                                .foregroundColor(Theme.textTertiary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $description)
                            .frame(minHeight: 140)
                            .scrollContentBackground(.hidden)
                    }
                }

                Section {
                    PhotosPicker(selection: $photoItems, maxSelectionCount: 5,
                                 matching: .any(of: [.images, .videos])) {
                        Label(
                            uploadingCount > 0
                                ? "Загружаю \(uploadingCount)…"
                                : "Прикрепить фото или видео",
                            systemImage: "paperclip"
                        )
                    }
                    .onChange(of: photoItems) { items in
                        Task { await handleAttachments(items) }
                    }

                    if !attachments.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(attachments.enumerated()), id: \.offset) { _, url in
                                    if let u = URL(string: ensureAbsolute(url)) {
                                        ZStack(alignment: .topTrailing) {
                                            AsyncImage(url: u) { phase in
                                                switch phase {
                                                case .success(let i): i.resizable().scaledToFill()
                                                default: Theme.pageBackground
                                                }
                                            }
                                            .frame(width: 70, height: 70)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            Button {
                                                attachments.removeAll { $0 == url }
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .foregroundColor(.white)
                                                    .background(Color.black.opacity(0.5).clipShape(Circle()))
                                                    .font(.system(size: 16))
                                            }
                                            .offset(x: 4, y: -4)
                                        }
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Вложения (\(attachments.count))")
                }

                if let err = lastError {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(Theme.danger)
                            Text(err)
                                .font(.footnote)
                                .foregroundColor(Theme.danger)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.pageBackground)
            .navigationTitle("Новое предложение")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Отмена") { dismiss() }
                        .tint(Theme.accent)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await create() }
                    } label: {
                        if sending {
                            ProgressView().tint(Theme.accent)
                        } else {
                            Text("Отправить").fontWeight(.semibold)
                        }
                    }
                    .disabled(!isValid || sending || uploadingCount > 0)
                    .tint(Theme.accent)
                }
            }
        }
    }

    private func create() async {
        struct Body: Encodable {
            let title: String
            let description: String
            let category: String
            let type: String
            let attachments: [String]
        }

        sending = true
        lastError = nil
        defer { sending = false }

        let body = Body(
            title: trimmedTitle,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            category: category,
            // Сервер использует поле `type` — отправляем оба для совместимости.
            type: category,
            attachments: attachments
        )

        do {
            let created: FeedbackItem = try await APIClient.shared.post("feedback", body: body)
            await onCreated(created)
            dismiss()
        } catch {
            self.lastError = apiUserMessage(error)
        }
    }

    /// Загружает выбранные файлы через presigned-S3 механизм
    /// (см. BugsView.swift — POST /files/upload-url, kind: "feedback_attachment").
    private func handleAttachments(_ items: [PhotosPickerItem]) async {
        for item in items {
            uploadingCount += 1
            defer { uploadingCount -= 1 }
            do {
                guard let raw = try await item.loadTransferable(type: Data.self) else { continue }
                let mime: String
                let ext: String
                if let _ = UIImage(data: raw) {
                    mime = "image/jpeg"
                    ext = "jpg"
                } else {
                    mime = "application/octet-stream"
                    ext = "bin"
                }
                let outData: Data = (UIImage(data: raw)?.jpegData(compressionQuality: 0.85)) ?? raw
                let req = FeedbackUploadUrlRequest(
                    kind: "feedback_attachment",
                    filename: "feedback-\(Int(Date().timeIntervalSince1970)).\(ext)",
                    mime: mime,
                    size: outData.count
                )
                let resp: FeedbackUploadUrlResponse = try await APIClient.shared.request(
                    "POST", "files/upload-url", body: req
                )
                guard let putURL = URL(string: resp.uploadUrl) else { continue }
                var putReq = URLRequest(url: putURL)
                putReq.httpMethod = "PUT"
                putReq.setValue(mime, forHTTPHeaderField: "Content-Type")
                let (_, response) = try await URLSession.shared.upload(for: putReq, from: outData)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    lastError = "Загрузка не удалась (\(http.statusCode))"
                    continue
                }
                attachments.append(resp.fileUrl)
            } catch {
                lastError = apiUserMessage(error)
            }
        }
        photoItems.removeAll()
    }
}

private struct FeedbackUploadUrlRequest: Encodable {
    let kind: String
    let filename: String
    let mime: String
    let size: Int
}

private struct FeedbackUploadUrlResponse: Decodable {
    let uploadUrl: String
    let fileId: String?
    let storageKey: String?
    let fileUrl: String
}

#Preview {
    NavigationStack { FeedbackView() }
}
