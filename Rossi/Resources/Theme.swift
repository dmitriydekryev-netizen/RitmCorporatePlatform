//
//  Theme.swift — design system, зеркальный с веб-версией
//  (apps/web/tailwind.config.ts + apps/web/src/app/globals.css).
//
//  Цвета, типографика, радиусы, тени — всё совпадает 1-в-1.
//  Light/Dark переключаются автоматически через UIColor(dynamicProvider:).
//

import SwiftUI
import UIKit

// MARK: - Design tokens

enum Theme {

    // ─── Brand / Accent ──────────────────────────────────────────
    /// iOS-blue-style accent. На веб: rgb(0,122,255) light / rgb(10,132,255) dark.
    static let accent       = dynamic(light: rgb(0, 122, 255), dark: rgb(10, 132, 255))
    static let accentHover  = dynamic(light: rgb(10, 132, 255), dark: rgb(100, 172, 255))
    static let accentSoft   = dynamic(light: rgb(222, 240, 255), dark: rgb(16, 36, 68))

    // Дополнительные градиентные акценты (для hero-cards, AI и т.п.)
    static let purple = Color(red: 168/255, green: 85/255,  blue: 247/255)
    static let pink   = Color(red: 236/255, green: 72/255,  blue: 153/255)
    static let indigo = Color(red: 99/255,  green: 102/255, blue: 241/255)

    // ─── Semantic ────────────────────────────────────────────────
    static let success = Color(hex: 0x10B981)   // emerald
    static let warning = Color(hex: 0xF59E0B)   // amber
    static let danger  = Color(hex: 0xEF4444)   // red
    static let info    = Color(hex: 0x0EA5E9)   // sky

    // ─── Surfaces & background ──────────────────────────────────
    static let pageBackground       = dynamic(light: rgb(246, 248, 251), dark: rgb(6, 8, 14))
    static let surfaceBackground    = dynamic(light: .white,             dark: rgb(20, 23, 31))
    static let surfaceElevated      = dynamic(light: .white,             dark: rgb(28, 32, 42))
    static let cardBackground       = surfaceBackground

    // ─── Borders ────────────────────────────────────────────────
    static let border         = dynamic(light: rgb(232, 236, 242), dark: rgb(38, 42, 54))
    static let borderStrong   = dynamic(light: rgb(214, 220, 229), dark: rgb(58, 64, 80))
    static let separator      = border

    // ─── Text ───────────────────────────────────────────────────
    static let textPrimary    = dynamic(light: rgb(15, 23, 42),    dark: rgb(237, 240, 248))
    static let textSecondary  = dynamic(light: rgb(82, 93, 113),   dark: rgb(156, 164, 182))
    static let textTertiary   = dynamic(light: rgb(140, 148, 168), dark: rgb(106, 114, 132))

    // MARK: - Helpers (private)

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> UIColor {
        UIColor(red: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: 1)
    }

    private static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { trait in trait.userInterfaceStyle == .dark ? dark : light })
    }
}

// MARK: - Color helpers

