//
//  CallManager.swift — менеджер аудио/видео-звонков для Rossi.
//
//  Подключается к существующему Socket.IO namespace `/chat` и слушает
//  события сигналинга, описанные в apps/api/src/modules/realtime/chat.gateway.ts:
//
//    Server → клиент:
//      call:incoming        ({ chatId, callId, callType, fromUserId })
//      call:existing-peers  ({ callId, peerIds: [String] })
//      call:peer-joined     ({ callId, peerId })
//      call:peer-left       ({ callId, peerId })
//      call:offer           ({ callId, fromUserId, sdp })
//      call:answer          ({ callId, fromUserId, sdp })
//      call:ice             ({ callId, fromUserId, candidate })
//      call:rejected        ({ callId, byUserId })
//      call:cancelled       ({ callId })
//      call:ended           ({ callId, status, duration })
//
//    Клиент → server:
//      call:invite          ({ chatId, callId, callType })
//      call:join            ({ chatId, callId })
//      call:leave           ({ chatId, callId })
//      call:reject          ({ callId, fromUserId })
//      call:cancel          ({ chatId, callId })
//      call:offer           ({ callId, toUserId, sdp })
//      call:answer          ({ callId, toUserId, sdp })
//      call:ice             ({ callId, toUserId, candidate })
//
//  WebRTC:
//   • Если SPM-пакет stasel/WebRTC подключён — используем настоящий peerConnection.
//   • Если нет — UI и signaling работают, аудио/видео-поток отсутствует
//     (это видно в `ActiveCallView` как заглушка). Это нормально для MVP.
//

import Foundation
import Combine
import SwiftUI
import SocketIO
import AVFoundation
#if canImport(AudioToolbox)
import AudioToolbox
#endif
#if canImport(WebRTC)
import WebRTC
#endif

// MARK: - Models

enum CallType: String, Codable {
    case audio
    case video
}

/// Входящий звонок — заявка от другого пользователя; пока не принят.
struct IncomingCall: Identifiable, Equatable {
    let id: String           // = callId
    let chatId: String
    let callType: CallType
    let fromUserId: String
    /// Имя/аватар звонящего — могут быть nil, если не успели подгрузить.
    var fromName: String?
    var fromAvatarUrl: String?
}

/// Активный звонок — либо исходящий, либо принятый входящий.
struct ActiveCall: Identifiable, Equatable {
    enum State: String { case dialing, ringing, connecting, connected, ended }

    let id: String           // = callId
    let chatId: String
    let callType: CallType
    let isOutgoing: Bool
    let peerName: String?
    let peerAvatarUrl: String?
    let peerUserId: String?
    var state: State
    /// Когда соединение реально установилось — для таймера длительности.
    var connectedAt: Date?
}

// MARK: - CallManager

@MainActor
final class CallManager: ObservableObject {
    static let shared = CallManager()

    @Published var incomingCall: IncomingCall?
    @Published var activeCall: ActiveCall?

    /// Локальные UI-состояния, которые читает `ActiveCallView`.
    @Published var isMuted: Bool = false
    @Published var isSpeakerOn: Bool = false
    @Published var isCameraOn: Bool = true
    @Published var isFrontCamera: Bool = true

    /// Идентификатор текущего пользователя (нужен для адресных offer/answer/ice).
    private var currentUserId: String?
    /// Имя текущего пользователя — для UI и push-метаданных (по желанию).
    private var currentUserName: String?

    /// Socket.IO-клиент — используем тот же manager, что и ChatRealtime,
    /// чтобы не плодить второе соединение. Если ChatRealtime ещё не connected,
    /// подключаемся отдельно (через тот же endpoint).
    private var manager: SocketManager?
    fileprivate var socket: SocketIOClient?
    private var bag = Set<AnyCancellable>()

