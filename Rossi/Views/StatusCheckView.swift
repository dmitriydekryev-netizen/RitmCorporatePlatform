//
//  StatusCheckView.swift — список «проверок статуса» (health-чеки сервисов).
//
//  Endpoints (Nest backend):
//   • GET   /status-check                 — конфиг проверок
//        response: [{ id, name, url, method?, expectedStatus?, timeoutMs? }]
//   • POST  /status-check/check-all       — прогнать все проверки
//        response: [{ id, ok, status, latencyMs, error, checkedAt }]
//   • POST  /status-check/:id/check       — прогнать одну
//        response:  { id, ok, status, latencyMs, error, checkedAt }
//
//  Деталь — история результатов: бэк не хранит историю, поэтому ведём
//  в памяти список ручных прогонов внутри сессии.
//
//  iOS 16+, без iOS 17 API. Русский UI.
//

import SwiftUI

// MARK: - Models

struct StatusCheckService: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let url: String?
    let method: String?
    let expectedStatus: Int?
    let timeoutMs: Int?
}

struct StatusCheckResult: Codable, Identifiable, Hashable {
    let id: String
    let ok: Bool
    let status: Int?
    let latencyMs: Int?
    let error: String?
    let checkedAt: String?

    /// Локально-сгенерированный uuid для уникальности в SwiftUI ForEach,
    /// потому что у нескольких прогонов одного сервиса один и тот же `id`.
    var stableId: String { "\(id)-\(checkedAt ?? UUID().uuidString)" }
}

enum StatusKind {
    case passed, failed, pending

    var color: Color {
        switch self {
        case .passed:  return Theme.success
        case .failed:  return Theme.danger
        case .pending: return Theme.warning
        }
    }
    var label: String {
        switch self {
        case .passed:  return "OK"
        case .failed:  return "Ошибка"
        case .pending: return "Ожидание"
        }
    }
    var icon: String {
        switch self {
        case .passed:  return "checkmark.circle.fill"
        case .failed:  return "xmark.octagon.fill"
        case .pending: return "clock.fill"
        }
    }
}

// MARK: - Helpers

private func parseStatusISO(_ s: String?) -> Date? {
    guard let s = s, !s.isEmpty else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    let g = ISO8601DateFormatter()
    g.formatOptions = [.withInternetDateTime]
    return g.date(from: s)
}

private func kindFromResult(_ r: StatusCheckResult?) -> StatusKind {
    guard let r = r else { return .pending }
    return r.ok ? .passed : .failed
}

// MARK: - List

struct StatusCheckView: View {
    @State private var services: [StatusCheckService] = []
    @State private var lastResults: [String: StatusCheckResult] = [:]   // id → последний результат
    @State private var history: [String: [StatusCheckResult]] = [:]     // id → локальная история
    @State private var loading = true
    @State private var checking = false
    @State private var error: String?

    // MARK: - Auto-polling
    @State private var pollTask: Task<Void, Never>?
    @State private var lastUpdate: Date = Date()

