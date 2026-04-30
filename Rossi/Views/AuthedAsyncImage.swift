//
//  AuthedAsyncImage.swift — AsyncImage с автоматической авто-подстановкой
//  access_token в query (наш JwtAuthGuard поддерживает `?access_token=`,
//  см. apps/api/src/common/guards/jwt-auth.guard.ts).
//
//  Используем для картинок из защищённых /admin/*/media/* endpoint'ов —
//  обычный AsyncImage не умеет в Authorization header.
//

import SwiftUI

/// Готовый URL с уже подставленным токеном.
struct AuthedAsyncImage<Content: View, Placeholder: View>: View {
    let path: String                // относительный путь, e.g. "admin/users/media/photos/abc"
    let content: (Image) -> Content
    let placeholder: () -> Placeholder

    @State private var resolvedURL: URL?

    init(path: String,
         @ViewBuilder content: @escaping (Image) -> Content,
         @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.path = path
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let url = resolvedURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): content(img)
                    case .empty:            placeholder()
                    case .failure:          placeholder()
                    @unknown default:       placeholder()
                    }
                }
            } else {
                placeholder()
            }
        }
        .task { await resolve() }
    }

    private func resolve() async {
        let token = await APIClient.shared.currentAccessToken() ?? ""
        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard var components = URLComponents(string: "https://rossihelp.ru/api/v1/\(cleanPath)") else { return }
        var items = components.queryItems ?? []
        if !token.isEmpty { items.append(URLQueryItem(name: "access_token", value: token)) }
        components.queryItems = items
        self.resolvedURL = components.url
    }
}
