//
//  AIChatView.swift — Ритм AI ассистент.
//  POST /ai/chat body { messages: [{role, content}] } → { text, tool_results? }
//
//  Редизайн под web — большой gradient hero на пустом, suggestion-chips,
//  bubbles с avatar/sparkles, paperclip-input bar.
//

import SwiftUI
import UIKit

// MARK: - Models

struct AIChatMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let role: String     // "user" | "assistant" | "system"
    let content: String

    init(role: String, content: String) {
        self.id = UUID()
        self.role = role
        self.content = content
    }
    enum CodingKeys: String, CodingKey { case role, content }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.role = try c.decode(String.self, forKey: .role)
        self.content = try c.decode(String.self, forKey: .content)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content)
    }
}

private struct AIChatRequest: Encodable {
    let messages: [AIChatMessage]
}

private struct AIChatResponse: Decodable {
    let text: String
    let tool_results: [AIToolResult]?
}

private struct AIToolResult: Decodable {
    let name: String?
    let result: AnyDecodable?
}

/// Гибкий decoder для tool_results.result.
struct AnyDecodable: Decodable {
    let value: Any?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let i = try? c.decode(Int.self) { value = i }
        else if let d = try? c.decode(Double.self) { value = d }
        else if let b = try? c.decode(Bool.self) { value = b }
        else { value = nil }
    }
}

// MARK: - View

struct AIChatView: View {
    @EnvironmentObject var tabSelection: TabSelectionStore
    @State private var messages: [AIChatMessage] = []
    @State private var input: String = ""
    @State private var sending = false
    @State private var error: String?
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Inline-header: «Назад» (на главную) + заголовок + очистить.
            HStack(spacing: 8) {
                Button {
                    inputFocused = false
                    tabSelection.selection = .dashboard
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Theme.accent)
                        .frame(width: 32, height: 32)
                }
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [Theme.accent, Theme.purple, Theme.pink],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .frame(width: 24, height: 24)
                    Image(systemName: "sparkles")
                        .foregroundColor(.white)
                        .font(.system(size: 11, weight: .bold))
                }
                Text("Ритм AI")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                if !messages.isEmpty {
                    Button {
                        messages.removeAll()
                        error = nil
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Theme.danger)
                            .frame(width: 32, height: 32)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Theme.surfaceBackground
                    .overlay(Rectangle().fill(Theme.separator).frame(height: 0.5),
                             alignment: .bottom)
                    .ignoresSafeArea(edges: .top)
            )

            if messages.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(messages) { msg in
                                MessageBubble(message: msg)
                                    .id(msg.id)
                            }
                            if sending {
                                HStack {
                                    TypingIndicator()
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
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
            }

            if let err = error {
                Text(err)
                    .font(.dsCaption)
                    .foregroundColor(Theme.danger)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }

            inputBar
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        // Полностью прячем таб-бар, пока пользователь в AI-чате — иначе
        // плавающая таблетка перекрывает поле ввода (особенно с клавиатурой).
        // Выход — кнопка «‹» в кастомном header'е выше → возврат на Главную.
        .hidesTabBar()
        .toolbar(.hidden, for: .navigationBar)
    }

    @ViewBuilder
    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 22) {
                Spacer().frame(height: 32)

                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [Theme.accent, Theme.purple, Theme.pink],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .frame(width: 96, height: 96)
                        .shadow(color: Theme.purple.opacity(0.35), radius: 20, x: 0, y: 8)
                    Image(systemName: "sparkles")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundColor(.white)
                }

                VStack(spacing: 6) {
                    Text("Ритм AI")
                        .font(.system(size: 32, weight: .bold))
                        .tracking(-0.6)
                        .foregroundColor(Theme.textPrimary)
                    Text("Помощник по корпоративным задачам.\nМожет записать в график, найти сотрудника, ответить на вопрос.")
                        .font(.dsBodySM)
                        .foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 32)

                VStack(spacing: 8) {
                    ForEach(suggestions, id: \.self) { s in
                        Button {
                            input = s
                            Task { await send() }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "sparkle")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(Theme.accent)
                                Text(s)
                                    .font(.dsBodySM)
                                    .foregroundColor(Theme.textPrimary)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 4)
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(Theme.textTertiary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.surfaceBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                                    .strokeBorder(Theme.border, lineWidth: 0.5)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                        }
                        .buttonStyle(DSPressScaleStyle())
                    }
                }
                .padding(.horizontal, 16)

                Spacer().frame(height: 16)
            }
        }
    }

    private let suggestions = [
        "Изменить статус на онлайн",
        "Какой у меня сегодня график?",
        "Найди коллег из отдела разработки",
        "Что нового в компании?",
    ]

    @ViewBuilder
    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button {
                // Заглушка для attachments — оставлено для совместимости с web-версией
            } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(Theme.textTertiary)
                    .frame(width: 38, height: 38)
                    .background(Theme.surfaceBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 19, style: .continuous)
                            .strokeBorder(Theme.border, lineWidth: 0.5)
                    )
                    .clipShape(Circle())
            }
            .buttonStyle(DSPressScaleStyle())
            .disabled(true)
            .opacity(0.5)

            TextField("Спросите Ритм AI…", text: $input, axis: .vertical)
                .focused($inputFocused)
                .lineLimit(1...5)
                .font(.system(size: 15))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.surfaceBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Theme.border, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

            Button {
                Task { await send() }
            } label: {
                ZStack {
                    Circle()
                        .fill(canSend
                              ? AnyShapeStyle(LinearGradient(
                                    colors: [Theme.accent, Theme.purple, Theme.pink],
                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                              : AnyShapeStyle(Theme.textTertiary.opacity(0.3)))
                        .frame(width: 38, height: 38)
                    Image(systemName: "arrow.up")
                        .foregroundColor(.white)
                        .font(.system(size: 15, weight: .bold))
                }
                .shadow(color: canSend ? Theme.accent.opacity(0.35) : .clear,
                        radius: 10, x: 0, y: 3)
            }
            .disabled(!canSend || sending)
            .buttonStyle(DSPressScaleStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.cardBackground)
        .overlay(
            Rectangle()
                .fill(Theme.separator)
                .frame(height: 0.5),
            alignment: .top
        )
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        let userMsg = AIChatMessage(role: "user", content: text)
        messages.append(userMsg)
        sending = true
        error = nil
        defer { sending = false }
        do {
            let resp: AIChatResponse = try await APIClient.shared.post(
                "ai/chat",
                body: AIChatRequest(messages: messages)
            )
            messages.append(AIChatMessage(role: "assistant", content: resp.text))
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}

// MARK: - Bubble

private struct MessageBubble: View {
    let message: AIChatMessage

    var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 40) }
            if !isUser {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [Theme.accent, Theme.purple, Theme.pink],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .frame(width: 30, height: 30)
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            Text(message.content)
                .font(.dsBodyLG)
                .foregroundColor(isUser ? .white : Theme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    Group {
                        if isUser {
                            LinearGradient(
                                colors: [Theme.accent, Theme.purple],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        } else {
                            Theme.surfaceBackground
                        }
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(isUser ? Color.clear : Theme.border, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
            if !isUser { Spacer(minLength: 40) }
        }
        .padding(.horizontal, 12)
    }
}

private struct TypingIndicator: View {
    @State private var phase = 0
    let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Theme.accent, Theme.purple, Theme.pink],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 30, height: 30)
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
            }
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Theme.textTertiary)
                        .frame(width: 7, height: 7)
                        .opacity(phase == i ? 1.0 : 0.3)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.surfaceBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .onReceive(timer) { _ in
            phase = (phase + 1) % 3
        }
    }
}
