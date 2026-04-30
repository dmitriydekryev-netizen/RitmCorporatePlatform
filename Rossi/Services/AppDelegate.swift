//
//  AppDelegate.swift — UIApplicationDelegate adapter для APNs push-уведомлений.
//
//  Зачем:
//   • SwiftUI App scene-API не умеет получать APNs device token без UIApplicationDelegate.
//   • Подключаем через @UIApplicationDelegateAdaptor в RossiApp.
//
//  Flow:
//   1) После успешного login AuthStore зовёт requestPermissionAndRegister()
//   2) Запрашиваем authorization (alert/badge/sound), при granted — registerForRemoteNotifications()
//   3) iOS возвращает didRegisterForRemoteNotificationsWithDeviceToken — POST /push/apns-token
//   4) Foreground push — показываем banner; tap — postим NotificationCenter event для роутинга.
//

import SwiftUI
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static var shared: AppDelegate!

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        AppDelegate.shared = self
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // MARK: - APNs token registration

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        // Снимаем UIDevice/Bundle на main thread заранее, чтобы детач-Task ничего не трогал.
        let deviceModel = UIDevice.current.model
        let osVersion = UIDevice.current.systemVersion
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let bundleId = Bundle.main.bundleIdentifier

        // POST на бэк через APIClient — ошибки игнорируем, повторим при следующем запуске.
        Task {
            try? await APIClient.shared.rawRequest(
                "POST", "push/apns-token",
                body: ApnsTokenBody(
                    token: token,
                    platform: "ios",
                    deviceModel: deviceModel,
                    osVersion: osVersion,
                    appVersion: appVersion,
                    bundleId: bundleId
                )
            )
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("APNs registration failed: \(error)")
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Foreground push — показываем banner/sound/badge и кладём в Notification Center.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        return [.banner, .sound, .badge, .list]
    }

    /// Tap по push-уведомлению — пробуем достать `url` из payload и роутить через NotificationCenter.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let url = response.notification.request.content.userInfo["url"] as? String
        if let url = url {
            await MainActor.run {
                NotificationCenter.default.post(name: .pushTapped, object: url)
            }
        }
    }

    // MARK: - Public API

    /// Запросить permission на push и, если granted, зарегистрировать APNs token.
    /// Вызывается из AuthStore сразу после successful login.
    static func requestPermissionAndRegister() async {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            if granted {
                await MainActor.run {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        } catch {
            // permission denied / restricted — silently ignore
        }
    }
}

extension Foundation.Notification.Name {
    /// Постится при тапе по push-уведомлению. object = url-строка из payload.
    static let pushTapped = Foundation.Notification.Name("pushTapped")
}

struct ApnsTokenBody: Encodable {
    let token: String
    let platform: String
    let deviceModel: String?
    let osVersion: String?
    let appVersion: String?
    let bundleId: String?
}
