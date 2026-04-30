//
//  LearningAdminView.swift — нативная админка обучения.
//
//  Endpoints (apps/api/src/modules/learning/learning.controller.ts):
//   • GET    /learning/courses                  — список
//   • GET    /learning/courses/:id              — детали
//   • POST   /learning/courses                  — создать
//   • PATCH  /learning/courses/:id              — обновить (включая status: draft|published)
//   • DELETE /learning/courses/:id              — удалить
//   • POST   /learning/modules                  — создать модуль (body: courseId, title, orderIndex)
//   • PATCH  /learning/modules/:id              — обновить
//   • DELETE /learning/modules/:id              — удалить
//   • POST   /learning/blocks                   — создать блок (body: moduleId, type, content, orderIndex)
//   • PATCH  /learning/blocks/:id               — обновить
//   • DELETE /learning/blocks/:id               — удалить
//   • POST   /learning/tests/upsert             — upsert теста для блока
//   • GET    /learning/courses/:id/view         — полный курс (для редактирования)
//

import SwiftUI

// MARK: - Models

struct AdminCourse: Codable, Identifiable {
    let id: String
    let title: String
    let description: String?
    let coverUrl: String?
    let status: String?
    let modulesCount: Int?
    let studentsCount: Int?
    let isPublished: Bool?

    var publishedFlag: Bool { isPublished ?? (status == "published") }
}

struct AdminCourseModule: Codable, Identifiable {
    let id: String
    let title: String
    let orderIndex: Int?
    let order: Int?
    let blocks: [AdminCourseBlock]?

    var displayOrder: Int? { orderIndex ?? order }
}

struct AdminCourseBlock: Codable, Identifiable {
    let id: String
    let type: String
    let content: LearningJSON?
    let orderIndex: Int?
}

/// Универсальный Codable для произвольного JSON content.
struct LearningJSON: Codable {
    let value: Any

    init(_ v: Any) { self.value = v }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self.value = v }
        else if let v = try? c.decode(Double.self) { self.value = v }
        else if let v = try? c.decode(String.self) { self.value = v }
        else if let v = try? c.decode([String: LearningJSON].self) {
            self.value = v.mapValues { $0.value }
        }
        else if let v = try? c.decode([LearningJSON].self) {
            self.value = v.map { $0.value }
        }
        else { self.value = NSNull() }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as Bool: try c.encode(v)
        case let v as Int: try c.encode(v)
        case let v as Double: try c.encode(v)
        case let v as String: try c.encode(v)
        case let v as [String: Any]:
            try c.encode(v.mapValues { LearningJSON($0) })
        case let v as [Any]:
            try c.encode(v.map { LearningJSON($0) })
        default: try c.encodeNil()
        }
    }

    var stringValue: String? { value as? String }
    var dictValue: [String: Any]? { value as? [String: Any] }
}

// MARK: - List

struct LearningAdminView: View {
    @State private var courses: [AdminCourse] = []
    @State private var loading = true
    @State private var error: String?
    @State private var editing: AdminCourse?
    @State private var showCreate = false

