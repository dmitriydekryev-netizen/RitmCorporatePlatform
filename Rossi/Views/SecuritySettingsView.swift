//
//  SecuritySettingsView.swift — отдельный экран безопасности.
//
//  Зеркалит apps/web/src/app/(app)/settings/security/page.tsx и
//  блок «Двух-этапная аутентификация» из settings/page.tsx:
//   • GET  /auth/me                          — узнаём, включена ли email-2FA
//   • POST /auth/2fa/toggle      { enabled } — переключаем 2FA
//   • GET  /security/devices                 — список активных сессий
//   • DELETE /security/devices/:id           — отозвать конкретное устройство
//   • POST /security/devices/revoke-all-other — выйти везде, кроме текущего
//
//  Если эндпоинт отдаёт 404 / 5xx — gracefully показываем «скоро будет».
//

import SwiftUI
import LocalAuthentication

// MARK: - DTO

struct SecurityMeResponse: Codable {
    let id: String
    let email: String?
    let twoFactorEmailEnabled: Bool?
}

struct SecurityDevice: Codable, Identifiable, Hashable {
    let id: String
    let ip: String?
    let userAgent: String?
    let device: SecurityDeviceInfo?
    let createdAt: String?
    let lastUsedAt: String?
    let isCurrent: Bool?
}

struct SecurityDeviceInfo: Codable, Hashable {
    let browser: String?
    let os: String?
    let kind: String?  // "mobile" | "tablet" | "desktop"
}

struct SecurityDevicesResponse: Codable {
    let data: [SecurityDevice]
}

struct TwoFactorToggleBody: Encodable {
    let enabled: Bool
}

// MARK: - View

struct SecuritySettingsView: View {
    @EnvironmentObject var auth: AuthStore

    // 2FA
    @State private var twoFactorEnabled: Bool = false
    @State private var twoFactorLoading: Bool = false
    @State private var twoFactorEmail: String? = nil
    @State private var twoFactorError: String? = nil

    // Devices
    @State private var devices: [SecurityDevice] = []
    @State private var devicesLoading: Bool = false
    @State private var devicesUnavailable: Bool = false
    @State private var devicesError: String? = nil

    // Logout-all confirmation
    @State private var confirmLogoutAll = false
    @State private var loggingOutAll = false
    @State private var revokingDeviceId: String? = nil

    // Биометрия (Face ID / Touch ID)
    @AppStorage("biometricLoginEnabled") private var biometricLoginEnabled: Bool = false
    @AppStorage("quickLoginEnabled") private var quickLoginEnabled: Bool = false
    @State private var biometricError: String? = nil
    @State private var biometricLoading: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {

                // ─── Способы входа ───────────────────────────────────
                VStack(alignment: .leading, spacing: 6) {
                    DSSectionHeader("Способы входа")
                    DSCard(radius: Radius.xl, padding: 0) {
                        VStack(spacing: 0) {
                            // 1. Email-2FA
                            twoFactorRow

                            loginMethodSeparator

                            // 2. Face ID / Touch ID
                            biometricRow

                            loginMethodSeparator

                            // 3. Быстрый вход (quick-login)
                            quickLoginRow
                        }
                        .padding(.vertical, 4)
                    }
                    if let err = twoFactorError {
                        Text(err)
                            .font(.dsCaption)
                            .foregroundColor(Theme.danger)
                            .padding(.horizontal, 4)
                    }
                    if let err = biometricError {
                        Text(err)
                            .font(.dsCaption)
                            .foregroundColor(Theme.danger)
                            .padding(.horizontal, 4)
                    }
                }

                // ─── Активные сессии ────────────────────────────────
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        DSSectionHeader("Активные сессии")
                        Spacer()
                        if !devices.isEmpty && devices.count > 1 {
                            Button {
                                confirmLogoutAll = true
                            } label: {
                                Text("Выйти везде")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(Theme.danger)
                            }
                            .padding(.bottom, 6)
                        }
                    }

