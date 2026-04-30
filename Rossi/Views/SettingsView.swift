//
//  SettingsView.swift — настройки приложения и ссылки на «большую» админку в вебе.
//
//  Структура (зеркальная вебу — apps/web/src/app/(app)/settings/page.tsx):
//   • Picker наверху: Уведомления / Оформление / Безопасность
//   • Уведомления:  GET/PATCH /notifications/settings  ({ type, enabled })
//   • Оформление:   тема (system/light/dark) + 6 preset-градиентов
//   • Безопасность: переход на SecuritySettingsView (2FA + сессии + logout-all)
//

import SwiftUI
import UserNotifications
import UIKit

// MARK: - Tabs

enum SettingsTab: String, CaseIterable, Identifiable {
    case notifications, appearance, security
    var id: String { rawValue }
    var title: String {
        switch self {
        case .notifications: return "Уведомления"
        case .appearance:    return "Оформление"
        case .security:      return "Безопасность"
        }
    }
    var icon: String {
        switch self {
        case .notifications: return "bell.fill"
        case .appearance:    return "paintbrush.fill"
        case .security:      return "lock.shield.fill"
        }
    }
}

// MARK: - Notification model (зеркало /notifications/settings)

struct NotificationPrefItem: Codable, Identifiable, Hashable {
    let type: String
    var enabled: Bool
    var id: String { type }
}

struct NotificationPrefsResponse: Codable {
    let data: [NotificationPrefItem]
}

/// Локальные дефолты (используются как fallback и shape для UI, если бэк
/// ничего не вернул для этого типа — считаем, что включено).
private let kNotificationTypes: [(type: String, label: String, description: String, icon: String, color: Color)] = [
    ("news.published",       "Новости",            "Уведомления о новых публикациях",      "newspaper.fill",       Theme.accent),
    ("news.important",       "Важные новости",     "Срочные и важные уведомления",         "exclamationmark.bubble.fill", Theme.danger),
    ("news.comment.created", "Комментарии",        "Когда кто-то комментирует",            "text.bubble.fill",     Theme.info),
    ("achievement.granted",  "Достижения",         "Когда вам выдают достижение",          "trophy.fill",          Theme.warning),
    ("chat.message",         "Чат",                "Новые личные и групповые сообщения",   "message.fill",         Theme.accent),
    ("user.roles.updated",   "Назначения ролей",   "Когда ваши роли меняются",             "person.badge.shield.checkmark.fill", Theme.purple),
    ("task.assigned",        "Задачи",             "Назначенные на вас задачи",            "checklist",            Theme.success),
    ("kudos.received",       "Kudos",              "Когда коллеги отправляют благодарности","hands.clap.fill",     Theme.pink),
    ("schedule.updated",     "Расписание",         "Изменения в графике",                  "calendar.badge.clock", Theme.info),
    ("support.reply",        "Поддержка",          "Ответы по тикетам",                    "lifepreserver.fill",   Theme.warning),
]

// MARK: - Background presets

struct BackgroundPreset: Identifiable, Hashable {
    let id: String
    let label: String
    let colors: [Color]

