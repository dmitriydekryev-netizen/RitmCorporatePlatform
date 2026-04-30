//
//  ActiveCallView.swift — fullScreen-экран активного звонка.
//
//  Показывается через `RootView.fullScreenCover(item: $callManager.activeCall)`.
//   • Audio: большой аватар, имя, таймер, mute/speaker/end-call.
//   • Video: full-screen RTCVideoView (если WebRTC SDK подключён) +
//            picture-in-picture с локальным видео в углу + те же кнопки + flip-camera.
//

import SwiftUI
#if canImport(WebRTC)
import WebRTC
#endif

struct ActiveCallView: View {
    @EnvironmentObject var callManager: CallManager
    let call: ActiveCall

    /// Тикер для обновления таймера длительности раз в секунду.
    @State private var now: Date = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // Фон
            background

            VStack(spacing: 0) {
                header
                    .padding(.top, 40)
                    .padding(.horizontal, 24)

                Spacer()

                if call.callType == .audio {
                    audioCenter
                } else {
                    videoCenter
                }

                Spacer()

                controls
                    .padding(.bottom, 40)
            }

            // Локальное видео picture-in-picture (только для видеозвонка).
            if call.callType == .video {
                VStack {
                    HStack {
                        Spacer()
                        localVideoPip
                            .padding(.trailing, 16)
                            .padding(.top, 60)
                    }
                    Spacer()
                }
            }
        }
        .onReceive(timer) { now = $0 }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var background: some View {
        if call.callType == .video {
            // Под видео-фоном — чёрный, поверх ляжет remote video.
            Color.black.ignoresSafeArea()
        } else {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.06, blue: 0.10),
                    Theme.accent.opacity(0.4),
                    Theme.purple.opacity(0.5),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text(stateLabel)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.75))
            Text(call.peerName ?? "Звонок")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white)
        }
    }

    @ViewBuilder
    private var audioCenter: some View {
        VStack(spacing: 18) {
            AvatarCircle(url: call.peerAvatarUrl, name: call.peerName ?? "?")
                .frame(width: 160, height: 160)
                .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 2))
                .shadow(color: .black.opacity(0.3), radius: 18, y: 6)
            Text(durationOrStatus)
                .font(.system(size: 18, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
        }
    }

    @ViewBuilder
    private var videoCenter: some View {
        ZStack {
#if canImport(WebRTC)
            // Главный удалённый видеопоток (берём первый, если их несколько).
            if let remote = callManager.remoteVideoTracks.values.first {
                RTCVideoSwiftUIView(track: remote, isLocal: false)
                    .ignoresSafeArea()
            } else {
                videoPlaceholder
            }
#else
            videoPlaceholder
#endif
        }
    }

    private var videoPlaceholder: some View {
        VStack(spacing: 14) {
            AvatarCircle(url: call.peerAvatarUrl, name: call.peerName ?? "?")
                .frame(width: 140, height: 140)
                .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 2))
            Text(durationOrStatus)
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
        }
    }

    @ViewBuilder
    private var localVideoPip: some View {
        ZStack {
#if canImport(WebRTC)
            // Локальное видео — TODO: в текущей реализации мы не публикуем
            // localVideoTrack отдельно для UI. Можно расширить CallManager
            // чтобы отдавать его сюда, как remoteVideoTracks.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.5))
                .overlay(
                    Image(systemName: callManager.isCameraOn ? "person.fill" : "video.slash.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.white.opacity(0.6))
                )
#else
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.5))
                .overlay(
                    Image(systemName: "video.slash.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.white.opacity(0.6))
                )
#endif
        }
        .frame(width: 96, height: 132)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.3), lineWidth: 1)
        )
    }

    private var controls: some View {
        HStack(spacing: 22) {
            controlButton(
                systemImage: callManager.isMuted ? "mic.slash.fill" : "mic.fill",
                active: callManager.isMuted,
                action: { callManager.toggleMute() }
            )
            if call.callType == .video {
                controlButton(
                    systemImage: "arrow.triangle.2.circlepath.camera.fill",
                    active: false,
                    action: { callManager.flipCamera() }
                )
                controlButton(
                    systemImage: callManager.isCameraOn ? "video.fill" : "video.slash.fill",
                    active: !callManager.isCameraOn,
                    action: { callManager.toggleCamera() }
                )
            } else {
                controlButton(
                    systemImage: callManager.isSpeakerOn ? "speaker.wave.3.fill" : "speaker.fill",
                    active: callManager.isSpeakerOn,
                    action: { callManager.toggleSpeaker() }
                )
            }
            // End call
            Button {
                callManager.endCall()
            } label: {
                ZStack {
                    Circle().fill(Theme.danger).frame(width: 68, height: 68)
                        .shadow(color: Theme.danger.opacity(0.4), radius: 12, y: 4)
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
    }

    private func controlButton(systemImage: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(active ? Color.white : Color.white.opacity(0.12))
                    .frame(width: 56, height: 56)
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(active ? .black : .white)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Labels

    private var stateLabel: String {
        switch call.state {
        case .dialing:    return "Вызов..."
        case .ringing:    return "Звонок..."
        case .connecting: return "Соединение..."
        case .connected:  return call.callType == .video ? "Видеозвонок" : "Аудио звонок"
        case .ended:      return "Завершён"
        }
    }

    private var durationOrStatus: String {
        guard let started = call.connectedAt, call.state == .connected else {
            return stateLabel
        }
        let elapsed = Int(now.timeIntervalSince(started))
        let mm = elapsed / 60
        let ss = elapsed % 60
        if elapsed >= 3600 {
            let hh = elapsed / 3600
            return String(format: "%d:%02d:%02d", hh, mm % 60, ss)
        }
        return String(format: "%02d:%02d", mm, ss)
    }
}

// MARK: - WebRTC video host

#if canImport(WebRTC)
/// SwiftUI-обёртка над `RTCMTLVideoView`. Подходит для отображения
/// удалённого (или локального) RTCVideoTrack.
struct RTCVideoSwiftUIView: UIViewRepresentable {
    let track: RTCVideoTrack
    let isLocal: Bool

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        view.videoContentMode = .scaleAspectFill
        if isLocal { view.transform = CGAffineTransform(scaleX: -1, y: 1) }
        track.add(view)
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        // ничего обновлять не нужно — track сам пушит кадры.
    }

    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: ()) {
        // Track будет удалён вместе с CallManager.teardownCall.
    }
}
#endif
