//
//  MainTabView.swift — корневая навигация после логина.
//
//  Структура зеркалит мобильную web-версию (apps/web/src/components/layout/MobileNav.tsx):
//   • TabBar 5 кнопок: Главная · Новости · Ритм AI · Чат · Ещё
//   • «Ещё» открывает bottom-sheet (Menu drawer) — НЕ отдельный экран
//   • Разделы внутри «Ещё» скрыты по правам пользователя (auth.currentUser?.permissions)
//

import SwiftUI
import UIKit

// MARK: - Permission helper (зеркалит usePermission в вебе)

extension AuthStore {
    /// Проверка одного permission. `*` или точное совпадение → true.
    /// Также поддерживает wildcard вида `admin.*`, `posting.*`.
    func has(_ permission: String) -> Bool {
        guard let perms = currentUser?.permissions else { return false }
        if perms.contains("*") { return true }
        if perms.contains(permission) { return true }
        // Wildcard в правах пользователя: "admin.*" покрывает "admin.dashboard"
        for p in perms where p.hasSuffix(".*") {
            let prefix = String(p.dropLast(2))
            if permission.hasPrefix(prefix + ".") || permission == prefix { return true }
        }
        return false
    }

    /// True если у пользователя есть хотя бы один из переданных permissions.
    func hasAny(_ permissions: [String]) -> Bool {
        for p in permissions where has(p) { return true }
        return false
    }

    /// Удобный флаг «это админ» — есть `*` или любое `admin.*`.
    var isAdmin: Bool {
        guard let perms = currentUser?.permissions else { return false }
        if perms.contains("*") { return true }
        return perms.contains(where: { $0 == "admin.dashboard" || $0.hasPrefix("admin.") || $0 == "users.manage" })
    }
}

// MARK: - MainTabView

/// Глобальное состояние выбранного таба — позволяет любому экрану
/// (например, AI-чату) программно переключиться на Главную, чтобы
/// дать пользователю «выход» из root-таба.
@MainActor
final class TabSelectionStore: ObservableObject {
    @Published var selection: MainTabView.Tab = .dashboard
}

/// Контроллер видимости плавающего таб-бара. Внутренние экраны
/// (chat detail, AI chat) могут скрыть его через
/// `.environmentObject` → `tabBar.hide()` / `tabBar.show()`.
@MainActor
final class TabBarVisibility: ObservableObject {
    @Published var isHidden: Bool = false
    /// Полная резервируемая высота под плавающую таблетку (height + bottom gap),
    /// которую каждый scroll-view должен оставлять снизу через `.tabBarBottomPadding()`.
    /// Это «честное» значение — bar height (62) + .padding снизу (8) + системный
    /// safe area home-indicator (~34) ≈ 104. Берём с запасом, чтобы наверняка.
    static let reservedHeight: CGFloat = 110
}

extension View {
    /// Добавляет нижний отступ под плавающий таб-бар, если он сейчас виден.
    /// Используется на каждом основном экране (Главная, Новости, Чат, Ещё, …)
    /// чтобы последний элемент скролла не прятался под таблеткой.
    func tabBarBottomPadding() -> some View {
        modifier(TabBarBottomPaddingModifier())
    }
}

private struct TabBarBottomPaddingModifier: ViewModifier {
    @EnvironmentObject var tabBar: TabBarVisibility
    func body(content: Content) -> some View {
        content
            .padding(.bottom, tabBar.isHidden ? 0 : TabBarVisibility.reservedHeight)
    }
}

struct MainTabView: View {
    @EnvironmentObject var auth: AuthStore
    @AppStorage("preferredColorScheme") private var preferredScheme: String = "system"
    @StateObject private var tabBar = TabBarVisibility()
    @StateObject private var tabSelection = TabSelectionStore()

    enum Tab: Hashable {
        case dashboard, news, ai, chat, more
    }

