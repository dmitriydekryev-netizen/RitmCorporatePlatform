//
//  AwardsAdminView.swift — нативная админка наград.
//
//  Endpoints (apps/api/src/modules/awards/awards.controller.ts):
//   • GET    /awards          — список (используется и для админа)
//   • GET    /awards/:id      — детали
//   • POST   /awards          — создать (DTO: title, description, fromName, template, colorScheme, font, signatureText, ...)
//   • PATCH  /awards/:id      — обновить
//   • DELETE /awards/:id      — удалить
//   • POST   /awards/:id/grant — { userId } выдать награду пользователю
//

import SwiftUI

struct AdminAward: Codable, Identifiable {
    let id: String
    let title: String?
    let name: String?
    let description: String?
    let fromName: String?
    let template: String?
    let colorScheme: String?
    let font: String?
    let signatureText: String?
    let signatureImageUrl: String?
    let logoRossi: Bool?
    let logoRitm: Bool?
    let issuedAt: String?
    let icon: String?
    let iconUrl: String?
    let year: Int?
    let grantedCount: Int?
    let category: String?
    let isActive: Bool?

    var displayTitle: String { title ?? name ?? "—" }
    var displayIcon: String { (icon?.isEmpty == false) ? icon! : "🏅" }
}

private let awardTemplates: [(String, String)] = [
    ("classic", "Классический"),
    ("modern", "Современный"),
    ("minimal", "Минимал"),
]
private let awardFonts: [(String, String)] = [
    ("inter", "Inter"),
    ("playfair", "Playfair"),
    ("merriweather", "Merriweather"),
]
private let awardColors: [String] = [
    "#0A84FF", "#FF3B30", "#34C759", "#FF9500",
    "#AF52DE", "#FF2D55", "#5856D6", "#8E8E93",
]

struct AwardsAdminView: View {
    @State private var items: [AdminAward] = []
    @State private var loading = true
    @State private var error: String?
    @State private var editing: AdminAward?
    @State private var granting: AdminAward?
    @State private var showCreate = false

    var body: some View {
        ZStack {
            Theme.pageBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    DSPageTitle(text: "Награды",
                                subtitle: items.isEmpty ? nil : "Всего: \(items.count)")
                        .padding(.top, 4)

                    if loading && items.isEmpty {
                        ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.top, 60)
                    } else if let err = error, items.isEmpty {
                        EmptyStateView(icon: "exclamationmark.triangle", title: "Ошибка", description: err)
                    } else if items.isEmpty {
                        EmptyStateView(icon: "rosette", title: "Скоро будет", description: "Награды ещё не созданы")
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(items) { item in
                                AwardAdminCard(item: item)
                                    .onTapGesture { editing = item }
                                    .contextMenu {
                                        Button("Редактировать") { editing = item }
                                        Button("Выдать сотруднику") { granting = item }
                                        Button("Удалить", role: .destructive) {
                                            Task { await deleteItem(item) }
                                        }
                                    }
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Награды")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showCreate = true } label: {
                    Image(systemName: "plus").font(.system(size: 16, weight: .semibold))
                }.tint(Theme.accent)
            }
        }
        .refreshable { await load() }
        .task { if items.isEmpty { await load() } }
        .sheet(item: $editing) { item in
            AwardEditSheet(item: item) { Task { await load() } }
        }
        .sheet(isPresented: $showCreate) {
            AwardEditSheet(item: nil) { Task { await load() } }
        }
        .sheet(item: $granting) { item in
            AwardGrantSheet(award: item) { Task { await load() } }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        if let arr: [AdminAward] = try? await APIClient.shared.get("awards") {
            self.items = arr; self.error = nil; return
        }
        do {
            let arr: [AdminAward] = try await APIClient.shared.get("admin/awards")
            self.items = arr
            self.error = nil
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func deleteItem(_ item: AdminAward) async {
        do {
            try await APIClient.shared.delete("awards/\(item.id)")
        } catch {
            try? await APIClient.shared.delete("admin/awards/\(item.id)")
        }
        await load()
    }
}

struct AwardAdminCard: View {
    let item: AdminAward

    private var color: Color {
        if let hex = item.colorScheme, let c = Color.fromHex(hex) { return c }
        return Theme.warning
    }

    var body: some View {
        DSCard(radius: Radius.lg, padding: 12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.sm)
                        .fill(color.opacity(0.15))
                    Image(systemName: "scroll.fill")
                        .foregroundColor(color)
                        .font(.system(size: 20))
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.displayTitle)
                        .font(.dsBodyLG.weight(.semibold))
                        .foregroundColor(Theme.textPrimary)
                    if let desc = item.description, !desc.isEmpty {
                        Text(desc).font(.dsCaption).foregroundColor(Theme.textTertiary).lineLimit(2)
                    }
                    HStack(spacing: 6) {
                        if let t = item.template {
                            DSBadge(text: t.capitalized, color: color, filled: false)
                        }
                        if let cnt = item.grantedCount {
                            DSBadge(text: "выдано: \(cnt)", color: Theme.success, filled: false)
                        }
                    }
                }
                Spacer()
            }
        }
    }
}

