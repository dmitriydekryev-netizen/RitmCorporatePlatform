//
//  SupportBotConfigView.swift — конфигурация авто-ответчика (бота) поддержки.
//
//  Endpoints:
//   • GET    /support/bot/config             → { enabled: Bool, ... }
//   • PATCH  /support/bot/config             body: { enabled: Bool }
//   • GET    /support/bot/rules              → { data: [SupportBotRule] }
//   • POST   /support/bot/rules              body: { keyword, response }
//   • DELETE /support/bot/rules/:id
//
//  Если эндпоинт отдаёт 404 — graceful empty-state «Скоро будет».
//

import SwiftUI

// MARK: - DTO

struct SupportBotConfig: Codable {
    let enabled: Bool?
}

struct SupportBotRule: Codable, Identifiable, Hashable {
    let id: String
    let keyword: String
    let response: String
}

struct SupportBotRulesResponse: Codable {
    let data: [SupportBotRule]
}

private struct SupportBotConfigBody: Encodable {
    let enabled: Bool
}

private struct SupportBotRuleCreateBody: Encodable {
    let keyword: String
    let response: String
}

// MARK: - View

struct SupportBotConfigView: View {

    // Config
    @State private var enabled: Bool = false
    @State private var configLoading: Bool = false
    @State private var configError: String?
    @State private var configUnavailable: Bool = false

    // Rules
    @State private var rules: [SupportBotRule] = []
    @State private var rulesLoading: Bool = false
    @State private var rulesUnavailable: Bool = false
    @State private var rulesError: String?
    @State private var deletingRuleId: String?

    // Add-rule sheet
    @State private var showAddSheet: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                DSPageTitle(text: "Авто-ответчик",
                            subtitle: "Бот отвечает на ключевые слова в чатах поддержки")

