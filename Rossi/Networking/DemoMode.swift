//
//  DemoMode.swift — оффлайн «демо-режим» приложения.
//
//  Когда APIClient.demoMode = true, ВСЕ HTTP-запросы перехватываются и
//  возвращают синтетические JSON-ответы — приложение не обращается к
//  реальному бэкенду и не трогает живые данные.
//
//  Демо-юзеру выдаются permissions=["*"] (super-admin), чтобы он увидел
//  все экраны и разделы. Все мутации (POST/PATCH/DELETE) тихо «успешны»
//  и возвращают {ok:true}.
//
//  Точки входа:
//    • AuthStore.startDemo() — включает режим и устанавливает фейкового юзера
//    • APIClient.shared.setDemoMode(true) — переключает route'инг
//    • DemoFixtures.respond(method:path:query:body:) — возвращает байты ответа
//

import Foundation

enum DemoFixtures {

    // ─── Стабильные демо-идентификаторы ──────────────────────────────────────
    static let userId    = "DEMO-0000-0000-0000-USER0000-0001"
    static let userName  = "demo"
    static let firstName = "Демо"
    static let lastName  = "Пользователь"
    static let position  = "Тестировщик"

    // Базовая дата для всех timestamp'ов в демо.
    private static let baseDate: Date = Date()

