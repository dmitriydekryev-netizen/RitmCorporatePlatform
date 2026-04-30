//
//  EditProfileSheet.swift — модалка редактирования профиля.
//
//  Endpoints:
//    GET   /profiles/me              — full profile DTO (для bootstrap полей)
//    PATCH /profiles/me              — обновление полей
//    POST  /files/upload-url         — presigned S3 URL для аватарки
//    PUT   <uploadUrl>               — заливаем JPEG напрямую на S3
//
//  Flow аватарки:
//   1) PhotosPicker → PhotosPickerItem → Data (JPEG)
//   2) POST /files/upload-url {kind:"avatar", filename, mime, size} → {uploadUrl, fileUrl}
//   3) PUT data на uploadUrl с Content-Type: image/jpeg (через URLSession, не APIClient)
//   4) avatarUrl = fileUrl, шлём в PATCH вместе с остальным.
//

import SwiftUI
import PhotosUI
import UIKit

// MARK: - DTOs

private struct FilesUploadUrlRequest: Encodable {
    let kind: String
    let filename: String
    let mime: String
    let size: Int
}

private struct FilesUploadUrlResponse: Decodable {
    let uploadUrl: String
    let fileId: String?
    let storageKey: String?
    let fileUrl: String
}

/// PATCH /profiles/me — все поля опциональны (PATCH-семантика).
private struct ProfileUpdateRequest: Encodable {
    var firstName: String?
    var lastName: String?
    var position: String?
    var bio: String?
    var phone: String?
    var telegram: String?
    var avatarUrl: String?
    var departmentId: String?
    /// ISO-8601 date string (yyyy-MM-dd)
    var birthDate: String?
    var skills: [String]?
    var interests: [String]?
}

// MARK: - View

struct EditProfileSheet: View {
    @EnvironmentObject var auth: AuthStore
    @Environment(\.dismiss) private var dismiss

    // Form state
    @State private var firstName: String = ""
    @State private var lastName: String = ""
    @State private var position: String = ""
    @State private var bio: String = ""
    @State private var phone: String = ""
    @State private var telegram: String = ""
    @State private var avatarUrl: String? = nil

    @State private var hasBirthDate: Bool = false
    @State private var birthDate: Date = Date()

    // Skills & Interests
    @State private var skills: [String] = []
    @State private var newSkill: String = ""
    @State private var interests: [String] = []
    @State private var newInterest: String = ""

    // Полная hydration происходит из GET /profiles/me — там все нужные поля
    // (auth.currentUser.profile содержит только сокращённую версию).
    @State private var hydrated = false
    @State private var loadingProfile = false

    // Avatar picker state
    @State private var pickerItem: PhotosPickerItem?
    @State private var uploadingAvatar = false

