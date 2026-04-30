//
//  SupportView.swift — модуль поддержки.
//  Threads from Telegram/VK/Staya, оператор отвечает с iOS.
//
//  Endpoints:
//   • GET    /support/threads?status=&limit=        — список обращений
//   • GET    /support/threads/:id                   — детальный thread
//   • GET    /support/threads/:id/messages?limit=   — сообщения
//   • POST   /support/threads/:id/messages          — ответить { text, clientMessageId? }
//   • POST   /support/threads/:id/take              — взять себе
//   • POST   /support/threads/:id/close             — закрыть
//   • POST   /support/threads/:id/reopen            — переоткрыть
//

import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Models

struct SupportThread: Codable, Identifiable, Equatable {
    let id: String
    let externalChatId: String?
    let userBotChatId: String?
    let type: String?
    let title: String?
    let status: String           // open | in_progress | closed
    let queueType: String?
    let subject: String?
    let source: String?          // rossi | telegram | vk | ...
    let createdAt: String?
    let updatedAt: String?
    let lastMessageAt: String?
    let user: SupportPerson?
    let assignedTo: SupportPerson?
    let lastMessage: SupportLastMessage?
}

struct SupportPerson: Codable, Equatable, Identifiable {
    let id: String
    let username: String?
    let firstName: String?
    let lastName: String?
    let avatarUrl: String?

    var displayName: String {
        let s = "\(firstName ?? "") \(lastName ?? "")".trimmingCharacters(in: .whitespaces)
        if !s.isEmpty { return s }
        return username ?? "?"
    }
}

struct SupportLastMessage: Codable, Equatable {
    let id: String
    let content: String?
    let authorId: String?
    let createdAt: String?
}

struct SupportThreadsResponse: Codable {
    let data: [SupportThread]
    let meta: PaginationMeta?
}

struct SupportMessage: Codable, Identifiable, Equatable {
    let id: String
    let chatId: String?
    let content: String?
    let createdAt: String
    let isEdited: Bool?
    let author: SupportPerson?
    let messageKind: String?     // user | operator | system | bot
    let status: String?
    let media: SupportMedia?
    let file: SupportFile?
}

struct SupportMedia: Codable, Equatable {
    let url: String?
    let mime: String?
    let width: Int?
    let height: Int?
}

struct SupportFile: Codable, Equatable {
    let url: String?
    let mime: String?
    let name: String?
    let size: Int?
}

struct SupportMessagesResponse: Codable {
    let data: [SupportMessage]
}

// MARK: - List

struct SupportThreadsView: View {
    @EnvironmentObject var auth: AuthStore
    @State private var threads: [SupportThread] = []
    @State private var loading = true
    @State private var error: String?
    @State private var statusFilter: String = "in_progress"
    @State private var search: String = ""

    private let segments: [(label: String, value: String)] = [
        ("В работе", "in_progress"),
        ("Открытые", "open"),
        ("Закрытые", "closed"),
        ("Все", "")
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 12) {
                DSPageTitle(text: "Поддержка",
                            subtitle: "Обращения из Telegram, VK и Rossi")
                statusSegmented
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 6)