                // ─── Toggle ──────────────────────────────────────────
                if configUnavailable {
                    unavailableCard(text: "Конфигурация бота появится в следующих обновлениях.")
                } else {
                    DSCard(radius: Radius.xl, padding: 14) {
                        HStack(alignment: .top, spacing: 12) {
                            DSIconTile(
                                systemImage: enabled ? "bolt.fill" : "bolt.slash",
                                color: enabled ? Theme.success : Theme.textTertiary,
                                size: 36
                            )
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Включить бота")
                                    .font(.dsBodyLG)
                                    .foregroundColor(Theme.textPrimary)
                                Text(enabled
                                     ? "Бот будет автоматически отвечать на сообщения, попадающие под правила."
                                     : "Все сообщения будут попадать оператору без авто-ответа.")
                                    .font(.dsCaption)
                                    .foregroundColor(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Toggle("", isOn: Binding(
                                get: { enabled },
                                set: { v in Task { await toggleEnabled(v) } }
                            ))
                            .labelsHidden()
                            .tint(Theme.accent)
                            .disabled(configLoading)
                        }
                    }
                    if let err = configError {
                        Text(err)
                            .font(.dsCaption)
                            .foregroundColor(Theme.danger)
                            .padding(.horizontal, 4)
                    }
                }

                // ─── Rules ──────────────────────────────────────────
                HStack {
                    DSSectionHeader("Авто-правила")
                    Spacer()
                    if !rulesUnavailable {
                        Button {
                            showAddSheet = true
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 22))
                                .foregroundColor(Theme.accent)
                        }
                        .padding(.bottom, 6)
                    }
                }

                if rulesUnavailable {
                    unavailableCard(text: "Правила бота появятся в следующих обновлениях.")
                } else if rulesLoading && rules.isEmpty {
                    DSCard(radius: Radius.xl, padding: 24) {
                        HStack {
                            Spacer()
                            ProgressView().tint(Theme.accent)
                            Spacer()
                        }
                    }
                } else if rules.isEmpty {
                    DSCard(radius: Radius.xl, padding: 18) {
                        VStack(spacing: 6) {
                            Image(systemName: "list.bullet.indent")
                                .font(.system(size: 26, weight: .light))
                                .foregroundColor(Theme.textTertiary)
                            Text("Пока нет правил")
                                .font(.dsBodyLG)
                                .foregroundColor(Theme.textPrimary)
                            Text("Добавьте первое правило, чтобы бот начал отвечать.")
                                .font(.dsCaption)
                                .foregroundColor(Theme.textTertiary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    VStack(spacing: 8) {
                        ForEach(rules) { rule in
                            ruleRow(rule)
                        }
                    }
                }

                if let err = rulesError {
                    Text(err)
                        .font(.dsCaption)
                        .foregroundColor(Theme.danger)
                        .padding(.horizontal, 4)
                }

                // ─── Add button (always visible at bottom) ──────────
                if !rulesUnavailable {
                    DSPrimaryButton(action: { showAddSheet = true }) {
                        Label("Добавить правило", systemImage: "plus")
                    }
                    .padding(.top, 4)
                }
            }
            .padding(16)
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("Бот поддержки")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAddSheet) {
            AddSupportRuleSheet { keyword, response in
                Task { await addRule(keyword: keyword, response: response) }
            }
            .presentationDetents([.medium, .large])
        }
        .task {
            await loadConfig()
            await loadRules()
        }
        .refreshable {
            await loadConfig()
            await loadRules()
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func unavailableCard(text: String) -> some View {
        DSCard(radius: Radius.xl, padding: 18) {
            VStack(spacing: 6) {
                Image(systemName: "clock.badge.questionmark")
                    .font(.system(size: 26, weight: .light))
                    .foregroundColor(Theme.textTertiary)
                Text("Скоро будет")
                    .font(.dsBodyLG)
                    .foregroundColor(Theme.textPrimary)
                Text(text)
                    .font(.dsCaption)
                    .foregroundColor(Theme.textTertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func ruleRow(_ rule: SupportBotRule) -> some View {
        DSCard(radius: Radius.lg, padding: 12) {
            HStack(alignment: .top, spacing: 12) {
                DSIconTile(systemImage: "text.bubble.fill",
                           color: Theme.accent, size: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(rule.keyword)
                        .font(.dsBodyLG.weight(.semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(2)
                    Text(rule.response)
                        .font(.dsBodySM)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button {
                    Task { await deleteRule(rule) }
                } label: {
                    if deletingRuleId == rule.id {
                        ProgressView().tint(Theme.danger).scaleEffect(0.7)
                    } else {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Theme.danger)
                    }
                }
                .buttonStyle(.plain)
                .frame(width: 32, height: 32)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Task { await deleteRule(rule) }
            } label: {
                Label("Удалить", systemImage: "trash")
            }
        }
    }

    // MARK: - API: config

    private func loadConfig() async {
        configLoading = true
        defer { configLoading = false }
        do {
            let resp: SupportBotConfig = try await APIClient.shared.get("support/bot/config")
            self.enabled = resp.enabled ?? false
            self.configUnavailable = false
            self.configError = nil
        } catch APIError.http(let status, _) where status == 404 {
            self.configUnavailable = true
        } catch {
            self.configUnavailable = true
        }
    }

    private func toggleEnabled(_ next: Bool) async {
        configLoading = true
        defer { configLoading = false }
        let prev = enabled
        enabled = next   // optimistic
        do {
            _ = try await APIClient.shared.rawRequest(
                "PATCH", "support/bot/config",
                body: SupportBotConfigBody(enabled: next)
            )
            configError = nil
        } catch {
            enabled = prev
            configError = "Не удалось изменить настройку"
        }
    }

    // MARK: - API: rules

    private func loadRules() async {
        rulesLoading = true
        defer { rulesLoading = false }
        do {
            let resp: SupportBotRulesResponse = try await APIClient.shared.get("support/bot/rules")
            self.rules = resp.data
            self.rulesUnavailable = false
            self.rulesError = nil
        } catch APIError.http(let status, _) where status == 404 {
            self.rulesUnavailable = true
        } catch {
            self.rulesUnavailable = true
        }
    }

    private func addRule(keyword: String, response: String) async {
        let body = SupportBotRuleCreateBody(keyword: keyword, response: response)
        do {
            let created: SupportBotRule = try await APIClient.shared.post(
                "support/bot/rules", body: body
            )
            rules.insert(created, at: 0)
            rulesError = nil
        } catch {
            rulesError = "Не удалось добавить правило"
            // На случай если бэк не вернул объект — перезагружаем список.
            await loadRules()
        }
    }

    private func deleteRule(_ rule: SupportBotRule) async {
        deletingRuleId = rule.id
        defer { deletingRuleId = nil }
        do {
            try await APIClient.shared.delete("support/bot/rules/\(rule.id)")
            rules.removeAll { $0.id == rule.id }
        } catch {
            rulesError = "Не удалось удалить правило"
        }
    }
}

// MARK: - Add-rule sheet

private struct AddSupportRuleSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (String, String) -> Void

    @State private var keyword: String = ""
    @State private var response: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Ключевое слово") {
                    TextField("например, «привет»", text: $keyword)
                }
                Section("Ответ бота") {
                    TextField("Текст автоматического ответа", text: $response, axis: .vertical)
                        .lineLimit(2...8)
                }
            }
            .navigationTitle("Новое правило")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        let k = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
                        let r = response.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !k.isEmpty, !r.isEmpty else { return }
                        onSave(k, r)
                        dismiss()
                    }
                    .disabled(
                        keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
        }
    }
}

#Preview {
    NavigationStack { SupportBotConfigView() }
}
