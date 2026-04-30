//
//  EmptyStateView.swift — fallback вместо ContentUnavailableView (iOS 17+)
//  для поддержки iOS 16. Та же роль: показать иконку + заголовок + описание.
//

import SwiftUI

struct EmptyStateView: View {
    let icon: String
    let title: String
    let description: String?

    init(icon: String, title: String, description: String? = nil) {
        self.icon = icon
        self.title = title
        self.description = description
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
            if let description {
                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 60)
    }
}