    /// Состояние peer-connection'ов: peerUserId → connection.
    /// В 1-on-1 будет один элемент, в группе — N (mesh).
#if canImport(WebRTC)
    private let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let videoEncoder = RTCDefaultVideoEncoderFactory()
        let videoDecoder = RTCDefaultVideoDecoderFactory()
        return RTCPeerConnectionFactory(encoderFactory: videoEncoder, decoderFactory: videoDecoder)
    }()
    private var peers: [String: RTCPeerConnection] = [:]
    private var localAudioTrack: RTCAudioTrack?
    private var localVideoTrack: RTCVideoTrack?
    private var localVideoCapturer: RTCCameraVideoCapturer?
    /// Удалённые видеотреки — UI наблюдает через published словарь.
    @Published var remoteVideoTracks: [String: RTCVideoTrack] = [:]
#endif

    // MARK: - Audio feedback (ringtone / dial tone)

    /// Проигрыватели для кастомных звуковых файлов (если они есть в Resources/Sounds).
    private var ringtonePlayer: AVAudioPlayer?
    private var dialTonePlayer: AVAudioPlayer?
    /// Таймеры — на случай, когда мы используем системные звуки и должны
    /// перезапускать их вручную через AudioServices.
    private var ringtoneTimer: Timer?
    private var dialToneTimer: Timer?
    /// Флаг — настроена ли уже AVAudioSession под звонок.
    private var audioSessionConfigured: Bool = false

    /// Системный рингтон iPhone (стандартный «opening»). Используется как fallback.
    private static let systemRingtoneSoundID: SystemSoundID = 1322
    /// Системный гудок «calling». 1306 — короткий звуковой эффект DTMF; 1100 — «звонок» в OS.
    private static let systemDialToneSoundID: SystemSoundID = 1306

    private init() {}

    // MARK: - Setup

    /// Привязать менеджер к текущему пользователю и токену.
    /// Вызываем из `RossiApp` после успешной авторизации (как уже делает ChatRealtime).
    func attach(userId: String, token: String, userName: String? = nil) {
        // Если уже подключены под этим же пользователем — ничего не делаем.
        if currentUserId == userId, socket?.status == .connected { return }
        detach()
        currentUserId = userId
        currentUserName = userName

        guard let url = URL(string: "https://rossihelp.ru") else { return }
        let mgr = SocketManager(socketURL: url, config: [
            .log(false),
            .compress,
            .reconnects(true),
            .reconnectAttempts(-1),
            .reconnectWait(2),
            .reconnectWaitMax(15),
            .extraHeaders(["Origin": "https://rossihelp.ru"]),
            .connectParams(["token": token]),
            .forceWebsockets(true),
            .secure(true),
        ])
        let s = mgr.socket(forNamespace: "/chat")
        wireEvents(socket: s)
        self.manager = mgr
        self.socket = s
        s.connect()
    }

    func detach() {
        // Завершаем активный звонок (если есть).
        if activeCall != nil { endCall() }
        socket?.disconnect()
        socket = nil
        manager?.disconnect()
        manager = nil
        currentUserId = nil
        currentUserName = nil
        bag.removeAll()
    }

    // MARK: - Public API

    /// Инициировать исходящий звонок.
    func startCall(chatId: String, type: CallType, peerName: String? = nil, peerAvatarUrl: String? = nil, peerUserId: String? = nil) {
        guard activeCall == nil else { return }
        let callId = UUID().uuidString
        let call = ActiveCall(
            id: callId,
            chatId: chatId,
            callType: type,
            isOutgoing: true,
            peerName: peerName,
            peerAvatarUrl: peerAvatarUrl,
            peerUserId: peerUserId,
            state: .dialing,
            connectedAt: nil
        )
        activeCall = call

        // Локальные медиа создаём заранее — чтобы отдать треки в peer connection
        // как только peer-joined придёт.
        setupLocalMedia(for: type)
        // Начинаем играть гудки до тех пор, пока peer не ответит.
        startDialTone()

        socket?.emit("call:invite", [
            "chatId": chatId,
            "callId": callId,
            "callType": type.rawValue,
        ])
        // Сразу же присоединяемся к комнате call:<id>.
        socket?.emit("call:join", [
            "chatId": chatId,
            "callId": callId,
        ])
    }

    /// Принять входящий звонок.
    func acceptCall(_ call: IncomingCall) {
        incomingCall = nil
        stopRingtone()
        let active = ActiveCall(
            id: call.id,
            chatId: call.chatId,
            callType: call.callType,
            isOutgoing: false,
            peerName: call.fromName,
            peerAvatarUrl: call.fromAvatarUrl,
            peerUserId: call.fromUserId,
            state: .connecting,
            connectedAt: nil
        )
        activeCall = active

        setupLocalMedia(for: call.callType)
        socket?.emit("call:join", [
            "chatId": call.chatId,
            "callId": call.id,
        ])
    }

    /// Отклонить входящий звонок.
    func rejectCall(_ call: IncomingCall) {
        socket?.emit("call:reject", [
            "callId": call.id,
            "fromUserId": call.fromUserId,
        ])
        incomingCall = nil
        stopRingtone()
    }

    /// Завершить активный звонок (или отменить исходящий до ответа).
    func endCall() {
        guard let call = activeCall else { return }
        if call.isOutgoing && call.state == .dialing {
            socket?.emit("call:cancel", [
                "chatId": call.chatId,
                "callId": call.id,
            ])
        } else {
            socket?.emit("call:leave", [
                "chatId": call.chatId,
                "callId": call.id,
            ])
        }
        teardownCall()
    }

    // MARK: - UI controls

    func toggleMute() {
        isMuted.toggle()
#if canImport(WebRTC)
        localAudioTrack?.isEnabled = !isMuted
#endif
    }

    func toggleSpeaker() {
        isSpeakerOn.toggle()
#if canImport(AVFoundation)
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(isSpeakerOn ? .speaker : .none)
#endif
    }

    func toggleCamera() {
        isCameraOn.toggle()
#if canImport(WebRTC)
        localVideoTrack?.isEnabled = isCameraOn
#endif
    }

    func flipCamera() {
        isFrontCamera.toggle()
#if canImport(WebRTC)
        startCapture()
#endif
    }

    // MARK: - Socket events wiring

    private func wireEvents(socket s: SocketIOClient) {
        s.on(clientEvent: .connect) { _, _ in /* connected */ }
        s.on(clientEvent: .error)   { _, _ in /* silent */ }

        s.on("call:incoming") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any] else { return }
            Task { @MainActor in self?.handleIncoming(dict) }
        }
        s.on("call:existing-peers") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let peerIds = dict["peerIds"] as? [String] else { return }
            Task { @MainActor in self?.handleExistingPeers(peerIds) }
        }
        s.on("call:peer-joined") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let peerId = dict["peerId"] as? String else { return }
            Task { @MainActor in self?.handlePeerJoined(peerId) }
        }
        s.on("call:peer-left") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let peerId = dict["peerId"] as? String else { return }
            Task { @MainActor in self?.handlePeerLeft(peerId) }
        }
        s.on("call:offer") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any] else { return }
            Task { @MainActor in self?.handleRemoteOffer(dict) }
        }
        s.on("call:answer") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any] else { return }
            Task { @MainActor in self?.handleRemoteAnswer(dict) }
        }
        s.on("call:ice") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any] else { return }
            Task { @MainActor in self?.handleRemoteIce(dict) }
        }
        s.on("call:rejected") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let callId = dict["callId"] as? String else { return }
            Task { @MainActor in
                if self?.activeCall?.id == callId { self?.teardownCall(reason: "rejected") }
            }
        }
        s.on("call:cancelled") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let callId = dict["callId"] as? String else { return }
            Task { @MainActor in
                if self?.incomingCall?.id == callId {
                    self?.incomingCall = nil
                    self?.stopRingtone()
                }
                if self?.activeCall?.id == callId { self?.teardownCall(reason: "cancelled") }
            }
        }
        s.on("call:ended") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let callId = dict["callId"] as? String else { return }
            Task { @MainActor in
                if self?.activeCall?.id == callId { self?.teardownCall(reason: "ended") }
            }
        }
    }

    // MARK: - Event handlers

    private func handleIncoming(_ dict: [String: Any]) {
        guard let chatId = dict["chatId"] as? String,
              let callId = dict["callId"] as? String,
              let typeRaw = dict["callType"] as? String,
              let type = CallType(rawValue: typeRaw),
              let fromUserId = dict["fromUserId"] as? String else { return }
        // Если уже разговариваем — не пушим второй "входящий".
        if activeCall != nil { return }

        incomingCall = IncomingCall(
            id: callId, chatId: chatId, callType: type,
            fromUserId: fromUserId, fromName: nil, fromAvatarUrl: nil
        )

        // Запускаем рингтон + вибрацию, пока пользователь не ответит/не отклонит.
        startRingtone()

        // Параллельно подгружаем профиль звонящего, чтобы показать имя/аватар.
        Task { [weak self] in
            await self?.loadCallerProfile(userId: fromUserId, callId: callId)
        }
    }

    private func loadCallerProfile(userId: String, callId: String) async {
        // /team/:id отдаёт публичный профиль; используем его как лёгкую ручку.
        struct TeamMemberDTO: Codable {
            let id: String
            let username: String?
            let firstName: String?
            let lastName: String?
            let avatarUrl: String?
        }
        let dto: TeamMemberDTO? = try? await APIClient.shared.get("team/\(userId)")
        await MainActor.run {
            guard self.incomingCall?.id == callId else { return }
            let full = "\(dto?.firstName ?? "") \(dto?.lastName ?? "")"
                .trimmingCharacters(in: .whitespaces)
            self.incomingCall?.fromName = full.isEmpty ? (dto?.username ?? "Звонок") : full
            self.incomingCall?.fromAvatarUrl = dto?.avatarUrl
        }
    }

    private func handleExistingPeers(_ peerIds: [String]) {
        // Мы только что вступили — для каждого peer создаём pc и шлём offer.
        for peerId in peerIds {
            createPeerConnection(for: peerId, asInitiator: true)
        }
    }

    private func handlePeerJoined(_ peerId: String) {
        // Существующий участник — ждёт offer от новичка.
        // (Если это мы новичок — нам пришёл existing-peers, см. выше.)
        // А если новичок — он сам инициатор, мы только готовим pc.
#if canImport(WebRTC)
        if peers[peerId] == nil {
            createPeerConnection(for: peerId, asInitiator: false)
        }
#else
        _ = peerId
#endif
        if activeCall?.state == .ringing || activeCall?.state == .dialing {
            activeCall?.state = .connecting
        }
    }

    private func handlePeerLeft(_ peerId: String) {
#if canImport(WebRTC)
        peers[peerId]?.close()
        peers.removeValue(forKey: peerId)
        remoteVideoTracks.removeValue(forKey: peerId)
        // 1-on-1: уход последнего peer'а = конец звонка
        if peers.isEmpty { teardownCall(reason: "peer-left") }
#else
        _ = peerId
        // Без WebRTC мы не отслеживаем peer'ов — любое peer-left трактуем
        // как конец 1-on-1 звонка.
        teardownCall(reason: "peer-left")
#endif
    }

    private func handleRemoteOffer(_ dict: [String: Any]) {
#if canImport(WebRTC)
        guard let from = dict["fromUserId"] as? String,
              let sdpDict = dict["sdp"] as? [String: Any],
              let sdp = sdpDict["sdp"] as? String else { return }
        let pc = peers[from] ?? createPeerConnection(for: from, asInitiator: false)
        let remote = RTCSessionDescription(type: .offer, sdp: sdp)
        pc?.setRemoteDescription(remote) { [weak self, weak pc] err in
            guard err == nil, let pc else { return }
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            pc.answer(for: constraints) { answer, err in
                guard let answer, err == nil else { return }
                pc.setLocalDescription(answer) { _ in
                    self?.socket?.emit("call:answer", [
                        "callId": self?.activeCall?.id ?? "",
                        "toUserId": from,
                        "sdp": ["type": "answer", "sdp": answer.sdp],
                    ])
                }
            }
        }
#else
        _ = dict
#endif
    }

    private func handleRemoteAnswer(_ dict: [String: Any]) {
#if canImport(WebRTC)
        guard let from = dict["fromUserId"] as? String,
              let sdpDict = dict["sdp"] as? [String: Any],
              let sdp = sdpDict["sdp"] as? String,
              let pc = peers[from] else { return }
        let remote = RTCSessionDescription(type: .answer, sdp: sdp)
        pc.setRemoteDescription(remote) { [weak self] _ in
            Task { @MainActor in
                self?.activeCall?.state = .connected
                self?.activeCall?.connectedAt = Date()
                // Удалённая сторона ответила — останавливаем гудки.
                self?.stopDialTone()
            }
        }
#else
        _ = dict
#endif
    }

    private func handleRemoteIce(_ dict: [String: Any]) {
#if canImport(WebRTC)
        guard let from = dict["fromUserId"] as? String,
              let cand = dict["candidate"] as? [String: Any],
              let sdp = cand["candidate"] as? String,
              let pc = peers[from] else { return }
        let mid = cand["sdpMid"] as? String
        let mline = cand["sdpMLineIndex"] as? Int32 ?? 0
        let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: mline, sdpMid: mid)
        pc.add(candidate) { _ in }