                    DSCard(radius: Radius.xl, padding: 0) {
                        if devicesLoading {
                            HStack {
                                Spacer()
                                ProgressView().tint(Theme.accent)
                                Spacer()
                            }
                            .padding(.vertical, 24)
                        } else if devicesUnavailable {
                            VStack(spacing: 8) {
                                Image(systemName: "clock.badge.questionmark")
                                    .font(.system(size: 28, weight: .light))
                                    .foregroundColor(Theme.textTertiary)
                                Text("Скоро будет")
                                    .font(.dsBodyLG)
                                    .foregroundColor(Theme.textPrimary)
                                Text("Управление сессиями появится в следующих обновлениях.")
                                    .font(.dsCaption)
                                    .foregroundColor(Theme.textTertiary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(20)
                        } else if devices.isEmpty {
                            VStack(spacing: 6) {
                                Text("Нет активных сессий")
                                    .font(.dsBody)
                                    .foregroundColor(Theme.textTertiary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(20)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(devices.enumerated()), id: \.element.id) { idx, dev in
                                    deviceRow(dev)
                                    if idx < devices.count - 1 {
                                        Rectangle()
                                            .fill(Theme.separator)
                                            .frame(height: 0.5)
                                            .padding(.leading, 14 + 32 + 12)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    if let err = devicesError {
                        Text(err)
                            .font(.dsCaption)
                            .foregroundColor(Theme.textTertiary)
                            .padding(.horizontal, 4)
                    }
                }

                // ─── Logout all (always-visible button) ─────────────
                Button {
                    confirmLogoutAll = true
                } label: {
                    HStack(spacing: 8) {
                        if loggingOutAll {
                            ProgressView().tint(.white).scaleEffect(0.85)
                        } else {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                        }
                        Text("Выйти на всех устройствах")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundColor(.white)
                    .background(Theme.danger)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    .shadow(color: Theme.danger.opacity(0.35), radius: 14, x: 0, y: 4)
                }
                .buttonStyle(DSPressScaleStyle())
                .disabled(loggingOutAll)
                .padding(.top, 4)
            }
            .padding(16)
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("Безопасность")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Выйти на всех устройствах?", isPresented: $confirmLogoutAll) {
            Button("Отмена", role: .cancel) {}
            Button("Выйти", role: .destructive) {
                Task { await logoutAll() }
            }
        } message: {
            Text("Все сессии (кроме текущей) будут завершены. Чтобы войти снова — потребуется пароль.")
        }
        .task {
            await loadTwoFactor()
            await loadDevices()
        }
    }

    // MARK: - Login-method rows

    private var loginMethodSeparator: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: 0.5)
            .padding(.leading, 14 + 36 + 12)
    }

    /// Row 1 — двухфакторка по email.
    @ViewBuilder
    private var twoFactorRow: some View {
        HStack(alignment: .top, spacing: 12) {
            DSIconTile(
                systemImage: twoFactorEnabled
                    ? "shield.lefthalf.filled.badge.checkmark"
                    : "shield",
                color: twoFactorEnabled ? Theme.success : Theme.textTertiary,
                size: 36
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Вход по коду из почты")
                        .font(.dsBodyLG)
                        .foregroundColor(Theme.textPrimary)
                    if twoFactorEnabled {
                        DSBadge(text: "Вкл.", systemImage: "checkmark", color: Theme.success, filled: false)
                    }
                }
                if let email = twoFactorEmail ?? auth.currentUser?.email {
                    Label(email, systemImage: "envelope")
                        .font(.dsCaption)
                        .foregroundColor(Theme.textTertiary)
                }
                Text("При каждом входе на почту приходит 6-значный код. Действует 10 минут.")
                    .font(.dsCaption)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { twoFactorEnabled },
                set: { newValue in
                    Task { await toggleTwoFactor(newValue) }
                }
            ))
            .labelsHidden()
            .tint(Theme.accent)
            .disabled(twoFactorLoading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Row 2 — Face ID / Touch ID.
    @ViewBuilder
    private var biometricRow: some View {
        let kind = AuthStore.availableBiometric()
        let isAvailable = kind != .none
        let isFaceID = kind == .faceID
        let title = isFaceID ? "Вход по Face ID" : (kind == .touchID ? "Вход по Touch ID" : "Биометрический вход")
        let subtitle: String = {
            if !isAvailable {
                return "Биометрия недоступна на этом устройстве"
            }
            return isFaceID
                ? "Разблокировка приложения по сканированию лица"
                : "Разблокировка приложения по отпечатку пальца"
        }()

        HStack(alignment: .top, spacing: 12) {
            DSIconTile(
                systemImage: isFaceID ? "faceid" : "touchid",
                color: biometricLoginEnabled ? Theme.accent : Theme.textTertiary,
                size: 36
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.dsBodyLG)
                        .foregroundColor(Theme.textPrimary)
                    if biometricLoginEnabled {
                        DSBadge(text: "Вкл.", systemImage: "checkmark", color: Theme.success, filled: false)
                    }
                }
                Text(subtitle)
                    .font(.dsCaption)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { biometricLoginEnabled },
                set: { newValue in
                    Task { await toggleBiometric(newValue) }
                }
            ))
            .labelsHidden()
            .tint(Theme.accent)
            .disabled(!isAvailable || biometricLoading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Row 3 — быстрый вход (как quick-login на вебе).
    @ViewBuilder
    private var quickLoginRow: some View {
        HStack(alignment: .top, spacing: 12) {
            DSIconTile(
                systemImage: "bolt.shield.fill",
                color: quickLoginEnabled ? Theme.warning : Theme.textTertiary,
                size: 36
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Быстрый вход")
                        .font(.dsBodyLG)
                        .foregroundColor(Theme.textPrimary)
                    if quickLoginEnabled {
                        DSBadge(text: "Вкл.", systemImage: "checkmark", color: Theme.warning, filled: false)
                    }
                }
                Text("Запоминать логин и сразу подставлять при следующем входе.")
                    .font(.dsCaption)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $quickLoginEnabled)
                .labelsHidden()
                .tint(Theme.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Device row

    @ViewBuilder
    private func deviceRow(_ dev: SecurityDevice) -> some View {
        let kind = dev.device?.kind ?? ""
        let icon: String = {
            switch kind {
            case "mobile":  return "iphone"
            case "tablet":  return "ipad"
            default:        return "laptopcomputer"
            }
        }()
        let title: String = {
            let browser = dev.device?.browser ?? "Браузер"
            let os = dev.device?.os ?? "?"
            return "\(browser) на \(os)"
        }()
        let subtitle: String = {
            var parts: [String] = []
            if let ip = dev.ip, !ip.isEmpty { parts.append(ip) }
            if let last = dev.lastUsedAt, !last.isEmpty { parts.append("был \(formatRelative(last))") }
            return parts.joined(separator: " · ")
        }()
        let isCurrent = dev.isCurrent ?? false

        HStack(spacing: 12) {
            DSIconTile(systemImage: icon, color: isCurrent ? Theme.accent : Theme.textSecondary, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.dsBodyLG)
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    if isCurrent {
                        DSBadge(text: "Текущее", color: Theme.accent, filled: false)
                    }
                }
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.dsCaption)
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if !isCurrent {
                Button {
                    Task { await revokeDevice(dev.id) }
                } label: {
                    if revokingDeviceId == dev.id {
                        ProgressView().tint(Theme.danger).scaleEffect(0.7)
                    } else {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.danger)
                    }
                }
                .buttonStyle(.plain)
                .frame(width: 32, height: 32)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - API: 2FA

    private func loadTwoFactor() async {
        // Сначала используем уже загруженного user, если он есть.
        if let user = auth.currentUser {
            twoFactorEnabled = user.twoFactorEmailEnabled ?? false
            twoFactorEmail = user.email
        }
        do {
            let resp: SecurityMeResponse = try await APIClient.shared.get("auth/me")
            twoFactorEnabled = resp.twoFactorEmailEnabled ?? false
            twoFactorEmail = resp.email
            twoFactorError = nil
        } catch {
            // Молча — UI покажет fallback из auth.currentUser
        }
    }

    private func toggleTwoFactor(_ next: Bool) async {
        twoFactorLoading = true
        defer { twoFactorLoading = false }
        let prev = twoFactorEnabled
        twoFactorEnabled = next  // optimistic
        do {
            _ = try await APIClient.shared.rawRequest(
                "POST", "auth/2fa/toggle",
                body: TwoFactorToggleBody(enabled: next)
            )
            twoFactorError = nil
        } catch {
            twoFactorEnabled = prev
            twoFactorError = "Не удалось изменить настройку"
        }
    }

    // MARK: - Biometric

    /// Включает/выключает биометрический вход.
    /// При включении — проверяет доступность LAPolicy и просит подтвердить
    /// текущим Face ID / Touch ID, чтобы юзер не «защёлкнул себя».
    /// Access token остаётся в Keychain (он там и так — используется APIClient),
    /// при следующем запуске RootView показывает биом-лок поверх контента.
    private func toggleBiometric(_ next: Bool) async {
        biometricLoading = true
        defer { biometricLoading = false }
        biometricError = nil

        if next {
            let ctx = LAContext()
            var nsError: NSError?
            guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &nsError) else {
                biometricError = nsError?.localizedDescription
                    ?? "Биометрия недоступна. Включите Face ID / Touch ID в настройках устройства."
                biometricLoginEnabled = false
                return
            }
            // Подтверждаем — сразу же запрашиваем биометрию,
            // чтобы пользователь убедился что она работает.
            let ok = await AuthStore.evaluateBiometric(reason: "Подтвердите включение биометрического входа")
            guard ok else {
                biometricError = "Не удалось подтвердить биометрию"
                biometricLoginEnabled = false
                return
            }
            biometricLoginEnabled = true
        } else {
            biometricLoginEnabled = false
        }
    }

    // MARK: - API: devices

    private func loadDevices() async {
        devicesLoading = true
        defer { devicesLoading = false }
        do {
            let resp: SecurityDevicesResponse = try await APIClient.shared.get("security/devices")
            devices = resp.data
            devicesUnavailable = false
            devicesError = nil
        } catch APIError.http(let status, _) where status == 404 {
            devicesUnavailable = true
        } catch {
            // Любая другая ошибка — пустое состояние с пометкой «скоро будет».
            devicesUnavailable = true
        }
    }

    private func revokeDevice(_ id: String) async {
        revokingDeviceId = id
        defer { revokingDeviceId = nil }
        do {
            _ = try await APIClient.shared.rawRequest("DELETE", "security/devices/\(id)")
            devices.removeAll { $0.id == id }
        } catch {
            devicesError = "Не удалось отозвать устройство"
        }
    }

    private func logoutAll() async {
        loggingOutAll = true
        defer { loggingOutAll = false }
        // Зеркалим веб (revoke-all-other), с fallback на /auth/logout-all.
        var ok = false
        do {
            _ = try await APIClient.shared.rawRequest("POST", "security/devices/revoke-all-other")
            ok = true
        } catch {
            // try fallback
        }
        if !ok {
            do {
                _ = try await APIClient.shared.rawRequest("POST", "auth/logout-all")
                ok = true
            } catch {
                ok = false
            }
        }
        if ok {
            await loadDevices()
        } else {
            devicesError = "Не удалось завершить сессии"
        }
    }

    // MARK: - Format helpers

    private func formatRelative(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: iso)
            ?? ISO8601DateFormatter().date(from: iso)
        guard let d = date else { return iso }
        let rel = RelativeDateTimeFormatter()
        rel.locale = Locale(identifier: "ru_RU")
        rel.unitsStyle = .short
        return rel.localizedString(for: d, relativeTo: Date())
    }
}
