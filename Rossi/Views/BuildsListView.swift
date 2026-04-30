//
//  BuildsListView.swift — список сборок приложения (TestFlight-style).
//
//  Endpoints:
//   • GET  /builds                       — список сборок
//        query: ?platform=ios|android|web|desktop  ?published=true|false
//        response: { data: [Build] }
//   • GET  /builds/:id                   — детальный
//
//  iOS 16+, без iOS 17 API. Русский UI.
//

import SwiftUI
import CoreImage.CIFilterBuiltins
import UIKit

// MARK: - Models

struct BuildItem: Codable, Identifiable {
    let id: String
    let platform: String?            // ios | android | web | desktop
    let version: String
    let buildNumber: String?
    let title: String?
    let changelog: String?
    let notes: String?
    let fileUrl: String?
    let fileName: String?
    let fileSize: Int?
    let externalUrl: String?
    let minOsVersion: String?
    let isPublished: Bool?
    let publishedAt: String?
    let createdAt: String?
    let updatedAt: String?
    let createdBy: BuildAuthor?

    /// Ссылка для установки/скачивания. Предпочитаем внешний URL
    /// (TestFlight / Diawi / прямой .ipa-ссылку), иначе — fileUrl.
    var downloadUrl: String? {
        if let s = externalUrl, !s.isEmpty { return s }
        if let s = fileUrl,     !s.isEmpty { return s }
        return nil
    }
}

struct BuildAuthor: Codable {
    let id: String
    let username: String?
    let firstName: String?
    let lastName: String?
    let avatarUrl: String?

    var displayName: String {
        let s = "\(firstName ?? "") \(lastName ?? "")".trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? (username ?? "?") : s
    }
}

struct BuildsListResponse: Codable {
    let data: [BuildItem]
}

// MARK: - Helpers

private let buildPlatformIcon: [String: String] = [
    "ios":     "applelogo",
    "android": "candybarphone",
    "web":     "globe",
    "desktop": "desktopcomputer",
]
private let buildPlatformLabel: [String: String] = [
    "ios":     "iOS",
    "android": "Android",
    "web":     "Web",
    "desktop": "Desktop",
]

private func parseISO(_ s: String?) -> Date? {
    guard let s = s, !s.isEmpty else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    let g = ISO8601DateFormatter()
    g.formatOptions = [.withInternetDateTime]
    return g.date(from: s)
}

private func formatBytes(_ bytes: Int) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f.string(fromByteCount: Int64(bytes))
}

// MARK: - List

