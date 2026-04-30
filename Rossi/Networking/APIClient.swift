//
//  APIClient.swift — единая точка для общения с https://rossihelp.ru/api/v1
//
//  Зеркалит логику apps/web/src/lib/api.ts:
//   • Bearer auth (token берём у AuthStore)
//   • Auto-refresh на 401 (POST /auth/refresh)
//   • Single-flight refresh (не дёргаем дважды одновременно)
//   • Cookies сохраняются для refresh-токена
//

import Foundation

enum APIError: Error, LocalizedError {
    case invalidURL
    case network(Error)
    case http(status: Int, body: String?)
    case decoding(Error)
    case unauthorized
    case noResponse
    /// Запрос отменён (view ушёл, .task пересоздался, и т.п.).
    /// Не показываем пользователю — это лайфсайкл, а не ошибка.
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidURL:           return "Некорректный URL"
        case .network(let e):
            // Дружелюбные сообщения вместо «Сеть: …». Системные
            // NSURLError-коды переводим в человеческий русский.
            let ns = e as NSError
            if ns.domain == NSURLErrorDomain {
                switch ns.code {
                case NSURLErrorCancelled:           return nil   // не показываем — отмена
                case NSURLErrorTimedOut:            return "Превышено время ожидания"
                case NSURLErrorNotConnectedToInternet:
                                                    return "Нет подключения к интернету"
                case NSURLErrorNetworkConnectionLost:
                                                    return "Соединение прервано"
                case NSURLErrorCannotFindHost,
                     NSURLErrorCannotConnectToHost: return "Сервер недоступен"
                default: break
                }
            }
            return "Сеть: \(e.localizedDescription)"
        case .cancelled:            return nil
        case .http(let s, let b):
            if let b = b, !b.isEmpty { return "Ошибка \(s): \(b.prefix(200))" }
            return "Ошибка \(s)"
        case .decoding(let e):
            // Включаем подробный путь к проблемному полю для удобства диагностики
            if let dec = e as? DecodingError {
                switch dec {
                case .keyNotFound(let k, let ctx):
                    return "Не пришло поле '\(k.stringValue)' (\(ctx.codingPath.map(\.stringValue).joined(separator: ".")))"
                case .typeMismatch(let t, let ctx):
                    return "Тип '\(t)' не совпал в '\(ctx.codingPath.map(\.stringValue).joined(separator: "."))': \(ctx.debugDescription)"
                case .valueNotFound(let t, let ctx):
                    return "Нет значения '\(t)' в '\(ctx.codingPath.map(\.stringValue).joined(separator: "."))'"
                case .dataCorrupted(let ctx):
                    return "Битые данные: \(ctx.debugDescription)"
                @unknown default: return "Не удалось разобрать ответ"
                }
            }
            return "Не удалось разобрать ответ: \(e.localizedDescription)"
        case .unauthorized:         return "Сессия истекла"
        case .noResponse:           return "Нет ответа от сервера"
        }
    }
}

extension APIError {
    /// Является ли ошибка отменой запроса (lifecycle, не настоящая ошибка).
    /// Используется в UI: при .isCancellation НЕ показываем тост/баннер.
    var isCancellation: Bool {
        if case .cancelled = self { return true }
        if case .network(let e) = self {
            let ns = e as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return true }
            if e is CancellationError { return true }
        }
        return false
    }
}

/// Универсальный конвертер ошибки в строку для UI. Для отмены возвращает nil —
/// это значит «не нужно ничего показывать».
func apiUserMessage(_ error: Error) -> String? {
    if let api = error as? APIError {
        if api.isCancellation { return nil }
        return api.errorDescription
    }
    if error is CancellationError { return nil }
    return error.localizedDescription
}

/// Тонкий wrapper над любой ошибкой, чтобы кодом ответа от бэка
/// не путать с локальной decoding-ошибкой.
struct APIServerErrorBody: Codable {
    let error: APIServerError?
}
struct APIServerError: Codable {
    let code: String?
    let message: String?
}

