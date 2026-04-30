//
//  LearningView.swift — модуль корпоративного обучения.
//  Список курсов («Мои» / «Каталог»), детальный просмотр модулей с
//  блоками контента (text/video/image/callout/test/embed/html) и
//  прохождение тестов.
//
//  Backend: /learning/* на rossihelp.ru/api/v1
//

import SwiftUI
import AVKit
import WebKit

// MARK: - Models

struct LearningCourse: Codable, Identifiable {
    let id: String
    let slug: String?              // not always returned by /learning/courses
    let title: String
    let description: String?
    let status: String?            // "draft" | "published"
    let coverUrl: String?
    let role: String?
    let isPublished: Bool?
    let estimatedDuration: Int?
    let modulesCount: Int?
    let blocksCount: Int?
    let progressPercent: Int?
    let completed: Bool?
    let completedAt: String?
    /// /learning/courses вкладывает счётчики в _count: { modules, assignments }
    let _count: LearningCourseCounts?
}

struct LearningCourseCounts: Codable {
    let modules: Int?
    let assignments: Int?
}

// /learning/my, /learning/courses возвращают массив без обёртки {data:...}.
// LearningCoursesResponse оставлен как алиас для обратной совместимости.

/// Бэк (см. apps/api/src/modules/learning/learning.service.ts getCourseForUser)
/// возвращает обёртку `{ course: {...}, progress: {...} }`. Поля внутри —
/// сырая Prisma-модель: `orderIndex` вместо `order`, `type` вместо `kind`,
/// тесты в `block.test.questions[].answers[]`, тексты в `questionText`/`answerText`.
/// Здесь — кастомный декодер, который нормализует это к удобной для UI форме.
struct LearningCourseView {
    let id: String
    let slug: String?
    let title: String
    let description: String?
    let coverUrl: String?
    let modules: [LearningModule]
    let progress: LearningCourseProgress?
}

extension LearningCourseView: Decodable {
    private enum Root: String, CodingKey { case course, progress }
    private enum CourseKeys: String, CodingKey {
        case id, slug, title, description, coverUrl, modules
    }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: Root.self)
        let course = try root.nestedContainer(keyedBy: CourseKeys.self, forKey: .course)
        self.id = try course.decode(String.self, forKey: .id)
        self.slug = try? course.decodeIfPresent(String.self, forKey: .slug)
        self.title = try course.decode(String.self, forKey: .title)
        self.description = try? course.decodeIfPresent(String.self, forKey: .description)
        self.coverUrl = try? course.decodeIfPresent(String.self, forKey: .coverUrl)
        self.modules = (try? course.decodeIfPresent([LearningModule].self, forKey: .modules)) ?? []
        self.progress = try? root.decodeIfPresent(LearningCourseProgress.self, forKey: .progress)
    }
}

struct LearningCourseProgress: Decodable {
    let progressPercent: Int?
    let completed: Bool?
    let completedBlocks: [String]?
    let testResults: [String: TestResult]?
}

struct TestResult: Decodable {
    let score: Int
    let passed: Bool
    let attemptedAt: String?

    init(score: Int, passed: Bool, attemptedAt: String?) {
        self.score = score
        self.passed = passed
        self.attemptedAt = attemptedAt
    }

    private enum CodingKeys: String, CodingKey {
        case score, passed, attemptedAt, passedAt, attempts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.score = (try? c.decodeIfPresent(Int.self, forKey: .score)) ?? 0
        // Бэк хранит `{ score, attempts, passedAt }`; iOS привык к
        // `{ score, passed, attemptedAt }`. Считаем passed по наличию passedAt.
        let passedAt: String? = try? c.decodeIfPresent(String.self, forKey: .passedAt)
        if let p: Bool = try? c.decodeIfPresent(Bool.self, forKey: .passed) {
            self.passed = p
        } else {
            self.passed = passedAt != nil
        }
        self.attemptedAt = (try? c.decodeIfPresent(String.self, forKey: .attemptedAt)) ?? passedAt
    }
}

struct LearningModule: Identifiable, Decodable {
    let id: String
    let title: String
    let description: String?
    let order: Int
    let blocks: [LearningBlock]