    private static func iso(_ offsetSeconds: TimeInterval) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: baseDate.addingTimeInterval(offsetSeconds))
    }

    private static func ymd(_ offsetDays: Int) -> String {
        let cal = Calendar(identifier: .gregorian)
        let date = cal.date(byAdding: .day, value: offsetDays, to: baseDate) ?? baseDate
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/Moscow")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    // ─── Главная функция-роутер ──────────────────────────────────────────────
    /// Возвращает байты JSON-ответа для пары (method, path).
    /// Если путь явно не описан, отвечает «общим» fallback'ом (`{data:[]}` или `{ok:true}`),
    /// чтобы UI просто показал пустое состояние, а не ошибку.
    static func respond(method: String, path: String,
                        query: [String: String],
                        body: Data?) -> Data {
        let p = stripLeadingSlash(path)
        let m = method.uppercased()

        // Все мутации демо-юзера — no-op success.
        let isMutation = (m == "POST" || m == "PATCH" || m == "DELETE" || m == "PUT")

        switch (m, p) {

        // ─── Auth ──────────────────────────────────────────────────────────
        case ("GET", "auth/me"):
            return j(demoUser)
        case ("POST", "auth/refresh"):
            return j([
                "accessToken": "demo-access-token-\(Int(Date().timeIntervalSince1970))",
                "accessTokenExpiresIn": 3600,
                "user": demoUser
            ] as [String: Any])
        case ("POST", "auth/logout"):
            return j(["ok": true])

        // ─── Profile / Me ──────────────────────────────────────────────────
        case ("GET", "me"):
            return j(demoUser)
        case ("GET", "me/profile"):
            return j(demoProfile)
        case ("GET", "me/2fa/status"):
            return j(["enabled": false])

        // ─── Dashboard ─────────────────────────────────────────────────────
        case ("GET", "dashboard"), ("GET", "dashboard/summary"):
            return j(demoDashboard)

        // ─── Notifications ─────────────────────────────────────────────────
        case ("GET", "notifications"):
            return j(["data": demoNotifications, "unread": 2])
        case ("GET", "notifications/unread-count"):
            return j(["count": 2])

        // ─── News ──────────────────────────────────────────────────────────
        case ("GET", "news"), ("GET", "news/feed"):
            return j(["data": demoNews, "nextCursor": nil] as [String: Any])
        case ("GET", let path) where path.hasPrefix("news/") && !path.contains("/comments"):
            // GET /news/:id
            return j(demoNews.first ?? [:])
        case ("GET", let path) where path.hasPrefix("news/") && path.hasSuffix("/comments"):
            return j(["data": demoComments] as [String: Any])

        // ─── Chats ─────────────────────────────────────────────────────────
        case ("GET", "chats"):
            return j(["data": demoChats] as [String: Any])
        case ("GET", "chats/self"):
            return j(demoSelfChat)
        case ("GET", let path) where path.hasPrefix("chats/") && path.hasSuffix("/messages"):
            return j(["data": demoMessages, "hasMore": false] as [String: Any])
        case ("GET", let path) where path.hasPrefix("chats/"):
            // GET /chats/:id
            return j(demoChats.first ?? [:])

        // ─── Polls ─────────────────────────────────────────────────────────
        case ("GET", let path) where path.hasPrefix("polls/"):
            return j(demoPoll)

        // ─── Admin health ──────────────────────────────────────────────────
        case ("GET", "admin/health/snapshot"):
            return j([
                "status": "ok",
                "timestamp": iso(0),
                "services": demoHealthServices,
                "metrics": ["cpu": 12, "memory": 38, "disk": 42] as [String: Any]
            ] as [String: Any])
        case ("GET", "admin/health/services"):
            return j(demoHealthServices)

        // ─── Learning ──────────────────────────────────────────────────────
        case ("GET", "learning/my"), ("GET", "learning/courses"):
            return j(demoCourses)
        case ("GET", "learning/progress"):
            return j([] as [Any])
        case ("GET", let path) where path.hasPrefix("learning/courses/") && path.hasSuffix("/view"):
            return j(demoCourseView)

        // ─── Schedule ──────────────────────────────────────────────────────
        case ("GET", "schedule/entries"):
            return j(demoScheduleEntries)
        case ("GET", "schedule/calendar"):
            return j(demoTeamCalendar)
        case ("GET", "schedule/requests"):
            return j(demoScheduleRequests)

        // ─── Bugs ──────────────────────────────────────────────────────────
        case ("GET", "bugs"):
            return j(["data": demoBugs] as [String: Any])
        case ("GET", "bug-columns"):
            return j(demoBugColumns)
        case ("GET", let path) where path.hasPrefix("bugs/"):
            return j(demoBugs.first ?? [:])

        // ─── Tasks ─────────────────────────────────────────────────────────
        case ("GET", "tasks"):
            return j(["data": demoTasks] as [String: Any])

        // ─── Reminders ─────────────────────────────────────────────────────
        case ("GET", "reminders"):
            return j(["data": []] as [String: Any])

        // ─── Feedback ──────────────────────────────────────────────────────
        case ("GET", "feedback"):
            return j(["data": demoFeedback] as [String: Any])

        // ─── Kudos ─────────────────────────────────────────────────────────
        case ("GET", "kudos"):
            return j(["data": demoKudos] as [String: Any])

        // ─── Achievements / Awards ─────────────────────────────────────────
        case ("GET", "achievements"), ("GET", "achievements/all"):
            return j(["data": demoAchievements] as [String: Any])
        case ("GET", "achievements/me"):
            return j(["data": demoAchievements.prefix(2).map { $0 }] as [String: Any])
        case ("GET", "awards"), ("GET", "awards/all"):
            return j(["data": demoAwards] as [String: Any])

        // ─── Team ──────────────────────────────────────────────────────────
        case ("GET", "team"), ("GET", "team/list"):
            return j(["data": demoTeam, "meta": ["total": demoTeam.count]] as [String: Any])
        case ("GET", let path) where path.hasPrefix("team/"):
            return j(demoTeam.first ?? [:])

        // ─── Departments / Roles ───────────────────────────────────────────
        case ("GET", "departments"):
            return j(["Разработка", "Тестирование", "Дизайн"].enumerated().map { idx, n in
                ["id": "dept-\(idx)", "name": n] as [String: Any]
            })
        case ("GET", "roles"):
            return j(demoRoles)
        case ("GET", "permissions"):
            return j(demoPermissions)

        // ─── Posting ───────────────────────────────────────────────────────
        case ("GET", "posting"):
            return j(["data": demoPosts, "meta": ["total": demoPosts.count]] as [String: Any])
        case ("GET", "posting/stats"):
            return j(["draft": 1, "scheduled": 1, "published": 3, "failed": 0])
        case ("GET", "posting/config"):
            return j(["vk": ["connected": true], "telegram": ["connected": true], "staya": ["connected": false]])

        // ─── Admin (модерация Rossi) ───────────────────────────────────────
        case ("GET", "admin/users"):
            return j(["users": demoRossiUsers, "total": demoRossiUsers.count] as [String: Any])
        case ("GET", let path) where path.hasPrefix("admin/users/"):
            return j(demoRossiUserDetail)
        case ("GET", "admin/groups"):
            return j(["groups": demoRossiGroups, "total": demoRossiGroups.count] as [String: Any])
        case ("GET", let path) where path.hasPrefix("admin/groups/") && path.hasSuffix("/info"):
            return j(demoRossiGroups.first ?? [:])
        case ("GET", let path) where path.hasPrefix("admin/groups/") && path.hasSuffix("/messages"):
            return j(["messages": demoRossiGroupMessages] as [String: Any])
        case ("GET", "admin/channels"):
            return j(["channels": demoRossiChannels, "total": demoRossiChannels.count] as [String: Any])
        case ("GET", let path) where path.hasPrefix("admin/channels/") && path.hasSuffix("/info"):
            return j(demoRossiChannels.first ?? [:])
        case ("GET", let path) where path.hasPrefix("admin/channels/") && path.hasSuffix("/posts"):
            return j(["posts": demoRossiChannelPosts] as [String: Any])

        // ─── Support ───────────────────────────────────────────────────────
        case ("GET", "support/threads"):
            return j(["data": []] as [String: Any])

        // ─── Misc ──────────────────────────────────────────────────────────
        case ("GET", "users"), ("GET", "users/me"):
            return j(["data": demoTeam] as [String: Any])
        case ("POST", "files/upload-url"):
            // Возвращаем псевдо-presigned URL — мы его всё равно не используем
            // (демо не отправляет файлы наружу).
            return j([
                "uploadUrl": "https://demo.local/upload",
                "fileId": UUID().uuidString,
                "storageKey": "demo/\(UUID().uuidString)",
                "fileUrl": "https://demo.local/file.bin"
            ] as [String: Any])

        default:
            // Fallback: GET → пустой список; мутация → ok.
            if isMutation {
                return j(["ok": true])
            }
            return j(["data": []] as [String: Any])
        }
    }

    // MARK: - Helpers

    private static func stripLeadingSlash(_ s: String) -> String {
        var r = s
        if r.hasPrefix("/") { r.removeFirst() }
        if r.hasPrefix("api/v1/") { r.removeFirst("api/v1/".count) }
        return r
    }

    private static func j(_ obj: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed]))
            ?? Data("{}".utf8)
    }

    // MARK: - Demo entities

    static var demoUser: [String: Any] {
        return [
            "id": userId,
            "username": userName,
            "email": "demo@rossi.local",
            "status": "active",
            "requirePasswordChange": false,
            // Wildcard — даём все экраны и админ-панели.
            "roles": ["superadmin"],
            "permissions": ["*"],
            "twoFactorEmailEnabled": false,
            "profile": demoProfile
        ]
    }

    static var demoProfile: [String: Any] {
        return [
            "firstName": firstName,
            "lastName": lastName,
            "avatarUrl": NSNull(),
            "position": position,
            "departmentId": "dept-0",
            "bio": "Это демо-аккаунт. Здесь синтетические данные — никаких реальных сообщений или пользователей.",
            "phone": NSNull(),
            "telegram": NSNull(),
            "department": ["id": "dept-0", "name": "Разработка"]
        ]
    }

    static var demoDashboard: [String: Any] {
        return [
            "stats": [
                "newsCount": 3,
                "tasksOpen": 2,
                "bugsOpen": 4,
                "scheduleToday": 1
            ],
            "shortcuts": []
        ]
    }

    static var demoNotifications: [Any] {
        return [
            ["id": "n1", "kind": "system", "title": "Добро пожаловать в демо!",
             "body": "Это синтетические данные. Действия не сохраняются.",
             "createdAt": iso(-60), "isRead": false],
            ["id": "n2", "kind": "chat", "title": "Сообщение из чата",
             "body": "Иван отправил вам сообщение",
             "createdAt": iso(-3600), "isRead": false]
        ]
    }

    static var demoNews: [[String: Any]] {
        return [
            [
                "id": "news-1",
                "title": "Новый релиз приложения 2.5.0",
                "content": "В этом обновлении мы переработали навигацию, добавили опросы в чате и улучшили работу с медиа.",
                "summary": "Переработали навигацию и добавили опросы.",
                "coverUrl": NSNull(),
                "isPinned": true,
                "isImportant": true,
                "tags": ["release", "iOS"],
                "category": ["id": "cat-1", "name": "Релизы"],
                "createdAt": iso(-3600 * 6),
                "publishedAt": iso(-3600 * 6),
                "author": ["id": userId, "username": "demo",
                           "firstName": firstName, "lastName": lastName, "avatarUrl": NSNull()],
                "reactionsCount": ["like": 5, "fire": 2],
                "commentsCount": 1,
                "myReactions": []
            ],
            [
                "id": "news-2",
                "title": "Корпоративный пикник 12 июня",
                "content": "Приглашаем всех на пикник в парке Сокольники. Игры, барбекю, призы — будет весело!",
                "summary": "Пикник в Сокольниках 12 июня.",
                "coverUrl": NSNull(),
                "isPinned": false,
                "isImportant": false,
                "tags": ["events"],
                "category": ["id": "cat-2", "name": "События"],
                "createdAt": iso(-3600 * 24 * 2),
                "publishedAt": iso(-3600 * 24 * 2),
                "author": ["id": "demo-author-2", "username": "anna",
                           "firstName": "Анна", "lastName": "Сидорова", "avatarUrl": NSNull()],
                "reactionsCount": ["heart": 12],
                "commentsCount": 4,
                "myReactions": []
            ],
            [
                "id": "news-3",
                "title": "Открыта вакансия: iOS-разработчик",
                "content": "Расширяем мобильную команду — ищем Senior iOS Developer. Подробности у HR.",
                "summary": "Senior iOS вакансия открыта.",
                "coverUrl": NSNull(),
                "isPinned": false,
                "isImportant": false,
                "tags": ["hr", "vacancy"],
                "category": ["id": "cat-3", "name": "HR"],
                "createdAt": iso(-3600 * 24 * 5),
                "publishedAt": iso(-3600 * 24 * 5),
                "author": ["id": "demo-author-3", "username": "hr",
                           "firstName": "HR", "lastName": "Бот", "avatarUrl": NSNull()],
                "reactionsCount": [:],
                "commentsCount": 0,
                "myReactions": []
            ]
        ]
    }

    static var demoComments: [Any] {
        return [
            [
                "id": "c1",
                "content": "Отличные новости!",
                "createdAt": iso(-3600 * 2),
                "author": ["id": "demo-author-2", "username": "anna",
                           "firstName": "Анна", "lastName": "Сидорова", "avatarUrl": NSNull()]
            ]
        ]
    }

    // ─── Chats ──────────────────────────────────────────────────────────
    static var demoChats: [[String: Any]] {
        return [
            [
                "id": "chat-direct-1",
                "type": "direct",
                "title": "Иван Петров",
                "avatarUrl": NSNull(),
                "lastMessage": [
                    "id": "msg-1",
                    "content": "Привет! Как дела?",
                    "authorId": "demo-author-2",
                    "createdAt": iso(-600)
                ],
                "unreadCount": 1,
                "pinnedAt": NSNull(),
                "members": [
                    ["id": userId, "role": "owner", "firstName": firstName, "lastName": lastName,
                     "avatarUrl": NSNull(), "username": userName, "lastReadMessageId": NSNull()],
                    ["id": "demo-author-2", "role": "member", "firstName": "Иван", "lastName": "Петров",
                     "avatarUrl": NSNull(), "username": "ivan", "lastReadMessageId": NSNull()]
                ],
                "myRole": "owner",
                "lastReadMessageId": NSNull(),
                "pinnedMessage": NSNull()
            ],
            [
                "id": "chat-group-1",
                "type": "group",
                "title": "iOS-команда",
                "avatarUrl": NSNull(),
                "lastMessage": [
                    "id": "msg-2",
                    "content": "Кто тестит сборку 2.5.0?",
                    "authorId": "demo-author-3",
                    "createdAt": iso(-1800)
                ],
                "unreadCount": 3,
                "pinnedAt": iso(-86400 * 7),
                "members": [
                    ["id": userId, "role": "owner", "firstName": firstName, "lastName": lastName,
                     "avatarUrl": NSNull(), "username": userName, "lastReadMessageId": NSNull()],
                    ["id": "demo-author-2", "role": "member", "firstName": "Иван", "lastName": "Петров",
                     "avatarUrl": NSNull(), "username": "ivan", "lastReadMessageId": NSNull()],
                    ["id": "demo-author-3", "role": "member", "firstName": "Мария", "lastName": "Иванова",
                     "avatarUrl": NSNull(), "username": "maria", "lastReadMessageId": NSNull()]
                ],
                "myRole": "owner",
                "lastReadMessageId": NSNull(),
                "pinnedMessage": NSNull()
            ]
        ]
    }

    static var demoSelfChat: [String: Any] {
        return [
            "id": "chat-self",
            "type": "group",
            "title": "__self__",
            "avatarUrl": NSNull(),
            "lastMessage": NSNull(),
            "unreadCount": 0,
            "pinnedAt": NSNull(),
            "members": [
                ["id": userId, "role": "owner", "firstName": firstName, "lastName": lastName,
                 "avatarUrl": NSNull(), "username": userName, "lastReadMessageId": NSNull()]
            ],
            "myRole": "owner",
            "lastReadMessageId": NSNull(),
            "pinnedMessage": NSNull()
        ]
    }

    static var demoMessages: [[String: Any]] {
        return [
            [
                "id": "m1",
                "chatId": "chat-direct-1",
                "authorId": "demo-author-2",
                "content": "Привет! Это демо-чат.",
                "isEdited": false,
                "createdAt": iso(-3600),
                "updatedAt": NSNull(),
                "deletedAt": NSNull(),
                "replyToId": NSNull(),
                "replyTo": NSNull(),
                "author": ["id": "demo-author-2", "username": "ivan",
                           "firstName": "Иван", "lastName": "Петров", "avatarUrl": NSNull()],
                "reactions": [:],
                "myReactions": []
            ],
            [
                "id": "m2",
                "chatId": "chat-direct-1",
                "authorId": userId,
                "content": "Привет, Иван! Тестирую новый релиз.",
                "isEdited": false,
                "createdAt": iso(-3000),
                "updatedAt": NSNull(),
                "deletedAt": NSNull(),
                "replyToId": "m1",
                "replyTo": ["id": "m1", "content": "Привет! Это демо-чат.", "authorName": "Иван Петров"],
                "author": ["id": userId, "username": userName,
                           "firstName": firstName, "lastName": lastName, "avatarUrl": NSNull()],
                "reactions": [:],
                "myReactions": []
            ],
            [
                "id": "m3",
                "chatId": "chat-direct-1",
                "authorId": "demo-author-2",
                "content": "👍 Круто! Давай созвонимся вечером.",
                "isEdited": false,
                "createdAt": iso(-1200),
                "updatedAt": NSNull(),
                "deletedAt": NSNull(),
                "replyToId": NSNull(),
                "replyTo": NSNull(),
                "author": ["id": "demo-author-2", "username": "ivan",
                           "firstName": "Иван", "lastName": "Петров", "avatarUrl": NSNull()],
                "reactions": ["like": 1],
                "myReactions": ["like"]
            ]
        ]
    }

    static var demoPoll: [String: Any] {
        return [
            "id": "demo-poll-1",
            "question": "Какой релиз вам нравится больше?",
            "options": ["2.4.0", "2.5.0 (текущий)", "Жду 2.6.0"],
            "counts": [3, 12, 5],
            "totalVotes": 20,
            "myVotes": [],
            "allowMulti": false,
            "isAnonymous": false,
            "closedAt": NSNull()
        ]
    }

    // ─── Learning ───────────────────────────────────────────────────────
    static var demoCourses: [[String: Any]] {
        return [
            [
                "id": "course-1",
                "title": "Введение в Rossi",
                "description": "Знакомство с экосистемой и основными возможностями.",
                "coverUrl": NSNull(),
                "moduleCount": 2,
                "modulesCount": 2,
                "progressPercent": 35,
                "completed": false
            ],
            [
                "id": "course-2",
                "title": "Этикет общения в чатах",
                "description": "Правила корпоративного общения.",
                "coverUrl": NSNull(),
                "moduleCount": 1,
                "modulesCount": 1,
                "progressPercent": 100,
                "completed": true
            ]
        ]
    }

    static var demoCourseView: [String: Any] {
        return [
            "course": [
                "id": "course-1",
                "title": "Введение в Rossi",
                "description": "Знакомство с экосистемой.",
                "coverUrl": NSNull(),
                "modules": [
                    [
                        "id": "mod-1",
                        "title": "Что такое Rossi",
                        "description": "Обзор продукта",
                        "orderIndex": 0,
                        "blocks": [
                            [
                                "id": "blk-1",
                                "type": "text",
                                "orderIndex": 0,
                                "content": ["text": "Rossi — корпоративная экосистема для команды."]
                            ]
                        ]
                    ]
                ],
                "assignments": []
            ],
            "progress": [
                "progressPercent": 35,
                "completed": false,
                "completedBlocks": [],
                "testResults": [:]
            ]
        ]
    }

    // ─── Schedule ───────────────────────────────────────────────────────
    static var demoScheduleEntries: [Any] {
        return (-3...3).map { offset in
            [
                "id": "entry-\(offset)",
                "date": ymd(offset),
                "type": offset % 7 == 0 ? "dayoff" : "workday",
                "startTime": "09:00",
                "endTime": "18:00",
                "comment": NSNull()
            ] as [String: Any]
        }
    }

    static var demoTeamCalendar: [String: Any] {
        var dict: [String: [Any]] = [:]
        for offset in -7...7 {
            let key = ymd(offset)
            dict[key] = [
                ["userId": userId, "type": "workday", "startTime": "09:00", "endTime": "18:00",
                 "user": ["firstName": firstName, "lastName": lastName, "avatarUrl": NSNull()]],
                ["userId": "demo-author-2", "type": "workday", "startTime": "10:00", "endTime": "19:00",
                 "user": ["firstName": "Иван", "lastName": "Петров", "avatarUrl": NSNull()]],
                ["userId": "demo-author-3", "type": offset == 0 ? "vacation" : "workday",
                 "startTime": "09:00", "endTime": "18:00",
                 "user": ["firstName": "Мария", "lastName": "Иванова", "avatarUrl": NSNull()]]
            ]
        }
        return dict
    }

    static var demoScheduleRequests: [Any] {
        return [
            [
                "id": "req-1", "status": "pending",
                "comment": "Хочу взять отпуск в августе",
                "createdAt": iso(-3600 * 24),
                "reviewedAt": NSNull(),
                "entries": [
                    ["id": "e1", "date": ymd(20), "type": "vacation",
                     "startTime": NSNull(), "endTime": NSNull(), "comment": NSNull()]
                ],
                "user": NSNull(),
                "reviewer": NSNull()
            ]
        ]
    }

    // ─── Bugs ───────────────────────────────────────────────────────────
    static var demoBugs: [[String: Any]] {
        let demoUser: [String: Any] = [
            "id": userId, "username": userName,
            "firstName": firstName, "lastName": lastName, "avatarUrl": NSNull()
        ]
        return [
            [
                "id": "bug-1",
                "title": "В чате не отображается превью видео",
                "description": "При отправке .mov файл показывается как ссылка вместо плеера.",
                "status": "open", "columnKey": "open",
                "priority": "high", "platform": "ios",
                "tags": ["chat", "media"], "appVersion": "2.5.0",
                "attachments": [],
                "reporter": demoUser,
                "assignee": NSNull(),
                "commentsCount": 2,
                "createdAt": iso(-3600 * 24)
            ],
            [
                "id": "bug-2",
                "title": "Демо-режим: отчёт об ошибке",
                "description": "Пример заполненного бага.",
                "status": "in_progress", "columnKey": "in_progress",
                "priority": "medium", "platform": "ios",
                "tags": ["demo"], "appVersion": "2.5.0",
                "attachments": [],
                "reporter": demoUser,
                "assignee": demoUser,
                "commentsCount": 0,
                "createdAt": iso(-3600 * 48)
            ]
        ]
    }

    static var demoBugColumns: [Any] {
        return [
            ["id": "col-1", "key": "open",        "name": "Открыто",     "color": "#3B82F6", "order": 1, "isDefault": true],
            ["id": "col-2", "key": "in_progress", "name": "В работе",     "color": "#F59E0B", "order": 2, "isDefault": false],
            ["id": "col-3", "key": "resolved",    "name": "Решено",       "color": "#10B981", "order": 3, "isDefault": false],
            ["id": "col-4", "key": "closed",      "name": "Закрыто",      "color": "#6B7280", "order": 4, "isDefault": false]
        ]
    }

    // ─── Tasks / Feedback / Kudos / Achievements ───────────────────────
    static var demoTasks: [Any] {
        return [
            ["id": "t1", "title": "Протестировать релиз 2.5.0",
             "status": "in_progress", "priority": "high",
             "createdAt": iso(-3600 * 24)],
            ["id": "t2", "title": "Заполнить график на следующую неделю",
             "status": "pending", "priority": "medium",
             "createdAt": iso(-3600 * 6)]
        ]
    }

    static var demoFeedback: [Any] {
        return [
            ["id": "f1", "kind": "idea",
             "title": "Добавить тёмную тему в редакторе",
             "description": "Удобнее ночью",
             "status": "open",
             "createdAt": iso(-3600 * 72),
             "author": ["id": userId, "username": userName,
                        "firstName": firstName, "lastName": lastName, "avatarUrl": NSNull()]]
        ]
    }

    static var demoKudos: [Any] {
        return [
            ["id": "k1", "message": "Спасибо за быструю помощь с релизом!",
             "createdAt": iso(-3600 * 24),
             "from": ["id": "demo-author-2", "firstName": "Иван", "lastName": "Петров",
                      "username": "ivan", "avatarUrl": NSNull()],
             "to": ["id": userId, "firstName": firstName, "lastName": lastName,
                    "username": userName, "avatarUrl": NSNull()]]
        ]
    }

    static var demoAchievements: [Any] {
        return [
            ["id": "a1", "title": "Первая неделя", "description": "Использовали Ритм 7 дней подряд",
             "iconUrl": NSNull(), "rarity": "common", "earned": true,
             "earnedAt": iso(-3600 * 24)],
            ["id": "a2", "title": "Социальный", "description": "Отправили 100 сообщений",
             "iconUrl": NSNull(), "rarity": "rare", "earned": false]
        ]
    }

    static var demoAwards: [Any] {
        return [
            ["id": "aw1", "title": "Сотрудник месяца",
             "description": "Лучший игрок команды в апреле",
             "icon": "trophy", "color": "#F59E0B"]
        ]
    }

    // ─── Team ──────────────────────────────────────────────────────────
    static var demoTeam: [[String: Any]] {
        return [
            ["id": userId, "username": userName, "firstName": firstName, "lastName": lastName,
             "avatarUrl": NSNull(), "position": position, "department": ["id": "dept-0", "name": "Разработка"],
             "isOnline": true],
            ["id": "demo-author-2", "username": "ivan", "firstName": "Иван", "lastName": "Петров",
             "avatarUrl": NSNull(), "position": "iOS Lead", "department": ["id": "dept-0", "name": "Разработка"],
             "isOnline": true],
            ["id": "demo-author-3", "username": "maria", "firstName": "Мария", "lastName": "Иванова",
             "avatarUrl": NSNull(), "position": "Дизайнер", "department": ["id": "dept-2", "name": "Дизайн"],
             "isOnline": false],
            ["id": "demo-author-4", "username": "anna", "firstName": "Анна", "lastName": "Сидорова",
             "avatarUrl": NSNull(), "position": "QA", "department": ["id": "dept-1", "name": "Тестирование"],
             "isOnline": true]
        ]
    }

    // ─── Roles / Permissions ───────────────────────────────────────────
    static var demoRoles: [Any] {
        return [
            ["id": "r-1", "code": "superadmin", "name": "Супер-админ", "description": "Все права"],
            ["id": "r-2", "code": "tester_ios", "name": "Тестер iOS",  "description": "Тестирование"],
            ["id": "r-3", "code": "developer",  "name": "Разработчик", "description": "Доступ к багам и сборкам"]
        ]
    }

    static var demoPermissions: [Any] {
        return ["news.read", "chat.view", "task.view", "schedule.view"].map {
            ["code": $0, "description": $0]
        }
    }

    // ─── Posting ───────────────────────────────────────────────────────
    static var demoPosts: [[String: Any]] {
        return [
            ["id": "p1", "text": "Демо-пост 1: запланирован на завтра.",
             "status": "scheduled", "platforms": ["vk", "telegram"],
             "vkPostUrl": NSNull(), "tgPostUrl": NSNull(),
             "vkError": NSNull(), "tgError": NSNull(),
             "stayaChatId": NSNull(), "stayaMessageId": NSNull(), "stayaError": NSNull(),
             "scheduledAt": iso(3600 * 24), "publishedAt": NSNull(),
             "createdAt": iso(-3600 * 6), "updatedAt": iso(-3600 * 6),
             "commentsCount": 0,
             "author": ["id": userId, "username": userName,
                        "firstName": firstName, "lastName": lastName, "avatarUrl": NSNull()],
             "attachments": []]
        ]
    }

    // ─── Rossi moderation (admin) ──────────────────────────────────────
    static var demoRossiUsers: [Any] {
        return [
            ["user_id": "rossi-u1", "username": "ivanivanov",
             "name": "Иван", "surname": "Иванов", "avatar_ref": NSNull(),
             "bio": "Демо-пользователь Rossi", "is_online": true, "last_seen": iso(-60)],
            ["user_id": "rossi-u2", "username": "petrov_p",
             "name": "Пётр", "surname": "Петров", "avatar_ref": NSNull(),
             "bio": NSNull(), "is_online": false, "last_seen": iso(-3600 * 5)]
        ]
    }

    static var demoRossiUserDetail: [String: Any] {
        return [
            "user": [
                "user_id": "rossi-u1", "username": "ivanivanov",
                "is_online": true, "last_seen": iso(-60),
                "user_created_at": iso(-3600 * 24 * 30),
                "name": "Иван", "surname": "Иванов",
                "avatar_ref": NSNull(),
                "bio": "Демо-профиль", "is_verified": true,
                "is_premium": false, "badge_type": NSNull()
            ],
            "global_sanctions": [],
            "admin_roles": []
        ]
    }

    static var demoRossiGroups: [[String: Any]] {
        return [
            ["id": "rossi-g1", "title": "Демо-группа Rossi",
             "banned_at": NSNull(), "created_at": iso(-3600 * 24 * 7),
             "members_count": 42]
        ]
    }

    static var demoRossiGroupMessages: [Any] {
        return [
            ["id": "rgm-1", "chat_id": "rossi-g1", "sender_id": "rossi-u1",
             "text": "Привет всем!", "created_at": iso(-3600 * 2),
             "media_kind": NSNull(), "media_ref": NSNull(),
             "sender_username": "ivanivanov", "sender_name": "Иван", "sender_surname": "Иванов"]
        ]
    }

    static var demoRossiChannels: [[String: Any]] {
        return [
            ["id": "rossi-c1", "title": "Демо-канал",
             "is_public": true, "banned_at": NSNull(),
             "created_at": iso(-3600 * 24 * 14),
             "members_count": 1234, "is_verified": true,
             "avatar_url": NSNull()]
        ]
    }

    static var demoHealthServices: [Any] {
        return [
            ["name": "PostgreSQL", "status": "ok", "lastCheck": iso(-30), "latencyMs": 4],
            ["name": "Redis",      "status": "ok", "lastCheck": iso(-30), "latencyMs": 2],
            ["name": "API server", "status": "ok", "lastCheck": iso(-30), "latencyMs": 0]
        ]
    }

    static var demoRossiChannelPosts: [Any] {
        return [
            ["id": "rcp-1", "channel_id": "rossi-c1", "sender_id": "rossi-u1",
             "sender_name": "Иван", "sender_surname": "Иванов",
             "text": "Демо-пост в канале Rossi.",
             "media_ref": NSNull(), "file_ref": NSNull(),
             "created_at": iso(-3600 * 12),
             "comments_count": 3, "views_count": 287]
        ]
    }
}