    var body: some View {
        // Кастомная навигация — floating capsule в ZStack overlay.
        // Каждый ScrollView/List экран использует `.tabBarBottomPadding()`
        // чтобы оставить место снизу — это работает надёжнее, чем
        // системный safeAreaInset (он не всегда применяется к контенту
        // внутри NavigationStack).
        ZStack(alignment: .bottom) {
            Group {
                switch tabSelection.selection {
                case .dashboard: NavigationStack { DashboardView() }
                case .news:      NavigationStack { NewsListView() }
                case .ai:        NavigationStack { AIChatView() }
                case .chat:      NavigationStack { ChatsListView() }
                case .more:      NavigationStack { MoreScreen() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !tabBar.isHidden {
                RoundedTabBar(selection: $tabSelection.selection)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: tabBar.isHidden)
        .environmentObject(tabBar)
        .environmentObject(tabSelection)
        .tint(Theme.accent)
        .preferredColorScheme(colorSchemeFromPref)
    }

    private var colorSchemeFromPref: ColorScheme? {
        switch preferredScheme {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil
        }
    }
}

// MARK: - View extension: спрятать таб-бар на конкретном экране.
//   Использование: `.hidesTabBar()` на корневом View внутреннего экрана
//   (например, ChatDetailView, AIChatView).

extension View {
    /// Полностью прятать таб-бар, пока этот View на экране (push'нутые детали).
    func hidesTabBar() -> some View {
        modifier(HidesTabBarModifier())
    }

    /// Прятать таб-бар, пока показана клавиатура. Полезно для root-табов,
    /// которые активно печатают (AI-чат, поддержка), чтобы input-bar не
    /// уезжал под плавающую таблетку.
    func hidesTabBarOnKeyboard() -> some View {
        modifier(HidesTabBarOnKeyboardModifier())
    }
}

private struct HidesTabBarModifier: ViewModifier {
    @EnvironmentObject var tabBar: TabBarVisibility
    func body(content: Content) -> some View {
        content
            .onAppear { tabBar.isHidden = true }
            .onDisappear { tabBar.isHidden = false }
    }
}

private struct HidesTabBarOnKeyboardModifier: ViewModifier {
    @EnvironmentObject var tabBar: TabBarVisibility
    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                tabBar.isHidden = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                tabBar.isHidden = false
            }
            .onDisappear { tabBar.isHidden = false }
    }
}

// MARK: - RoundedTabBar — плавающая капсула как в мобильном вебе
//        (apps/web/src/components/layout/MobileNav.tsx).

private struct RoundedTabBar: View {
    @Binding var selection: MainTabView.Tab

    private struct Item {
        let tab: MainTabView.Tab
        let icon: String
        let label: String
    }

    private let items: [Item] = [
        .init(tab: .dashboard, icon: "house.fill",            label: "Главная"),
        .init(tab: .news,      icon: "newspaper.fill",        label: "Новости"),
        .init(tab: .ai,        icon: "sparkles",              label: "Ритм"),
        .init(tab: .chat,      icon: "message.fill",          label: "Чат"),
        .init(tab: .more,      icon: "square.grid.2x2.fill",  label: "Ещё"),
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.tab) { item in
                Button {
                    withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.78)) {
                        selection = item.tab
                    }
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                } label: {
                    tabButton(item)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(6)
        .frame(height: 62)
        .frame(maxWidth: 520)
        .background(
            // «Glass» эффект: blur + полупрозрачный фон + бордер
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Theme.surfaceBackground.opacity(0.55))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Theme.border.opacity(0.4), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.10), radius: 16, x: 0, y: 6)
    }

    @ViewBuilder
    private func tabButton(_ item: Item) -> some View {
        let isActive = selection == item.tab
        ZStack {
            if isActive {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Theme.accent.opacity(0.12))
            }
            VStack(spacing: 2) {
                if item.tab == .ai {
                    // Спец-иконка «Ритм» — градиентный кружок (как в вебе).
                    ZStack {
                        Circle()
                            .fill(LinearGradient(
                                colors: [Theme.accent, Theme.purple, Theme.pink],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                            .frame(width: 26, height: 26)
                            .shadow(color: Theme.accent.opacity(0.35), radius: 4, x: 0, y: 2)
                        Image(systemName: item.icon)
                            .foregroundColor(.white)
                            .font(.system(size: 13, weight: .bold))
                    }
                } else {
                    Image(systemName: item.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(isActive ? Theme.accent : Theme.textTertiary)
                }
                Text(item.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(isActive ? Theme.accent : Theme.textTertiary)
                    .lineLimit(1)
            }
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
}

// MARK: - More screen

/// Экран «Ещё» — список разделов как обычный таб (не bottom sheet).
struct MoreScreen: View {
    @EnvironmentObject var auth: AuthStore
    @State private var showNotifications = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                    // Top bar: статус-picker слева + колокольчик справа
                    // (как в мобильном вебе)
                    HStack(spacing: 8) {
                        StatusPickerInline()
                        Spacer()
                        Button {
                            showNotifications = true
                        } label: {
                            Image(systemName: "bell.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(Theme.accent)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(Theme.surfaceBackground))
                                .overlay(Circle().strokeBorder(Theme.border, lineWidth: 0.5))
                        }
                    }
                    .padding(.bottom, 4)

                    // Header — карточка пользователя (тап → Профиль)
                    if let user = auth.currentUser {
                        NavigationLink {
                            ProfileView()
                        } label: {
                            userHeaderCard(user: user)
                        }
                        .buttonStyle(.plain)
                    }

                    // ─── Разделы (доступны всем) ───
                    // Команда убрана — есть на главном экране.
                    // Уведомления — теперь по кнопке-колокольчику в header'е.
                    section(title: "Разделы") {
                        row(destination: ScheduleView(),
                            icon: "calendar", color: Theme.accent,
                            title: "График")
                        row(destination: KudosView(),
                            icon: "heart.fill", color: Theme.pink,
                            title: "Благодарности")
                        row(destination: FeedbackView(),
                            icon: "lightbulb.fill", color: Theme.warning,
                            title: "Идеи и баги")
                        row(destination: LearningView(),
                            icon: "graduationcap.fill", color: Theme.purple,
                            title: "Обучение")
                    }

                    // ─── Сервис ───
                    if auth.has("support.view") || auth.isAdmin {
                        section(title: "Сервис") {
                            row(destination: SupportThreadsView(),
                                icon: "lifepreserver.fill", color: Theme.info,
                                title: "Поддержка")
                        }
                    }

                    // ─── Модерация ROSSI ───
                    // Доступно админам или пользователям с модерационными правами
                    // Staya (users.moderate.* / groups.moderate.* / channels.moderate.*).
                    let canModUsers = auth.hasAny(["users.moderate.view", "users.moderate.*"]) || auth.isAdmin
                    let canModGroups = auth.hasAny(["groups.moderate.view", "groups.moderate.*"]) || auth.isAdmin
                    let canModChannels = auth.hasAny(["channels.moderate.view", "channels.moderate.*"]) || auth.isAdmin
                    if canModUsers || canModGroups || canModChannels {
                        section(title: "Модерация ROSSI") {
                            if canModUsers {
                                row(destination: RossiUsersModerationView(),
                                    icon: "person.crop.rectangle.stack.fill", color: Theme.accent,
                                    title: "Пользователи Rossi")
                            }
                            if canModGroups {
                                row(destination: RossiGroupsModerationView(),
                                    icon: "person.3.sequence.fill", color: Theme.purple,
                                    title: "Группы Rossi")
                            }
                            if canModChannels {
                                row(destination: RossiChannelsModerationView(),
                                    icon: "dot.radiowaves.left.and.right", color: Theme.indigo,
                                    title: "Каналы Rossi")
                            }
                        }
                    }

                    // ─── Постинг ───
                    if auth.hasAny(["posting.view", "posting.manage", "posting.create"]) || auth.isAdmin {
                        section(title: "Постинг") {
                            row(destination: PostingView(),
                                icon: "megaphone.fill", color: Theme.pink,
                                title: "Постинг")
                        }
                    }

                    // ─── Тестирование ───
                    let canBugs = auth.has("bug.view") || auth.isAdmin
                    let canBuilds = auth.has("testing.builds.view") || auth.isAdmin
                    let canTestAcc = auth.has("testing.accounts.view") || auth.isAdmin
                    let canStatus = auth.has("testing.status.view") || auth.isAdmin
                    if canBugs || canBuilds || canTestAcc || canStatus {
                        section(title: "Тестирование") {
                            if canBugs {
                                row(destination: BugsView(),
                                    icon: "ladybug.fill", color: Theme.danger,
                                    title: "Баг-трекер")
                            }
                            if canBuilds {
                                row(destination: BuildsListView(),
                                    icon: "shippingbox.fill", color: Theme.indigo,
                                    title: "Сборки")
                            }
                            if canTestAcc {
                                row(destination: TestAccountsView(),
                                    icon: "key.fill", color: Theme.warning,
                                    title: "Тестовые аккаунты")
                            }
                            if canStatus {
                                row(destination: StatusCheckView(),
                                    icon: "waveform.path.ecg", color: Theme.success,
                                    title: "Проверка статуса")
                            }
                        }
                    }

                    // ─── Администрирование ───
                    // Верификация / Аудит / Ошибки доступны только внутри
                    // Админ-панели (AdminHubView) — здесь не дублируем.
                    if auth.isAdmin {
                        section(title: "Администрирование") {
                            row(destination: AdminHubView(),
                                icon: "shield.lefthalf.filled", color: Theme.accent,
                                title: "Админ-панель")
                        }
                    }

                    // ─── Аккаунт ───
                    // Кнопка «Профиль» отдельно не нужна — переход на профиль
                    // доступен по тапу на user header card сверху.
                    section(title: "Аккаунт") {
                        row(destination: SettingsView(),
                            icon: "gear", color: .secondary,
                            title: "Настройки")
                    }

                Spacer(minLength: 24)
                Color.clear.frame(height: TabBarVisibility.reservedHeight)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("Ещё")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showNotifications) {
            NavigationStack {
                NotificationsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Готово") { showNotifications = false }
                        }
                    }
            }
        }
    }

    // MARK: - User header card

    @ViewBuilder
    private func userHeaderCard(user: AuthUser) -> some View {
        DSCard(radius: Radius.xl2, padding: 14) {
            HStack(spacing: 12) {
                AvatarCircle(url: user.profile?.avatarUrl, name: user.displayName)
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(user.displayName)
                        .font(.dsBodyLG.weight(.semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Text("@\(user.username)")
                        .font(.dsCaption)
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textTertiary)
            }
        }
    }

    // MARK: - Section + row

    @ViewBuilder
    private func section<Content: View>(title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DSSectionHeader(title)
                .padding(.horizontal, 4)
            VStack(spacing: 6) {
                content()
            }
        }
    }

    @ViewBuilder
    private func row<D: View>(destination: D,
                              icon: String,
                              color: Color,
                              title: String) -> some View {
        NavigationLink {
            destination
        } label: {
            DSCard(radius: Radius.xl, padding: 10) {
                HStack(spacing: 12) {
                    DSIconTile(systemImage: icon, color: color, size: 34)
                    Text(title)
                        .font(.dsBody.weight(.medium))
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.textTertiary)
                }
            }
        }
        .buttonStyle(DSPressScaleStyle())
    }
}

#Preview {
    MainTabView()
        .environmentObject(AuthStore())
}