    var gradient: LinearGradient {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

private let kBackgroundPresets: [BackgroundPreset] = [
    .init(id: "none",     label: "Без фона",  colors: [Color(hex: 0xF6F8FB), Color(hex: 0xE5E9F0)]),
    .init(id: "sunset",   label: "Закат",     colors: [Color(hex: 0xF093FB), Color(hex: 0xF5576C)]),
    .init(id: "ocean",    label: "Океан",     colors: [Color(hex: 0x4FACFE), Color(hex: 0x00F2FE)]),
    .init(id: "forest",   label: "Лес",       colors: [Color(hex: 0x43E97B), Color(hex: 0x38F9D7)]),
    .init(id: "night",    label: "Ночь",      colors: [Color(hex: 0x0F2027), Color(hex: 0x203A43), Color(hex: 0x2C5364)]),
    .init(id: "lavender", label: "Лаванда",   colors: [Color(hex: 0xA18CD1), Color(hex: 0xFBC2EB)]),
    .init(id: "flame",    label: "Пламя",     colors: [Color(hex: 0xF77062), Color(hex: 0xFE5196)]),
    .init(id: "indigo",   label: "Индиго",    colors: [Color(hex: 0x6366F1), Color(hex: 0x8B5CF6)]),
]

// MARK: - View

struct SettingsView: View {
    @EnvironmentObject var auth: AuthStore
    @AppStorage("preferredColorScheme") private var preferredScheme: String = "system"
    @AppStorage("appBackgroundPreset")  private var backgroundPreset: String = "none"
    @AppStorage("useLiquidGlass")        private var useLiquidGlass: Bool = false
    @State private var showLogoutConfirm = false
    @State private var loggingOut = false
    @State private var activeTab: SettingsTab = .notifications

    // Notification prefs state
    @State private var notifPrefs: [String: Bool] = [:]
    @State private var notifLoading = false
    @State private var notifError: String? = nil
    @State private var notifLoaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Header — компактная карточка пользователя
                if let user = auth.currentUser {
                    NavigationLink {
                        ProfileView()
                    } label: {
                        DSCard(radius: Radius.xl, padding: 14) {
                            HStack(spacing: 12) {
                                AvatarCircle(url: user.profile?.avatarUrl, name: user.displayName)
                                    .frame(width: 56, height: 56)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(user.displayName)
                                        .font(.dsH3)
                                        .foregroundColor(Theme.textPrimary)
                                    Text("@\(user.username)")
                                        .font(.dsCaption)
                                        .foregroundColor(Theme.textTertiary)
                                    if let pos = user.profile?.position {
                                        Text(pos)
                                            .font(.dsCaption)
                                            .foregroundColor(Theme.textSecondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(Theme.textTertiary)
                            }
                        }
                    }
                    .buttonStyle(DSPressScaleStyle())
                }

                // Tab picker (segmented)
                Picker("", selection: $activeTab) {
                    ForEach(SettingsTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.vertical, 2)

                // Активная секция
                switch activeTab {
                case .notifications: notificationsSection
                case .appearance:    appearanceSection
                case .security:      securitySection
                }

                // Кеш — общий блок, всегда виден
                cacheSection

                // Доступы (всегда видны — полезный контекст)
                if let perms = auth.currentUser?.permissions, !perms.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        DSSectionHeader("Мои права (\(perms.count))")
                        DSCard(radius: Radius.xl, padding: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(perms.prefix(8), id: \.self) { p in
                                    Text(p)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(Theme.textSecondary)
                                }
                                if perms.count > 8 {
                                    Text("…ещё \(perms.count - 8)")
                                        .font(.system(size: 11))
                                        .foregroundColor(Theme.textTertiary)
                                }
                            }
                        }
                    }
                }

                // Logout
                Button {
                    showLogoutConfirm = true
                } label: {
                    HStack(spacing: 8) {
                        if loggingOut {
                            ProgressView().tint(.white).scaleEffect(0.85)
                        } else {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                        }
                        Text("Выйти из аккаунта")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundColor(.white)
                    .background(Theme.danger)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    .shadow(color: Theme.danger.opacity(0.35), radius: 14, x: 0, y: 4)
                }
                .buttonStyle(DSPressScaleStyle())
                .disabled(loggingOut)
                .padding(.top, 4)

                // Зарезервированное место под плавающую таблетку (см. MainTabView)
                Color.clear.frame(height: TabBarVisibility.reservedHeight)
            }
            .padding(16)
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("Настройки")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Выйти из аккаунта?", isPresented: $showLogoutConfirm) {
            Button("Отмена", role: .cancel) {}
            Button("Выйти", role: .destructive) {
                Task {
                    loggingOut = true
                    await auth.logout()
                    loggingOut = false
                }
            }
        } message: {
            Text("Сессия будет завершена. Чтобы продолжить, войдите снова.")
        }
        .task {
            if !notifLoaded { await loadNotificationPrefs() }
        }
    }

