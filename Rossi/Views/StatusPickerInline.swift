//
//  StatusPickerInline.swift — нативный пикер пользовательского статуса
//  (online / busy / away / vacation / sick) для размещения в любом header.
//
//  Зеркалит web-версию: apps/web/src/components/layout/StatusPicker.tsx.
//
//  Endpoints:
//    GET  /presence/me             — { status, text, lastSeenAt, ... }
//    POST /presence/me  { status }  — обновить
//

import SwiftUI

struct PresenceStatusInfo {
    let key: String
    let label: String
    let color: Color
    let icon: String
}

private let PRESENCE_STATUSES: [PresenceStatusInfo] = [
    .init(key: "online",   label: "В сети",       color: Color(red: 0.20, green: 0.78, blue: 0.35), icon: "circle.fill"),
    .init(key: "busy",     label: "Не беспокоить", color: Color(red: 0.86, green: 0.30, blue: 0.22), icon: "minus.circle.fill"),
    .init(key: "away",     label: "Отошёл",       color: Color(red: 0.96, green: 0.65, blue: 0.14), icon: "moon.fill"),
    .init(key: "vacation", label: "Отпуск",       color: Color(red: 0.36, green: 0.61, blue: 0.95), icon: "sun.max.fill"),
    .init(key: "sick",     label: "Болею",        color: Color(red: 0.62, green: 0.40, blue: 0.94), icon: "bandage.fill"),
]

private struct PresenceMe: Decodable {
    let status: String?
}

struct StatusPickerInline: View {
    @State private var current: String = "online"
    @State private var isOpen: Bool = false
    @State private var saving: Bool = false

    private var info: PresenceStatusInfo {
        PRESENCE_STATUSES.first(where: { $0.key == current }) ?? PRESENCE_STATUSES[0]
    }

    var body: some View {
        Menu {
            ForEach(PRESENCE_STATUSES, id: \.key) { s in
                Button {
                    set(s.key)
                } label: {
                    Label {
                        Text(s.label)
                    } icon: {
                        Image(systemName: s.icon).foregroundColor(s.color)
                    }
                    if current == s.key {
                        Image(systemName: "checkmark")
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(info.color)
                    .frame(width: 8, height: 8)
                Text(info.label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.surfaceBackground)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
            .opacity(saving ? 0.6 : 1)
        }
        .task { await load() }
    }

    private func load() async {
        do {
            let me: PresenceMe = try await APIClient.shared.get("presence/me")
            if let s = me.status { self.current = s }
        } catch { /* keep default */ }
    }

    private struct SetBody: Encodable { let status: String }

    private func set(_ status: String) {
        guard status != current, !saving else { return }
        let prev = current
        current = status
        saving = true
        Task {
            defer { Task { @MainActor in saving = false } }
            do {
                _ = try await APIClient.shared.rawRequest(
                    "POST", "presence/me", body: SetBody(status: status)
                )
            } catch {
                // rollback
                await MainActor.run { current = prev }
            }
        }
    }
}