// MARK: - Edit/Create Sheet

struct AwardEditSheet: View {
    let item: AdminAward?
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var fromName = ""
    @State private var template = "classic"
    @State private var colorScheme = "#0A84FF"
    @State private var font = "inter"
    @State private var signatureText = ""
    @State private var signatureImageUrl = ""
    @State private var logoRossi = true
    @State private var logoRitm = false
    @State private var issuedAt: Date = Date()
    @State private var hasIssuedAt: Bool = false
    @State private var saving = false
    @State private var error: String?

    private var isCreate: Bool { item == nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Основное") {
                    TextField("Название", text: $title)
                    TextField("Описание", text: $description, axis: .vertical)
                        .lineLimit(2...6)
                    TextField("От кого (организация)", text: $fromName)
                }

                Section("Дизайн") {
                    Picker("Шаблон", selection: $template) {
                        ForEach(awardTemplates, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    Picker("Шрифт", selection: $font) {
                        ForEach(awardFonts, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Цвет").font(.dsCaption).foregroundColor(Theme.textSecondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(awardColors, id: \.self) { hex in
                                    Button {
                                        colorScheme = hex
                                    } label: {
                                        Circle()
                                            .fill(Color.fromHex(hex) ?? .gray)
                                            .frame(width: 30, height: 30)
                                            .overlay(
                                                Circle().stroke(colorScheme == hex ? Theme.accent : .clear, lineWidth: 3)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        TextField("Hex (#RRGGBB)", text: $colorScheme)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                Section("Логотипы") {
                    Toggle("Логотип Rossi", isOn: $logoRossi)
                    Toggle("Логотип РИТМ", isOn: $logoRitm)
                }

                Section("Подпись") {
                    TextField("Текст подписи (необязательно)", text: $signatureText)
                    TextField("URL изображения подписи", text: $signatureImageUrl)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Дата выдачи") {
                    Toggle("Указать дату", isOn: $hasIssuedAt)
                    if hasIssuedAt {
                        DatePicker("Дата", selection: $issuedAt, displayedComponents: .date)
                    }
                }

                if let err = error {
                    Section { Text(err).font(.dsCaption).foregroundColor(Theme.danger) }
                }
            }
            .navigationTitle(isCreate ? "Новая награда" : "Редактирование")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Сохраняю…" : "Сохранить") { Task { await save() } }
                        .disabled(saving || title.isEmpty || description.isEmpty || fromName.isEmpty)
                }
            }
            .onAppear {
                if let i = item {
                    title = i.displayTitle
                    description = i.description ?? ""
                    fromName = i.fromName ?? ""
                    template = i.template ?? "classic"
                    colorScheme = i.colorScheme ?? "#0A84FF"
                    font = i.font ?? "inter"
                    signatureText = i.signatureText ?? ""
                    signatureImageUrl = i.signatureImageUrl ?? ""
                    logoRossi = i.logoRossi ?? true
                    logoRitm = i.logoRitm ?? false
                    if let iso = i.issuedAt, let d = ISO8601DateFormatter().date(from: iso) {
                        issuedAt = d
                        hasIssuedAt = true
                    }
                }
            }
        }
    }

    struct Payload: Encodable {
        let title: String
        let description: String
        let fromName: String
        let template: String?
        let colorScheme: String?
        let font: String?
        let signatureText: String?
        let signatureImageUrl: String?
        let logoRossi: Bool?
        let logoRitm: Bool?
        let issuedAt: String?
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let iso = ISO8601DateFormatter()
        let body = Payload(
            title: title,
            description: description,
            fromName: fromName,
            template: template,
            colorScheme: colorScheme,
            font: font,
            signatureText: signatureText.isEmpty ? nil : signatureText,
            signatureImageUrl: signatureImageUrl.isEmpty ? nil : signatureImageUrl,
            logoRossi: logoRossi,
            logoRitm: logoRitm,
            issuedAt: hasIssuedAt ? iso.string(from: issuedAt) : nil
        )
        let path: String
        let method: String
        if let i = item {
            path = "awards/\(i.id)"; method = "PATCH"
        } else {
            path = "awards"; method = "POST"
        }
        do {
            _ = try await APIClient.shared.rawRequest(method, path, body: body)
            onSaved(); dismiss()
        } catch {
            // fallback admin/awards
            let alt = "admin/" + path
            do {
                _ = try await APIClient.shared.rawRequest(method, alt, body: body)
                onSaved(); dismiss()
            } catch {
                self.error = apiUserMessage(error)
            }
        }
    }
}

// MARK: - Grant Sheet

struct AwardGrantSheet: View {
    let award: AdminAward
    let onGranted: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var users: [AdminUserItem] = []
    @State private var search = ""
    @State private var saving = false
    @State private var error: String?

    private var filtered: [AdminUserItem] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return users }
        return users.filter { u in
            "\(u.profile?.firstName ?? "") \(u.profile?.lastName ?? "") \(u.username) \(u.email)".lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            VStack {
                if users.isEmpty && error == nil {
                    ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.top, 60)
                } else if let err = error, users.isEmpty {
                    EmptyStateView(icon: "exclamationmark.triangle", title: "Ошибка", description: err)
                } else {
                    List(filtered) { u in
                        Button {
                            Task { await grant(userId: u.id) }
                        } label: {
                            HStack(spacing: 10) {
                                AvatarCircle(url: u.profile?.avatarUrl,
                                             name: "\(u.profile?.firstName ?? "") \(u.profile?.lastName ?? "")")
                                    .frame(width: 32, height: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(u.profile?.firstName ?? "") \(u.profile?.lastName ?? "")".trimmingCharacters(in: .whitespaces).ifEmpty(or: u.username))
                                        .foregroundColor(Theme.textPrimary)
                                    Text("@\(u.username)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(Theme.textTertiary)
                                }
                                Spacer()
                                if saving { ProgressView() }
                            }
                        }
                        .disabled(saving)
                    }
                    .searchable(text: $search, prompt: "Поиск")
                }
            }
            .navigationTitle("Выдать «\(award.displayTitle)»")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
            }
            .task { await loadUsers() }
        }
    }

    private func loadUsers() async {
        if let arr: [AdminUserItem] = try? await APIClient.shared.get("users", query: ["limit": "200"]) {
            self.users = arr
        } else if let env: AdminUsersListEnv = try? await APIClient.shared.get("users", query: ["limit": "200"]) {
            self.users = env.data ?? []
        }
    }

    struct GrantBody: Encodable { let userId: String }
    private struct AdminUsersListEnv: Codable { let data: [AdminUserItem]? }

    private func grant(userId: String) async {
        saving = true; defer { saving = false }
        do {
            _ = try await APIClient.shared.rawRequest("POST", "awards/\(award.id)/grant", body: GrantBody(userId: userId))
            onGranted()
            dismiss()
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}

// MARK: - Color helper

extension Color {
    static func fromHex(_ hex: String) -> Color? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8) & 0xFF) / 255
        let b = Double(v & 0xFF) / 255
        return Color(red: r, green: g, blue: b)
    }
}

#Preview {
    NavigationStack { AwardsAdminView() }
}
