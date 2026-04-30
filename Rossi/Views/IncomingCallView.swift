//
//  IncomingCallView.swift — fullScreen-экран входящего звонка.
//
//  Показывается через `RootView.fullScreenCover(item: $callManager.incomingCall)`.
//  Большой аватар с пульсирующим кольцом, имя, тип звонка, две круглые
//  кнопки (отклонить/принять). Принятие переключает CallManager в `activeCall`.
//

import SwiftUI

struct IncomingCallView: View {
    @EnvironmentObject var callManager: CallManager
    let call: IncomingCall

    @State private var pulse: Bool = false

    var body: some View {
        ZStack {
            // Фон — мягкий градиент в фирменных цветах.
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.06, blue: 0.10),
                    Color(red: 0.10, green: 0.10, blue: 0.18),
                    Theme.purple.opacity(0.5),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                // Header
                VStack(spacing: 8) {
                    Text(call.callType == .video ? "Видеозвонок" : "Аудио звонок")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                    Text(call.fromName ?? "Входящий")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                }

                // Avatar + pulse
                ZStack {
                    ForEach(0..<3) { i in
                        Circle()
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                            .frame(width: 120, height: 120)
                            .scaleEffect(pulse ? 1.6 + CGFloat(i) * 0.25 : 1.0)
                            .opacity(pulse ? 0 : 0.6)
                            .animation(
                                .easeOut(duration: 1.8)
                                .repeatForever(autoreverses: false)
                                .delay(Double(i) * 0.6),
                                value: pulse
                            )
                    }
                    AvatarCircle(url: call.fromAvatarUrl, name: call.fromName ?? "?")
                        .frame(width: 120, height: 120)
                        .overlay(Circle().stroke(.white.opacity(0.4), lineWidth: 2))
                        .shadow(color: .black.opacity(0.4), radius: 18, y: 6)
                }
                .padding(.vertical, 20)

                Spacer()

                // Кнопки
                HStack {
                    callButton(
                        systemImage: "phone.down.fill",
                        background: Theme.danger,
                        action: { callManager.rejectCall(call) }
                    )
                    Spacer()
                    callButton(
                        systemImage: call.callType == .video ? "video.fill" : "phone.fill",
                        background: Theme.success,
                        action: { callManager.acceptCall(call) }
                    )
                }
                .padding(.horizontal, 56)
                .padding(.bottom, 60)
            }
            .padding(.horizontal, 24)
        }
        .onAppear {
            pulse = true
            // Лёгкая вибрация на старте.
            #if canImport(UIKit)
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            #endif
        }
    }

    private func callButton(systemImage: String, background: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(background)
                    .frame(width: 76, height: 76)
                    .shadow(color: background.opacity(0.5), radius: 14, y: 6)
                Image(systemName: systemImage)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
        .buttonStyle(.plain)
    }
}