#else
        _ = dict
#endif
    }

    // MARK: - WebRTC plumbing

    @discardableResult
    private func createPeerConnection(for peerId: String, asInitiator: Bool) -> AnyObject? {
#if canImport(WebRTC)
        let config = RTCConfiguration()
        config.iceServers = [RTCIceServer(urlStrings: [
            "stun:stun.l.google.com:19302",
            "stun:stun1.l.google.com:19302",
        ])]
        config.sdpSemantics = .unifiedPlan

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let delegate = PeerDelegate(peerId: peerId, owner: self)
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: delegate) else { return nil }
        delegate.retain()
        peers[peerId] = pc

        // Прицепляем локальные треки (они должны быть созданы в setupLocalMedia).
        if let audio = localAudioTrack {
            pc.add(audio, streamIds: ["rossi-stream"])
        }
        if let video = localVideoTrack {
            pc.add(video, streamIds: ["rossi-stream"])
        }

        if asInitiator {
            let offerC = RTCMediaConstraints(mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": (activeCall?.callType == .video) ? "true" : "false",
            ], optionalConstraints: nil)
            pc.offer(for: offerC) { [weak self, weak pc] sdp, _ in
                guard let sdp, let pc else { return }
                pc.setLocalDescription(sdp) { _ in
                    self?.socket?.emit("call:offer", [
                        "callId": self?.activeCall?.id ?? "",
                        "toUserId": peerId,
                        "sdp": ["type": "offer", "sdp": sdp.sdp],
                    ])
                }
            }
        }
        return pc