    // MARK: - Cache section

    @StateObject private var cache = CacheManager.shared
    @State private var clearingCache: String? = nil // "images" | "api" | "tmp" | "all"

    @ViewBuilder
    private var cacheSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            DSSectionHeader("Кеш")
            DSCard(radius: Radius.xl, padding: 0) {
                VStack(spacing: 0) {
                    cacheRow(
                        title: "Изображения",
                        subtitle: "Аватарки, обложки, картинки в чате",
                        icon: "photo.on.rectangle",
                        color: Theme.purple,
                        size: cache.imagesSize,
                        busy: clearingCache == "images"
                    ) {
                        Task {
                            clearingCache = "images"
                            await cache.clearImages()
                            clearingCache = nil
                        }
                    }
                    Divider().padding(.leading, 56)
                    cacheRow(
                        title: "Ответы API",
                        subtitle: "Кешированные данные с сервера",
                        icon: "tray.full.fill",
                        color: Theme.indigo,
                        size: cache.apiResponsesSize,
                        busy: clearingCache == "api"
                    ) {
                        Task {
                            clearingCache = "api"
                            await cache.clearApiResponses()
                            clearingCache = nil
                        }
                    }
                    Divider().padding(.leading, 56)
                    cacheRow(
                        title: "Временные файлы",
                        subtitle: "Загрузки, превью, обработка медиа",
                        icon: "folder.fill",
                        color: Theme.warning,
                        size: cache.temporarySize,
                        busy: clearingCache == "tmp"
                    ) {
                        Task {
                            clearingCache = "tmp"
                            cache.clearTemporary()
                            await cache.refresh()
                            clearingCache = nil
                        }
                    }
                }
            }