    // Save state
    @State private var saving = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Avatar hero
                    DSCard(radius: Radius.xl2, padding: 18) {
                        HStack(spacing: 16) {
                            ZStack(alignment: .bottomTrailing) {
                                AvatarCircle(
                                    url: avatarUrl,
                                    name: "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)
                                )
                                .frame(width: 84, height: 84)
                                .overlay(
                                    Circle().strokeBorder(Theme.border, lineWidth: 0.5)
                                )
                                if uploadingAvatar {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .padding(6)
                                        .background(Theme.surfaceBackground)
                                        .clipShape(Circle())
                                        .shadow(color: .black.opacity(0.1), radius: 3)
                                }
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Фото профиля")
                                    .font(.dsBodySM.weight(.semibold))
                                    .foregroundColor(Theme.textPrimary)
                                Text("Видно коллегам в чате, новостях и команде")
                                    .font(.dsCaption)
                                    .foregroundColor(Theme.textTertiary)
                                PhotosPicker(
                                    selection: $pickerItem,
                                    matching: .images,
                                    photoLibrary: .shared()
                                ) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "camera.fill")
                                            .font(.system(size: 11, weight: .bold))
                                        Text("Сменить")
                                            .font(.dsCaption.weight(.semibold))
                                    }
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(Theme.accent)
                                    .clipShape(Capsule())
                                }
                                .disabled(uploadingAvatar || saving)
                            }
                            Spacer(minLength: 0)
                        }
                    }

                    // Имя
                    fieldsGroup(title: "Имя") {
                        textField("Имя", text: $firstName, icon: "person.fill", color: Theme.accent, content: .givenName)
                        Divider().background(Theme.separator).padding(.leading, 56)
                        textField("Фамилия", text: $lastName, icon: "person.fill", color: Theme.accent, content: .familyName)
                    }

                    // Должность
                    fieldsGroup(title: "Должность") {
                        textField("Senior Engineer", text: $position, icon: "briefcase.fill", color: Theme.indigo, content: .jobTitle)
                    }

                    // О себе
                    VStack(alignment: .leading, spacing: 8) {
                        DSSectionHeader("О себе")
                        DSCard(radius: Radius.xl, padding: 14) {
                            TextField("Расскажите о себе", text: $bio, axis: .vertical)
                                .lineLimit(3...8)
                                .font(.dsBody)
                                .foregroundColor(Theme.textPrimary)
                        }
                    }

                    // Контакты
                    fieldsGroup(title: "Контакты") {
                        textField("+7 (___) ___-__-__", text: $phone, icon: "phone.fill", color: Theme.success,
                                  keyboard: .phonePad, content: .telephoneNumber)
                        Divider().background(Theme.separator).padding(.leading, 56)
                        textField("@username", text: $telegram, icon: "paperplane.fill", color: Theme.indigo,
                                  autocap: false, autocorrect: false)
                    }

                    // Дата рождения
                    VStack(alignment: .leading, spacing: 8) {
                        DSSectionHeader("Дата рождения")
                        DSCard(radius: Radius.xl, padding: 14) {
                            VStack(alignment: .leading, spacing: 10) {
                                Toggle(isOn: $hasBirthDate) {
                                    HStack(spacing: 10) {
                                        DSIconTile(systemImage: "gift.fill", color: Theme.pink, size: 32)
                                        Text("Указать дату").font(.dsBody.weight(.medium)).foregroundColor(Theme.textPrimary)
                                    }
                                }.tint(Theme.accent)
                                if hasBirthDate {
                                    DatePicker(
                                        "",
                                        selection: $birthDate,
                                        in: ...Date(),
                                        displayedComponents: .date
                                    )
                                    .labelsHidden()
                                    .datePickerStyle(.compact)
                                    .padding(.horizontal, 4)
                                }
                            }
                        }
                    }

                    // Навыки
                    VStack(alignment: .leading, spacing: 8) {
                        DSSectionHeader("Навыки")
                        DSCard(radius: Radius.xl, padding: 14) {
                            chipEditor(
                                items: $skills,
                                draft: $newSkill,
                                placeholder: "Например, Swift",
                                background: Theme.accent.opacity(0.15),
                                foreground: Theme.accent
                            )
                        }
                    }

                    // Интересы
                    VStack(alignment: .leading, spacing: 8) {
                        DSSectionHeader("Интересы")
                        DSCard(radius: Radius.xl, padding: 14) {
                            chipEditor(
                                items: $interests,
                                draft: $newInterest,
                                placeholder: "Например, фотография",
                                background: Theme.purple.opacity(0.15),
                                foreground: Theme.purple
                            )
                        }
                    }

                    if let err = errorText {
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
            .navigationTitle("Редактирование")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                        .foregroundColor(Theme.textSecondary)
                        .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if saving {
                            ProgressView().tint(Theme.accent)
                        } else {
                            Text("Сохранить")
                                .font(.dsBody.weight(.semibold))
                                .foregroundColor(Theme.accent)
                        }
                    }
                    .disabled(saving || uploadingAvatar)
                }
            }
            .task {
                if !hydrated { await hydrateFromServer() }
            }
            .onChange(of: pickerItem) { newItem in
                guard let newItem else { return }
                Task { await uploadAvatar(item: newItem) }
            }
        }
    }

    @ViewBuilder
    private func fieldsGroup<Content: View>(title: String, @ViewBuilder _ content: @escaping () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DSSectionHeader(title)
            DSCard(radius: Radius.xl, padding: 0) {
                VStack(spacing: 0) {
                    content()
                }
            }
        }
    }

    @ViewBuilder
    private func textField(_ placeholder: String, text: Binding<String>, icon: String, color: Color,
                           keyboard: UIKeyboardType = .default,
                           content: UITextContentType? = nil,
                           autocap: Bool = true,
                           autocorrect: Bool = true) -> some View {
        HStack(spacing: 10) {
            DSIconTile(systemImage: icon, color: color, size: 32)
            TextField(placeholder, text: text)
                .font(.dsBody)
                .foregroundColor(Theme.textPrimary)
                .keyboardType(keyboard)
                .textContentType(content)
                .textInputAutocapitalization(autocap ? .sentences : .never)
                .autocorrectionDisabled(!autocorrect)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    // MARK: - Chip editor (для skills и interests)

    @ViewBuilder
    private func chipEditor(
        items: Binding<[String]>,
        draft: Binding<String>,
        placeholder: String,
        background: Color,
        foreground: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !items.wrappedValue.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(Array(items.wrappedValue.enumerated()), id: \.offset) { idx, value in
                        HStack(spacing: 6) {
                            Text(value)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(foreground)
                            Button {
                                var copy = items.wrappedValue
                                guard idx < copy.count else { return }
                                copy.remove(at: idx)
                                items.wrappedValue = copy
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(foreground.opacity(0.8))
                                    .padding(3)
                                    .background(Circle().fill(foreground.opacity(0.15)))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(background))
                    }
                }
            }
            HStack(spacing: 8) {
                TextField(placeholder, text: draft)
                    .font(.dsBody)
                    .foregroundColor(Theme.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .onSubmit { addChip(items: items, draft: draft) }
                Button {
                    addChip(items: items, draft: draft)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Theme.accent))
                }
                .buttonStyle(DSPressScaleStyle())
                .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func addChip(items: Binding<[String]>, draft: Binding<String>) {
        let trimmed = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var copy = items.wrappedValue
        if !copy.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            copy.append(trimmed)
            items.wrappedValue = copy
        }
        draft.wrappedValue = ""
    }

    // MARK: - Hydrate from /profiles/me (full DTO)

    /// AuthStore.currentUser.profile содержит только базовый набор
    /// (firstName/lastName/position/avatarUrl/departmentId), а bio/phone/telegram/birthDate
    /// возвращает только GET /profiles/me. Поэтому подтягиваем оттуда.
    private func hydrateFromServer() async {
        loadingProfile = true
        defer { loadingProfile = false; hydrated = true }
        do {
            let p: PublicProfile = try await APIClient.shared.get("profiles/me")
            firstName = p.firstName ?? ""
            lastName = p.lastName ?? ""
            position = p.position ?? ""
            bio = p.bio ?? ""
            phone = p.phone ?? ""
            telegram = p.telegram ?? ""
            avatarUrl = p.avatarUrl
            if let bd = p.birthDate, let parsed = ISO8601DateFormatter().date(from: bd) {
                birthDate = parsed
                hasBirthDate = true
            }
            skills = p.skills ?? []
            interests = p.interests ?? []
        } catch {
            // Fallback на auth.currentUser.profile, если /profiles/me упал
            if let user = auth.currentUser {
                firstName = user.profile?.firstName ?? ""
                lastName = user.profile?.lastName ?? ""
                position = user.profile?.position ?? ""
                avatarUrl = user.profile?.avatarUrl
            }
            errorText = apiUserMessage(error)
        }
    }

    // MARK: - Avatar upload

    private func uploadAvatar(item: PhotosPickerItem) async {
        uploadingAvatar = true
        errorText = nil
        defer { uploadingAvatar = false }

        do {
            // 1) Получаем Data из PhotosPickerItem
            guard let raw = try await item.loadTransferable(type: Data.self) else {
                errorText = "Не удалось прочитать выбранное изображение"
                return
            }

            // Конвертируем в JPEG (если PNG/HEIC) для стабильного Content-Type.
            let jpegData: Data
            if let img = UIImage(data: raw), let j = img.jpegData(compressionQuality: 0.85) {
                jpegData = j
            } else {
                jpegData = raw
            }

            // 2) POST /files/upload-url → presigned S3
            let req = FilesUploadUrlRequest(
                kind: "avatar",
                filename: "avatar.jpg",
                mime: "image/jpeg",
                size: jpegData.count
            )
            let resp: FilesUploadUrlResponse = try await APIClient.shared.request(
                "POST", "files/upload-url",
                body: req
            )

            // 3) PUT на presigned URL — простым URLSession, не APIClient.
            guard let putURL = URL(string: resp.uploadUrl) else {
                errorText = "Некорректный uploadUrl"
                return
            }
            var putReq = URLRequest(url: putURL)
            putReq.httpMethod = "PUT"
            putReq.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
            let (_, response) = try await URLSession.shared.upload(for: putReq, from: jpegData)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                errorText = "S3 PUT не удался (\(http.statusCode))"
                return
            }

            // 4) Сохраняем fileUrl в state — отправим в PATCH /profiles/me при сохранении.
            avatarUrl = resp.fileUrl
        } catch let e as APIError {
            errorText = e.errorDescription
        } catch {
            errorText = error.localizedDescription
        }
    }

    // MARK: - Save (PATCH /profiles/me)

    private func save() async {
        saving = true
        errorText = nil
        defer { saving = false }

        var body = ProfileUpdateRequest()
        body.firstName = firstName.isEmpty ? nil : firstName
        body.lastName = lastName.isEmpty ? nil : lastName
        body.position = position.isEmpty ? nil : position
        body.bio = bio.isEmpty ? nil : bio
        body.phone = phone.isEmpty ? nil : phone
        body.telegram = telegram.isEmpty ? nil : telegram
        body.avatarUrl = avatarUrl
        if hasBirthDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            body.birthDate = formatter.string(from: birthDate)
        }
        body.skills = skills
        body.interests = interests

        do {
            _ = try await APIClient.shared.rawRequest("PATCH", "profiles/me", body: body)
            // После успеха — перечитываем /auth/me и закрываем sheet.
            await auth.bootstrap()
            dismiss()
        } catch let e as APIError {
            errorText = e.errorDescription
        } catch {
            errorText = error.localizedDescription
        }
    }
}

#Preview {
    EditProfileSheet()
        .environmentObject(AuthStore())
}