extension Color {
    /// Hex без прозрачности.
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8)  & 0xFF) / 255.0
        let b = Double(hex         & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Typography (зеркало fontSize в tailwind.config.ts)

extension Font {
    /// 40pt / 48 / -0.025em — display-xl
    static let dsDisplayXL = Font.system(size: 40, weight: .bold)
    /// 32pt / 40 / -0.022em — display-lg
    static let dsDisplayLG = Font.system(size: 32, weight: .bold)
    /// 26pt / 34 / -0.018em — h1
    static let dsH1        = Font.system(size: 26, weight: .bold)
    /// 21pt / 28 / -0.012em — h2
    static let dsH2        = Font.system(size: 21, weight: .semibold)
    /// 17pt / 24 / -0.006em — h3
    static let dsH3        = Font.system(size: 17, weight: .semibold)
    /// 16pt / 24 — body-lg
    static let dsBodyLG    = Font.system(size: 16)
    /// 14pt / 22 — body
    static let dsBody      = Font.system(size: 14)
    /// 13pt / 20 — body-sm
    static let dsBodySM    = Font.system(size: 13)
    /// 12pt / 16 — caption
    static let dsCaption   = Font.system(size: 12)
}

extension View {
    /// Применить web-style typographic tracking + line-spacing.
    /// Использовать для крупных заголовков (h1/h2/display).
    func dsTracking(_ value: CGFloat) -> some View {
        self.tracking(value)
    }
}

// MARK: - Radii

enum Radius {
    static let xs:   CGFloat = 6
    static let sm:   CGFloat = 10
    static let md:   CGFloat = 14    // tailwind DEFAULT
    static let lg:   CGFloat = 16
    static let xl:   CGFloat = 20
    static let xl2:  CGFloat = 24    // 2xl
    static let xl3:  CGFloat = 28    // 3xl
    static let xl4:  CGFloat = 32    // 4xl
}

// MARK: - Shadows

extension View {
    /// `shadow-card` web — лёгкая карточная тень.
    func dsCardShadow() -> some View {
        self
            .shadow(color: Color.black.opacity(0.04), radius: 2, x: 0, y: 1)
            .shadow(color: Color.black.opacity(0.03), radius: 1, x: 0, y: 0.5)
    }
    /// `shadow-card-hover` — для приподнятых hover/pressed состояний.
    func dsCardHoverShadow() -> some View {
        self
            .shadow(color: Color.black.opacity(0.06), radius: 24, x: 0, y: 8)
            .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 2)
    }
    /// `shadow-modal` — для bottom sheets и больших модалок.
    func dsModalShadow() -> some View {
        self
            .shadow(color: Color.black.opacity(0.18), radius: 80, x: 0, y: 32)
            .shadow(color: Color.black.opacity(0.08), radius: 32, x: 0, y: 12)
    }
    /// `shadow-soft-md` — для дашборд-карточек.
    func dsSoftShadow() -> some View {
        self.shadow(color: Color.black.opacity(0.06), radius: 16, x: 0, y: 4)
    }
}

// MARK: - UI primitives (используем во всех экранах)

/// Карточка как `bg-surface rounded-2xl border border-border` в вебе.
/// Если включён `useLiquidGlass` (через AppStorage) — фон становится `.ultraThinMaterial`
/// и добавляется gradient-border + soft shadow в стиле iOS 26 «Liquid Glass».
struct DSCard<Content: View>: View {
    @AppStorage("useLiquidGlass") private var useLiquidGlass: Bool = false

    let content: () -> Content
    var radius: CGFloat = Radius.xl   // 20px
    var padding: CGFloat = 14
    var bordered: Bool = true

    init(radius: CGFloat = Radius.xl, padding: CGFloat = 14, bordered: Bool = true,
         @ViewBuilder _ content: @escaping () -> Content) {
        self.radius = radius
        self.padding = padding
        self.bordered = bordered
        self.content = content
    }

    var body: some View {
        if useLiquidGlass {
            content()
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.35), Color.white.opacity(0.05)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.6
                        )
                )
                .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 6)
        } else {
            content()
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surfaceBackground)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(bordered ? Theme.border : Color.clear, lineWidth: 0.5)
                )
                .dsCardShadow()
        }
    }
}

/// Альтернатива `DSCard`, всегда использующая `.ultraThinMaterial` —
/// удобно для одиночных «glass»-карточек независимо от глобального тумблера.
struct DSGlassCard<Content: View>: View {
    let content: () -> Content
    var radius: CGFloat = Radius.xl
    var padding: CGFloat = 14

    init(radius: CGFloat = Radius.xl, padding: CGFloat = 14,
         @ViewBuilder _ content: @escaping () -> Content) {
        self.radius = radius
        self.padding = padding
        self.content = content
    }

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlass(radius: radius)
    }
}

// MARK: - Liquid Glass modifier (iOS 26-style)

extension View {
    /// «Liquid Glass» эффект: ultraThinMaterial + gradient stroke + soft shadow.
    /// Безопасно работает с iOS 16+ (Material API доступен с iOS 15).
    @ViewBuilder
    func liquidGlass(radius: CGFloat = Radius.xl) -> some View {
        self
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: radius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.35), Color.white.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.6
                    )
            )
            .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 6)
    }
}