    var body: some View {
        ZStack {
            Theme.pageBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    DSPageTitle(text: "Обучение",
                                subtitle: courses.isEmpty ? nil : "Курсов: \(courses.count)")
                        .padding(.top, 4)

                    if loading && courses.isEmpty {
                        ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.top, 60)
                    } else if let err = error, courses.isEmpty {
                        EmptyStateView(icon: "exclamationmark.triangle", title: "Ошибка", description: err)
                    } else if courses.isEmpty {
                        EmptyStateView(icon: "graduationcap", title: "Скоро будет", description: "Курсы ещё не созданы")
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(courses) { course in
                                NavigationLink {
                                    CourseAdminDetailView(course: course) { Task { await load() } }
                                } label: {
                                    CourseAdminCard(course: course)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Редактировать") { editing = course }
                                    Button("Удалить", role: .destructive) {
                                        Task { await deleteCourse(course) }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Обучение")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showCreate = true } label: {
                    Image(systemName: "plus").font(.system(size: 16, weight: .semibold))
                }.tint(Theme.accent)
            }
        }
        .refreshable { await load() }
        .task { if courses.isEmpty { await load() } }
        .sheet(isPresented: $showCreate) {
            CourseEditSheet(course: nil) { Task { await load() } }
        }
        .sheet(item: $editing) { c in
            CourseEditSheet(course: c) { Task { await load() } }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        if let arr: [AdminCourse] = try? await APIClient.shared.get("learning/courses") {
            self.courses = arr; self.error = nil; return
        }
        if let arr: [AdminCourse] = try? await APIClient.shared.get("admin/learning/courses") {
            self.courses = arr; self.error = nil; return
        }
        self.error = "Не удалось загрузить курсы"
    }

    private func deleteCourse(_ c: AdminCourse) async {
        do {
            try await APIClient.shared.delete("learning/courses/\(c.id)")
        } catch {
            try? await APIClient.shared.delete("admin/learning/courses/\(c.id)")
        }
        await load()
    }
}

struct CourseAdminCard: View {
    let course: AdminCourse

    var body: some View {
        DSCard(radius: Radius.lg, padding: 12) {
            HStack(spacing: 12) {
                DSIconTile(systemImage: "book.fill", color: Theme.purple, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(course.title)
                        .font(.dsBodyLG.weight(.semibold))
                        .foregroundColor(Theme.textPrimary)
                    if let desc = course.description, !desc.isEmpty {
                        Text(desc).font(.dsCaption).foregroundColor(Theme.textTertiary).lineLimit(2)
                    }
                    HStack(spacing: 6) {
                        if let m = course.modulesCount {
                            DSBadge(text: "модулей: \(m)", color: Theme.accent, filled: false)
                        }
                        if let s = course.studentsCount {
                            DSBadge(text: "студентов: \(s)", color: Theme.success, filled: false)
                        }
                        if !course.publishedFlag {
                            DSBadge(text: "draft", color: Theme.warning, filled: false)
                        } else {
                            DSBadge(text: "published", color: Theme.success, filled: false)
                        }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textTertiary)
            }
        }
    }
}

// MARK: - Detail

struct CourseAdminDetailView: View {
    let course: AdminCourse
    let onChanged: () -> Void

    @State private var modules: [AdminCourseModule] = []
    @State private var loading = true
    @State private var showCreateModule = false
    @State private var showEdit = false
    @State private var addBlockToModule: AdminCourseModule?
    @State private var error: String?

    var body: some View {
        ZStack {
            Theme.pageBackground.ignoresSafeArea()
            List {
                Section {
                    DSCard(radius: Radius.xl, padding: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(course.title).font(.dsH2).foregroundColor(Theme.textPrimary)
                            if let d = course.description, !d.isEmpty {
                                Text(d).font(.dsCaption).foregroundColor(Theme.textSecondary)
                            }
                            HStack {
                                Button("Редактировать") { showEdit = true }
                                    .buttonStyle(.bordered)
                                    .tint(Theme.accent)
                                Spacer()
                                DSBadge(text: course.publishedFlag ? "published" : "draft",
                                        color: course.publishedFlag ? Theme.success : Theme.warning,
                                        filled: true)
                            }
                            .padding(.top, 6)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                Section {
                    if loading {
                        ProgressView().tint(Theme.accent).frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    } else if modules.isEmpty {
                        EmptyStateView(icon: "rectangle.stack", title: "Нет модулей", description: "Добавьте первый модуль")
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    } else {
                        ForEach(modules) { m in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 12) {
                                    DSIconTile(systemImage: "rectangle.stack.fill", color: Theme.purple, size: 32)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(m.title).font(.dsBodySM.weight(.medium)).foregroundColor(Theme.textPrimary)
                                        if let o = m.displayOrder {
                                            Text("Порядок: \(o)").font(.dsCaption).foregroundColor(Theme.textTertiary)
                                        }
                                    }
                                    Spacer()
                                    Button {
                                        addBlockToModule = m
                                    } label: {
                                        Image(systemName: "plus.circle.fill").foregroundColor(Theme.accent)
                                    }
                                }
                                if let blocks = m.blocks, !blocks.isEmpty {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ForEach(blocks) { b in
                                            HStack(spacing: 6) {
                                                Image(systemName: blockIcon(b.type))
                                                    .font(.system(size: 11))
                                                    .foregroundColor(Theme.accent)
                                                Text(blockSummary(b))
                                                    .font(.dsCaption)
                                                    .foregroundColor(Theme.textSecondary)
                                                    .lineLimit(1)
                                            }
                                        }
                                    }
                                    .padding(.leading, 44)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    Task { await deleteModule(m) }
                                } label: {
                                    Label("Удалить", systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Модули")
                        Spacer()
                        Button {
                            showCreateModule = true
                        } label: {
                            Image(systemName: "plus.circle.fill").foregroundColor(Theme.accent)
                        }
                    }
                }

                if let err = error {
                    Text(err).font(.dsCaption).foregroundColor(Theme.danger)
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Курс")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadModules() }
        .refreshable { await loadModules() }
        .sheet(isPresented: $showCreateModule) {
            ModuleEditSheet(courseId: course.id, module: nil) { Task { await loadModules() } }
        }
        .sheet(isPresented: $showEdit) {
            CourseEditSheet(course: course) { onChanged() }
        }
        .sheet(item: $addBlockToModule) { m in
            BlockCreateSheet(moduleId: m.id) { Task { await loadModules() } }
        }
    }

    private func blockIcon(_ type: String) -> String {
        switch type {
        case "text": return "text.alignleft"
        case "video": return "video.fill"
        case "image": return "photo.fill"
        case "file": return "doc.fill"
        case "test": return "checkmark.square.fill"
        case "custom": return "chevron.left.slash.chevron.right"
        default: return "doc"
        }
    }

    private func blockSummary(_ b: AdminCourseBlock) -> String {
        let dict = b.content?.dictValue ?? [:]
        switch b.type {
        case "text":
            if let s = dict["text"] as? String { return s }
            return "Текст"
        case "video":
            if let url = dict["url"] as? String { return url }
            return "Видео"
        case "test": return "Тест"
        default: return b.type.capitalized
        }
    }

    private func loadModules() async {
        loading = true
        defer { loading = false }
        // Try /learning/courses/:id/view (returns full course with modules+blocks)
        struct CourseView: Codable {
            let modules: [AdminCourseModule]?
        }
        if let v: CourseView = try? await APIClient.shared.get("learning/courses/\(course.id)/view") {
            self.modules = v.modules ?? []
            return
        }
        if let arr: [AdminCourseModule] = try? await APIClient.shared.get("admin/learning/courses/\(course.id)/modules") {
            self.modules = arr
            return
        }
        if let arr: [AdminCourseModule] = try? await APIClient.shared.get("learning/courses/\(course.id)/modules") {
            self.modules = arr
        }
    }

    private func deleteModule(_ m: AdminCourseModule) async {
        do {
            try await APIClient.shared.delete("learning/modules/\(m.id)")
        } catch {
            try? await APIClient.shared.delete("admin/learning/modules/\(m.id)")
        }
        await loadModules()
    }
}

// MARK: - Course Sheet

struct CourseEditSheet: View {
    let course: AdminCourse?
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var coverUrl = ""
    @State private var isPublished = false
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Курс") {
                    TextField("Название", text: $title)
                    TextField("Описание", text: $description, axis: .vertical).lineLimit(2...6)
                    TextField("URL обложки", text: $coverUrl)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Публикация") {
                    Toggle("Опубликован", isOn: $isPublished)
                }
                if let err = error {
                    Section { Text(err).font(.dsCaption).foregroundColor(Theme.danger) }
                }
            }
            .navigationTitle(course == nil ? "Новый курс" : "Редактирование")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Сохраняю…" : "Сохранить") { Task { await save() } }
                        .disabled(saving || title.isEmpty)
                }
            }
            .onAppear {
                if let c = course {
                    title = c.title
                    description = c.description ?? ""
                    coverUrl = c.coverUrl ?? ""
                    isPublished = c.publishedFlag
                }
            }
        }
    }

    struct Payload: Encodable {
        let title: String
        let description: String?
        let coverUrl: String?
        let status: String?
    }

    private func save() async {
        saving = true; defer { saving = false }
        let body = Payload(
            title: title,
            description: description.isEmpty ? nil : description,
            coverUrl: coverUrl.isEmpty ? nil : coverUrl,
            status: isPublished ? "published" : "draft"
        )
        let path: String; let method: String
        if let c = course { path = "learning/courses/\(c.id)"; method = "PATCH" }
        else { path = "learning/courses"; method = "POST" }
        do {
            _ = try await APIClient.shared.rawRequest(method, path, body: body)
            onSaved(); dismiss()
        } catch {
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

// MARK: - Module Sheet

struct ModuleEditSheet: View {
    let courseId: String
    let module: AdminCourseModule?
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var orderIndex: String = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Модуль") {
                    TextField("Название", text: $title)
                    TextField("Порядок (число)", text: $orderIndex)
                        .keyboardType(.numberPad)
                }
                if let err = error { Section { Text(err).font(.dsCaption).foregroundColor(Theme.danger) } }
            }
            .navigationTitle(module == nil ? "Новый модуль" : "Редактирование")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Сохраняю…" : "Сохранить") { Task { await save() } }
                        .disabled(saving || title.isEmpty)
                }
            }
            .onAppear {
                if let m = module {
                    title = m.title
                    if let o = m.displayOrder { orderIndex = "\(o)" }
                }
            }
        }
    }

    struct CreatePayload: Encodable {
        let courseId: String
        let title: String
        let orderIndex: Int?
    }
    struct UpdatePayload: Encodable {
        let title: String?
        let orderIndex: Int?
    }

    private func save() async {
        saving = true; defer { saving = false }
        let order = Int(orderIndex)
        do {
            if let m = module {
                let body = UpdatePayload(title: title, orderIndex: order)
                _ = try await APIClient.shared.rawRequest("PATCH", "learning/modules/\(m.id)", body: body)
            } else {
                let body = CreatePayload(courseId: courseId, title: title, orderIndex: order)
                _ = try await APIClient.shared.rawRequest("POST", "learning/modules", body: body)
            }
            onSaved(); dismiss()
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}

// MARK: - Block Sheet

struct BlockCreateSheet: View {
    let moduleId: String
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var type: String = "text"
    @State private var textContent = ""
    @State private var url = ""
    @State private var orderIndex = ""
    @State private var saving = false
    @State private var error: String?

    private let types: [(String, String, String)] = [
        ("text", "Текст", "text.alignleft"),
        ("video", "Видео", "video.fill"),
        ("image", "Картинка", "photo.fill"),
        ("file", "Файл", "doc.fill"),
        ("test", "Тест (создать)", "checkmark.square.fill"),
        ("custom", "HTML / embed", "chevron.left.slash.chevron.right"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Тип блока") {
                    Picker("Тип", selection: $type) {
                        ForEach(types, id: \.0) { Text($0.1).tag($0.0) }
                    }
                }
                Section("Содержимое") {
                    switch type {
                    case "text":
                        TextField("Текст…", text: $textContent, axis: .vertical).lineLimit(3...10)
                    case "video":
                        TextField("URL видео", text: $url)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    case "image", "file":
                        TextField("URL", text: $url)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    case "custom":
                        TextField("HTML / embed", text: $textContent, axis: .vertical).lineLimit(3...10)
                    case "test":
                        Text("Тест будет создан с заглушкой. Добавьте вопросы из веб-версии.")
                            .font(.dsCaption).foregroundColor(Theme.textTertiary)
                    default: EmptyView()
                    }
                }
                Section("Порядок") {
                    TextField("Индекс (число)", text: $orderIndex)
                        .keyboardType(.numberPad)
                }
                if let err = error { Section { Text(err).font(.dsCaption).foregroundColor(Theme.danger) } }
            }
            .navigationTitle("Новый блок")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Сохраняю…" : "Создать") { Task { await save() } }
                        .disabled(saving)
                }
            }
        }
    }

    struct BlockBody: Encodable {
        let moduleId: String
        let type: String
        let content: [String: LearningJSON]
        let orderIndex: Int?
    }

    private func save() async {
        saving = true; defer { saving = false }
        var content: [String: LearningJSON] = [:]
        switch type {
        case "text", "custom":
            content["text"] = LearningJSON(textContent)
        case "video", "image", "file":
            content["url"] = LearningJSON(url)
        case "test":
            content["title"] = LearningJSON("Новый тест")
            content["passScore"] = LearningJSON(70)
        default: break
        }
        let body = BlockBody(
            moduleId: moduleId,
            type: type,
            content: content,
            orderIndex: Int(orderIndex)
        )
        do {
            _ = try await APIClient.shared.rawRequest("POST", "learning/blocks", body: body)
            onSaved(); dismiss()
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}

#Preview {
    NavigationStack { LearningAdminView() }
}
