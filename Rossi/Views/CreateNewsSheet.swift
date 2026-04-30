//
//  CreateNewsSheet.swift — модалка создания новости.
//
//  Эндпоинты:
//   • GET  /news/categories       — список категорий
//   • POST /files/upload-url      — presigned URL для cover-картинки (как в FeedbackView)
//   • POST /news                  — создать новость { title, content, isImportant, coverUrl, categoryId }
//
//  Доступ к экрану — у пользователей с правом news.create | * | admin.*
//  (см. NewsListView.canCreate).
//

import SwiftUI
import PhotosUI
import UIKit

struct CreateNewsSheet: View {
    let onCreated: () -> Void

    @Environment(\.dismiss) private var dismiss

    // Поля формы
    @State private var title: String = ""
    @State private var content: String = ""
    @State private var isImportant: Bool = false
    @State private var selectedCategoryId: String? = nil
    @State private var coverUrl: String? = nil

    // Категории
    @State private var categories: [NewsCategory] = []
    @State private var loadingCategories = false

    // Cover upload
    @State private var photoItem: PhotosPickerItem? = nil
    @State private var uploadingCover = false

    // Состояние отправки
    @State private var sending = false
    @State private var lastError: String?

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var trimmedContent: String {
        content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Серверная валидация: title min 3, content min 1
    /// (см. apps/api/src/modules/news/dto/news.dto.ts CreateNewsDto).
    private var isValid: Bool {
        trimmedTitle.count >= 3 && !trimmedContent.isEmpty && !sending && !uploadingCover
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Заголовок") {
                    TextField("Заголовок новости", text: $title, axis: .vertical)
                        .lineLimit(1...3)
                }

                Section("Содержимое") {
                    ZStack(alignment: .topLeading) {
                        if content.isEmpty {
                            Text("Расскажите подробно о событии. Поддерживается обычный текст.")
                                .font(.body)
                                .foregroundColor(Theme.textTertiary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                        TextField("", text: $content, axis: .vertical)
                            .lineLimit(6...20)
                    }
                }

                Section("Категория") {
                    if loadingCategories {
                        HStack {
                            ProgressView().tint(Theme.accent)
                            Text("Загрузка…").foregroundColor(Theme.textSecondary)
                        }
                    } else if categories.isEmpty {
                        Text("Категории недоступны")
                            .foregroundColor(Theme.textTertiary)
                    } else {
                        Picker("Категория", selection: $selectedCategoryId) {
                            Text("Без категории").tag(String?.none)
                            ForEach(categories, id: \.id) { c in
                                Text(c.name).tag(Optional(c.id))
                            }
                        }
                    }
                }

                Section {
                    Toggle(isOn: $isImportant) {
                        Label("Важная", systemImage: "exclamationmark.circle.fill")
                    }
                    .tint(Theme.accent)
                } footer: {
                    Text("Важные новости отображаются в верхней части ленты.")
                }

                Section {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        if uploadingCover {
                            Label("Загружаю обложку…", systemImage: "arrow.up.circle")
                        } else if coverUrl != nil {
                            Label("Заменить обложку", systemImage: "photo.fill")
                        } else {
                            Label("Добавить обложку", systemImage: "photo")
                        }
                    }
                    .onChange(of: photoItem) { item in
                        guard let item else { return }
                        Task { await uploadCover(item) }
                    }

                    if let raw = coverUrl, let u = URL(string: ensureAbsolute(raw)) {
                        ZStack(alignment: .topTrailing) {
                            AsyncImage(url: u) { phase in
                                switch phase {
                                case .success(let img): img.resizable().scaledToFill()
                                default: Theme.pageBackground
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 160)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                            Button {
                                coverUrl = nil
                                photoItem = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.white)
                                    .background(Color.black.opacity(0.5).clipShape(Circle()))
                                    .font(.system(size: 18))
                            }
                            .padding(8)
                        }
                    }
                } header: {
                    Text("Обложка")
                }

                if let err = lastError {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(Theme.danger)
                            Text(err)
                                .font(.footnote)
                                .foregroundColor(Theme.danger)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.pageBackground)
            .navigationTitle("Новая новость")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Отмена") { dismiss() }
                        .tint(Theme.accent)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await create() }
                    } label: {
                        if sending {
                            ProgressView().tint(Theme.accent)
                        } else {
                            Text("Опубликовать").fontWeight(.semibold)
                        }
                    }
                    .disabled(!isValid)
                    .tint(Theme.accent)
                }
            }
            .task { await loadCategories() }
        }
    }

    // MARK: - Networking

    private func loadCategories() async {
        loadingCategories = true
        defer { loadingCategories = false }
        do {
            // Бэк может вернуть либо массив, либо { data: [...] } — пробуем оба варианта.
            if let list: [NewsCategory] = try? await APIClient.shared.get("news/categories") {
                self.categories = list
                return
            }
            struct Wrapped: Decodable { let data: [NewsCategory] }
            let wrapped: Wrapped = try await APIClient.shared.get("news/categories")
            self.categories = wrapped.data
        } catch {
            // Тихо — категория опциональна.
        }
    }

    private func create() async {
        // Бэк (apps/api/src/modules/news/dto/news.dto.ts) принимает:
        //   title (min 3, max 200), content (min 1), excerpt?, coverUrl?,
        //   categoryId? (UUID), tagIds?, isPinned?, isImportant?, status?
        // Чтобы новость сразу публиковалась, передаём status: "published".
        // categoryId опускаем целиком, если не выбран (вместо null) — тогда
        // class-validator IsUUID не падает на пустом значении.
        struct Body: Encodable {
            let title: String
            let content: String
            let isImportant: Bool
            let status: String
            let coverUrl: String?
            let categoryId: String?

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(title, forKey: .title)
                try c.encode(content, forKey: .content)
                try c.encode(isImportant, forKey: .isImportant)
                try c.encode(status, forKey: .status)
                if let coverUrl, !coverUrl.isEmpty {
                    try c.encode(coverUrl, forKey: .coverUrl)
                }
                if let categoryId, !categoryId.isEmpty {
                    try c.encode(categoryId, forKey: .categoryId)
                }
            }

            enum CodingKeys: String, CodingKey {
                case title, content, isImportant, status, coverUrl, categoryId
            }
        }

        sending = true
        lastError = nil
        defer { sending = false }

        let body = Body(
            title: trimmedTitle,
            content: trimmedContent,
            isImportant: isImportant,
            status: "published",
            coverUrl: coverUrl,
            categoryId: selectedCategoryId
        )

        do {
            _ = try await APIClient.shared.rawRequest("POST", "news", body: body)
            onCreated()
            dismiss()
        } catch {
            self.lastError = friendlyServerError(error)
        }
    }

    /// Извлекает читаемое сообщение из APIError.
    /// Сервер шлёт `{ error: { code, message, details } }`,
    /// но для class-validator `message` может быть массивом строк —
    /// в этом случае APIError.errorDescription отдаст что-то вроде
    /// `Ошибка 400: ["title must be longer than..."]`. Чистим скобки.
    private func friendlyServerError(_ error: Error) -> String {
        let raw = apiUserMessage(error) ?? "Не удалось отправить запрос"
        // Пытаемся выдрать message из JSON, если ошибка APIError.http(_, body)
        if case let .http(_, body) = (error as? APIError) ?? .noResponse,
           let body, let data = body.data(using: .utf8) {
            struct Wrap: Decodable {
                struct Inner: Decodable {
                    let code: String?
                    let messageString: String?
                    let messageArray: [String]?
                    init(from decoder: Decoder) throws {
                        let c = try decoder.container(keyedBy: K.self)
                        self.code = try c.decodeIfPresent(String.self, forKey: .code)
                        if let s = try? c.decode(String.self, forKey: .message) {
                            self.messageString = s
                            self.messageArray = nil
                        } else if let arr = try? c.decode([String].self, forKey: .message) {
                            self.messageArray = arr
                            self.messageString = nil
                        } else {
                            self.messageString = nil
                            self.messageArray = nil
                        }
                    }
                    enum K: String, CodingKey { case code, message }
                }
                let error: Inner?
            }
            if let w = try? JSONDecoder().decode(Wrap.self, from: data),
               let inner = w.error {
                if let arr = inner.messageArray, !arr.isEmpty {
                    return arr.joined(separator: "\n")
                }
                if let s = inner.messageString, !s.isEmpty {
                    return s
                }
            }
        }
        return raw
    }

    /// Загрузка cover через presigned-S3 (см. FeedbackView.handleAttachments).
    private func uploadCover(_ item: PhotosPickerItem) async {
        uploadingCover = true
        lastError = nil
        defer { uploadingCover = false }
        do {
            guard let raw = try await item.loadTransferable(type: Data.self) else { return }
            let mime = "image/jpeg"
            let outData: Data = (UIImage(data: raw)?.jpegData(compressionQuality: 0.85)) ?? raw
            let req = NewsUploadUrlRequest(
                kind: "news_cover",
                filename: "news-cover-\(Int(Date().timeIntervalSince1970)).jpg",
                mime: mime,
                size: outData.count
            )
            let resp: NewsUploadUrlResponse = try await APIClient.shared.request(
                "POST", "files/upload-url", body: req
            )
            guard let putURL = URL(string: resp.uploadUrl) else { return }
            var putReq = URLRequest(url: putURL)
            putReq.httpMethod = "PUT"
            putReq.setValue(mime, forHTTPHeaderField: "Content-Type")
            let (_, response) = try await URLSession.shared.upload(for: putReq, from: outData)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                self.lastError = "Загрузка обложки не удалась (\(http.statusCode))"
                return
            }
            self.coverUrl = resp.fileUrl
        } catch {
            self.lastError = apiUserMessage(error)
        }
    }
}

private struct NewsUploadUrlRequest: Encodable {
    let kind: String
    let filename: String
    let mime: String
    let size: Int
}

private struct NewsUploadUrlResponse: Decodable {
    let uploadUrl: String
    let fileId: String?
    let storageKey: String?
    let fileUrl: String
}
