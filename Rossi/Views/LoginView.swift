//
//  LoginView.swift — экран входа.
//  POST /api/v1/auth/login → AuthStore.state = .authenticated
//
//  Редизайн под web-версию apps/web/src/app/(auth)/login/page.tsx:
//  ambient gradient blobs, центрированная карточка max-width 400, DS-кнопки.
//

import SwiftUI

struct LoginView: View {
    @EnvironmentObject var auth: AuthStore
    @State private var identifier = ""
    @State private var password = ""
    @State private var isSubmitting = false
    @FocusState private var focused: Field?

    enum Field { case identifier, password }

    var body: some View {
        ZStack {
            // Page bg
            Theme.pageBackground.ignoresSafeArea()

            // Ambient blurred blobs (как в вебе)
            ambientBlobs.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    Spacer().frame(height: 56)

                    // Header (logo + title)
                    VStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                                .fill(Theme.surfaceBackground)
                                .frame(width: 56, height: 56)
                                .overlay(
                                    RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                                        .strokeBorder(Theme.border, lineWidth: 0.5)
                                )
                                .dsSoftShadow()
                            Image(systemName: "waveform.path.ecg.rectangle.fill")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(LinearGradient(
                                    colors: [Theme.accent, Theme.purple, Theme.pink],
                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                        }

                        Text("Ритм")
                            .font(.system(size: 32, weight: .bold))
                            .tracking(-0.6)
                            .foregroundColor(Theme.textPrimary)

                        Text("Корпоративный портал")
                            .font(.dsCaption)
                            .foregroundColor(Theme.textSecondary)
                    }
                    .padding(.bottom, 32)

                    // Form card
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Вход в систему")
                            .font(.dsH3)
                            .fontWeight(.semibold)
                            .foregroundColor(Theme.textPrimary)
                            .padding(.bottom, 2)

                        StyledField(
                            placeholder: "Email или логин",
                            text: $identifier,
                            isSecure: false,
                            focused: focused == .identifier,
                            contentType: .username,
                            keyboard: .emailAddress,
                            submitLabel: .next,
                            onSubmit: { focused = .password }
                        )
                        .focused($focused, equals: .identifier)

                        StyledField(
                            placeholder: "Пароль",
                            text: $password,
                            isSecure: true,
                            focused: focused == .password,
                            contentType: .password,
                            keyboard: .default,
                            submitLabel: .go,
                            onSubmit: { Task { await submit() } }
                        )
                        .focused($focused, equals: .password)

                        if let err = auth.lastError {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(Theme.danger)
                                    .padding(.top, 2)
                                Text(err)
                                    .font(.dsBodySM)
                                    .foregroundColor(Theme.danger)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(12)
                            .background(Theme.danger.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                                    .strokeBorder(Theme.danger.opacity(0.3), lineWidth: 0.5)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                        }

                        DSPrimaryButton(
                            action: { Task { await submit() } },
                            loading: isSubmitting,
                            enabled: !identifier.isEmpty && !password.isEmpty,
                            gradient: true
                        ) {
                            Text(isSubmitting ? "Вход…" : "Войти")
                        }
                        .padding(.top, 4)

                        Text("Забыли пароль? Обратитесь к администратору.")
                            .font(.dsCaption)
                            .foregroundColor(Theme.textTertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 8)
                    }
                    .padding(24)
                    .background(Theme.surfaceBackground)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.xl2, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.xl2, style: .continuous)
                            .strokeBorder(Theme.border, lineWidth: 0.5)
                    )
                    .dsModalShadow()
                    .frame(maxWidth: 400)
                    .padding(.horizontal, 20)

                    Spacer().frame(height: 60)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            if identifier.isEmpty, let saved = Keychain.get(.savedUsername) {
                identifier = saved
            }
        }
    }

    // MARK: - Background

    @ViewBuilder
    private var ambientBlobs: some View {
        GeometryReader { geo in
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.15))
                    .frame(width: geo.size.width * 0.85, height: geo.size.width * 0.85)
                    .blur(radius: 80)
                    .offset(x: -geo.size.width * 0.30, y: geo.size.height * 0.35)

                Circle()
                    .fill(Theme.pink.opacity(0.10))
                    .frame(width: geo.size.width * 0.85, height: geo.size.width * 0.85)
                    .blur(radius: 80)
                    .offset(x: geo.size.width * 0.30, y: -geo.size.height * 0.35)

                Circle()
                    .fill(Theme.purple.opacity(0.08))
                    .frame(width: geo.size.width * 0.7, height: geo.size.width * 0.7)
                    .blur(radius: 90)
                    .offset(x: 0, y: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Actions

    private func submit() async {
        guard !identifier.isEmpty, !password.isEmpty else { return }
        focused = nil
        isSubmitting = true
        defer { isSubmitting = false }
        _ = try? await auth.login(identifier: identifier, password: password)
    }

}

// MARK: - Styled field (reused by LoginView / TwoFactorView)

struct StyledField: View {
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false
    var focused: Bool = false
    var contentType: UITextContentType? = nil
    var keyboard: UIKeyboardType = .default
    var submitLabel: SubmitLabel = .return
    var onSubmit: () -> Void = {}

    var body: some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
                    .keyboardType(keyboard)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }
        }
        .textContentType(contentType)
        .submitLabel(submitLabel)
        .onSubmit(onSubmit)
        .font(.system(size: 15))
        .foregroundColor(Theme.textPrimary)
        .padding(14)
        .background(Theme.pageBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(focused ? Theme.accent : Theme.border,
                              lineWidth: focused ? 1.5 : 0.5)
        )
        .animation(.easeOut(duration: 0.15), value: focused)
    }
}

#Preview {
    LoginView()
        .environmentObject(AuthStore())
}