    private enum CodingKeys: String, CodingKey {
        case id, title, description, order, orderIndex, blocks
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        self.description = try? c.decodeIfPresent(String.self, forKey: .description)
        self.order = (try? c.decodeIfPresent(Int.self, forKey: .order))
            ?? (try? c.decodeIfPresent(Int.self, forKey: .orderIndex)) ?? 0
        self.blocks = (try? c.decodeIfPresent([LearningBlock].self, forKey: .blocks)) ?? []
    }
}

struct LearningBlock: Identifiable, Decodable {
    let id: String
    let kind: String
    let title: String?
    let order: Int
    let content: LearningBlockContent?

    private enum CodingKeys: String, CodingKey {
        case id, kind, type, title, order, orderIndex, content, test
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        // Бэк отдаёт `type`, в иос везде используем `kind`.
        self.kind = (try? c.decodeIfPresent(String.self, forKey: .kind))
            ?? (try? c.decodeIfPresent(String.self, forKey: .type)) ?? "text"
        self.title = try? c.decodeIfPresent(String.self, forKey: .title)
        self.order = (try? c.decodeIfPresent(Int.self, forKey: .order))
            ?? (try? c.decodeIfPresent(Int.self, forKey: .orderIndex)) ?? 0

        // Контент — JSON-колонка с произвольной формой (text/video/image/file/test/...).
        // Дополнительно для test-блоков есть отдельная nested-таблица `test` с
        // questions/answers — её склеиваем сюда же, чтобы UI работал единообразно.
        let baseContent = try? c.decodeIfPresent(LearningBlockContent.self, forKey: .content)
        let testBlock = try? c.decodeIfPresent(LearningTestEnvelope.self, forKey: .test)
        self.content = LearningBlockContent.merge(base: baseContent, test: testBlock)
    }
}

/// Подсхема для test-блоков: бэк отдаёт `block.test = { passScore, questions: [...] }`.
private struct LearningTestEnvelope: Decodable {
    let passScore: Int?
    let questions: [TestQuestion]?
}

struct LearningBlockContent: Decodable {
    let body: String?
    let url: String?
    let videoUrl: String?
    let imageUrl: String?
    let calloutType: String?
    let embedUrl: String?
    let htmlContent: String?
    let questions: [TestQuestion]?
    let passingScore: Int?
    /// Для file-блоков
    let fileName: String?

    private enum CodingKeys: String, CodingKey {
        case body, text, url, videoUrl, imageUrl, calloutType, embedUrl,
             htmlContent, questions, passingScore, name, fileName, provider
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // body / text — допускаем оба варианта.
        self.body = (try? c.decodeIfPresent(String.self, forKey: .body))
            ?? (try? c.decodeIfPresent(String.self, forKey: .text))
        self.url = try? c.decodeIfPresent(String.self, forKey: .url)
        self.videoUrl = try? c.decodeIfPresent(String.self, forKey: .videoUrl)
        self.imageUrl = try? c.decodeIfPresent(String.self, forKey: .imageUrl)
        self.calloutType = try? c.decodeIfPresent(String.self, forKey: .calloutType)
        self.embedUrl = try? c.decodeIfPresent(String.self, forKey: .embedUrl)
        self.htmlContent = try? c.decodeIfPresent(String.self, forKey: .htmlContent)
        self.questions = try? c.decodeIfPresent([TestQuestion].self, forKey: .questions)
        self.passingScore = try? c.decodeIfPresent(Int.self, forKey: .passingScore)
        self.fileName = (try? c.decodeIfPresent(String.self, forKey: .fileName))
            ?? (try? c.decodeIfPresent(String.self, forKey: .name))
    }

    init(body: String?, url: String?, videoUrl: String?, imageUrl: String?,
         calloutType: String?, embedUrl: String?, htmlContent: String?,
         questions: [TestQuestion]?, passingScore: Int?, fileName: String?) {
        self.body = body
        self.url = url
        self.videoUrl = videoUrl
        self.imageUrl = imageUrl
        self.calloutType = calloutType
        self.embedUrl = embedUrl
        self.htmlContent = htmlContent
        self.questions = questions
        self.passingScore = passingScore
        self.fileName = fileName
    }