#else
        _ = peerId; _ = asInitiator
        return nil
#endif
    }

    private func setupLocalMedia(for type: CallType) {
#if canImport(WebRTC)
        // Audio
        let audioConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let audioSource = factory.audioSource(with: audioConstraints)
        let audio = factory.audioTrack(with: audioSource, trackId: "rossi-audio")
        self.localAudioTrack = audio

        // Video
        if type == .video {
            let videoSource = factory.videoSource()
            let video = factory.videoTrack(with: videoSource, trackId: "rossi-video")
            self.localVideoTrack = video
            let capturer = RTCCameraVideoCapturer(delegate: videoSource)
            self.localVideoCapturer = capturer
            startCapture()
        }

        // Audio session — для звонка нужен playAndRecord.
        // Используем системный AVAudioSession (а не RTCAudioSession) — у разных
        // версий stasel/WebRTC разная сигнатура setCategory, AVAudioSession стабильнее.
        ensureAudioSessionConfigured()
#else
        _ = type
        // Без WebRTC мы всё равно хотим иметь рабочую AVAudioSession для
        // ringtone/dial tone — но реальная её настройка отложена до момента,
        // когда пойдёт первый звук (см. ensureAudioSessionConfigured).
#endif
    }

#if canImport(WebRTC)
    private func startCapture() {
        guard let capturer = localVideoCapturer else { return }
        let position: AVCaptureDevice.Position = isFrontCamera ? .front : .back
        let devices = RTCCameraVideoCapturer.captureDevices()
        guard let device = devices.first(where: { $0.position == position }) ?? devices.first else { return }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let format = formats
            .sorted { (CMVideoFormatDescriptionGetDimensions($0.formatDescription).width)
                    < (CMVideoFormatDescriptionGetDimensions($1.formatDescription).width) }
            .first { CMVideoFormatDescriptionGetDimensions($0.formatDescription).width >= 640 }
            ?? formats.last
        guard let format else { return }
        let fps = (format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 30)
        capturer.startCapture(with: device, format: format, fps: Int(fps))
    }
