//
//  NewsViews.swift — список и детальный экран новостей.
//  GET /news, GET /news/:slug
//

import SwiftUI

// MARK: - List

struct NewsListView: View {
    @EnvironmentObject var auth: AuthStore

    @State private var items: [NewsItem] = []
    @State private var loading = false
    @State private var error: String?

    // Фильтры
    @State private var searchText: String = ""
    @State private var debouncedSearch: String = ""
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var importantOnly: Bool = false
    @State private var selectedCategory: String? = nil // categoryName

    /// Право создать новость: news.create | * | admin.*
    private var canCreate: Bool {
        if auth.has("news.create") { return true }
        let perms = auth.currentUser?.permissions ?? []
        if perms.contains("*") { return true }
        if perms.contains("admin.*") { return true }
        // Любая admin.<что-то> тоже даёт право публиковать новости.
        if perms.contains(where: { $0.hasPrefix("admin.") }) { return true }
        return false
    }

    @State private var showCreate = false

    /// Уникальные категории, обнаруженные в текущем списке новостей.
    private var availableCategories: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for it in items {
            if let name = it.category?.name, !name.isEmpty, !seen.contains(name) {
                seen.insert(name)
                ordered.append(name)
            }
        }
        return ordered
    }

    /// Применённый локально набор фильтров.
    private var filteredItems: [NewsItem] {
        var arr = items
        if importantOnly {
            arr = arr.filter { $0.isImportant == true }
        }
        if let cat = selectedCategory {
            arr = arr.filter { $0.category?.name == cat }
        }
        let q = debouncedSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            arr = arr.filter { item in
                if item.title.lowercased().contains(q) { return true }
                if let ex = item.excerpt?.lowercased(), ex.contains(q) { return true }
                if let cat = item.category?.name.lowercased(), cat.contains(q) { return true }
                return false
            }
        }
        return arr
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DSPageTitle(text: "Новости", subtitle: subtitle)
                    .padding(.top, 4)

                // Ряд чипов фильтров
                if !items.isEmpty {
                    filterChipsRow
                }

                if items.isEmpty && loading {
                    VStack(spacing: 12) {
                        ForEach(0..<3, id: \.self) { _ in skeletonCard }
                    }
                } else if filteredItems.isEmpty && !items.isEmpty {
                    EmptyStateView(
                        icon: "magnifyingglass",
                        title: "Ничего не найдено",
                        description: "Попробуйте изменить фильтры или запрос"
                    )
                } else if items.isEmpty {
                    EmptyStateView(
                        icon: "newspaper",
                        title: "Нет новостей",
                        description: error ?? "Скоро появятся свежие посты"
                    )
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(filteredItems) { item in
                            NavigationLink {
                                NewsDetailView(slug: item.slug)
                            } label: {
                                NewsRow(item: item)
                            }
                            .buttonStyle(DSPressScaleStyle())
                        }
                    }
                }
                Color.clear.frame(height: TabBarVisibility.reservedHeight)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar {
            if canCreate {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showCreate = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundColor(Theme.accent)
                    }
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            // Поскольку navbar скрыт — дублируем "+" в углу для пользователей
            // с правом news.create.
            if canCreate {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(Theme.accent)
                        .background(
                            Circle()
                                .fill(Theme.surfaceBackground)
                                .frame(width: 32, height: 32)
                        )
                }
                .buttonStyle(DSPressScaleStyle())
                .padding(.top, 14)
                .padding(.trailing, 16)
            }
        }
        .searchable(text: $searchText, prompt: "Поиск новостей")
        .onChange(of: searchText) { newValue in
            scheduleSearchDebounce(newValue)
        }
        .refreshable { await load() }
        .task { if items.isEmpty { await load() } }
        .sheet(isPresented: $showCreate) {
            CreateNewsSheet { Task { await load() } }
        }
    }

    // MARK: - Chips row

    @ViewBuilder
    private var filterChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // «Только важные»
                FilterChip(
                    title: "Только важные",
                    systemImage: "exclamationmark.circle.fill",
                    isActive: importantOnly,
                    action: { importantOnly.toggle() }
                )

                // Категории — «Все» + список из данных
                FilterChip(
                    title: "Все",
                    systemImage: nil,
                    isActive: selectedCategory == nil,
                    action: { selectedCategory = nil }
                )

                ForEach(availableCategories, id: \.self) { cat in
                    FilterChip(
                        title: cat,
                        systemImage: nil,
                        isActive: selectedCategory == cat,
                        action: {
                            selectedCategory = (selectedCategory == cat) ? nil : cat
                        }
                    )
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
    }

    // MARK: - Search debounce

    private func scheduleSearchDebounce(_ value: String) {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            await MainActor.run { self.debouncedSearch = value }
        }
    }

    private var subtitle: String? {
        if items.isEmpty { return nil }
        let total = items.count
        let shown = filteredItems.count
        if shown == total {
            return "\(total) публикаций"
        }
        return "\(shown) из \(total)"
    }

    private var skeletonCard: some View {
        RoundedRectangle(cornerRadius: Radius.xl)
            .fill(Theme.surfaceBackground)
            .frame(height: 320)
            .redacted(reason: .placeholder)
            .shimmering()
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let resp: NewsListResponse = try await APIClient.shared.get("news", query: ["limit": "30"])
            self.items = resp.data
            self.error = nil
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}