    /// Склеиваем JSON-колонку `content` с nested `block.test`, если он есть.
    fileprivate static func merge(base: LearningBlockContent?,
                                  test: LearningTestEnvelope?) -> LearningBlockContent? {
        guard base != nil || test != nil else { return nil }
        return LearningBlockContent(
            body: base?.body,
            url: base?.url,
            videoUrl: base?.videoUrl ?? base?.url,
            imageUrl: base?.imageUrl ?? base?.url,
            calloutType: base?.calloutType,
            embedUrl: base?.embedUrl,
            htmlContent: base?.htmlContent,
            questions: test?.questions ?? base?.questions,
            passingScore: test?.passScore ?? base?.passingScore,
            fileName: base?.fileName
        )
    }
}

struct TestQuestion: Identifiable, Decodable {
    let id: String
    let text: String
    let kind: String
    let options: [TestOption]

    private enum CodingKeys: String, CodingKey {
        case id, text, questionText, kind, type, options, answers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.text = (try? c.decodeIfPresent(String.self, forKey: .text))
            ?? (try? c.decodeIfPresent(String.self, forKey: .questionText)) ?? ""
        self.kind = (try? c.decodeIfPresent(String.self, forKey: .kind))
            ?? (try? c.decodeIfPresent(String.self, forKey: .type)) ?? "single"
        self.options = (try? c.decodeIfPresent([TestOption].self, forKey: .options))
            ?? (try? c.decodeIfPresent([TestOption].self, forKey: .answers)) ?? []
    }
}

struct TestOption: Identifiable, Decodable {
    let id: String
    let text: String

    private enum CodingKeys: String, CodingKey {
        case id, text, answerText
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.text = (try? c.decodeIfPresent(String.self, forKey: .text))
            ?? (try? c.decodeIfPresent(String.self, forKey: .answerText)) ?? ""
    }
}

// MARK: - Request bodies

private struct ProgressUpdateBody: Encodable {
    let courseId: String
    let blockId: String
    let completed: Bool
}

private struct TestSubmitAnswer: Encodable {
    let questionId: String
    let optionIds: [String]
}

private struct TestSubmitBody: Encodable {
    let courseId: String
    let blockId: String
    let answers: [TestSubmitAnswer]
}

private struct TestSubmitResponse: Decodable {
    let score: Int
    let passed: Bool
    let correctAnswers: Int?
}

// MARK: - LearningView (главный экран)

enum LearningTab: String, Hashable, CaseIterable {
    case my = "Мои курсы"
    case catalog = "Каталог"
}

struct LearningView: View {
    @State private var tab: LearningTab = .my
    @State private var myCourses: [LearningCourse] = []
    @State private var catalogCourses: [LearningCourse] = []
    @State private var loading = false
    @State private var error: String?
    /// Скрывает курсы, которые уже на 100% пройдены / completed == true.
    @State private var onlyIncomplete: Bool = false

    private var rawVisibleCourses: [LearningCourse] {
        tab == .my ? myCourses : catalogCourses
    }

    private var visibleCourses: [LearningCourse] {
        guard onlyIncomplete else { return rawVisibleCourses }
        return rawVisibleCourses.filter { course in
            if course.completed == true { return false }
            if let pct = course.progressPercent, pct >= 100 { return false }
            return true
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                DSPageTitle(text: "Обучение",
                            subtitle: "Курсы и материалы для развития")
                    .padding(.top, 4)

                Picker("Раздел", selection: $tab) {
                    ForEach(LearningTab.allCases, id: \.self) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)

                // Чип-фильтр «Только незавершённые»
                HStack(spacing: 8) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { onlyIncomplete.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: onlyIncomplete ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Только незавершённые")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .foregroundColor(onlyIncomplete ? .white : Theme.textSecondary)
                        .background(
                            Capsule()
                                .fill(onlyIncomplete ? Theme.accent : Theme.surfaceBackground)
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                onlyIncomplete ? Color.clear : Theme.border, lineWidth: 0.5
                            )
                        )
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)
                }