/// Pill-капсула для бейджей (status, category, count). Аналог `h-5 px-2 rounded-full text-[11px] font-semibold`
struct DSBadge: View {
    let text: String
    var systemImage: String? = nil
    var color: Color = Theme.accent
    var filled: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if let icon = systemImage {
                Image(systemName: icon).font(.system(size: 9, weight: .bold))
            }
            Text(text)
        }
        .font(.system(size: 11, weight: .semibold, design: .default))
        .tracking(-0.005 * 12)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .foregroundColor(filled ? .white : color)
        .background(filled ? color : color.opacity(0.12))
        .clipShape(Capsule())
        .lineLimit(1)
    }
}

/// Primary-кнопка с градиентом или solid-accent. Аналог bg-accent text-white press-scale shadow-[0_1px_2px...]
struct DSPrimaryButton<Label: View>: View {
    let action: () -> Void
    let label: () -> Label
    var loading: Bool = false
    var enabled: Bool = true
    var gradient: Bool = false

    init(action: @escaping () -> Void, loading: Bool = false, enabled: Bool = true,
         gradient: Bool = false, @ViewBuilder label: @escaping () -> Label) {
        self.action = action
        self.loading = loading
        self.enabled = enabled
        self.gradient = gradient
        self.label = label
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if loading {
                    ProgressView().tint(.white).scaleEffect(0.85)
                }
                label()
            }
            .font(.system(size: 14, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundColor(.white)
            .background(
                Group {
                    if gradient {
                        LinearGradient(
                            colors: [Theme.accent, Theme.purple, Theme.pink],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    } else {
                        Theme.accent
                    }
                }
            )
            .opacity(enabled ? 1 : 0.5)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .shadow(color: Theme.accent.opacity(0.35), radius: 14, x: 0, y: 4)
        }
        .disabled(!enabled || loading)
        .buttonStyle(DSPressScaleStyle())
    }
}

/// Secondary-кнопка — outline, white/page bg.
struct DSSecondaryButton<Label: View>: View {
    let action: () -> Void
    let label: () -> Label

    init(action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: action) {
            label()
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundColor(Theme.textPrimary)
                .background(Theme.surfaceBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.md)
                        .strokeBorder(Theme.borderStrong, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
        .buttonStyle(DSPressScaleStyle())
    }
}

/// `press-scale` из веба (active:scale[0.97]).
struct DSPressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Section header в стиле веба — uppercase mini-caption, tracking, secondary-color.
struct DSSectionHeader: View {
    let text: String
    var trailing: AnyView? = nil

    init(_ text: String, trailing: AnyView? = nil) {
        self.text = text
        self.trailing = trailing
    }

    var body: some View {
        HStack {
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundColor(Theme.textTertiary)
            Spacer()
            if let trailing { trailing }
        }
        .padding(.bottom, 6)
    }
}

/// Page title H1 в стиле веба — `text-[26px] font-semibold tracking-[-0.025em]`.
struct DSPageTitle: View {
    let text: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.system(size: 26, weight: .bold))
                .tracking(-0.6)
                .foregroundColor(Theme.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// «Liquid» icon-tile — иконка в кружке цвета как в вебе (w-9 h-9 rounded-xl bg-{color}/10).
struct DSIconTile: View {
    let systemImage: String
    var color: Color = Theme.accent
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size / 2.8, style: .continuous)
                .fill(color.opacity(0.12))
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundColor(color)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Backwards-compat (старые поля Theme.* остаются)
// (всё уже определено выше — не нужны лишние алиасы)

// ─── Additional web-style helpers ─────────────────────────────────────

extension View {
    /// Web-style separator (border-b in Tailwind)
    func dsSeparator() -> some View {
        self.overlay(
            Rectangle()
                .fill(Theme.separator)
                .frame(height: 1)
                .offset(y: 0.5)
        )
    }
    
    /// Soft background for surface (как bg-surface в вебе)
    func dsSurfaceBackground() -> some View {
        self.background(Theme.surfaceBackground)
    }
    
    /// Hover effect для карточек (как hover:bg-page в вебе)
    func dsCardHoverEffect(isHovered: Bool) -> some View {
        self.background(isHovered ? Theme.surfaceElevated : Theme.surfaceBackground)
    }
}

// ─── Animation helpers ────────────────────────────────────────────────

struct DSSlideUpAnimation: ViewModifier {
    func body(content: Content) -> some View {
        content
            .transition(.asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .opacity
            ))
    }
}

extension View {
    func dsSlideUpAnimation() -> some View {
        self.modifier(DSSlideUpAnimation())
    }
}
