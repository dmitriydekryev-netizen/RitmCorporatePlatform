//
//  ChatRealtime.swift — Socket.IO клиент для namespace `/chat`.
//
//  Зеркалит apps/web/src/lib/socket.ts:
//   • подключение через wss с auth: { token }
//   • events from server:
//       message:new          (Message)
//       message:edit         (Message)
//       message:delete       ({ id, chatId })
//       message:reaction     (Message)
//       chat:typing          ({ userId, chatId })
//   • events to server:
//       chat:join            ({ chatId })
//       chat:leave           ({ chatId })
//       chat:typing          ({ chatId })
//

import Foundation
import SocketIO
import Combine

@MainActor
final class ChatRealtime: ObservableObject {
    static let shared = ChatRealtime()

    @Published var connected = false
    /// Подписка на события — каждый ChatDetailView подписывается через `events` publisher.
    let messageNew    = PassthroughSubject<[String: Any], Never>()
    let messageEdit   = PassthroughSubject<[String: Any], Never>()
    let messageDelete = PassthroughSubject<[String: Any], Never>()
    let messageReact  = PassthroughSubject<[String: Any], Never>()
    let typing        = PassthroughSubject<[String: Any], Never>()
    /// presence:update { userId, status: "online" | "offline" } — глобальный презенс.
    let presence      = PassthroughSubject<[String: Any], Never>()
    /// user:read { userId, chatId, lastMessageId } — кто куда дочитал.
    let read          = PassthroughSubject<[String: Any], Never>()
    /// chat:pin { chatId, pinnedMessage } — закрепили / открепили сообщение.
    let chatPin       = PassthroughSubject<[String: Any], Never>()

    private var manager: SocketManager?
    private var socket: SocketIOClient?
    private var joinedChats = Set<String>()
    private var currentToken: String?

    private init() {}

    /// Connect (idempotent). Если уже подключены и токен тот же — no-op.
    func connect(token: String) {
        if connected, currentToken == token { return }
        disconnect()
        currentToken = token

        guard let url = URL(string: "https://rossihelp.ru") else { return }
        let manager = SocketManager(socketURL: url, config: [
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
        let s = manager.socket(forNamespace: "/chat")

        s.on(clientEvent: .connect) { [weak self] _, _ in
            Task { @MainActor in
                self?.connected = true
                // Перезаходим в чаты после реконнекта
                if let chats = self?.joinedChats {
                    for cid in chats { s.emit("chat:join", ["chatId": cid]) }
                }
            }
        }
        s.on(clientEvent: .disconnect) { [weak self] _, _ in
            Task { @MainActor in self?.connected = false }
        }
        s.on(clientEvent: .error) { _, _ in /* silent */ }

        s.on("message:new") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any] else { return }
            Task { @MainActor in self?.messageNew.send(dict) }
        }
        // Бэк эмитит `message:updated` / `message:deleted` (см. chat.gateway.ts).
        // Подписываемся на оба варианта для совместимости.
        s.on("message:updated") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any] else { return }
            Task { @MainActor in self?.messageEdit.send(dict) }
        }
        s.on("message:edit") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any] else { return }
            Task { @MainActor in self?.messageEdit.send(dict) }
        }
        s.on("message:deleted") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any] else { return }
            // Сервер шлёт { messageId } — нормализуем под старый ключ id.
            var norm = dict
            if let mid = dict["messageId"] as? String { norm["id"] = mid }
            Task { @MainActor in self?.messageDelete.send(norm) }
        }
        s.on("message:delete") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any] else { return }
            Task { @MainActor in self?.messageDelete.send(dict) }
        }
        s.on("message:reaction") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any] else { return }
            Task { @MainActor in self?.messageReact.send(dict) }
        }
        // Бэк (apps/api/src/modules/realtime/chat.gateway.ts) шлёт `user:typing`,
        // а от клиента ждёт `message:typing`. Подписываемся на оба варианта,
        // чтобы пережить любое переименование.
        s.on("user:typing") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any] else { return }
            Task { @MainActor in self?.typing.send(dict) }
        }
        s.on("chat:typing") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any] else { return }
            Task { @MainActor in self?.typing.send(dict) }
        }
        // Online/offline презенс — для DM-хедера «в сети / не в сети».
        s.on("presence:update") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any] else { return }
            Task { @MainActor in self?.presence.send(dict) }
        }
        s.on("user:read") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any] else { return }
            Task { @MainActor in self?.read.send(dict) }
        }
        // Pin сообщения — рассылается в комнату чата (если бэк такой ивент эмитит).
        s.on("chat:pin") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any] else { return }
            Task { @MainActor in self?.chatPin.send(dict) }
        }

        self.manager = manager
        self.socket = s
        s.connect()
    }

    func disconnect() {
        socket?.disconnect()
        socket = nil
        manager?.disconnect()
        manager = nil
        connected = false
        joinedChats.removeAll()
    }

    func join(chatId: String) {
        joinedChats.insert(chatId)
        socket?.emit("chat:join", ["chatId": chatId])
    }

    func leave(chatId: String) {
        joinedChats.remove(chatId)
        socket?.emit("chat:leave", ["chatId": chatId])
    }

    func sendTyping(chatId: String) {
        // Бэкенд (chat.gateway.ts) подписан на `message:typing`. Шлём оба
        // имени — на случай legacy/staging серверов с другим mapping.
        socket?.emit("message:typing", ["chatId": chatId])
        socket?.emit("chat:typing", ["chatId": chatId])
    }

    /// Сообщить серверу что мы дочитали до сообщения. Бэк ретранслирует
    /// событие как `user:read` остальным участникам.
    func sendRead(chatId: String, lastMessageId: String) {
        socket?.emit("message:read", ["chatId": chatId, "lastMessageId": lastMessageId])
    }
}

// MARK: - Decoding helper

extension ChatMessage {
    /// Декодим Socket.IO-словарь в ChatMessage.
    static func from(socketDict dict: [String: Any]) -> ChatMessage? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(ChatMessage.self, from: data)
    }
}
