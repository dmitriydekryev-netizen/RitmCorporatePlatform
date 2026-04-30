//
//  CacheManager.swift — единая точка управления кешем приложения.
//
//  Что кешируется:
//   • URLCache (memory + disk) для AsyncImage и любых GET-запросов через URLSession
//   • UserDefaults — пользовательские настройки (НЕ чистим без явного запроса)
//   • Keychain — токены (НЕ чистим — это logout)
//   • FileManager.default.temporaryDirectory — временные файлы (загрузки/превью)
//   • cachesDirectory — наш собственный disk-кеш для медиа из защищённых endpoint'ов
//
//  Используется в SettingsView → секция «Кеш»: показ размера, очистка
//  по категориям (как в Telegram).
//

import Foundation
import UIKit

@MainActor
final class CacheManager: ObservableObject {
    static let shared = CacheManager()

    /// Размер каждого вида кеша (байты), пересчитывается через `refresh()`.
    @Published private(set) var imagesSize: Int64 = 0
    @Published private(set) var apiResponsesSize: Int64 = 0
    @Published private(set) var temporarySize: Int64 = 0
    @Published private(set) var totalSize: Int64 = 0
    @Published private(set) var refreshing: Bool = false

    private init() {
        // Конфигурируем общий URLCache: 64 МБ в памяти, 256 МБ на диске.
        // Этот же URLCache используется AsyncImage внутри SwiftUI.
        let cache = URLCache(
            memoryCapacity: 64 * 1024 * 1024,
            diskCapacity: 256 * 1024 * 1024,
            diskPath: "rossi-shared-cache"
        )
        URLCache.shared = cache
    }

    // MARK: - Refresh sizes

    func refresh() async {
        refreshing = true
        defer { refreshing = false }

        let images = sizeOfURLCache()                                   // disk + memory of URLCache
        let api = sizeOfDirectory(at: cachesDirectory(named: "api"))    // optional response cache dir
        let tmp = sizeOfDirectory(at: FileManager.default.temporaryDirectory)

        self.imagesSize = images
        self.apiResponsesSize = api
        self.temporarySize = tmp
        self.totalSize = images + api + tmp
    }

    // MARK: - Clear

    /// Полная очистка всего, что мы можем чистить.
    func clearAll() async {
        clearImagesAndApi()
        clearTemporary()
        await refresh()
    }

    func clearImages() async {
        URLCache.shared.removeAllCachedResponses()
        await refresh()
    }

    func clearApiResponses() async {
        try? FileManager.default.removeItem(at: cachesDirectory(named: "api"))
        await refresh()
    }

    func clearTemporary() {
        let tmp = FileManager.default.temporaryDirectory
        if let items = try? FileManager.default.contentsOfDirectory(atPath: tmp.path) {
            for it in items {
                try? FileManager.default.removeItem(atPath: tmp.appendingPathComponent(it).path)
            }
        }
    }

    private func clearImagesAndApi() {
        URLCache.shared.removeAllCachedResponses()
        try? FileManager.default.removeItem(at: cachesDirectory(named: "api"))
    }

    // MARK: - Helpers

    private func sizeOfURLCache() -> Int64 {
        Int64(URLCache.shared.currentDiskUsage + URLCache.shared.currentMemoryUsage)
    }

    private func cachesDirectory(named name: String) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(name, isDirectory: true)
    }

    private func sizeOfDirectory(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
            options: .skipsHiddenFiles
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let v = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
               let size = v.totalFileAllocatedSize {
                total += Int64(size)
            }
        }
        return total
    }

    // MARK: - Formatting

    static func format(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}