// MARK: - Filter chip

private struct FilterChip: View {
    let title: String
    let systemImage: String?
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon = systemImage {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundColor(isActive ? .white : Theme.accent)
            .background(
                Capsule().fill(isActive ? Theme.accent : Theme.accent.opacity(0.12))
            )
        }
        .buttonStyle(DSPressScaleStyle())
    }
}

// MARK: - Detail

struct NewsDetailView: View {
    let slug: String
    @State private var item: NewsDetailItem?
    @State private var loading = true
    @State private var error: String?

    /// Реакции — отдельный стейт, чтобы переключать toggle мгновенно.
    @State private var reactions: [NewsReaction] = []
    /// Если эндпоинт реакций отдаёт 404 — скрываем ряд.
    @State private var reactionsAvailable = true
    /// Базовый набор emoji, который показываем всегда (даже при 0 реакциях).
    /// Соответствует ReactionType на бэкенде (apps/api/src/modules/reactions):
    ///   like → 👍, fire → 🔥, heart → ❤️, star → ⭐, important → ❗
    private let defaultEmoji: [String] = ReactionTypeMap.orderedEmoji

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let item {
                    // Cover full-bleed
                    if let cover = item.coverUrl, let url = URL(string: ensureAbsolute(cover)) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .empty: Theme.pageBackground
                            case .success(let img): img.resizable().scaledToFill()
                            case .failure: Theme.pageBackground
                            @unknown default: Theme.pageBackground
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 240)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: Radius.xl2, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text(item.title)
                            .font(.dsH1)
                            .tracking(-0.6)
                            .foregroundColor(Theme.textPrimary)

