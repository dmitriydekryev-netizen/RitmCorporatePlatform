//
//  SystemHealthView.swift — мониторинг здоровья системы (нативно).
//
//  Endpoints:
//   • GET /admin/health/snapshot   — общий снапшот { status, services, metrics }
//   • GET /admin/health/services   — список сервисов
//   Polling каждые 10 секунд.
//

import SwiftUI

struct HealthSnapshot: Codable {
    let status: String?
    let timestamp: String?
    let services: [HealthService]?
    let metrics: HealthMetrics?
}

struct HealthMetrics: Codable {
    let cpu: Double?
    let memory: Double?
    let disk: Double?
}

struct HealthService: Codable, Identifiable {
    var id: String { name }
    let name: String
    let status: String         // ok | degraded | down
    let lastCheck: String?
    let latencyMs: Int?
    let message: String?
}

struct SystemHealthView: View {
    @State private var snapshot: HealthSnapshot?
    @State private var services: [HealthService] = []
    @State private var loading = true
    @State private var error: String?
    @State private var pollTask: Task<Void, Never>?
    @State private var lastUpdated: Date?

    var body: some View {
        ZStack {
            Theme.pageBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    DSPageTitle(text: "Здоровье системы",
                                subtitle: lastUpdated.map { "Обновлено: \(timeFmt.string(from: $0))" })
                        .padding(.top, 4)

                    heroCard

                    if let m = snapshot?.metrics {
                        DSSectionHeader("Метрики")
                        metricsGrid(m)
                    }

                    DSSectionHeader("Сервисы")
                    if loading && services.isEmpty {
                        ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.top, 30)
                    } else if let err = error, services.isEmpty {
                        EmptyStateView(icon: "exclamationmark.triangle", title: "Ошибка", description: err)
                    } else if services.isEmpty {
                        EmptyStateView(icon: "server.rack", title: "Скоро будет", description: "Сервисы не зарегистрированы")
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(services) { s in
                                HealthServiceCard(service: s)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Здоровье")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reloadOnce() }
        .onAppear {
            guard pollTask == nil else { return }
            pollTask = Task {
                while !Task.isCancelled {
                    await reloadOnce()
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                }
            }
        }
        .onDisappear {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    private func heroColors(for status: String) -> [Color] {
        switch status {
        case "ok": return [Theme.success, Theme.accent]
        case "degraded": return [Theme.warning, Theme.purple]
        case "down": return [Theme.danger, Theme.pink]
        default: return [Theme.indigo, Theme.purple]
        }
    }

    @ViewBuilder
    private var heroCard: some View {
        let status = snapshot?.status ?? "—"
        let colors = heroColors(for: status)
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "waveform.path.ecg").foregroundColor(.white).font(.title3)
                    Text("Статус").font(.dsH2).foregroundColor(.white)
                    Spacer()
                    Text(status.uppercased())
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.white.opacity(0.18))
                        .clipShape(Capsule())
                }
                Text(servicesSummary)
                    .font(.dsCaption)
                    .foregroundColor(.white.opacity(0.92))
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Radius.xl2, style: .continuous))
    }

    private var servicesSummary: String {
        let ok = services.filter { $0.status == "ok" }.count
        let degraded = services.filter { $0.status == "degraded" }.count
        let down = services.filter { $0.status == "down" }.count
        return "OK: \(ok)  •  degraded: \(degraded)  •  down: \(down)"
    }

    @ViewBuilder
    private func metricsGrid(_ m: HealthMetrics) -> some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        LazyVGrid(columns: cols, spacing: 10) {
            metricCard(title: "CPU", value: m.cpu, icon: "cpu")
            metricCard(title: "RAM", value: m.memory, icon: "memorychip")
            metricCard(title: "Disk", value: m.disk, icon: "internaldrive")
        }
    }

    @ViewBuilder
    private func metricCard(title: String, value: Double?, icon: String) -> some View {
        DSCard(radius: Radius.lg, padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    DSIconTile(systemImage: icon, color: metricColor(value), size: 28)
                    Spacer()
                }
                if let v = value {
                    Text("\(Int(v))%")
                        .font(.dsH2)
                        .foregroundColor(Theme.textPrimary)
                        .monospacedDigit()
                } else {
                    Text("—").font(.dsH2).foregroundColor(Theme.textTertiary)
                }
                Text(title).font(.dsCaption).foregroundColor(Theme.textSecondary)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3).fill(Theme.border).frame(height: 4)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(metricColor(value))
                            .frame(width: max(2, geo.size.width * CGFloat((value ?? 0) / 100)), height: 4)
                    }
                }.frame(height: 4)
            }
        }
    }

    private func metricColor(_ v: Double?) -> Color {
        guard let v = v else { return Theme.textTertiary }
        if v >= 85 { return Theme.danger }
        if v >= 65 { return Theme.warning }
        return Theme.success
    }

    private let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func reloadOnce() async {
        loading = (snapshot == nil)
        defer { loading = false; lastUpdated = Date() }
        // Snapshot
        if let snap: HealthSnapshot = try? await APIClient.shared.get("admin/health/snapshot") {
            self.snapshot = snap
            if let svc = snap.services {
                self.services = svc
            }
        }
        // Services list (separate endpoint)
        if let svc: [HealthService] = try? await APIClient.shared.get("admin/health/services") {
            self.services = svc
            self.error = nil
        } else if services.isEmpty {
            // fallback — leave services from snapshot, or set error if neither worked
            if snapshot == nil {
                self.error = "Endpoint недоступен"
            }
        }
    }
}

struct HealthServiceCard: View {
    let service: HealthService

    private var color: Color {
        switch service.status {
        case "ok": return Theme.success
        case "degraded": return Theme.warning
        case "down": return Theme.danger
        default: return Theme.textTertiary
        }
    }
    private var label: String {
        switch service.status {
        case "ok": return "OK"
        case "degraded": return "Проблемы"
        case "down": return "Не работает"
        default: return service.status
        }
    }

    var body: some View {
        DSCard(radius: Radius.lg, padding: 12) {
            HStack(spacing: 12) {
                Circle().fill(color).frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(service.name).font(.dsBodyLG.weight(.semibold)).foregroundColor(Theme.textPrimary)
                    if let m = service.message, !m.isEmpty {
                        Text(m).font(.dsCaption).foregroundColor(Theme.textTertiary).lineLimit(2)
                    } else if let lc = service.lastCheck {
                        Text("Последняя проверка: \(lc)")
                            .font(.dsCaption).foregroundColor(Theme.textTertiary).lineLimit(1)
                    }
                }
                Spacer()
                if let lat = service.latencyMs {
                    Text("\(lat)ms").font(.dsCaption.monospacedDigit()).foregroundColor(Theme.textTertiary)
                }
                DSBadge(text: label, color: color, filled: true)
            }
        }
    }
}

#Preview {
    NavigationStack { SystemHealthView() }
}