#endif

    private func teardownCall(reason: String? = nil) {
        // Сначала глушим звуки — иначе AVAudioSession.setActive(false) может ругнуться,
        // если плеер ещё держит сессию.
        stopRingtone()
        stopDialTone()

#if canImport(WebRTC)
        for (_, pc) in peers { pc.close() }
        peers.removeAll()
        remoteVideoTracks.removeAll()
        localVideoCapturer?.stopCapture()
        localVideoCapturer = nil
        localVideoTrack = nil
        localAudioTrack = nil
#endif

        // Деактивируем аудио-сессию (и для WebRTC, и для случая когда мы
        // включали её только под ringtone/dial tone без WebRTC).
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        audioSessionConfigured = false

        activeCall = nil
        isMuted = false
        isSpeakerOn = false
        isCameraOn = true
        isFrontCamera = true
        _ = reason
    }

    // MARK: - Audio session

    /// Настроить AVAudioSession под звонок: playAndRecord + voiceChat.
    /// Идемпотентно — повторные вызовы безопасны.
    private func ensureAudioSessionConfigured() {
        if audioSessionConfigured { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord,
                                 mode: .voiceChat,
                                 options: [.defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true)
        audioSessionConfigured = true
    }

    // MARK: - Ringtone (incoming call)

    /// Запустить рингтон + вибрацию. Если в bundle лежит `incoming.caf` или
    /// `incoming.mp3` — играем его в loop через AVAudioPlayer. Иначе — дёргаем
    /// системный звук (1322) каждые 2.5s через Timer и параллельно вибрируем.
    private func startRingtone() {
        // Если уже играет — не перезапускаем.
        if ringtonePlayer?.isPlaying == true || ringtoneTimer != nil { return }

        ensureAudioSessionConfigured()

        if let url = ringtoneFileURL() {
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.numberOfLoops = -1
                player.volume = 1.0
                player.prepareToPlay()
                player.play()
                ringtonePlayer = player
            } catch {
                playSystemRingtoneTick()
            }
        } else {
            playSystemRingtoneTick()
        }

        // Вибрация — каждые 2.5s одновременно с тиком.
        let timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Если играет файл-плеер — нам нужен только vibrate, без перезапуска системного звука.
            #if canImport(AudioToolbox)
            AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
            #endif
            if self.ringtonePlayer == nil {
                #if canImport(AudioToolbox)
                AudioServicesPlaySystemSound(Self.systemRingtoneSoundID)
                #endif
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ringtoneTimer = timer
    }

    /// Однократный «тик» системного рингтона + вибрация (используется для первого
    /// вызова, до того как Timer стартует следующий цикл).
    private func playSystemRingtoneTick() {
        #if canImport(AudioToolbox)
        AudioServicesPlaySystemSound(Self.systemRingtoneSoundID)
        AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
        #endif
    }

    fileprivate func stopRingtone() {
        ringtonePlayer?.stop()
        ringtonePlayer = nil
        ringtoneTimer?.invalidate()
        ringtoneTimer = nil
    }

    /// URL встроенного файла рингтона, если он есть в bundle.
    private func ringtoneFileURL() -> URL? {
        let bundle = Bundle.main
        if let url = bundle.url(forResource: "incoming", withExtension: "caf") { return url }
        if let url = bundle.url(forResource: "incoming", withExtension: "mp3") { return url }
        return nil
    }

    // MARK: - Dial tone (outgoing call)

    /// Гудки на исходящем вызове. Аналогично рингтону: либо файл, либо системный
    /// звук (1306) раз в 3s.
    private func startDialTone() {
        if dialTonePlayer?.isPlaying == true || dialToneTimer != nil { return }

        ensureAudioSessionConfigured()

        if let url = dialToneFileURL() {
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.numberOfLoops = -1
                player.volume = 0.8
                player.prepareToPlay()
                player.play()
                dialTonePlayer = player
                return
            } catch {
                // fall through to system-sound timer
            }
        }

        // Сразу первый «гудок», чтобы пользователь услышал отклик мгновенно.
        #if canImport(AudioToolbox)
        AudioServicesPlaySystemSound(Self.systemDialToneSoundID)
        #endif
        let timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
            #if canImport(AudioToolbox)
            AudioServicesPlaySystemSound(CallManager.systemDialToneSoundID)
            #endif
        }
        RunLoop.main.add(timer, forMode: .common)
        dialToneTimer = timer
    }

    fileprivate func stopDialTone() {
        dialTonePlayer?.stop()
        dialTonePlayer = nil
        dialToneTimer?.invalidate()
        dialToneTimer = nil
    }

    private func dialToneFileURL() -> URL? {
        let bundle = Bundle.main
        if let url = bundle.url(forResource: "dialing", withExtension: "caf") { return url }
        if let url = bundle.url(forResource: "dialing", withExtension: "mp3") { return url }
        return nil
    }
}

