//
//  TwoFactorView.swift — экран ввода 6-значного кода из email (2FA).
//
//  Показывается, когда AuthStore.state == .twoFactor(challengeId, emailHint).
//  Авто-сабмит при вводе 6 цифр, кнопка resend с 30-секундным cooldown.
//
//  Редизайн под web — PIN-style cells, ambient gradient bg, gradient submit-button.
//

import SwiftUI

struct TwoFactorView: View {
    @EnvironmentObject var auth: AuthStore
    let challengeId: String
    let emailHint: String?

    @State private var code = ""
    @State private var isVerifying = false
    @State private var isResending = false
    @State private var resendCooldown = 0
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Theme.pageBackground.ignoresSafeArea()
            ambientBlobs.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    Spacer().frame(height: 56)

                    // Header
                    VStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(Theme.accent.opacity(0.15))
                                .frame(width: 64, height: 64)
                            Image(systemName: "envelope.badge.fill")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundColor(Theme.accent)
                        }

                        Text("Введите код")
                            .font(.system(size: 32, weight: .bold))
                            .tracking(-0.6)
                            .foregroundColor(Theme.textPrimary)

                        VStack(spacing: 4) {
                            Text("Мы отправили 6-значный код на")
                                .font(.dsBodySM)
                                .foregroundColor(Theme.textSecondary)
                            if let h = emailHint, !h.isEmpty {
                                Text(h)
                                    .font(.dsBodySM.weight(.semibold))
                                    .foregroundColor(Theme.textPrimary)
                            }
                            Text("Код действует 10 минут")
                                .font(.dsCaption)
                                .foregroundColor(Theme.textTertiary)
                                .padding(.top, 2)
                        }
                        .multilineTextAlignment(.center)
                    }
                    .padding(.bottom, 32)

                    // Code-input card
                    VStack(spacing: 16) {
                        PinCodeView(code: $code, focused: $focused)

                        if let err = auth.lastError {
                            Text(err)
                                .font(.dsBodySM)
                                .foregroundColor(Theme.danger)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                        }

                        DSPrimaryButton(
                            action: { Task { await submit() } },
                            loading: isVerifying,
                            enabled: code.count == 6,
                            gradient: true
                        ) {
                            Text(isVerifying ? "Проверяю…" : "Подтвердить")
                        }
                    }
                    .padding(20)
                    .background(Theme.surfaceBackground)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.xl2, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.xl2, style: .continuous)
                            .strokeBorder(Theme.border, lineWidth: 0.5)
                    )
                    .dsModalShadow()
                    .frame(maxWidth: 400)
                    .padding(.horizontal, 20)

                    // Resend / cancel
                    VStack(spacing: 14) {
                        if resendCooldown > 0 {
                            Text("Новый код можно запросить через \(resendCooldown) с")
                                .font(.dsCaption)
                                .foregroundColor(Theme.textSecondary)
                        } else {
                            Button {
                                Task { await resend() }
                            } label: {
                                if isResending {
                                    ProgressView().scaleEffect(0.7)
                                } else {
                                    Text("Отправить код повторно")
                                        .font(.dsBodySM.weight(.medium))
                                        .foregroundColor(Theme.accent)
                                }
                            }
                            .disabled(isResending)
                        }

                        Button {
                            auth.cancelTwoFactor()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.left")
                                Text("Назад к логину")
                            }
                            .font(.dsBodySM)
                            .foregroundColor(Theme.textSecondary)
                        }
                    }
                    .padding(.top, 24)

                    Spacer().frame(height: 60)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { focused = true }
        .onReceive(timer) { _ in
            if resendCooldown > 0 { resendCooldown -= 1 }
        }
    }

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
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private func submit() async {
        guard code.count == 6 else { return }
        focused = false
        isVerifying = true
        defer { isVerifying = false }
        let ok = await auth.verifyTwoFactor(code: code)
        if !ok {
            code = ""
            focused = true
        }
    }

    private func resend() async {
        isResending = true
        defer { isResending = false }
        let ok = await auth.resendTwoFactor()
        if ok { resendCooldown = 30 }
    }
}

// MARK: - Pin Code Input

private struct PinCodeView: View {
    @Binding var code: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        ZStack {
            // Прозрачное поле под капотом для системного ввода numpad / oneTimeCode.
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused(focused)
                .opacity(0.001)
                .frame(height: 1)
                .onChange(of: code) { newValue in
                    let cleaned = newValue.filter { $0.isNumber }
                    let truncated = String(cleaned.prefix(6))
                    if truncated != code { code = truncated }
                }

            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { idx in
                    PinCell(
                        char: charAt(idx),
                        isActive: idx == code.count,
                        isFilled: idx < code.count
                    )
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { focused.wrappedValue = true }
        }
    }

    private func charAt(_ i: Int) -> String {
        guard i < code.count else { return "" }
        return String(code[code.index(code.startIndex, offsetBy: i)])
    }
}

private struct PinCell: View {
    let char: String
    let isActive: Bool
    let isFilled: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .fill(Theme.pageBackground)

            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(
                    isActive ? Theme.accent : (isFilled ? Theme.borderStrong : Theme.border),
                    lineWidth: isActive ? 1.5 : 0.5
                )

            Text(char)
                .font(.system(size: 24, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
        }
        .frame(width: 48, height: 56)
        .animation(.easeOut(duration: 0.15), value: isActive)
        .animation(.easeOut(duration: 0.15), value: isFilled)
    }
}