                content
                Color.clear.frame(height: TabBarVisibility.reservedHeight)
            }
            .padding(16)
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("Обучение")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load(force: true) }
        .task { await load(force: false) }
        .onChange(of: tab) { _ in
            Task { await load(force: false) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if visibleCourses.isEmpty && loading {
            ProgressView()
                .tint(Theme.accent)
                .frame(maxWidth: .infinity, minHeight: 200)
        } else if visibleCourses.isEmpty {
            if onlyIncomplete && !rawVisibleCourses.isEmpty {
                EmptyStateView(
                    icon: "checkmark.seal",
                    title: "Все курсы пройдены",
                    description: "Снимите фильтр «Только незавершённые», чтобы увидеть весь список"
                )
            } else {
                EmptyStateView(
                    icon: "graduationcap",
                    title: tab == .my ? "Нет назначенных курсов" : "Каталог пуст",
                    description: error ?? (tab == .my
                        ? "Когда вам назначат обучение, оно появится здесь"
                        : "Скоро здесь появятся курсы для самостоятельного изучения")
                )
            }
        } else {
            VStack(spacing: 14) {
                ForEach(visibleCourses) { course in
                    NavigationLink {
                        CourseDetailView(courseId: course.id)
                    } label: {
                        CourseCard(course: course)
                    }
                    .buttonStyle(DSPressScaleStyle())
                }
            }
        }
    }

    private func load(force: Bool) async {
        // Кэшируем уже загруженный таб, если не форсим refresh.
        if !force {
            if tab == .my && !myCourses.isEmpty { return }
            if tab == .catalog && !catalogCourses.isEmpty { return }
        }

        loading = true
        defer { loading = false }
        do {
            let path = tab == .my ? "learning/my" : "learning/courses"
            let courses: [LearningCourse] = try await APIClient.shared.get(path)
            if tab == .my {
                self.myCourses = courses
            } else {
                self.catalogCourses = courses
            }
            self.error = nil
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}

// MARK: - Course card

private struct CourseCard: View {
    let course: LearningCourse

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cover
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .clipped()

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Text(course.title)
                        .font(.dsH2)
                        .foregroundColor(Theme.textPrimary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if course.completed == true {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(Theme.success)
                            .font(.system(size: 18))
                    }
                }

                if let desc = course.description, !desc.isEmpty {
                    Text(desc)
                        .font(.dsBodyLG)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                if let pct = course.progressPercent, pct > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: Double(pct) / 100.0)
                            .tint(Theme.accent)
                        Text("\(pct)% пройдено")
                            .font(.dsCaption)
                            .foregroundColor(Theme.textTertiary)
                    }
                    .padding(.top, 4)
                }

                statsRow
                    .padding(.top, 2)
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.xl2, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.xl2, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 0.5)
        )
        .dsCardShadow()
    }

    @ViewBuilder
    private var statsRow: some View {
        let modules = course.modulesCount ?? 0
        let blocks = course.blocksCount ?? 0
        let dur = course.estimatedDuration ?? 0
        let parts: [String] = {
            var arr: [String] = []
            if modules > 0 { arr.append("\(modules) \(pluralize(modules, ["модуль", "модуля", "модулей"]))") }
            if blocks > 0 { arr.append("\(blocks) \(pluralize(blocks, ["блок", "блока", "блоков"]))") }
            if dur > 0 { arr.append(formatDuration(minutes: dur)) }
            return arr
        }()
        if !parts.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
                Text(parts.joined(separator: " · "))
                    .font(.dsCaption)
                    .foregroundColor(Theme.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var cover: some View {
        if let url = course.coverUrl, let parsed = URL(string: ensureAbsolute(url)) {
            AsyncImage(url: parsed) { phase in
                switch phase {
                case .empty:
                    Theme.pageBackground.shimmering()
                case .success(let img):
                    img.resizable().scaledToFill()
                case .failure:
                    placeholderCover
                @unknown default:
                    placeholderCover
                }
            }
        } else {
            placeholderCover
        }
    }

    private var placeholderCover: some View {
        ZStack {
            LinearGradient(
                colors: [Theme.accent.opacity(0.7), Theme.purple.opacity(0.7), Theme.pink.opacity(0.7)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Image(systemName: "graduationcap.fill")
                .font(.system(size: 56, weight: .bold))
                .foregroundColor(.white.opacity(0.85))
        }
    }

    private func formatDuration(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) мин" }
        let h = minutes / 60
        let m = minutes % 60
        return m == 0 ? "\(h) ч" : "\(h) ч \(m) мин"
    }

    private func pluralize(_ n: Int, _ forms: [String]) -> String {
        let mod10 = n % 10
        let mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return forms[0] }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return forms[1] }
        return forms[2]
    }
}

