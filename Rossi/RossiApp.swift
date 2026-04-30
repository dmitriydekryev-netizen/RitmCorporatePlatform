//
//  RossiApp.swift
//  Ритм — нативный iOS-клиент корпоративного портала Rossi.
//
//  Архитектура:
//   • Backend — тот же что у веба: https://rossihelp.ru/api/v1
//   • Auth — JWT (access в памяти + Keychain, refresh в HTTP-cookie)
//   • Source of truth — Postgres за NestJS-API. Мы тонкий клиент.
//

import SwiftUI
import UIKit

@main
struct RossiApp: App {
    /// UIKit-делегат для APNs push-уведомлений (см. Services/AppDelegate.swift).
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var auth = AuthStore()

    init() {
        configureNavBarAppearance()
        // Принудительно инициализируем CacheManager на старте — он
        // настраивает URLCache.shared (64 MB RAM + 256 MB disk),
        // которым автоматически пользуются AsyncImage и другие URLSession.
        Task { @MainActor in _ = CacheManager.shared }
    }

    /// Делаем navigation bar тонким и плоским — как в мобильном вебе:
    /// без heavy-bg, без тени, мелкий заголовок (15pt semibold), компактная высота.
    private func configureNavBarAppearance() {
        let app = UINavigationBarAppearance()
        app.configureWithTransparentBackground()
        app.backgroundColor = .clear
        app.shadowColor = .clear
        app.titleTextAttributes = [
            .font: UIFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: UIColor.label
        ]
        app.largeTitleTextAttributes = [
            .font: UIFont.systemFont(ofSize: 22, weight: .bold),
            .foregroundColor: UIColor.label
        ]
        let backImage = UIImage(systemName: "chevron.left",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        app.setBackIndicatorImage(backImage, transitionMaskImage: backImage)
        app.backButtonAppearance.normal.titleTextAttributes = [
            .foregroundColor: UIColor.clear
        ]
        UINavigationBar.appearance().standardAppearance = app
        UINavigationBar.appearance().scrollEdgeAppearance = app
        UINavigationBar.appearance().compactAppearance = app
        UINavigationBar.appearance().tintColor = UIColor(named: "AccentColor") ?? .systemBlue
    }
    /// Менеджер звонков — общий для всего приложения.
    /// Подключается к Socket.IO `/chat` сразу после успешной авторизации
    /// (см. RootView.task ниже) и слушает события `call:incoming` глобально,
    /// чтобы экран входящего звонка появлялся из любого таба.
    @StateObject private var callManager = CallManager.shared

    /// Тема. SettingsView пишет сюда `system` | `light` | `dark`.
    /// Раньше значение писалось, но не применялось — теперь применяем
    /// `.preferredColorScheme` на корневой WindowGroup.
    @AppStorage("preferredColorScheme") private var preferredScheme: String = "system"

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(callManager)
                .preferredColorScheme(colorScheme(for: preferredScheme))
                .task {
                    // При запуске пробуем восстановить сессию из Keychain
                    await auth.bootstrap()
                }
        }
    }

    private func colorScheme(for raw: String) -> ColorScheme? {
        switch raw {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil  // system
        }
    }
}

/// Корневой контейнер — переключает между логином и основным TabView
/// на основе состояния AuthStore.
struct RootView: View {
    @EnvironmentObject var auth: AuthStore
    @EnvironmentObject var callManager: CallManager
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome: Bool = false
    @AppStorage("biometricLoginEnabled") private var biometricLoginEnabled: Bool = false

    /// Активен ли биометрический «замок» поверх контента
    /// (показываем blur пока пользователь не подтвердил Face ID/Touch ID).
    @State private var biometricUnlocked: Bool = false
    @State private var biometricPromptInFlight: Bool = false

