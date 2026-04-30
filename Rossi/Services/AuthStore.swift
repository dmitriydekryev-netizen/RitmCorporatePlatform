//
//  AuthStore.swift — глобальное состояние аутентификации.
//
//  Зеркалит auth.store.ts из веб-версии. Источник истины для:
//   • текущий User (из /auth/refresh или /auth/login)
//   • состояние loading|unauthenticated|authenticated
//   • biometric login через LocalAuthentication
//

import Foundation
import LocalAuthentication

@MainActor
final class AuthStore: ObservableObject {
    enum State: Equatable {
        case loading
        case unauthenticated
        /// 2FA — пользователь ввёл логин/пароль правильно, ждём код из email.
        /// challengeId живёт ~10 минут, потом надо перелогиниться.
        case twoFactor(challengeId: String, emailHint: String?)
        case authenticated(AuthUser)
    }

    @Published var state: State = .loading
    @Published var lastError: String?

    /// Удобный доступ к текущему юзеру из вьюх
    var currentUser: AuthUser? {
        if case .authenticated(let u) = state { return u }
        return nil
    }

    init() {
        Task {
            await APIClient.shared.setUnauthorizedHandler { [weak self] in
                await self?.handleUnauthorized()
            }
        }
    }

    // MARK: - Bootstrap (запуск приложения)

    /// При старте приложения пробуем восстановить сессию.
    /// 1) Если есть accessToken в Keychain — пробуем GET /auth/me
    /// 2) Если 401 — APIClient сам попробует POST /auth/refresh (refresh-cookie)
    /// 3) Если оба не сработали — показываем экран логина
    func bootstrap() async {
        await APIClient.shared.loadStoredToken()

        do {
            let user: AuthUser = try await APIClient.shared.get("auth/me")
            self.state = .authenticated(user)
            // Уже залогинены — обновим APNs регистрацию (silent, если уже granted).
            Task { await AppDelegate.requestPermissionAndRegister() }
            if let t = await APIClient.shared.currentAccessToken() { ChatRealtime.shared.connect(token: t) }
            return
        } catch APIError.unauthorized {
            self.state = .unauthenticated
        } catch {
            // network error / parse error — даём пользователю шанс залогиниться
            self.state = .unauthenticated
        }
    }

    // MARK: - Login