// MARK: - Course detail

struct CourseDetailView: View {
    let courseId: String
    @State private var course: LearningCourseView?
    @State private var completedBlocks: Set<String> = []
    @State private var testResults: [String: TestResult] = [:]
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let course {
                    header(course)

                    ForEach(course.modules.sorted(by: { $0.order < $1.order })) { module in
                        ModuleSection(
                            module: module,
                            courseId: course.id,
                            completedBlocks: completedBlocks,
                            testResults: testResults,
                            onToggleBlock: { blockId, completed in
                                Task { await toggleBlock(blockId: blockId, completed: completed) }
                            },
                            onTestSubmitted: { blockId, result in
                                testResults[blockId] = result
                                if result.passed {
                                    completedBlocks.insert(blockId)
                                }
                            }
                        )
                    }
                } else if loading {
                    ProgressView()
                        .tint(Theme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 100)
                } else if let err = error {
                    EmptyStateView(
                        icon: "exclamationmark.triangle",
                        title: "Не удалось загрузить курс",
                        description: err
                    )
                }
            }
            .padding(16)
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle(course?.title ?? "Курс")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    @ViewBuilder
    private func header(_ course: LearningCourseView) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let cover = course.coverUrl, let url = URL(string: ensureAbsolute(cover)) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty: Theme.pageBackground
                    case .success(let img): img.resizable().scaledToFill()
                    case .failure: Theme.pageBackground
                    @unknown default: Theme.pageBackground
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
            }

            Text(course.title)
                .font(.dsH1)
                .tracking(-0.5)
                .foregroundColor(Theme.textPrimary)

            if let desc = course.description, !desc.isEmpty {
                Text(desc)
                    .font(.dsBodyLG)
                    .foregroundColor(Theme.textSecondary)
            }

            if let progress = course.progress {
                DSCard(radius: Radius.md, padding: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Прогресс")
                                .font(.dsCaption.weight(.semibold))
                                .foregroundColor(Theme.textSecondary)
                            Spacer()
                            Text("\(progress.progressPercent ?? 0)%")
                                .font(.dsCaption.weight(.semibold))
                                .foregroundColor(Theme.textSecondary)
                            if progress.completed == true {
                                Image(systemName: "checkmark.seal.fill")
                                    .foregroundColor(Theme.success)
                                    .font(.system(size: 12))
                            }
                        }
                        ProgressView(value: Double(progress.progressPercent ?? 0) / 100.0)
                            .tint(Theme.accent)
                    }
                }
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let view: LearningCourseView = try await APIClient.shared.get("learning/courses/\(courseId)/view")
            self.course = view
            if let p = view.progress {
                self.completedBlocks = Set(p.completedBlocks ?? [])
                self.testResults = p.testResults ?? [:]
            }
            self.error = nil
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func toggleBlock(blockId: String, completed: Bool) async {
        // Оптимистичный апдейт для отзывчивости UI.
        if completed { completedBlocks.insert(blockId) } else { completedBlocks.remove(blockId) }
        do {
            let body = ProgressUpdateBody(courseId: courseId, blockId: blockId, completed: completed)
            let _: EmptyResponse = try await APIClient.shared.post("learning/progress", body: body)
        } catch {
            // Откатываем при ошибке.
            if completed { completedBlocks.remove(blockId) } else { completedBlocks.insert(blockId) }
        }
    }
}

// MARK: - Module section