// MARK: - PeerDelegate (WebRTC)

#if canImport(WebRTC)
/// Делегат для одного RTCPeerConnection. Мы держим его strong через `retain()`
/// потому что RTCPeerConnection хранит делегата weak.
private final class PeerDelegate: NSObject, RTCPeerConnectionDelegate {
    let peerId: String
    weak var owner: CallManager?
    private var selfRef: PeerDelegate?

    init(peerId: String, owner: CallManager) {
        self.peerId = peerId
        self.owner = owner
    }

    func retain() { selfRef = self }
    func release() { selfRef = nil }

    // MARK: RTCPeerConnectionDelegate

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor [weak owner, peerId] in
            guard let owner else { return }
            switch newState {
            case .connected, .completed:
                owner.activeCall?.state = .connected
                if owner.activeCall?.connectedAt == nil { owner.activeCall?.connectedAt = Date() }
                // ICE поднялось — гудки/рингтон больше не нужны.
                owner.stopDialTone()
                owner.stopRingtone()
            case .failed, .disconnected, .closed:
                // Если ICE упал — даём шанс реконнекту, но логически peer ушёл.
                _ = peerId
            default: break
            }
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor [weak owner, peerId] in
            guard let owner, let callId = owner.activeCall?.id else { return }
            owner.socket?.emit("call:ice", [
                "callId": callId,
                "toUserId": peerId,
                "candidate": [
                    "candidate": candidate.sdp,
                    "sdpMid": candidate.sdpMid as Any,
                    "sdpMLineIndex": candidate.sdpMLineIndex,
                ],
            ])
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    // Unified-plan: новый трек.
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track else { return }
        if let videoTrack = track as? RTCVideoTrack {
            Task { @MainActor [weak owner, peerId] in
                owner?.remoteVideoTracks[peerId] = videoTrack
            }
        }
    }
}
#endif
