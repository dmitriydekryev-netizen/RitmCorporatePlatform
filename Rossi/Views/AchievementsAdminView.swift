//
//  AchievementsAdminView.swift — нативная админка достижений.
//
//  Endpoints:
//   • GET    /admin/achievements         — список (fallback /achievements)
//   • POST   /admin/achievements         — создать
//   • PATCH  /admin/achievements/:id     — обновить
//   • DELETE /admin/achievements/:id     — удалить
//

import SwiftUI

struct AdminAchievement: Codable, Identifiable {
    let id: String
    let title: String?
    let name: String?
    let description: String?
    let icon: String?      // emoji
    let iconUrl: String?
    let category: String?
    let points: Int?
    let grantedCount: Int?
    let isActive: Bool?

    var displayTitle: String { title ?? name ?? "—" }
    var displayIcon: String { (icon?.isEmpty == false) ? icon! : "🏆" }
}

struct AchievementsAdminView: View {
    @State private var items: [AdminAchievement] = []
    @State private var loading = true
    @State private var error: String?
    @State private var editing: AdminAchievement?
    @State private var showCreate = false

    var body: some View {
        ZStack {
            Theme.pageBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    DSPageTitle(text: "Достижения",
                                subtitle: items.isEmpty ? nil : "Всего: \(items.count)")
                        .padding(.top, 4)

                    if loading && items.isEmpty {
                        ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.top, 60)
                    } else if let err = error, items.isEmpty {
                        EmptyStateView(icon: "exclamationmark.triangle", title: "Ошибка", description: err)
                    } else if items.isEmpty {
                        EmptyStateView(icon: "trophy", title: "Скоро будет", description: "Достижения ещё не созданы")
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(items) { item in
                                AchievementAdminCard(item: item)
                                    .onTapGesture { editing = item }
                                    .contextMenu {
                                        Button("Редактировать") { editing = item }
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
        .navigationTitle("Достижения")
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
            AchievementEditSheet(item: item) { Task { await load() } }
        }
        .sheet(isPresented: $showCreate) {
            AchievementEditSheet(item: nil) { Task { await load() } }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        if let arr: [AdminAchievement] = try? await APIClient.shared.get("admin/achievements") {
            self.items = arr; self.error = nil; return
        }
        do {
            let arr: [AdminAchievement] = try await APIClient.shared.get("achievements")
            self.items = arr
            self.error = nil
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func deleteItem(_ item: AdminAchievement) async {
        do {
            try await APIClient.shared.delete("admin/achievements/\(item.id)")
        } catch {
            try? await APIClient.shared.delete("achievements/\(item.id)")
        }
        await load()
    }
}

struct AchievementAdminCard: View {
    let item: AdminAchievement

    var body: some View {
        DSCard(radius: Radius.lg, padding: 12) {
            HStack(spacing: 12) {
                Text(item.displayIcon)
                    .font(.system(size: 28))
                    .frame(width: 44, height: 44)
                    .background(Theme.accent.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.displayTitle)
                        .font(.dsBodyLG.weight(.semibold))
                        .foregroundColor(Theme.textPrimary)
                    if let desc = item.description, !desc.isEmpty {
                        Text(desc).font(.dsCaption).foregroundColor(Theme.textTertiary).lineLimit(2)
                    }
                    HStack(spacing: 6) {
                        if let cat = item.category {
                            DSBadge(text: cat, color: Theme.purple, filled: false)
                        }
                        if let pts = item.points {
                            DSBadge(text: "\(pts) pts", color: Theme.warning, filled: false)
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

struct AchievementEditSheet: View {
    let item: AdminAchievement?
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var icon = "🏆"
    @State private var category = ""
    @State private var points = ""
    @State private var saving = false
    @State private var error: String?

    private var isCreate: Bool { item == nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Основное") {
                    TextField("Название", text: $title)
                    TextField("Описание", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                    TextField("Иконка (emoji)", text: $icon)
                    TextField("Категория", text: $category)
                    TextField("Очки", text: $points)
                        .keyboardType(.numberPad)
                }
                if let err = error {
                    Section { Text(err).font(.dsCaption).foregroundColor(Theme.danger) }
                }
            }
            .navigationTitle(isCreate ? "Новое достижение" : "Редактирование")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Сохраняю…" : "Сохранить") { Task { await save() } }
                        .disabled(saving || title.isEmpty)
                }
            }
            .onAppear {
                if let i = item {
                    title = i.displayTitle
                    description = i.description ?? ""
                    icon = i.displayIcon
                    category = i.category ?? ""
                    points = i.points.map(String.init) ?? ""
                }
            }
        }
    }

    struct Payload: Encodable {
        let title: String
        let description: String?
        let icon: String?
        let category: String?
        let points: Int?
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let body = Payload(
            title: title,
            description: description.isEmpty ? nil : description,
            icon: icon.isEmpty ? nil : icon,
            category: category.isEmpty ? nil : category,
            points: Int(points)
        )
        let path: String
        let method: String
        if let i = item {
            path = "admin/achievements/\(i.id)"; method = "PATCH"
        } else {
            path = "admin/achievements"; method = "POST"
        }
        do {
            _ = try await APIClient.shared.rawRequest(method, path, body: body)
            onSaved(); dismiss()
        } catch {
            // fallback no-prefix
            let alt = path.replacingOccurrences(of: "admin/", with: "")
            do {
                _ = try await APIClient.shared.rawRequest(method, alt, body: body)
                onSaved(); dismiss()
            } catch {
                self.error = apiUserMessage(error)
            }
        }
    }
}

#Preview {
    NavigationStack { AchievementsAdminView() }
}
