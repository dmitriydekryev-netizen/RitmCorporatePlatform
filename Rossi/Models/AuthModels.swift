//
//  AuthModels.swift — DTO для /auth/* endpoints.
//
//  Структуры зеркалят то, что отдаёт NestJS-API. Не трогаем без сверки
//  с apps/api/src/modules/auth/auth.controller.ts.
//

import Foundation

struct LoginRequest: Codable {
    let identifier: String
    let password: String
}

/// Универсальная форма ответа /auth/login и /auth/2fa/verify.
/// 2FA-flow:    requires2fa: true + challengeId + emailHint (без accessToken и user)
/// Normal flow: accessToken + user (+ accessTokenExpiresIn / requirePasswordChange)
struct LoginResponse: Codable {
    let accessToken: String?
    let accessTokenExpiresIn: Int?
    let user: AuthUser?
    let requirePasswordChange: Bool?

    // 2FA branch
    let requires2fa: Bool?
    let method: String?
    let challengeId: String?
    let emailHint: String?
}

struct RefreshResponse: Codable {
    let accessToken: String
    let accessTokenExpiresIn: Int?
    let user: AuthUser?
}

/// User-объект, возвращаемый /auth/login и /auth/me.
/// Зеркалит apps/api/src/modules/auth/auth.service.ts → buildSession().
struct AuthUser: Codable, Identifiable, Equatable {
    let id: String
    let username: String
    let email: String?
    let status: String?
    let requirePasswordChange: Bool?
    let roles: [String]?
    let permissions: [String]?
    let profile: UserProfile?
    // Настройки 2FA — приходят только из /auth/me
    let twoFactorEmailEnabled: Bool?
}

/// Профиль внутри user-объекта. Поля совпадают с тем, что возвращает
/// auth.service.ts при логине (firstName/lastName/position/avatarUrl/departmentId).
/// Дополнительные поля (bio/phone/telegram/department) приходят с /team/:id и /profile/:id.
struct UserProfile: Codable, Equatable {
    let firstName: String?
    let lastName: String?
    let avatarUrl: String?
    let position: String?
    let departmentId: String?
    // Расширенные — могут быть пустыми в ответе login, заполняются /profile/:id
    let bio: String?
    let phone: String?
    let telegram: String?
    let department: Department?
}

struct Department: Codable, Equatable {
    let id: String
    let name: String
}

extension AuthUser {
    var displayName: String {
        let first = profile?.firstName ?? ""
        let last  = profile?.lastName ?? ""
        let full = "\(first) \(last)".trimmingCharacters(in: .whitespaces)
        return full.isEmpty ? username : full
    }

    var initials: String {
        let f = profile?.firstName?.first.map(String.init) ?? ""
        let l = profile?.lastName?.first.map(String.init) ?? ""
        let combo = (f + l).uppercased()
        return combo.isEmpty ? String(username.prefix(2)).uppercased() : combo
    }
}