private struct ModuleSection: View {
    let module: LearningModule
    let courseId: String
    let completedBlocks: Set<String>
    let testResults: [String: TestResult]
    let onToggleBlock: (String, Bool) -> Void
    let onTestSubmitted: (String, TestResult) -> Void

    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.textTertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(module.title)
                            .font(.dsH3)
                            .foregroundColor(Theme.textPrimary)
                            .multilineTextAlignment(.leading)
                        if let desc = module.description, !desc.isEmpty {
                            Text(desc)
                                .font(.dsCaption)
                                .foregroundColor(Theme.textSecondary)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    Spacer()
                    DSBadge(
                        text: "\(completedInModule)/\(module.blocks.count)",
                        color: completedInModule == module.blocks.count ? Theme.success : Theme.accent
                    )
                }
                .padding(14)
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(spacing: 12) {
                    ForEach(module.blocks.sorted(by: { $0.order < $1.order })) { block in
                        BlockCard(
                            block: block,
                            courseId: courseId,
                            isCompleted: completedBlocks.contains(block.id),
                            testResult: testResults[block.id],
                            onToggle: { newValue in onToggleBlock(block.id, newValue) },
                            onTestSubmitted: { result in onTestSubmitted(block.id, result) }
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .background(Theme.surfaceBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 0.5)
        )
        .dsCardShadow()
    }

    private var completedInModule: Int {
        module.blocks.filter { completedBlocks.contains($0.id) }.count
    }
}

// MARK: - Block card

private struct BlockCard: View {
    let block: LearningBlock
    let courseId: String
    let isCompleted: Bool
    let testResult: TestResult?
    let onToggle: (Bool) -> Void
    let onTestSubmitted: (TestResult) -> Void