    var body: some View {
        Group {
            if loading && services.isEmpty {
                ProgressView().tint(Theme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if services.isEmpty {
                EmptyStateView(
                    icon: "checkmark.shield",
                    title: "Проверок не настроено",
                    description: error ?? "Администратор пока не добавил ни одной health-проверки. Когда добавит — список появится здесь."
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        DSPageTitle(text: "Проверки статуса",
                                    subtitle: "\(services.count) сервис\(services.count == 1 ? "" : "ов")")

                        pollingIndicator

                        runAllButton

                        DSSectionHeader("Сервисы")
                        VStack(spacing: 8) {
                            ForEach(services) { svc in
                                NavigationLink {
                                    StatusCheckDetailView(
                                        service: svc,
                                        lastResult: lastResults[svc.id],
                                        initialHistory: history[svc.id] ?? [],
                                        onNewResult: { r in
                                            lastResults[svc.id] = r
                                            history[svc.id, default: []].insert(r, at: 0)
                                        }
                                    )
                                } label: {
                                    DSCard(radius: Radius.xl, padding: 12) {
                                        StatusCheckRow(
                                            service: svc,
                                            result: lastResults[svc.id]
                                        )
                                    }
                                }
                                .buttonStyle(DSPressScaleStyle())
                            }
                        }

                        if let err = error {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(Theme.danger)
                                Text(err).font(.dsCaption).foregroundColor(Theme.danger)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: Radius.md)
                                    .fill(Theme.danger.opacity(0.10))
                            )
                        }

                        Spacer(minLength: 16)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .background(Theme.pageBackground.ignoresSafeArea())
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await loadAndCheck() }
        .onAppear {
            // Запускаем фоновое опрашивание каждые 10 секунд.
            // Если уже запущен — не дублируем.
            guard pollTask == nil else { return }
            pollTask = Task {
                while !Task.isCancelled {
                    await load()
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                }
            }
        }
        .onDisappear {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    @ViewBuilder
    private var pollingIndicator: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.textTertiary)
            Text("Обновлено: \(Self.timeFormatter.string(from: lastUpdate))")
                .font(.dsCaption)
                .foregroundColor(Theme.textTertiary)
            if loading || checking {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(Theme.accent)
            }
            Spacer()
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    @ViewBuilder
    private var runAllButton: some View {
        Button {
            Task { await runAll() }
        } label: {
            HStack {
                if checking {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                Text(checking ? "Проверяем…" : "Запустить все проверки")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                LinearGradient(colors: [Theme.accent, Theme.purple],
                               startPoint: .leading, endPoint: .trailing)
            )
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(checking)
    }

    // MARK: Loading

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let list: [StatusCheckService] = try await APIClient.shared.get("status-check")
            self.services = list
            self.error = nil
            self.lastUpdate = Date()
        } catch {
            // На polling-цикле не очищаем services при сетевых ошибках,
            // чтобы UI не дёргался; обновляем только error.
            if services.isEmpty {
                self.services = []
            }
            self.error = apiUserMessage(error)
        }
    }

    private func loadAndCheck() async {
        await load()
        if !services.isEmpty { await runAll() }
    }

    private func runAll() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        do {
            let results: [StatusCheckResult] = try await APIClient.shared.post("status-check/check-all")
            for r in results {
                lastResults[r.id] = r
                history[r.id, default: []].insert(r, at: 0)
            }
            self.error = nil
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}

// MARK: - Row

private struct StatusCheckRow: View {
    let service: StatusCheckService
    let result: StatusCheckResult?

    var body: some View {
        let kind = kindFromResult(result)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Circle()
                    .fill(kind.color)
                    .frame(width: 12, height: 12)
                    .overlay(
                        Circle().stroke(kind.color.opacity(0.3), lineWidth: 4)
                    )
                Text(service.name)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(kind.label)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(kind.color.opacity(0.15))
                    .foregroundColor(kind.color)
                    .clipShape(Capsule())
            }
            if let url = service.url, !url.isEmpty {
                Text(url)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 10) {
                if let m = service.method, !m.isEmpty {
                    Text(m)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.accent.opacity(0.12))
                        .foregroundColor(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                if let r = result {
                    if let st = r.status {
                        Text("HTTP \(st)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    if let l = r.latencyMs {
                        Label("\(l) мс", systemImage: "speedometer")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if let date = parseStatusISO(r.checkedAt) {
                        Text(relativeTime(from: date))
                            .font(.caption2)
                            .foregroundColor(.tertiary)
                    }
                } else {
                    Spacer()
                    Text("ещё не проверялся")
                        .font(.caption2)
                        .foregroundColor(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Detail

struct StatusCheckDetailView: View {
    let service: StatusCheckService
    let lastResult: StatusCheckResult?
    let initialHistory: [StatusCheckResult]
    var onNewResult: (StatusCheckResult) -> Void

    @State private var history: [StatusCheckResult] = []
    @State private var checking = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerCard

                serviceConfigCard

                runButton

                if !history.isEmpty {
                    historyCard
                } else {
                    EmptyStateView(
                        icon: "clock.arrow.circlepath",
                        title: "История пуста",
                        description: "Запустите проверку, чтобы увидеть результат"
                    )
                    .frame(minHeight: 180)
                    .background(Theme.surfaceBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }

                if let err = error {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(Theme.danger)
                }
            }
            .padding(16)
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle(service.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Сливаем то, что уже было в списке + последний результат если есть.
            if history.isEmpty {
                history = initialHistory
                if let r = lastResult, !history.contains(where: { $0.checkedAt == r.checkedAt }) {
                    history.insert(r, at: 0)
                }
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var headerCard: some View {
        let latest = history.first ?? lastResult
        let kind = kindFromResult(latest)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(kind.color.opacity(0.15))
                        .frame(width: 56, height: 56)
                    Image(systemName: kind.icon)
                        .font(.title2)
                        .foregroundColor(kind.color)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(service.name).font(.title3.weight(.bold))
                    Text(kind.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(kind.color)
                }
                Spacer()
            }
            if let r = latest {
                HStack(spacing: 12) {
                    if let st = r.status {
                        Label("HTTP \(st)", systemImage: "number")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if let l = r.latencyMs {
                        Label("\(l) мс", systemImage: "speedometer")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if let date = parseStatusISO(r.checkedAt) {
                        Label(relativeTime(from: date), systemImage: "clock")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                if let e = r.error, !e.isEmpty {
                    Text(e)
                        .font(.caption)
                        .foregroundColor(Theme.danger)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.danger.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var serviceConfigCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Конфигурация", systemImage: "gear")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            Divider()
            if let url = service.url, !url.isEmpty {
                infoRow(label: "URL", value: url)
            }
            if let m = service.method, !m.isEmpty {
                infoRow(label: "Метод", value: m)
            }
            if let st = service.expectedStatus {
                infoRow(label: "Ожидаемый статус", value: "\(st)")
            }
            if let t = service.timeoutMs {
                infoRow(label: "Таймаут", value: "\(t) мс")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.subheadline).foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private var runButton: some View {
        Button {
            Task { await runOne() }
        } label: {
            HStack {
                if checking {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "play.circle.fill")
                }
                Text(checking ? "Проверяем…" : "Запустить проверку")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                LinearGradient(colors: [Theme.accent, Theme.purple],
                               startPoint: .leading, endPoint: .trailing)
            )
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(checking)
    }

    @ViewBuilder
    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("История прогонов", systemImage: "clock.arrow.circlepath")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 8)
            ForEach(history, id: \.stableId) { r in
                HistoryRow(result: r)
                if r.stableId != history.last?.stableId {
                    Divider().padding(.leading, 16)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func runOne() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        do {
            let r: StatusCheckResult = try await APIClient.shared.post("status-check/\(service.id)/check")
            history.insert(r, at: 0)
            onNewResult(r)
            self.error = nil
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}

private struct HistoryRow: View {
    let result: StatusCheckResult

    var body: some View {
        let kind: StatusKind = result.ok ? .passed : .failed
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(kind.color).frame(width: 10, height: 10)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(kind.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(kind.color)
                    if let st = result.status {
                        Text("HTTP \(st)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if let date = parseStatusISO(result.checkedAt) {
                        Text(relativeTime(from: date))
                            .font(.caption2)
                            .foregroundColor(.tertiary)
                    }
                }
                if let l = result.latencyMs {
                    Label("\(l) мс", systemImage: "speedometer")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if let e = result.error, !e.isEmpty {
                    Text(e)
                        .font(.caption)
                        .foregroundColor(Theme.danger)
                        .lineLimit(3)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
