//
//  DomainModels.swift — модели предметной области.
//  Соответствуют DTO из:
//    apps/api/src/modules/news/news.controller.ts        (NewsListItem)
//    apps/api/src/modules/tasks/tasks.controller.ts      (Task)
//    apps/api/src/modules/notifications/...             (Notification)
//    apps/api/src/modules/team/team.controller.ts        (TeamMember)
//

import Foundation

// MARK: - News

struct NewsItem: Codable, Identifiable {
    let id: String
    let slug: String
    let title: String
    let excerpt: String?
    let coverUrl: String?
    let publishedAt: String?
    let readsCount: Int?
    let likesCount: Int?
    let commentsCount: Int?
    let author: NewsAuthor?

    // Бэк дополнительно возвращает:
    let isPinned: Bool?
    let isImportant: Bool?
    let isRead: Bool?
    let category: NewsCategory?
    let tags: [String]?
    let counters: NewsCounters?
}

struct NewsCategory: Codable {
    let id: String
    let code: String?
    let name: String
    let color: String?
}

struct NewsCounters: Codable {
    let comments: Int?
    let reads: Int?
    let reactions: Int?
}

struct NewsAuthor: Codable {
    let id: String
    let username: String
    let firstName: String?
    let lastName: String?
    let avatarUrl: String?
}

struct NewsListResponse: Codable {
    let data: [NewsItem]
    let meta: PaginationMeta?
}

/// Универсальный мета-блок для списочных эндпоинтов.
/// Разные эндпоинты возвращают разные форматы:
///   /team, /notifications → { total, page, limit }
///   /news, /chats         → { nextCursor }
///   /kudos                → { total }
/// Поэтому ВСЕ поля Optional — иначе декодер падает на эндпоинтах
/// которые отдают только часть полей.
struct PaginationMeta: Codable {
    let total: Int?
    let page: Int?
    let limit: Int?
    let nextCursor: String?
}

// MARK: - Tasks

struct TaskItem: Codable, Identifiable {
    let id: String
    let title: String
    let description: String?
    let status: String        // pending | in_progress | done | cancelled
    let statusComment: String?
    let dueDate: String?
    let createdAt: String
    let creator: TaskCreator?

    var isActive: Bool { status == "pending" || status == "in_progress" }
    var isOverdue: Bool {
        guard isActive, let due = dueDate, let date = ISO8601DateFormatter().date(from: due) else { return false }
        return date < Date()
    }
}

struct TaskCreator: Codable {
    let id: String
    let username: String
    let profile: TaskCreatorProfile?
}

struct TaskCreatorProfile: Codable {
    let firstName: String?
    let lastName: String?
    let avatarUrl: String?
}

// MARK: - Team

struct TeamMember: Codable, Identifiable {
    let id: String
    let username: String
    let firstName: String?
    let lastName: String?
    let position: String?
    let avatarUrl: String?
    let department: Department?
    let telegram: String?
    let roles: [TeamRole]?
    let presenceStatus: String?
}

struct TeamRole: Codable, Equatable {
    let code: String
    let name: String
}

struct TeamListResponse: Codable {
    let data: [TeamMember]
    let meta: PaginationMeta?
}

struct BirthdayUser: Codable, Identifiable {
    let id: String
    let username: String
    let firstName: String?
    let lastName: String?
    let position: String?
    let avatarUrl: String?
    let department: Department?
    let birthDate: String
    let nextBirthday: String
    let daysUntil: Int
    let turningAge: Int

    var displayName: String {
        "\(firstName ?? "") \(lastName ?? "")"
            .trimmingCharacters(in: .whitespaces)
            .ifEmpty(or: username)
    }
}

struct BirthdayListResponse: Codable {
    let data: [BirthdayUser]
}

// MARK: - Notifications
// Реальная модель — NotificationItem в NotificationsView.swift.
// Здесь оставлен старый stub чтобы не ломать AppDelegate, который импортирует
// этот файл (см. agent F report). Имя сохраняем но переименовываем тип чтобы
// не коллидировать с Foundation.Notification.