struct BuildsListView: View {
    enum PlatformFilter: String, CaseIterable, Identifiable {
        case all, ios, android
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all:     return "Все"
            case .ios:     return "iOS"
            case .android: return "Android"
            }
        }
        var apiValue: String? {
            switch self {
            case .all:     return nil
            case .ios:     return "ios"
            case .android: return "android"
            }
        }
    }

    enum StatusFilter: String, CaseIterable, Identifiable {
        case all, published, draft
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all:       return "Все"
            case .published: return "Опубликован"
            case .draft:     return "Черновик"
            }
        }
        var icon: String {
            switch self {
            case .all:       return "tray.full"
            case .published: return "checkmark.seal.fill"
            case .draft:     return "tray"
            }
        }
        var color: Color {
            switch self {
            case .all:       return Theme.textSecondary
            case .published: return Theme.success
            case .draft:     return Theme.textTertiary
            }
        }
    }

    @State private var builds: [BuildItem] = []
    @State private var loading = true
    @State private var error: String?
    @State private var platform: PlatformFilter = .all
    @State private var status: StatusFilter = .all

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                DSPageTitle(text: "Сборки", subtitle: "Свежие версии приложения")
                platformPicker
                statusChips
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(Theme.pageBackground)

            Group {
                if loading && builds.isEmpty {
                    ProgressView().tint(Theme.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if builds.isEmpty {
                    EmptyStateView(
                        icon: "shippingbox",
                        title: "Сборок пока нет",
                        description: error ?? "Когда команда выложит новую сборку — она появится здесь"
                    )
                } else if filtered.isEmpty {
                    EmptyStateView(
                        icon: status == .published ? "checkmark.seal" : "tray",
                        title: status == .published ? "Нет опубликованных" : "Нет черновиков",
                        description: "Попробуйте сменить фильтр статуса"
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(filtered) { b in
                                NavigationLink {
                                    BuildDetailView(id: b.id, initial: b)
                                } label: {
                                    BuildRow(build: b)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                }
            }
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { if builds.isEmpty { await load() } }
    }

    private var platformPicker: some View {
        Picker("Платформа", selection: $platform) {
            ForEach(PlatformFilter.allCases) { p in
                Text(p.title).tag(p)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: platform) { _ in
            Task { await load() }
        }
    }

    private var statusChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(StatusFilter.allCases) { s in
                    Button {
                        status = s
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: s.icon)
                                .font(.system(size: 11, weight: .semibold))
                            Text(s.title)
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .foregroundColor(status == s ? .white : s.color)
                        .background(
                            Capsule().fill(status == s ? s.color : s.color.opacity(0.12))
                        )
                    }
                    .buttonStyle(DSPressScaleStyle())
                }
            }
        }
    }

    private var filtered: [BuildItem] {
        // Локальная фильтрация по статусу; платформа идёт на бэк через query.
        switch status {
        case .all:       return builds
        case .published: return builds.filter { $0.isPublished == true }
        case .draft:     return builds.filter { $0.isPublished != true }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        var q: [String: String] = [:]
        if let p = platform.apiValue { q["platform"] = p }
        do {
            let resp: BuildsListResponse = try await APIClient.shared.get("builds", query: q)
            self.builds = resp.data
            self.error = nil
        } catch {
            self.builds = []
            self.error = apiUserMessage(error)
        }
    }
}

// MARK: - Row

private struct BuildRow: View {
    let build: BuildItem

    private var platformColor: Color {
        switch build.platform {
        case "ios":     return Theme.accent
        case "android": return Theme.success
        case "web":     return Theme.info
        case "desktop": return Theme.purple
        default:        return Theme.textSecondary
        }
    }

    private var platformIcon: String {
        if let p = build.platform, let icon = buildPlatformIcon[p] { return icon }
        return "shippingbox"
    }

    var body: some View {
        DSCard(radius: Radius.lg, padding: 14) {
            HStack(alignment: .top, spacing: 12) {
                DSIconTile(systemImage: platformIcon, color: platformColor, size: 44)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(build.version)
                            .font(.system(size: 17, weight: .semibold, design: .monospaced))
                            .foregroundColor(Theme.textPrimary)
                        if let bn = build.buildNumber, !bn.isEmpty {
                            DSBadge(text: bn, color: Theme.textSecondary)
                        }
                        Spacer(minLength: 4)
                        publishedBadge
                    }

                    if let title = build.title, !title.isEmpty {
                        Text(title)
                            .font(.dsBodySM.weight(.semibold))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(2)
                    }

                    if let summary = build.changelog ?? build.notes, !summary.isEmpty {
                        Text(summary)
                            .font(.dsCaption)
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(2)
                    }

                    HStack(spacing: 8) {
                        if let p = build.platform, let label = buildPlatformLabel[p] {
                            DSBadge(text: label, color: platformColor)
                        }
                        if let date = parseISO(build.publishedAt ?? build.createdAt) {
                            HStack(spacing: 4) {
                                Image(systemName: "clock")
                                    .font(.system(size: 10))
                                Text(relativeTime(from: date))
                                    .font(.system(size: 11))
                            }
                            .foregroundColor(Theme.textTertiary)
                        }
                        Spacer()
                        if let author = build.createdBy {
                            AvatarCircle(url: author.avatarUrl, name: author.displayName)
                                .frame(width: 22, height: 22)
                        }
                    }

                    if let urlStr = build.downloadUrl, let url = URL(string: urlStr) {
                        Link(destination: url) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.down.circle.fill")
                                Text("Установить")
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .background(
                                LinearGradient(
                                    colors: [Theme.accent, Theme.purple, Theme.pink],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                            )
                            .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                            .shadow(color: Theme.accent.opacity(0.3), radius: 10, x: 0, y: 3)
                        }
                        .buttonStyle(DSPressScaleStyle())
                        .padding(.top, 4)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var publishedBadge: some View {
        if build.isPublished == true {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 12))
                .foregroundColor(Theme.success)
        } else {
            Image(systemName: "tray")
                .font(.system(size: 12))
                .foregroundColor(Theme.textTertiary)
        }
    }
}

// MARK: - Detail

struct BuildDetailView: View {
    let id: String
    let initial: BuildItem

    @State private var build: BuildItem?
    @State private var loading = true
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        let b = build ?? initial
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerCard(b)

                if let changelog = (b.changelog ?? "").isEmpty ? nil : b.changelog {
                    sectionCard(title: "Список изменений", icon: "list.bullet.rectangle") {
                        Text(changelog)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let notes = b.notes, !notes.isEmpty {
                    sectionCard(title: "Заметки", icon: "note.text") {
                        Text(notes)
                            .font(.body)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                metaCard(b)

                if let urlStr = b.downloadUrl, let url = URL(string: urlStr) {
                    actionsCard(downloadURL: url, raw: urlStr)
                    qrCard(urlStr: urlStr)
                } else {
                    sectionCard(title: "Установка", icon: "exclamationmark.triangle") {
                        Text("Ссылка на установку пока не загружена. Спросите у автора сборки.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let err = error {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(Theme.danger)
                        .padding(.horizontal, 16)
                }
            }
            .padding(16)
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle(b.version)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: Sections

    @ViewBuilder
    private func headerCard(_ b: BuildItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if let p = b.platform, let icon = buildPlatformIcon[p] {
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundColor(Theme.accent)
                }
                Text(b.version)
                    .font(.system(size: 34, weight: .bold))
                if let bn = b.buildNumber, !bn.isEmpty {
                    Text("(\(bn))")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            if let title = b.title, !title.isEmpty {
                Text(title).font(.headline)
            }
            HStack(spacing: 8) {
                if let p = b.platform, let label = buildPlatformLabel[p] {
                    Text(label)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Theme.accent.opacity(0.12))
                        .foregroundColor(Theme.accent)
                        .clipShape(Capsule())
                }
                if b.isPublished == true {
                    Label("Опубликована", systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Theme.success.opacity(0.15))
                        .foregroundColor(Theme.success)
                        .clipShape(Capsule())
                } else {
                    Label("Черновик", systemImage: "tray")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.15))
                        .foregroundColor(.secondary)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func metaCard(_ b: BuildItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Информация", systemImage: "info.circle")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            Divider()
            if let author = b.createdBy {
                HStack(spacing: 10) {
                    AvatarCircle(url: author.avatarUrl, name: author.displayName)
                        .frame(width: 28, height: 28)
                    Text("Автор")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(author.displayName)
                        .font(.subheadline.weight(.medium))
                }
            }
            if let date = parseISO(b.publishedAt) {
                metaRow(label: "Опубликовано", value: relativeTime(from: date))
            }
            if let date = parseISO(b.createdAt) {
                metaRow(label: "Создано", value: relativeTime(from: date))
            }
            if let v = b.minOsVersion, !v.isEmpty {
                metaRow(label: "Минимум ОС", value: v)
            }
            if let size = b.fileSize, size > 0 {
                metaRow(label: "Размер файла", value: formatBytes(size))
            }
            if let name = b.fileName, !name.isEmpty {
                metaRow(label: "Файл", value: name)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func metaRow(label: String, value: String) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.subheadline.weight(.medium))
                .multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder
    private func actionsCard(downloadURL: URL, raw: String) -> some View {
        VStack(spacing: 10) {
            Link(destination: downloadURL) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("Установить")
                }
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundColor(.white)
                .background(
                    LinearGradient(
                        colors: [Theme.accent, Theme.purple, Theme.pink],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .shadow(color: Theme.accent.opacity(0.35), radius: 14, x: 0, y: 4)
            }
            .buttonStyle(DSPressScaleStyle())

            DSSecondaryButton(action: {
                UIPasteboard.general.string = raw
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    copied = false
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    Text(copied ? "Скопировано" : "Скопировать ссылку")
                }
                .foregroundColor(Theme.accent)
            }
        }
    }

    @ViewBuilder
    private func qrCard(urlStr: String) -> some View {
        VStack(spacing: 12) {
            Label("QR для коллеги", systemImage: "qrcode")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let img = generateQRCode(from: urlStr) {
                Image(uiImage: img)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 200, height: 200)
                    .padding(8)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            Text("Покажите этот код коллеге, чтобы он установил сборку")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(Theme.surfaceBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func sectionCard<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            Divider()
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Loading

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let b: BuildItem = try await APIClient.shared.get("builds/\(id)")
            self.build = b
            self.error = nil
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}

// MARK: - QR-code generator

private func generateQRCode(from string: String) -> UIImage? {
    let context = CIContext()
    let filter = CIFilter.qrCodeGenerator()
    let data = Data(string.utf8)
    filter.setValue(data, forKey: "inputMessage")
    filter.correctionLevel = "M"
    guard let output = filter.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
    return UIImage(cgImage: cg)
}