    func login(identifier: String, password: String) async throws -> Bool {
        lastError = nil
        let req = LoginRequest(identifier: identifier, password: password)
        do {
            let resp: LoginResponse = try await APIClient.shared.post("auth/login", body: req, skipAuth: true)

            // 2FA: сервер возвращает {requires2fa, challengeId, emailHint} без токена.
            // Переводим стейт на ввод кода — UI покажет TwoFactorView.
            if resp.requires2fa == true || (resp.accessToken == nil && resp.challengeId != nil) {
                guard let chId = resp.challengeId else {
                    lastError = "Сервер не вернул challengeId для 2FA"
                    return false
                }
                Keychain.set(identifier, for: .savedUsername)
                self.state = .twoFactor(challengeId: chId, emailHint: resp.emailHint)
                return true
            }

            guard let token = resp.accessToken, let user = resp.user else {
                lastError = "Сервер вернул неожиданный ответ. Попробуйте ещё раз."
                return false
            }

            await APIClient.shared.setAccessToken(token)
            Keychain.set(identifier, for: .savedUsername)
            self.state = .authenticated(user)
            // После успешного login запрашиваем APNs permission и регистрируем token.
            Task { await AppDelegate.requestPermissionAndRegister() }
            if let t = await APIClient.shared.currentAccessToken() { ChatRealtime.shared.connect(token: t) }
            return true

        } catch APIError.http(let status, let body) {
            switch status {
            case 401: lastError = body ?? "Неверный логин или пароль"
            case 423: lastError = "Аккаунт временно заблокирован, попробуйте позже"
            case 429: lastError = "Слишком много попыток входа. Подождите минуту."
            default:  lastError = body ?? "Ошибка входа (\(status))"
            }
            return false
        } catch APIError.network(let underlying) {
            lastError = "Нет связи с сервером: \(underlying.localizedDescription)"
            return false
        } catch APIError.decoding(let e) {
            lastError = "Не удалось разобрать ответ сервера: \(e.localizedDescription)"
            return false
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: - 2FA verify + resend

    struct TwoFactorVerifyRequest: Codable {
        let challengeId: String
        let code: String
    }

    struct TwoFactorResendRequest: Codable {
        let challengeId: String
    }

    /// POST /auth/2fa/verify — отправляем 6-значный код из email.
    /// При успехе сервер возвращает accessToken+user, как обычный login.
    func verifyTwoFactor(code: String) async -> Bool {
        guard case .twoFactor(let chId, _) = state else {
            lastError = "Сессия 2FA истекла — войдите снова"
            return false
        }
        lastError = nil
        do {
            let resp: LoginResponse = try await APIClient.shared.post(
                "auth/2fa/verify",
                body: TwoFactorVerifyRequest(challengeId: chId, code: code),
                skipAuth: true
            )
            guard let token = resp.accessToken, let user = resp.user else {
                lastError = "Неверный код"
                return false
            }
            await APIClient.shared.setAccessToken(token)
            self.state = .authenticated(user)
            // После успешной 2FA-проверки тоже регистрируем APNs token.
            Task { await AppDelegate.requestPermissionAndRegister() }
            if let t = await APIClient.shared.currentAccessToken() { ChatRealtime.shared.connect(token: t) }
            return true
        } catch APIError.http(let status, let body) {
            switch status {
            case 401, 400:
                lastError = body ?? "Неверный код"
            case 410:
                lastError = "Срок действия кода истёк. Запросите новый."
            default:
                lastError = body ?? "Ошибка проверки кода (\(status))"
            }
            return false
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// POST /auth/2fa/resend — запросить новый код.
    func resendTwoFactor() async -> Bool {
        guard case .twoFactor(let chId, _) = state else { return false }
        lastError = nil
        do {
            _ = try await APIClient.shared.rawRequest(
                "POST", "auth/2fa/resend",
                body: TwoFactorResendRequest(challengeId: chId),
                skipAuth: true
            )
            return true
        } catch APIError.http(let status, let body) {
            switch status {
            case 429: lastError = "Слишком часто — подождите ~30 секунд"
            case 410: lastError = "Сессия 2FA истекла, войдите заново"
            default:  lastError = body ?? "Не удалось отправить новый код"
            }
            return false
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Отменить 2FA — вернуться на экран логина.
    func cancelTwoFactor() {
        lastError = nil
        state = .unauthenticated
    }

    // MARK: - Demo mode

    /// Локальный демо-вход без обращения к серверу:
    ///   • APIClient переключается на демо-режим (фейковые ответы)
    ///   • устанавливается синтетический super-admin user
    ///   • realtime/socket НЕ подключается
    /// Все мутации в демо превращаются в no-op {ok:true}, никакие реальные
    /// данные не затрагиваются.
    func startDemo() async {
        await APIClient.shared.setDemoMode(true)
        await APIClient.shared.setAccessToken("demo-mock-token")
        let demoUser = AuthUser(
            id: DemoFixtures.userId,
            username: DemoFixtures.userName,
            email: "demo@rossi.local",
            status: "active",
            requirePasswordChange: false,
            roles: ["superadmin"],
            permissions: ["*"],
            profile: UserProfile(
                firstName: DemoFixtures.firstName,
                lastName: DemoFixtures.lastName,
                avatarUrl: nil,
                position: DemoFixtures.position,
                departmentId: "dept-0",
                bio: "Это демо-аккаунт. Действия не сохраняются.",
                phone: nil,
                telegram: nil,
                department: Department(id: "dept-0", name: "Разработка")
            ),
            twoFactorEmailEnabled: false
        )
        self.state = .authenticated(demoUser)
        self.lastError = nil
    }

    var isDemoActive: Bool {
        get async { await APIClient.shared.isDemoMode() }
    }

    // MARK: - Logout

    func logout() async {
        // Из демо-режима выходим без обращения к /auth/logout — там нет сессии.
        if await APIClient.shared.isDemoMode() {
            await APIClient.shared.setDemoMode(false)
            await APIClient.shared.setAccessToken(nil)
            self.state = .unauthenticated
            return
        }
        do {
            _ = try await APIClient.shared.rawRequest("POST", "auth/logout")
        } catch {
            // если /auth/logout упал — всё равно чистим локальное состояние
        }
        await APIClient.shared.setAccessToken(nil)
        Keychain.clearAll()
        ChatRealtime.shared.disconnect()
        self.state = .unauthenticated
    }

    // MARK: - Unauthorized handler (вызывается из APIClient на 401 после неудачного refresh)

    private func handleUnauthorized() async {
        await APIClient.shared.setAccessToken(nil)
        Keychain.remove(.accessToken)
        Keychain.remove(.refreshToken)
        self.state = .unauthenticated
    }

    // MARK: - Biometric helpers

    enum BiometricKind { case faceID, touchID, none }

    /// Какая биометрия доступна на устройстве?
    static func availableBiometric() -> BiometricKind {
        let ctx = LAContext()
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .none
        }
        switch ctx.biometryType {
        case .faceID:  return .faceID
        case .touchID: return .touchID
        default:       return .none
        }
    }

    /// Запросить биометрию у пользователя — возвращает true/false.
    static func evaluateBiometric(reason: String = "Войти в Ритм") async -> Bool {
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Ввести пароль"
        do {
            return try await ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
        } catch {
            return false
        }
    }
}