                        // Author + дата
                        HStack(spacing: 10) {
                            if let author = item.author {
                                AvatarCircle(url: author.avatarUrl, name: authorName(author))
                                    .frame(width: 32, height: 32)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(authorName(author))
                                        .font(.dsBodySM)
                                        .fontWeight(.semibold)
                                        .foregroundColor(Theme.textPrimary)
                                    if let pub = item.publishedAt, let d = ISO8601DateFormatter().date(from: pub) {
                                        Text(relativeTime(from: d))
                                            .font(.dsCaption)
                                            .foregroundColor(Theme.textTertiary)
                                    }
                                }
                            } else if let pub = item.publishedAt, let d = ISO8601DateFormatter().date(from: pub) {
                                Text(relativeTime(from: d))
                                    .font(.dsCaption)
                                    .foregroundColor(Theme.textTertiary)
                            }
                            Spacer()
                        }

                        // Markdown content
                        Text(parseMarkdown(item.content))
                            .font(.dsBodyLG)
                            .foregroundColor(Theme.textPrimary)
                            .lineSpacing(5)
                            .textSelection(.enabled)
                            .padding(.top, 4)
                    }
                    .padding(.horizontal, 4)

                    // Реакции
                    if reactionsAvailable {
                        reactionsRow(newsId: item.id)
                            .padding(.horizontal, 4)
                    }

                    // Комментарии
                    NewsCommentsSection(newsId: item.id)
                        .padding(.top, 8)
                } else if loading {
                    ProgressView().tint(Theme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 100)
                } else if let err = error {
                    EmptyStateView(
                        icon: "exclamationmark.triangle",
                        title: "Не удалось загрузить",
                        description: err
                    )
                }
                Color.clear.frame(height: TabBarVisibility.reservedHeight)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let detail: NewsDetailItem = try await APIClient.shared.get("news/\(slug)")
            self.item = detail
            // Реакции: либо приходят вместе с детально новостью, либо тянем отдельно.
            if let inline = detail.reactions {
                self.reactions = inline
            } else {
                await loadReactions(newsId: detail.id)
            }
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    // MARK: - Reactions

    @ViewBuilder
    private func reactionsRow(newsId: String) -> some View {
        let merged = mergedReactions()
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(merged, id: \.emoji) { r in
                    let mine = r.byMe == true
                    Button {
                        Task { await toggle(newsId: newsId, emoji: r.emoji) }
                    } label: {
                        HStack(spacing: 6) {
                            Text(r.emoji).font(.system(size: 16))
                            if r.count > 0 {
                                Text("\(r.count)")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(mine ? Theme.accent : Theme.textSecondary)
                                    .monospacedDigit()
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(mine ? Theme.accent.opacity(0.18) : Theme.surfaceBackground)
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                mine ? Theme.accent : Theme.border,
                                lineWidth: mine ? 1.2 : 0.5
                            )
                        )
                    }
                    .buttonStyle(DSPressScaleStyle())
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// Сливает дефолтный набор emoji со счётчиками с сервера.
    /// Дефолтные emoji всегда отображаются, даже если count == 0.
    private func mergedReactions() -> [NewsReaction] {
        var byEmoji: [String: NewsReaction] = [:]
        for r in reactions { byEmoji[r.emoji] = r }
        var ordered: [NewsReaction] = []
        var seen = Set<String>()
        for e in defaultEmoji {
            if let r = byEmoji[e] {
                ordered.append(r)
            } else {
                ordered.append(NewsReaction(emoji: e, count: 0, byMe: false))
            }
            seen.insert(e)
        }
        // Кастомные emoji, которых нет в дефолтном наборе — после.
        for r in reactions where !seen.contains(r.emoji) {
            ordered.append(r)
        }
        return ordered
    }

    private func loadReactions(newsId: String) async {
        do {
            let data = try await APIClient.shared.rawRequest(
                "GET", "news/\(newsId)/reactions"
            )
            if let parsed = NewsReactionsDecoder.decodeTopLevel(data) {
                self.reactions = parsed
                self.reactionsAvailable = true
            } else {
                // Неизвестный формат — не падаем, просто оставляем дефолт.
                self.reactionsAvailable = true
            }
        } catch APIError.http(let status, _) where status == 404 {
            self.reactionsAvailable = false
        } catch {
            // Сетевая ошибка — оставим строку видимой с дефолтными нулями.
        }
    }

    /// Переключение реакции.
    /// Бэкенд: `POST /news/:id/reactions { type: "like"|"fire"|"heart"|"star"|"important" }`
    /// Этот же эндпоинт служит и для удаления — повторный POST снимает реакцию.
    /// Возвращает `{ counts: { type: int }, mine: [type] }`.
    private func toggle(newsId: String, emoji: String) async {
        // Optimistic-only update: счётчик увеличиваем/уменьшаем мгновенно
        // и НЕ перезаписываем после ответа сервера, чтобы избежать «мигания»
        // при гонках. Реальные счётчики догонят при следующем load().
        let wasActive = reactions.first(where: { $0.emoji == emoji })?.byMe == true
        applyLocalToggle(emoji: emoji, activate: !wasActive)

        // Маппим emoji в backend-type. Если это не известный тип —
        // отказываемся, чтобы не словить 400 от validation pipe.
        guard let typeCode = ReactionTypeMap.code(forEmoji: emoji) else {
            // Откатываем optimistic.
            applyLocalToggle(emoji: emoji, activate: wasActive)
            return
        }

        struct Body: Encodable { let type: String }
        do {
            _ = try await APIClient.shared.rawRequest(
                "POST", "news/\(newsId)/reactions",
                body: Body(type: typeCode)
            )
            // Намеренно НЕ вызываем loadReactions() здесь:
            // ответ сервера уже содержит актуальное состояние, но повторный
            // запрос/перетирание стейта приводит к «исчезновению» эмоджи
            // у пользователя (если, например, кэш ответа отстаёт).
        } catch APIError.http(let status, _) where status == 404 {
            // Эндпоинт не поддерживается — откатываем и прячем UI.
            applyLocalToggle(emoji: emoji, activate: wasActive)
            self.reactionsAvailable = false
        } catch {
            // Откатываем optimistic update.
            applyLocalToggle(emoji: emoji, activate: wasActive)
        }
    }

    private func applyLocalToggle(emoji: String, activate: Bool) {
        if let idx = reactions.firstIndex(where: { $0.emoji == emoji }) {
            let cur = reactions[idx]
            let delta = activate ? 1 : -1
            let newCount = max(0, cur.count + delta)
            if newCount == 0 && !activate {
                reactions.remove(at: idx)
            } else {
                reactions[idx] = NewsReaction(emoji: emoji, count: newCount, byMe: activate)
            }
        } else if activate {
            reactions.append(NewsReaction(emoji: emoji, count: 1, byMe: true))
        }
    }

    private func parseMarkdown(_ md: String) -> AttributedString {
        do {
            return try AttributedString(markdown: md, options: .init(
                allowsExtendedAttributes: true,
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            ))
        } catch {
            return AttributedString(md)
        }
    }

    private func authorName(_ a: NewsAuthor) -> String {
        let first = a.firstName ?? ""
        let last = a.lastName ?? ""
        let full = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
        return full.isEmpty ? a.username : full
    }
}

struct NewsDetailItem: Decodable {
    let id: String
    let slug: String
    let title: String
    let excerpt: String?
    let content: String
    let coverUrl: String?
    let publishedAt: String?
    let author: NewsAuthor?
    /// Реакции — могут отсутствовать (если эндпоинт не поддерживается).
    let reactions: [NewsReaction]?

    private enum CodingKeys: String, CodingKey {
        case id, slug, title, excerpt, content, coverUrl, publishedAt, author, reactions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.slug = try c.decode(String.self, forKey: .slug)
        self.title = try c.decode(String.self, forKey: .title)
        self.excerpt = try c.decodeIfPresent(String.self, forKey: .excerpt)
        self.content = try c.decode(String.self, forKey: .content)
        self.coverUrl = try c.decodeIfPresent(String.self, forKey: .coverUrl)
        self.publishedAt = try c.decodeIfPresent(String.self, forKey: .publishedAt)
        self.author = try c.decodeIfPresent(NewsAuthor.self, forKey: .author)
        self.reactions = NewsReactionsDecoder.decode(from: c, key: .reactions)
    }
}

/// Реакция на новость. Сервер возвращает либо массив [{emoji, count, byMe}],
/// либо словарь {counts: {emoji: count}, mine: [emoji]},
/// либо словарь {emoji: {count, byMe}}. Поддерживаем все три варианта.
struct NewsReaction: Codable, Hashable, Identifiable {
    let emoji: String
    let count: Int
    let byMe: Bool?

    var id: String { emoji }
}

/// Маппинг между backend type-кодами реакций и эмоджи в UI.
/// Бэкенд: `apps/api/src/modules/reactions/reactions.controller.ts` —
///   ReactionType: like | fire | heart | star | important
enum ReactionTypeMap {
    /// Порядок отображения чипов слева-направо.
    static let orderedCodes: [String] = ["like", "heart", "fire", "star", "important"]

    /// Соответствующие emoji-представления.
    static let codeToEmoji: [String: String] = [
        "like":      "👍",
        "fire":      "🔥",
        "heart":     "❤️",
        "star":      "⭐️",
        "important": "❗",
    ]

    static var emojiToCode: [String: String] {
        var map: [String: String] = [:]
        for (code, emoji) in codeToEmoji { map[emoji] = code }
        return map
    }

    static var orderedEmoji: [String] {
        orderedCodes.compactMap { codeToEmoji[$0] }
    }

    static func emoji(forCode code: String) -> String? { codeToEmoji[code] }
    static func code(forEmoji emoji: String) -> String? { emojiToCode[emoji] }
}

/// Гибкий декодер реакций — поддерживает несколько форматов:
///  1) `[ { emoji, count, byMe } ]`               — старый/legacy с emoji
///  2) `{ counts: { type: int }, mine: [type] }`  — текущий бэк (reactions.service.ts)
///  3) `{ emoji: { count, byMe } }`               — альтернативный формат
///
/// Ключи в `counts`/`mine` — это backend-коды (`like`, `fire` и т.д.),
/// которые мы транслируем в emoji через `ReactionTypeMap`.
enum NewsReactionsDecoder {
    /// Аггрегированный шейп от reactions.service.aggregate().
    private struct AggregateShape: Decodable {
        let counts: [String: Int]?
        let mine: [String]?
    }
    /// Словарь со значением-объектом — `{ key: { count, byMe } }`.
    private struct PerKeyShape: Decodable {
        let count: Int
        let byMe: Bool?
    }

    /// Превращает ключ-строку (либо backend-code типа `"like"`, либо уже emoji)
    /// в emoji для отображения. Неизвестные коды отбрасываем.
    private static func emojiFor(key: String) -> String? {
        if let e = ReactionTypeMap.emoji(forCode: key) { return e }
        // Если ключ — это уже emoji (legacy / клиент-side формат).
        if ReactionTypeMap.emojiToCode[key] != nil { return key }
        // Иначе считаем валидным любой непустой не-ASCII ключ как emoji.
        if !key.isEmpty && !key.allSatisfy({ $0.isASCII }) { return key }
        return nil
    }

    static func decode<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        key: K
    ) -> [NewsReaction]? {
        guard container.contains(key) else { return nil }
        if (try? container.decodeNil(forKey: key)) == true { return nil }

        // 1) Массив объектов с emoji-полем.
        if let arr = try? container.decode([NewsReaction].self, forKey: key) {
            return arr
        }
        // 2) { counts, mine }
        if let agg = try? container.decode(AggregateShape.self, forKey: key),
           let counts = agg.counts {
            return makeFromAggregate(counts: counts, mine: agg.mine ?? [])
        }
        // 3) { key: { count, byMe } }
        if let map = try? container.decode([String: PerKeyShape].self, forKey: key) {
            return map.compactMap { (k, v) in
                guard let emoji = emojiFor(key: k) else { return nil }
                return NewsReaction(emoji: emoji, count: v.count, byMe: v.byMe)
            }.sorted { $0.count > $1.count }
        }
        // 4) { key: count }
        if let map = try? container.decode([String: Int].self, forKey: key) {
            return map.compactMap { (k, v) in
                guard let emoji = emojiFor(key: k) else { return nil }
                return NewsReaction(emoji: emoji, count: v, byMe: nil)
            }.sorted { $0.count > $1.count }
        }
        return nil
    }

    /// Standalone-эндпоинт: `GET /news/:id/reactions`.
    static func decodeTopLevel(_ data: Data) -> [NewsReaction]? {
        let dec = JSONDecoder()
        if let arr = try? dec.decode([NewsReaction].self, from: data) { return arr }
        struct Wrap: Decodable {
            let data: [NewsReaction]?
        }
        if let w = try? dec.decode(Wrap.self, from: data), let d = w.data { return d }
        if let agg = try? dec.decode(AggregateShape.self, from: data),
           let counts = agg.counts {
            return makeFromAggregate(counts: counts, mine: agg.mine ?? [])
        }
        if let map = try? dec.decode([String: PerKeyShape].self, from: data) {
            return map.compactMap { (k, v) in
                guard let emoji = emojiFor(key: k) else { return nil }
                return NewsReaction(emoji: emoji, count: v.count, byMe: v.byMe)
            }.sorted { $0.count > $1.count }
        }
        if let map = try? dec.decode([String: Int].self, from: data) {
            return map.compactMap { (k, v) in
                guard let emoji = emojiFor(key: k) else { return nil }
                return NewsReaction(emoji: emoji, count: v, byMe: nil)
            }.sorted { $0.count > $1.count }
        }
        return nil
    }

    private static func makeFromAggregate(counts: [String: Int], mine: [String]) -> [NewsReaction] {
        let mineSet = Set(mine)
        return counts.compactMap { (k, count) in
            guard let emoji = emojiFor(key: k) else { return nil }
            // mine может содержать как код, так и (теоретически) emoji.
            let byMe = mineSet.contains(k) ||
                       (ReactionTypeMap.code(forEmoji: emoji).map { mineSet.contains($0) } ?? false)
            return NewsReaction(emoji: emoji, count: count, byMe: byMe)
        }.sorted { $0.count > $1.count }
    }
}

#Preview {
    NavigationStack { NewsListView() }
}