actor APIClient {
    static let shared = APIClient()

    /// Базовый URL прода. В будущем можно переопределить для staging
    /// через UserDefaults или scheme env var.
    private let baseURL: URL

    /// Сессия использует общее cookie-хранилище — тот же mechanism
    /// что у Safari, не теряем refresh-cookie между запусками.
    private let session: URLSession

    /// Текущий accessToken (кэш в памяти; persist в Keychain через AuthStore).
    private var accessToken: String?

    /// Single-flight refresh: если 401 пришёл одновременно из 5 запросов,
    /// делаем ОДИН вызов /auth/refresh и все остальные ждут его результат.
    private var refreshTask: Task<String, Error>?

    /// Делегат для logout — устанавливается AuthStore.
    private var onUnauthorized: (() async -> Void)?

    /// Демо-режим: если true, ВСЕ запросы перехватываются и отвечаются
    /// синтетическими данными (см. DemoFixtures). Никаких сетевых вызовов
    /// в этом режиме не происходит — приложение полностью оффлайновое.
    private var demoMode: Bool = false

    func setDemoMode(_ enabled: Bool) {
        self.demoMode = enabled
    }

    func isDemoMode() -> Bool { demoMode }

    private init() {
        self.baseURL = URL(string: "https://rossihelp.ru/api/v1")!

        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    // MARK: - Token management

    func setAccessToken(_ token: String?) {
        self.accessToken = token
        if let t = token {
            Keychain.set(t, for: .accessToken)
        } else {
            Keychain.remove(.accessToken)
        }
    }

    /// Текущий access-токен (для подключения к Socket.IO realtime).
    func currentAccessToken() -> String? {
        accessToken
    }

    func loadStoredToken() {
        self.accessToken = Keychain.get(.accessToken)
    }

    func setUnauthorizedHandler(_ handler: @escaping () async -> Void) {
        self.onUnauthorized = handler
    }

    // MARK: - Generic request

    /// Выполнить произвольный HTTP-запрос с авто-decode JSON-ответа.
    /// `skipAuth` — если true, не добавляем Authorization-header (для /auth/login).
    func request<T: Decodable>(
        _ method: String,
        _ path: String,
        body: Encodable? = nil,
        query: [String: String] = [:],
        skipAuth: Bool = false,
        skipRefresh: Bool = false
    ) async throws -> T {
        let data = try await rawRequest(method, path, body: body, query: query,
                                        skipAuth: skipAuth, skipRefresh: skipRefresh)

        if T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(T.self, from: data)
        } catch {
            // Иногда бэк возвращает {ok: true} без полезных полей
            if let empty = try? JSONDecoder().decode(EmptyResponse.self, from: data),
               T.self == EmptyResponse.self {
                return empty as! T
            }
            throw APIError.decoding(error)
        }
    }

    /// Сырой запрос без JSON-decode — для случаев когда нужен только статус.
    @discardableResult
    func rawRequest(
        _ method: String,
        _ path: String,
        body: Encodable? = nil,
        query: [String: String] = [:],
        skipAuth: Bool = false,
        skipRefresh: Bool = false
    ) async throws -> Data {
        // ─── Демо-режим — без сетевых вызовов ─────────────────────────
        if demoMode {
            // Небольшая задержка, чтобы UI выглядел «живым».
            try? await Task.sleep(nanoseconds: 120_000_000)
            let bodyData: Data? = (body as? Data) ?? (try? body.map { try JSONEncoder().encode(AnyEncodable($0)) })
            return DemoFixtures.respond(method: method, path: path, query: query, body: bodyData)
        }

        var components = URLComponents(
            url: baseURL.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path),
            resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw APIError.invalidURL }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        if !skipAuth, let token = accessToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            req.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }

        let (data, response) = try await performRequest(req)

        guard let http = response as? HTTPURLResponse else { throw APIError.noResponse }

        // 401 → пробуем refresh ОДИН раз
        if http.statusCode == 401, !skipAuth, !skipRefresh {
            do {
                _ = try await refreshAccessToken()
            } catch {
                await onUnauthorized?()
                throw APIError.unauthorized
            }
            // Повторяем запрос с новым токеном
            return try await rawRequest(method, path, body: body, query: query,
                                        skipAuth: skipAuth, skipRefresh: true)
        }

        guard (200...299).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8)
            // Пытаемся вытащить human-readable message из {"error":{"message":...}}
            if let serverErr = try? JSONDecoder().decode(APIServerErrorBody.self, from: data),
               let msg = serverErr.error?.message {
                throw APIError.http(status: http.statusCode, body: msg)
            }
            throw APIError.http(status: http.statusCode, body: bodyStr)
        }

        return data
    }

    private func performRequest(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: req)
        } catch {
            // Если задачу отменили (view размонтировался, .task пересоздался,
            // юзер свернул экран и т.п.) — это НЕ ошибка, не показываем
            // «Сеть: отменено» как алерт. Бросаем отдельный case.
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                throw APIError.cancelled
            }
            if error is CancellationError {
                throw APIError.cancelled
            }
            throw APIError.network(error)
        }
    }

    // MARK: - Refresh (single-flight)

    @discardableResult
    func refreshAccessToken() async throws -> String {
        if let task = refreshTask {
            return try await task.value
        }
        let task = Task<String, Error> {
            defer { self.refreshTask = nil }
            let resp: RefreshResponse = try await self.request(
                "POST", "auth/refresh",
                skipAuth: true, skipRefresh: true
            )
            self.setAccessToken(resp.accessToken)
            return resp.accessToken
        }
        self.refreshTask = task
        return try await task.value
    }

    // MARK: - Convenience helpers

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try await request("GET", path, query: query)
    }

    func post<T: Decodable>(_ path: String, body: Encodable? = nil, skipAuth: Bool = false) async throws -> T {
        try await request("POST", path, body: body, skipAuth: skipAuth)
    }

    func patch<T: Decodable>(_ path: String, body: Encodable? = nil) async throws -> T {
        try await request("PATCH", path, body: body)
    }

    func delete(_ path: String) async throws {
        _ = try await rawRequest("DELETE", path)
    }
}

// MARK: - Helpers

struct EmptyResponse: Decodable {}

/// Type-erased Encodable wrapper — иначе Encodable as parameter не пролезет
/// в JSONEncoder().encode(...) из-за existential type ограничений Swift.
struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void
    init<E: Encodable>(_ wrapped: E) {
        self._encode = wrapped.encode
    }
    func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}