    @State private var showVideo = false
    @State private var showHTML = false
    @State private var showTest = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = block.title, !title.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: kindIcon)
                        .foregroundColor(Theme.accent)
                        .font(.subheadline.weight(.semibold))
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    Spacer()
                }
            }

            content

            if block.kind != "test" {
                Button {
                    onToggle(!isCompleted)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundColor(isCompleted ? Theme.success : .secondary)
                        Text(isCompleted ? "Пройдено" : "Отметить как пройденное")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(isCompleted ? Theme.success : .primary)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(
                        (isCompleted ? Theme.success.opacity(0.10) : Theme.pageBackground)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Theme.surfaceBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var kindIcon: String {
        switch block.kind {
        case "text":    return "text.alignleft"
        case "video":   return "play.rectangle.fill"
        case "image":   return "photo"
        case "test":    return "checkmark.square"
        case "callout": return "info.circle"
        case "embed":   return "link"
        case "html":    return "doc.richtext"
        default:        return "rectangle"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch block.kind {
        case "text":
            textBlock
        case "video":
            videoBlock
        case "image":
            imageBlock
        case "callout":
            calloutBlock
        case "test":
            testBlock
        case "embed":
            embedBlock
        case "html":
            htmlBlock
        default:
            EmptyView()
        }
    }

    // MARK: text
    private var textBlock: some View {
        Text(parseMarkdown(block.content?.body ?? ""))
            .font(.body)
            .lineSpacing(4)
            .foregroundColor(.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: video
    private var videoBlock: some View {
        Button { showVideo = true } label: {
            ZStack {
                if let thumb = block.content?.imageUrl, let url = URL(string: ensureAbsolute(thumb)) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img): img.resizable().scaledToFill()
                        default: thumbPlaceholder
                        }
                    }
                } else {
                    thumbPlaceholder
                }
                Color.black.opacity(0.25)
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.white)
                    .shadow(radius: 6)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 200)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showVideo) {
            if let videoUrl = block.content?.videoUrl, let url = URL(string: ensureAbsolute(videoUrl)) {
                VideoPlayerSheet(url: url)
            } else {
                Text("Видео недоступно").padding()
            }
        }
    }

    private var thumbPlaceholder: some View {
        LinearGradient(
            colors: [Theme.accent.opacity(0.7), Theme.purple.opacity(0.7)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    // MARK: image
    @ViewBuilder
    private var imageBlock: some View {
        if let img = block.content?.imageUrl, let url = URL(string: ensureAbsolute(img)) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    Theme.pageBackground.shimmering()
                        .frame(height: 200)
                case .success(let image):
                    image.resizable().scaledToFit()
                case .failure:
                    Theme.pageBackground.frame(height: 120)
                @unknown default:
                    Theme.pageBackground.frame(height: 120)
                }
            }
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: callout
    private var calloutBlock: some View {
        let kind = block.content?.calloutType ?? "info"
        let color: Color = {
            switch kind {
            case "warning": return Theme.warning
            case "danger":  return Theme.danger
            case "success": return Theme.success
            default:        return Theme.info
            }
        }()
        let icon: String = {
            switch kind {
            case "warning": return "exclamationmark.triangle.fill"
            case "danger":  return "xmark.octagon.fill"
            case "success": return "checkmark.circle.fill"
            default:        return "info.circle.fill"
            }
        }()

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.title3)
            Text(parseMarkdown(block.content?.body ?? ""))
                .font(.subheadline)
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(color.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(color.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: test
    private var testBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let result = testResult {
                HStack(spacing: 10) {
                    Image(systemName: result.passed ? "checkmark.seal.fill" : "xmark.seal.fill")
                        .foregroundColor(result.passed ? Theme.success : Theme.danger)
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.passed ? "Тест пройден" : "Тест не пройден")
                            .font(.subheadline.weight(.semibold))
                        Text("Результат: \(result.score)%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Button {
                showTest = true
            } label: {
                HStack {
                    Image(systemName: "checkmark.square")
                    Text(testResult == nil ? "Пройти тест" : "Пройти ещё раз")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .foregroundColor(.white)
                .background(Theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $showTest) {
            if let questions = block.content?.questions, !questions.isEmpty {
                NavigationStack {
                    TestView(
                        courseId: courseId,
                        blockId: block.id,
                        questions: questions,
                        passingScore: block.content?.passingScore ?? 70,
                        onSubmitted: { result in
                            onTestSubmitted(result)
                        }
                    )
                }
            } else {
                Text("Вопросы недоступны").padding()
            }
        }
    }

    // MARK: embed
    @ViewBuilder
    private var embedBlock: some View {
        if let embed = block.content?.embedUrl, let url = URL(string: ensureAbsolute(embed)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .foregroundColor(Theme.accent)
                    Text(url.host ?? embed)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Link(destination: url) {
                    HStack {
                        Image(systemName: "safari")
                        Text("Открыть в браузере")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 14)
                    .foregroundColor(.white)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    // MARK: html
    @ViewBuilder
    private var htmlBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let html = block.content?.htmlContent, !html.isEmpty {
                Button {
                    showHTML = true
                } label: {
                    HStack {
                        Image(systemName: "doc.richtext")
                        Text("Открыть содержимое")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 14)
                    .foregroundColor(.white)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showHTML) {
                    NavigationStack {
                        HTMLViewer(html: html)
                            .navigationTitle(block.title ?? "Содержимое")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button("Закрыть") { showHTML = false }
                                }
                            }
                    }
                }
            }
        }
    }
}

// MARK: - Video player sheet

private struct VideoPlayerSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VideoPlayer(player: AVPlayer(url: url))
                .ignoresSafeArea()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Закрыть") { dismiss() }
                    }
                }
        }
    }
}

// MARK: - HTML viewer

private struct HTMLViewer: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        WKWebView()
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let wrapped = """
        <!doctype html><html><head>
        <meta name='viewport' content='width=device-width, initial-scale=1'>
        <style>
            body { font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                   font-size: 16px; line-height: 1.5; padding: 16px; color: #111; }
            img, video, iframe { max-width: 100%; height: auto; border-radius: 8px; }
            pre { background: #f4f4f5; padding: 10px; border-radius: 8px; overflow-x: auto; }
            a { color: #6366f1; }
            @media (prefers-color-scheme: dark) {
                body { background: #000; color: #f4f4f5; }
                pre  { background: #1f1f23; }
            }
        </style></head><body>\(html)</body></html>
        """
        webView.loadHTMLString(wrapped, baseURL: URL(string: "https://rossihelp.ru/"))
    }
}

// MARK: - TestView

struct TestView: View {
    let courseId: String
    let blockId: String
    let questions: [TestQuestion]
    let passingScore: Int
    let onSubmitted: (TestResult) -> Void

    @Environment(\.dismiss) private var dismiss

