//
//  KudosView.swift — лента благодарностей сотрудников друг другу.
//  GET /kudos
//

import SwiftUI

struct KudosListResponse: Codable {
    let data: [KudosItem]
    let meta: PaginationMeta?
}

struct KudosItem: Codable, Identifiable {
    let id: String
    let message: String
    let isPublic: Bool?
    let createdAt: String
    /// Сервер отдаёт `from` и `to` (см. apps/api/src/modules/kudos/kudos.controller.ts).
    /// Маппим через CodingKeys чтобы в UI оставить понятные имена.
    let fromUser: KudosPerson?
    let toUser: KudosPerson?

    enum CodingKeys: String, CodingKey {
        case id, message, isPublic, createdAt
        case fromUser = "from"
        case toUser   = "to"
    }
}

struct KudosPerson: Codable {
    let id: String
    let username: String
    let firstName: String?
    let lastName: String?
    let avatarUrl: String?
    let position: String?

    var fullName: String {
        "\(firstName ?? "") \(lastName ?? "")".trimmingCharacters(in: .whitespaces).ifEmpty(or: username)
    }
}

extension String {
    func ifEmpty(or fallback: String) -> String { self.isEmpty ? fallback : self }
}

struct KudosView: View {
    @EnvironmentObject var auth: AuthStore

    enum Direction: String, Hashable, CaseIterable {
        case all, received, sent
        var title: String {
            switch self {
            case .all: return "Все"
            case .received: return "Полученные"
            case .sent: return "Отправленные"
            }
        }
    }

    enum SortOrder: Hashable, CaseIterable {
        case newest, oldest, popular
        var title: String {
            switch self {
            case .newest: return "Сначала новые"
            case .oldest: return "Сначала старые"
            case .popular: return "Популярные"
            }
        }
        var icon: String {
            switch self {
            case .newest: return "arrow.down"
            case .oldest: return "arrow.up"
            case .popular: return "flame"
            }
        }
    }

    @State private var items: [KudosItem] = []
    @State private var loading = true
    @State private var error: String?
    @State private var showCreateSheet = false
    @State private var direction: Direction = .all
    @State private var sortOrder: SortOrder = .newest

    /// Локально применённые фильтры/сортировка (на случай если бэк отдал больше
    /// чем нужно — например, не понимает ?direction=…).
    private var visibleItems: [KudosItem] {
        let currentId = auth.currentUser?.id
        let filtered: [KudosItem] = items.filter { k in
            switch direction {
            case .all:
                return true
            case .received:
                return k.toUser?.id == currentId
            case .sent:
                return k.fromUser?.id == currentId
            }
        }
        switch sortOrder {
        case .newest:
            return filtered.sorted { $0.createdAt > $1.createdAt }
        case .oldest:
            return filtered.sorted { $0.createdAt < $1.createdAt }
        case .popular:
            // Поля reactionsCount у KudosItem нет — сортируем по дате (свежее → выше).
            return filtered.sorted { $0.createdAt > $1.createdAt }
        }
    }

    var body: some View {
        Group {
            ScrollView {
                LazyVStack(spacing: 14) {
                    DSPageTitle(text: "Благодарности",
                                subtitle: "Сотрудники говорят друг другу спасибо")
                        .padding(.top, 4)

                    Picker("", selection: $direction) {
                        ForEach(Direction.allCases, id: \.self) { d in
                            Text(d.title).tag(d)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: direction) { _ in
                        Task { await load() }
                    }

                    if loading && items.isEmpty {
                        ProgressView().tint(Theme.accent)
                            .frame(maxWidth: .infinity, minHeight: 200)
                    } else if visibleItems.isEmpty {
                        EmptyStateView(
                            icon: "heart.slash",
                            title: "Пока нет благодарностей",
                            description: error ?? "Здесь появятся kudos сотрудников друг другу"
                        )
                        .frame(maxWidth: .infinity, minHeight: 200)
                    } else {
                        ForEach(visibleItems) { kudo in
                            KudoCard(kudo: kudo)
                        }
                    }
                    Color.clear.frame(height: TabBarVisibility.reservedHeight)
                }
                .padding(16)
            }
            .background(Theme.pageBackground.ignoresSafeArea())
        }
        .navigationTitle("Благодарности")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    ForEach(SortOrder.allCases, id: \.self) { s in
                        Button {
                            sortOrder = s
                        } label: {
                            if sortOrder == s {
                                Label(s.title, systemImage: "checkmark")
                            } else {
                                Label(s.title, systemImage: s.icon)
                            }
                        }
                    }
                } label: {
                    Label("Сортировка", systemImage: "arrow.up.arrow.down")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showCreateSheet = true
                } label: {
                    Label("Создать", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateKudosSheet(onCreated: {
                await load()
            })
        }
        .refreshable { await load() }
        .task { if items.isEmpty { await load() } }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            var query: [String: String] = ["limit": "30"]
            if direction != .all {
                query["direction"] = direction.rawValue
            }
            let resp: KudosListResponse = try await APIClient.shared.get("kudos", query: query)
            self.items = resp.data
            self.error = nil
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}

struct KudoCard: View {
    let kudo: KudosItem

    var body: some View {
        DSCard(radius: Radius.xl, padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                // From → arrow → To
                HStack(spacing: 8) {
                    if let from = kudo.fromUser {
                        AvatarCircle(url: from.avatarUrl, name: from.fullName)
                            .frame(width: 32, height: 32)
                        Text(from.fullName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                    }
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.textTertiary)
                    if let to = kudo.toUser {
                        AvatarCircle(url: to.avatarUrl, name: to.fullName)
                            .frame(width: 32, height: 32)
                        Text(to.fullName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }

                // Message — pink/purple gradient bubble
                Text(kudo.message)
                    .font(.dsBodyLG)
                    .foregroundColor(Theme.textPrimary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        LinearGradient(
                            colors: [Theme.pink.opacity(0.10), Theme.purple.opacity(0.05)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Theme.pink.opacity(0.15), lineWidth: 0.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                // Footer: heart + relative time
                if let d = ISO8601DateFormatter().date(from: kudo.createdAt) {
                    HStack(spacing: 6) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Theme.pink)
                        Text(relativeTime(from: d))
                            .font(.dsCaption)
                            .foregroundColor(Theme.textTertiary)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}