            content
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("Поддержка")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SupportBotConfigView()
                } label: {
                    Image(systemName: "wand.and.rays")
                }
            }
        }
        .searchable(text: $search, prompt: "Поиск по обращениям")
        .refreshable { await load() }
        .task { if threads.isEmpty { await load() } }
    }

    @ViewBuilder
    private var statusSegmented: some View {
        HStack(spacing: 4) {
            ForEach(segments, id: \.value) { seg in
                Button {
                    statusFilter = seg.value
                    Task { await load() }
                } label: {
                    Text(seg.label)
                        .font(.system(size: 13, weight: statusFilter == seg.value ? .semibold : .medium))
                        .foregroundColor(statusFilter == seg.value ? .white : Theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(statusFilter == seg.value ? Theme.accent : Color.clear)
                        )
                }
                .buttonStyle(DSPressScaleStyle())
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surfaceBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 0.5)
        )
    }

    private var filteredThreads: [SupportThread] {
        // 1) Фильтр «В работе» = только мои назначения (как вкладка «Мои» в вебе)
        var base = threads
        if statusFilter == "in_progress", let myId = auth.currentUser?.id {
            base = base.filter { $0.assignedTo?.id == myId }
        }

        // 2) Поиск
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter { t in
            let pieces = [
                t.title, t.subject,
                t.user?.displayName, t.user?.username,
                t.lastMessage?.content
            ].compactMap { $0?.lowercased() }
            return pieces.contains { $0.contains(q) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading && threads.isEmpty {
            ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredThreads.isEmpty {
            EmptyStateView(
                icon: "lifepreserver",
                title: "Нет обращений",
                description: error ?? "В этом фильтре пока нет обращений"
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(filteredThreads) { thread in
                        NavigationLink {
                            SupportThreadDetailView(threadId: thread.id, initialThread: thread)
                        } label: {
                            SupportThreadRow(thread: thread)
                        }
                        .buttonStyle(DSPressScaleStyle())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Theme.pageBackground)
        }
    }

    private func load() async {
        if threads.isEmpty { loading = true }
        defer { loading = false }
        var q: [String: String] = ["limit": "50"]
        if !statusFilter.isEmpty { q["status"] = statusFilter }
        // Как в вебе: вкладка «Мои» (in_progress) — добавляем assignedToId=<my-id>,
        // чтобы бэк отдал и orphan-state'ы, не попавшие в Staya top-100.
        if statusFilter == "in_progress", let myId = auth.currentUser?.id {
            q["assignedToId"] = myId
        }
        do {
            let resp: SupportThreadsResponse = try await APIClient.shared.get("support/threads", query: q)
            self.threads = resp.data
            self.error = nil
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}

// MARK: - Row

struct SupportThreadRow: View {
    let thread: SupportThread

    var body: some View {
        DSCard(radius: Radius.xl, padding: 14) {
            HStack(alignment: .top, spacing: 12) {
                AvatarCircle(url: thread.user?.avatarUrl, name: thread.user?.displayName ?? "?")
                    .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(thread.title ?? thread.user?.displayName ?? "Обращение")
                            .font(.dsBodyLG.weight(.semibold))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        statusBadge
                    }

                    if let last = thread.lastMessage?.content, !last.isEmpty {
                        Text(last)
                            .font(.dsBodySM)
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 6) {
                        if let src = thread.source, !src.isEmpty {
                            sourceBadge(src)
                        }
                        if let assignee = thread.assignedTo {
                            Text("· @\(assignee.username ?? "?")")
                                .font(.dsCaption)
                                .foregroundColor(Theme.textTertiary)
                        }
                        Spacer()
                        if let d = parseSupportDate(thread.lastMessageAt ?? thread.updatedAt) {
                            Text(relativeTime(from: d))
                                .font(.dsCaption)
                                .foregroundColor(Theme.textTertiary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        let (label, color): (String, Color) = {
            switch thread.status {
            case "open":        return ("Открыто",  Theme.accent)
            case "in_progress": return ("В работе", Theme.warning)
            case "closed":      return ("Закрыто",  Theme.textSecondary)
            default:            return (thread.status, Theme.textSecondary)
            }
        }()
        DSBadge(text: label, color: color, filled: false)
    }

    @ViewBuilder
    private func sourceBadge(_ src: String) -> some View {
        let (icon, label, color): (String, String, Color) = {
            switch src.lowercased() {
            case "telegram": return ("paperplane.fill", "Telegram", Theme.info)
            case "vk":       return ("person.crop.square.fill", "VK", Theme.indigo)
            case "rossi":    return ("waveform.path.ecg", "Rossi", Theme.accent)
            default:         return ("antenna.radiowaves.left.and.right", src.capitalized, Theme.textSecondary)
            }
        }()
        DSBadge(text: label, systemImage: icon, color: color, filled: false)
    }
}

// MARK: - Detail

struct SupportThreadDetailView: View {
    let threadId: String
    let initialThread: SupportThread

    @EnvironmentObject var auth: AuthStore
    @State private var thread: SupportThread?
    @State private var messages: [SupportMessage] = []
    @State private var loading = true
    @State private var sending = false
    @State private var taking = false
    @State private var error: String?
    @State private var inputText = ""
    @State private var showCloseConfirm = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var uploading = false
    @FocusState private var inputFocused: Bool

    /// Текущий thread (с учётом обновлённого assignedTo после "Взять").
    private var currentThread: SupportThread { thread ?? initialThread }

    /// Тред уже взят и именно мной → можно отвечать.
    private var isMine: Bool {
        guard let myId = auth.currentUser?.id else { return false }
        return currentThread.assignedTo?.id == myId
    }

    /// Тред никто не взял (status=open в терминах вебa).
    private var isUnassigned: Bool {
        currentThread.assignedTo == nil
    }

    /// Закрыт.
    private var isClosed: Bool {
        currentThread.status == "closed"
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if loading && messages.isEmpty {
                            ProgressView().tint(Theme.accent).padding(.top, 80)
                        } else {
                            ForEach(messages) { msg in
                                SupportMessageBubble(message: msg, currentUserId: auth.currentUser?.id)
                                    .id(msg.id)
                                    .padding(.horizontal, 12)
                            }
                        }
                    }
                    .padding(.vertical, 12)
                }
                .onChange(of: messages.count) { _ in
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            if let err = error {
                Text(err).font(.dsCaption).foregroundColor(Theme.danger)
                    .padding(.horizontal, 16).padding(.bottom, 4)
            }

            // Гейт: «Взять обращение» / «Закрыто» / «У другого оператора» / поле ввода
            footer
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .hidesTabBar()
        .navigationTitle(thread?.user?.displayName ?? initialThread.user?.displayName ?? "Поддержка")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    if isUnassigned {
                        Button { Task { await takeThread() } } label: {
                            Label("Взять себе", systemImage: "person.fill.checkmark")
                        }
                    }
                    if isClosed {
                        Button { Task { await reopenThread() } } label: {
                            Label("Переоткрыть", systemImage: "arrow.triangle.2.circlepath")
                        }
                    } else if isMine {
                        Button(role: .destructive) {
                            showCloseConfirm = true
                        } label: {
                            Label("Завершить обращение", systemImage: "xmark.circle")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Завершить обращение?", isPresented: $showCloseConfirm) {
            Button("Отмена", role: .cancel) {}
            Button("Завершить", role: .destructive) {
                Task { await closeThread() }
            }
        }
        .task {
            if thread == nil { thread = initialThread }
            await loadMessages()
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        if isClosed {
            closedBanner
        } else if isUnassigned {
            takeBanner
        } else if !isMine {
            assignedToOtherBanner
        } else {
            inputBar
        }
    }

    @ViewBuilder
    private var takeBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Сначала возьмите обращение")
                    .font(.dsBodyLG.weight(.semibold))
                    .foregroundColor(Theme.textPrimary)
                Text("Отвечать можно только после того как возьмёте обращение в работу")
                    .font(.dsCaption)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DSPrimaryButton(action: { Task { await takeThread() } },
                            loading: taking,
                            enabled: !taking,
                            gradient: true) {
                Label("Взять обращение", systemImage: "hand.raised.fill")
            }
        }
        .padding(14)
        .background(Theme.accent.opacity(0.05))
        .overlay(
            Rectangle().fill(Theme.separator).frame(height: 0.5),
            alignment: .top
        )
    }

    @ViewBuilder
    private var assignedToOtherBanner: some View {
        let name = currentThread.assignedTo?.displayName ?? "другой оператор"
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "person.fill.questionmark")
                .foregroundColor(Theme.warning)
                .font(.system(size: 18, weight: .semibold))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("В работе у: \(name)")
                    .font(.dsBodyLG.weight(.semibold))
                    .foregroundColor(Theme.textPrimary)
                Text("Отвечать может только текущий оператор обращения.")
                    .font(.dsCaption)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Theme.warning.opacity(0.06))
        .overlay(
            Rectangle().fill(Theme.separator).frame(height: 0.5),
            alignment: .top
        )
    }

    @ViewBuilder
    private var closedBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundColor(Theme.textSecondary)
                .font(.system(size: 18, weight: .semibold))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Обращение закрыто")
                    .font(.dsBodyLG.weight(.semibold))
                    .foregroundColor(Theme.textPrimary)
                Text("Чтобы продолжить переписку, переоткройте обращение.")
                    .font(.dsCaption)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Theme.surfaceBackground)
        .overlay(
            Rectangle().fill(Theme.separator).frame(height: 0.5),
            alignment: .top
        )
    }

    @ViewBuilder
    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Кнопка прикрепления медиа.
            // Бэк (apps/api/src/modules/support/support.controller.ts):
            //   POST /support/upload/photo (multipart) → { photoId } → шлём как mediaRef
            PhotosPicker(selection: $pickerItems,
                         maxSelectionCount: 1,
                         matching: .images) {
                ZStack {
                    Circle().fill(Theme.pageBackground)
                        .frame(width: 38, height: 38)
                    if uploading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "paperclip")
                            .foregroundColor(Theme.textSecondary)
                            .font(.system(size: 16, weight: .medium))
                    }
                }
                .overlay(Circle().strokeBorder(Theme.border, lineWidth: 0.5))
            }
            .disabled(uploading || sending)
            .onChange(of: pickerItems) { items in
                guard let item = items.first else { return }
                Task { await uploadAndSendPhoto(item) }
            }

            TextField("Ответить", text: $inputText, axis: .vertical)
                .focused($inputFocused)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.pageBackground)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .strokeBorder(Theme.border, lineWidth: 0.5)
                )

            Button { Task { await send() } } label: {
                ZStack {
                    Circle()
                        .fill(canSend
                              ? AnyShapeStyle(LinearGradient(
                                  colors: [Theme.accent, Theme.accentHover],
                                  startPoint: .top, endPoint: .bottom))
                              : AnyShapeStyle(Theme.textTertiary.opacity(0.3)))
                        .frame(width: 38, height: 38)
                    if sending {
                        ProgressView().tint(.white).scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.up")
                            .foregroundColor(.white)
                            .font(.system(size: 15, weight: .bold))
                    }
                }
            }
            .disabled(!canSend || sending)
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Theme.surfaceBackground)
        .overlay(
            Rectangle()
                .fill(Theme.separator)
                .frame(height: 0.5),
            alignment: .top
        )
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func loadMessages() async {
        loading = messages.isEmpty
        defer { loading = false }
        do {
            let resp: SupportMessagesResponse = try await APIClient.shared.get(
                "support/threads/\(threadId)/messages",
                query: ["limit": "100"]
            )
            self.messages = resp.data.sorted { $0.createdAt < $1.createdAt }
            self.error = nil
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func send() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let clientId = UUID().uuidString
        struct Body: Encodable { let text: String; let clientMessageId: String }
        sending = true
        defer { sending = false }
        do {
            _ = try await APIClient.shared.rawRequest(
                "POST", "support/threads/\(threadId)/messages",
                body: Body(text: text, clientMessageId: clientId)
            )
            inputText = ""
            await loadMessages()
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    /// Загружаем фото из PhotosPicker:
    ///  1) POST /support/upload/photo (multipart) → photoId
    ///  2) POST /support/threads/:id/messages с mediaRef=photoId
    private func uploadAndSendPhoto(_ item: PhotosPickerItem) async {
        defer { pickerItems = [] }
        uploading = true
        defer { uploading = false }
        do {
            guard let raw = try await item.loadTransferable(type: Data.self) else { return }
            let payload: Data = (UIImage(data: raw)?.jpegData(compressionQuality: 0.85)) ?? raw
            let filename = "support-\(Int(Date().timeIntervalSince1970)).jpg"
            let mime = "image/jpeg"

            // 1. Multipart-загрузка фото
            let upResp = try await uploadMultipart(
                path: "support/upload/photo",
                fieldName: "file",
                filename: filename,
                mime: mime,
                data: payload
            )
            struct UploadResp: Decodable {
                let photoId: String?
                let mediaRef: String?
            }
            let parsed = try JSONDecoder().decode(UploadResp.self, from: upResp)
            guard let mediaRef = parsed.mediaRef ?? parsed.photoId else {
                self.error = "Не удалось получить mediaRef после загрузки"
                return
            }

            // 2. Шлём сообщение с mediaRef
            struct MsgBody: Encodable {
                let text: String?
                let clientMessageId: String
                let mediaRef: String
            }
            let textTrim = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await APIClient.shared.rawRequest(
                "POST", "support/threads/\(threadId)/messages",
                body: MsgBody(
                    text: textTrim.isEmpty ? nil : textTrim,
                    clientMessageId: UUID().uuidString,
                    mediaRef: mediaRef
                )
            )
            inputText = ""
            await loadMessages()
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    /// Multipart POST через прямой URLSession (APIClient умеет только JSON).
    /// Берём accessToken из APIClient, чтобы попасть в защищённый endpoint.
    private func uploadMultipart(path: String,
                                 fieldName: String,
                                 filename: String,
                                 mime: String,
                                 data: Data) async throws -> Data {
        let token = await APIClient.shared.currentAccessToken()
        guard let url = URL(string: "https://rossihelp.ru/api/v1/\(path)") else {
            throw APIError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token = token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        let (respData, response) = try await URLSession.shared.upload(for: req, from: body)
        guard let http = response as? HTTPURLResponse else { throw APIError.noResponse }
        guard (200...299).contains(http.statusCode) else {
            throw APIError.http(status: http.statusCode, body: String(data: respData, encoding: .utf8))
        }
        return respData
    }

    private func takeThread() async {
        guard !taking else { return }
        taking = true
        defer { taking = false }
        do {
            _ = try await APIClient.shared.rawRequest("POST", "support/threads/\(threadId)/take")
            // Локально обновляем thread → assignedTo = me, status = in_progress.
            if let me = auth.currentUser {
                let assignee = SupportPerson(
                    id: me.id,
                    username: me.username,
                    firstName: me.profile?.firstName,
                    lastName: me.profile?.lastName,
                    avatarUrl: me.profile?.avatarUrl
                )
                let base = currentThread
                thread = SupportThread(
                    id: base.id,
                    externalChatId: base.externalChatId,
                    userBotChatId: base.userBotChatId,
                    type: base.type,
                    title: base.title,
                    status: "in_progress",
                    queueType: base.queueType,
                    subject: base.subject,
                    source: base.source,
                    createdAt: base.createdAt,
                    updatedAt: base.updatedAt,
                    lastMessageAt: base.lastMessageAt,
                    user: base.user,
                    assignedTo: assignee,
                    lastMessage: base.lastMessage
                )
            }
            error = nil
            await loadMessages()
        } catch APIError.http(_, let body) where (body ?? "").contains("ALREADY_ASSIGNED") {
            error = "Обращение уже взято другим оператором"
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func closeThread() async {
        do {
            _ = try await APIClient.shared.rawRequest("POST", "support/threads/\(threadId)/close")
            let base = currentThread
            thread = SupportThread(
                id: base.id,
                externalChatId: base.externalChatId,
                userBotChatId: base.userBotChatId,
                type: base.type,
                title: base.title,
                status: "closed",
                queueType: base.queueType,
                subject: base.subject,
                source: base.source,
                createdAt: base.createdAt,
                updatedAt: base.updatedAt,
                lastMessageAt: base.lastMessageAt,
                user: base.user,
                assignedTo: base.assignedTo,
                lastMessage: base.lastMessage
            )
            error = nil
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func reopenThread() async {
        do {
            _ = try await APIClient.shared.rawRequest("POST", "support/threads/\(threadId)/reopen")
            // После reopen бэк удаляет state-row → assignedTo = nil, status = open.
            let base = currentThread
            thread = SupportThread(
                id: base.id,
                externalChatId: base.externalChatId,
                userBotChatId: base.userBotChatId,
                type: base.type,
                title: base.title,
                status: "open",
                queueType: base.queueType,
                subject: base.subject,
                source: base.source,
                createdAt: base.createdAt,
                updatedAt: base.updatedAt,
                lastMessageAt: base.lastMessageAt,
                user: base.user,
                assignedTo: nil,
                lastMessage: base.lastMessage
            )
            error = nil
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}

// MARK: - Message bubble

struct SupportMessageBubble: View {
    let message: SupportMessage
    let currentUserId: String?

    var isMine: Bool {
        // operator-сообщения от текущего юзера в нашем UI справа
        if let uid = currentUserId, message.author?.id == uid { return true }
        if message.messageKind == "operator", message.author?.id == currentUserId { return true }
        return false
    }

    var isSystem: Bool {
        message.messageKind == "system" || message.messageKind == "bot"
    }

    var body: some View {
        if isSystem {
            HStack {
                Spacer()
                Text(message.content ?? "")
                    .font(.dsCaption)
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.surfaceBackground.opacity(0.6))
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
                Spacer()
            }
        } else {
            HStack(alignment: .bottom, spacing: 8) {
                if isMine { Spacer(minLength: 50) }
                if !isMine {
                    AvatarCircle(url: message.author?.avatarUrl, name: message.author?.displayName ?? "?")
                        .frame(width: 28, height: 28)
                }
                VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                    if !isMine, let name = message.author?.displayName {
                        Text(name)
                            .font(.dsCaption.weight(.semibold))
                            .foregroundColor(Theme.accent)
                            .padding(.horizontal, 12)
                    }
                    if let media = message.media, let urlStr = media.url, let url = URL(string: ensureAbsolute(urlStr)) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let img): img.resizable().scaledToFit()
                            default: Color.secondary.opacity(0.1).frame(height: 160)
                            }
                        }
                        .frame(maxWidth: 240, maxHeight: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    if let text = message.content, !text.isEmpty {
                        bubbleText(text)
                    }
                    if let f = message.file, let name = f.name {
                        Label(name, systemImage: "doc.fill")
                            .font(.dsCaption)
                            .foregroundColor(Theme.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Theme.surfaceBackground)
                            .clipShape(Capsule())
                            .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
                    }
                    if let d = parseSupportDate(message.createdAt) {
                        Text(relativeTime(from: d))
                            .font(.dsCaption)
                            .foregroundColor(Theme.textTertiary)
                            .padding(.horizontal, 8)
                    }
                }
                if !isMine { Spacer(minLength: 50) }
            }
        }
    }

    @ViewBuilder
    private func bubbleText(_ text: String) -> some View {
        Text(text)
            .font(.dsBodyLG)
            .foregroundColor(isMine ? .white : Theme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Group {
                    if isMine {
                        LinearGradient(
                            colors: [Theme.accent, Theme.accentHover],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    } else {
                        Theme.surfaceBackground
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(isMine ? Color.clear : Theme.border, lineWidth: 0.5)
            )
            .clipShape(BubbleShape(isMine: isMine))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Bubble Shape (asymmetric corners для tail-эффекта)

struct BubbleShape: Shape {
    let isMine: Bool

    func path(in rect: CGRect) -> Path {
        let big: CGFloat = 18
        let small: CGFloat = 4
        let tl: CGFloat = big
        let tr: CGFloat = big
        let bl: CGFloat = isMine ? big : small
        let br: CGFloat = isMine ? small : big

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr),
                    radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br),
                    radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl),
                    radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl),
                    radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}

// MARK: - Helpers

private let supportISOFormatters: [ISO8601DateFormatter] = {
    let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let f2 = ISO8601DateFormatter(); f2.formatOptions = [.withInternetDateTime]
    return [f1, f2]
}()

func parseSupportDate(_ s: String?) -> Date? {
    guard let s else { return nil }
    for f in supportISOFormatters {
        if let d = f.date(from: s) { return d }
    }
    return nil
}