    /// questionId -> set of selected optionIds
    @State private var answers: [String: Set<String>] = [:]
    @State private var submitting = false
    @State private var error: String?
    @State private var result: TestSubmitResponse?

    var body: some View {
        Group {
            if let result {
                resultView(result)
            } else {
                questionsView
            }
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("Тест")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Закрыть") { dismiss() }
            }
        }
    }

    private var questionsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Проходной балл: \(passingScore)%")
                    .font(.dsCaption.weight(.semibold))
                    .foregroundColor(Theme.textSecondary)

                ForEach(Array(questions.enumerated()), id: \.element.id) { idx, q in
                    questionCard(index: idx, question: q)
                }

                if let err = error {
                    Text(err)
                        .font(.dsBody)
                        .foregroundColor(Theme.danger)
                        .padding(.top, 4)
                }

                DSPrimaryButton(
                    action: { Task { await submit() } },
                    loading: submitting,
                    enabled: canSubmit
                ) {
                    HStack(spacing: 8) {
                        Image(systemName: "paperplane.fill")
                        Text("Отправить ответы")
                    }
                }
                .padding(.top, 8)
            }
            .padding(16)
        }
    }

    private var canSubmit: Bool {
        questions.allSatisfy { (answers[$0.id]?.isEmpty == false) }
    }

    private func questionCard(index: Int, question: TestQuestion) -> some View {
        DSCard(radius: Radius.lg, padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(index + 1). \(question.text)")
                    .font(.dsH3)
                    .foregroundColor(Theme.textPrimary)
                    .multilineTextAlignment(.leading)

                VStack(spacing: 8) {
                    ForEach(question.options) { option in
                        optionRow(question: question, option: option)
                    }
                }
            }
        }
    }

    private func optionRow(question: TestQuestion, option: TestOption) -> some View {
        let selected = answers[question.id]?.contains(option.id) ?? false
        let isMulti = question.kind == "multi"
        return Button {
            toggle(question: question, optionId: option.id)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: iconName(selected: selected, isMulti: isMulti))
                    .font(.title3)
                    .foregroundColor(selected ? Theme.accent : .secondary)
                Text(option.text)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(selected ? Theme.accent.opacity(0.10) : Theme.surfaceBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func iconName(selected: Bool, isMulti: Bool) -> String {
        if isMulti {
            return selected ? "checkmark.square.fill" : "square"
        } else {
            return selected ? "largecircle.fill.circle" : "circle"
        }
    }

    private func toggle(question: TestQuestion, optionId: String) {
        var current = answers[question.id] ?? []
        if question.kind == "multi" {
            if current.contains(optionId) { current.remove(optionId) } else { current.insert(optionId) }
        } else {
            current = [optionId]
        }
        answers[question.id] = current
    }

    private func submit() async {
        submitting = true
        defer { submitting = false }
        let payload = questions.map { q in
            TestSubmitAnswer(
                questionId: q.id,
                optionIds: Array(answers[q.id] ?? [])
            )
        }
        let body = TestSubmitBody(courseId: courseId, blockId: blockId, answers: payload)
        do {
            let resp: TestSubmitResponse = try await APIClient.shared.post("learning/tests/submit", body: body)
            self.result = resp
            self.error = nil
            onSubmitted(TestResult(
                score: resp.score,
                passed: resp.passed,
                attemptedAt: ISO8601DateFormatter().string(from: Date())
            ))
        } catch {
            self.error = apiUserMessage(error)
        }
    }

    private func resultView(_ result: TestSubmitResponse) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: result.passed ? "checkmark.seal.fill" : "xmark.seal.fill")
                .font(.system(size: 96))
                .foregroundColor(result.passed ? Theme.success : Theme.danger)

            Text(result.passed ? "Тест пройден" : "Тест не пройден")
                .font(.title.weight(.bold))

            VStack(spacing: 6) {
                Text("Ваш результат")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("\(result.score)%")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundColor(result.passed ? Theme.success : Theme.danger)
                if let correct = result.correctAnswers {
                    Text("Правильных ответов: \(correct) из \(questions.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text("Проходной балл: \(passingScore)%")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            DSPrimaryButton(action: { dismiss() }) {
                Text("Назад к курсу")
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack { LearningView() }
}