    var body: some View {
        Group {
            switch auth.state {
            case .loading:
                LaunchScreen()
            case .unauthenticated:
                LoginView()
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            case .twoFactor(let challengeId, let emailHint):
                TwoFactorView(challengeId: challengeId, emailHint: emailHint)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            case .authenticated:
                MainTabView()
                    .transition(.opacity)
                    .overlay {
                        if biometricLoginEnabled && !biometricUnlocked {
                            biometricLockOverlay
                                .transition(.opacity)
                        }
                    }
                    .task { await runBiometricGateIfNeeded() }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: auth.state)
        .animation(.easeInOut(duration: 0.2), value: biometricUnlocked)
        .onChange(of: auth.state) { newState in
            // При выходе из аккаунта сбрасываем «биом-замок»,
            // чтобы при следующем логине пользователь снова прошёл проверку.
            if case .unauthenticated = newState {
                biometricUnlocked = false
            }
        }
        .fullScreenCover(isPresented: .init(
            get: { !hasSeenWelcome },
            set: { newVal in if newVal == false { hasSeenWelcome = true } }
        )) {
            WelcomeView()
        }
        // Звонки — единый fullScreenCover, который показывает либо входящий
        // (приоритет), либо активный. Состояния mutually exclusive по флоу
        // CallManager: при accept incomingCall сначала обнуляется, потом ставится
        // activeCall — поэтому один cover ок.
        .fullScreenCover(isPresented: Binding(
            get: { callManager.incomingCall != nil || callManager.activeCall != nil },
            set: { newVal in
                if newVal == false {
                    // Закрытие свайпом запрещено — но если как-то закрыли,
                    // даём CallManager шанс корректно завершить.
                    if callManager.incomingCall != nil { callManager.incomingCall = nil }
                    if callManager.activeCall != nil { callManager.endCall() }
                }
            }
        )) {
            Group {
                if let inc = callManager.incomingCall {
                    IncomingCallView(call: inc)
                } else if let act = callManager.activeCall {
                    ActiveCallView(call: act)
                }
            }
            .environmentObject(callManager)
        }
        // При появлении/смене авторизованного юзера — подключаем CallManager
        // к тому же Socket.IO endpoint, что и ChatRealtime.
        .task {
            await syncCallManager()
        }
        .onChange(of: auth.state) { _ in
            Task { await syncCallManager() }
        }
    }

    /// Подцепляет CallManager к текущей сессии (или отвязывает при выходе).
    private func syncCallManager() async {
        if case .authenticated(let user) = auth.state,
           let token = await APIClient.shared.currentAccessToken() {
            callManager.attach(userId: user.id, token: token, userName: user.displayName)
        } else {
            callManager.detach()
        }
    }

    // MARK: - Biometric gate

    @ViewBuilder
    private var biometricLockOverlay: some View {
        ZStack {
            // Размытие под локом + фирменный градиент сверху.
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            LinearGradient(
                colors: [Theme.accent.opacity(0.25), Theme.purple.opacity(0.25), Theme.pink.opacity(0.25)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: AuthStore.availableBiometric() == .faceID
                      ? "faceid"
                      : "touchid")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(Theme.accent)
                Text("Ритм заблокирован")
                    .font(.dsH2)
                    .foregroundColor(Theme.textPrimary)
                Text("Подтвердите вход с помощью\nFace ID или Touch ID")
                    .font(.dsBody)
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                Button {
                    Task { await promptBiometric() }
                } label: {
                    Text("Войти")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: 220, minHeight: 44)
                        .foregroundColor(.white)
                        .background(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                }
                .buttonStyle(DSPressScaleStyle())
                .padding(.top, 8)
            }
            .padding(24)
        }
    }

    private func runBiometricGateIfNeeded() async {
        guard biometricLoginEnabled else {
            biometricUnlocked = true
            return
        }
        // Если устройство не умеет в биометрию — не блокируем.
        if AuthStore.availableBiometric() == .none {
            biometricUnlocked = true
            return
        }
        await promptBiometric()
    }

    private func promptBiometric() async {
        guard !biometricPromptInFlight else { return }
        biometricPromptInFlight = true
        defer { biometricPromptInFlight = false }
        let ok = await AuthStore.evaluateBiometric(reason: "Войти в Ритм")
        if ok { biometricUnlocked = true }
    }
}

/// Сплеш-экран на время восстановления сессии (POST /auth/refresh)
struct LaunchScreen: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Theme.accent, Theme.purple, Theme.pink],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 16) {
                Text("Ритм")
                    .font(.system(size: 56, weight: .bold, design: .default))
                    .tracking(-1.5)
                    .foregroundColor(.white)
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(0.85)
            }
        }
    }
}