            // Большая красная кнопка очистки всего
            Button {
                Task {
                    clearingCache = "all"
                    await cache.clearAll()
                    clearingCache = nil
                }
            } label: {
                HStack(spacing: 8) {
                    if clearingCache == "all" {
                        ProgressView().tint(.white).scaleEffect(0.85)
                    } else {
                        Image(systemName: "trash.fill")
                    }
                    Text("Очистить весь кеш")
                    Spacer()
                    Text(CacheManager.format(cache.totalSize))
                        .font(.caption.monospacedDigit())
                        .opacity(0.85)
                }
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal, 14)
                .foregroundColor(.white)
                .background(Theme.danger)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            }
            .disabled(clearingCache != nil)
            .padding(.top, 6)
        }
        .task { await cache.refresh() }
    }

    @ViewBuilder
    private func cacheRow(
        title: String,
        subtitle: String,
        icon: String,
        color: Color,
        size: Int64,
        busy: Bool,
        clear: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            DSIconTile(systemImage: icon, color: color, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.dsBody.weight(.medium))
                    .foregroundColor(Theme.textPrimary)
                Text(subtitle)
                    .font(.dsCaption)
                    .foregroundColor(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(CacheManager.format(size))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(Theme.textSecondary)
                Button {
                    clear()
                } label: {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Очистить")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(Theme.accent)
                    }
                }
                .disabled(busy)
            }
        }
        .padding(12)
    }

    // MARK: - Notifications section

    @ViewBuilder
    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            DSSectionHeader("Push и системные")
            DSCard(radius: Radius.xl, padding: 0) {
                VStack(spacing: 0) {
                    NavigationLink {
                        NotificationsView()
                    } label: {
                        SettingsRow(
                            icon: "bell.badge.fill",
                            iconColor: Theme.warning,
                            title: "Журнал уведомлений",
                            accessory: .chevron
                        )
                    }
                    .buttonStyle(.plain)

                    settingsSeparator

                    Button {
                        Task { await requestPushPermission() }
                    } label: {
                        SettingsRow(
                            icon: "app.badge.fill",
                            iconColor: Theme.accent,
                            title: "Включить push-уведомления",
                            accessory: .chevron
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 4)
            }
        }

        VStack(alignment: .leading, spacing: 6) {
            DSSectionHeader("Типы уведомлений")
            DSCard(radius: Radius.xl, padding: 0) {
                VStack(spacing: 0) {
                    if notifLoading && !notifLoaded {
                        HStack {
                            Spacer()
                            ProgressView().tint(Theme.accent)
                            Spacer()
                        }
                        .padding(.vertical, 24)
                    } else {
                        ForEach(Array(kNotificationTypes.enumerated()), id: \.offset) { idx, item in
                            NotificationToggleRow(
                                icon: item.icon,
                                color: item.color,
                                label: item.label,
                                description: item.description,
                                isOn: Binding(
                                    get: { notifPrefs[item.type] ?? true },
                                    set: { newValue in
                                        notifPrefs[item.type] = newValue
                                        // Локальный fallback на случай если бэк недоступен.
                                        UserDefaults.standard.set(newValue, forKey: "notif.\(item.type)")
                                        Task { await patchNotificationPref(type: item.type, enabled: newValue) }
                                    }
                                )
                            )
                            if idx < kNotificationTypes.count - 1 { settingsSeparator }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            if let err = notifError {
                Text(err)
                    .font(.dsCaption)
                    .foregroundColor(Theme.textTertiary)
                    .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Appearance section

    @ViewBuilder
    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            DSSectionHeader("Тема")
            DSCard(radius: Radius.xl, padding: 14) {
                HStack {
                    DSIconTile(systemImage: "paintpalette.fill", color: Theme.purple, size: 32)
                    Text("Оформление")
                        .font(.dsBodyLG)
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    Picker("", selection: $preferredScheme) {
                        Text("Система").tag("system")
                        Text("Светлая").tag("light")
                        Text("Тёмная").tag("dark")
                    }
                    .pickerStyle(.menu)
                    .tint(Theme.accent)
                }
            }
        }

        VStack(alignment: .leading, spacing: 6) {
            DSSectionHeader("Эффекты")
            DSCard(radius: Radius.xl, padding: 14) {
                HStack(alignment: .top, spacing: 12) {
                    DSIconTile(systemImage: "sparkles", color: Theme.indigo, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Эффект жидкого стекла")
                            .font(.dsBodyLG)
                            .foregroundColor(Theme.textPrimary)
                        Text("Размытие в стиле iOS 26 для карточек интерфейса")
                            .font(.dsCaption)
                            .foregroundColor(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: $useLiquidGlass)
                        .labelsHidden()
                        .tint(Theme.accent)
                }
            }
        }
    }

    // MARK: - Security section (entry card → SecuritySettingsView)

    @ViewBuilder
    private var securitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            DSSectionHeader("Безопасность")
            DSCard(radius: Radius.xl, padding: 0) {
                VStack(spacing: 0) {
                    NavigationLink {
                        SecuritySettingsView()
                    } label: {
                        SettingsRow(
                            icon: "lock.shield.fill",
                            iconColor: Theme.success,
                            title: "Двухфакторка и сессии",
                            accessory: .chevron
                        )
                    }
                    .buttonStyle(.plain)

                    settingsSeparator

                    Button {
                        Task { await logoutAllDevices() }
                    } label: {
                        SettingsRow(
                            icon: "rectangle.portrait.and.arrow.right.fill",
                            iconColor: Theme.danger,
                            title: "Выйти на всех устройствах",
                            accessory: .chevron
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 4)
            }

            Text("Завершит сессии на всех устройствах кроме текущего.")
                .font(.dsCaption)
                .foregroundColor(Theme.textTertiary)
                .padding(.horizontal, 4)
        }
    }

    // MARK: - Helpers (subviews)

    private var settingsSeparator: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: 0.5)
            .padding(.leading, 14 + 32 + 12)
    }

    @ViewBuilder
    private func settingsLinkRow(_ title: String, icon: String, color: Color, path: String, isLast: Bool) -> some View {
        if let url = URL(string: "https://rossihelp.ru\(path)") {
            Link(destination: url) {
                SettingsRow(
                    icon: icon,
                    iconColor: color,
                    title: title,
                    accessory: .openExternal
                )
            }
        }
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    private func requestPushPermission() async {
        let center = UNUserNotificationCenter.current()
        do {
            _ = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            await UIApplication.shared.registerForRemoteNotifications()
        } catch {}
    }

    // MARK: - API: notification prefs

    private func loadNotificationPrefs() async {
        notifLoading = true
        defer { notifLoading = false }
        // Сначала — локальный fallback, чтобы UI не пустовал.
        var local: [String: Bool] = [:]
        for nt in kNotificationTypes {
            if UserDefaults.standard.object(forKey: "notif.\(nt.type)") != nil {
                local[nt.type] = UserDefaults.standard.bool(forKey: "notif.\(nt.type)")
            }
        }
        notifPrefs = local

        do {
            let resp: NotificationPrefsResponse = try await APIClient.shared.get("notifications/settings")
            var map: [String: Bool] = [:]
            for it in resp.data { map[it.type] = it.enabled }
            // Сохраняем известные типы; для тех, что бэк не вернул — оставляем дефолт = true
            notifPrefs = map.merging(local) { server, _ in server }
            notifLoaded = true
            notifError = nil
        } catch {
            // 404 / отсутствие эндпоинта — gracefully используем UserDefaults.
            // TODO: синхронизировать notifPrefs с бэком, когда /notifications/settings заработает.
            notifLoaded = true
            notifError = "Серверные настройки недоступны — изменения сохраняются на устройстве."
        }
    }

    private func patchNotificationPref(type: String, enabled: Bool) async {
        struct Body: Encodable { let type: String; let enabled: Bool }
        do {
            _ = try await APIClient.shared.rawRequest(
                "PATCH", "notifications/settings",
                body: Body(type: type, enabled: enabled)
            )
        } catch {
            // Игнорируем — у нас уже сохранилось в UserDefaults.
        }
    }

    // MARK: - API: logout-all

    private func logoutAllDevices() async {
        // POST /security/devices/revoke-all-other (как в вебе);
        // если такого нет — пробуем POST /auth/logout-all как fallback.
        do {
            _ = try await APIClient.shared.rawRequest("POST", "security/devices/revoke-all-other")
            return
        } catch {
            // try fallback
        }
        do {
            _ = try await APIClient.shared.rawRequest("POST", "auth/logout-all")
        } catch {
            // gracefully ignore
        }
    }
}

// MARK: - Reusable rows

struct NotificationToggleRow: View {
    let icon: String
    let color: Color
    let label: String
    let description: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            DSIconTile(systemImage: icon, color: color, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.dsBodyLG)
                    .foregroundColor(Theme.textPrimary)
                Text(description)
                    .font(.dsCaption)
                    .foregroundColor(Theme.textTertiary)
                    .lineLimit(2)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(Theme.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

enum SettingsRowAccessory {
    case chevron
    case openExternal
    case none
}

struct SettingsRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    var accessory: SettingsRowAccessory = .chevron

    var body: some View {
        HStack(spacing: 12) {
            DSIconTile(systemImage: icon, color: iconColor, size: 32)
            Text(title)
                .font(.dsBodyLG)
                .foregroundColor(Theme.textPrimary)
            Spacer()
            switch accessory {
            case .chevron:
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textTertiary)
            case .openExternal:
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textTertiary)
            case .none:
                EmptyView()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

struct SettingsValueRow: View {
    let label: String
    let value: String
    var isLast: Bool = false

    var body: some View {
        HStack {
            Text(label)
                .font(.dsBody)
                .foregroundColor(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.dsBody)
                .foregroundColor(Theme.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
