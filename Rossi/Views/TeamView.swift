//
//  TeamView.swift — список сотрудников.
//  GET /team?limit=200
//
//  Дизайн: DS-примитивы из Theme.swift, зеркальный с web (Next.js + Tailwind).
//

import SwiftUI

struct TeamView: View {
    @State private var members: [TeamMember] = []
    @State private var departments: [Department] = []
    @State private var total: Int = 0
    @State private var loading = true
    @State private var search = ""
    @State private var debouncedSearch = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var selectedDepartmentId = ""
    @State private var selectedRole: String? = nil
    @State private var error: String?

    /// Уникальные роли из текущей выборки (берём первую роль через member.roles?.first?.name).
    private var availableRoles: [String] {
        var set = Set<String>()
        for m in members {
            if let r = m.roles?.first?.name, !r.isEmpty {
                set.insert(r)
            }
        }
        return set.sorted()
    }

    var filtered: [TeamMember] {
        guard let role = selectedRole, !role.isEmpty else { return members }
        return members.filter { ($0.roles?.first?.name ?? "") == role }
    }

    var body: some View {
        ZStack {
            Theme.pageBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    DSPageTitle(text: "Команда", subtitle: subtitleText)
                    departmentFilter
                    roleFilterMenu
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)

                content
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Поиск по имени или должности")
        .onChange(of: search) { value in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run { debouncedSearch = value }
                await load()
            }
        }
        .refreshable { await load() }
        .task {
            if departments.isEmpty { await loadDepartments() }
            if members.isEmpty { await load() }
        }
    }

    private var subtitleText: String? {
        if total == 0 && members.isEmpty { return nil }
        if !debouncedSearch.isEmpty || !selectedDepartmentId.isEmpty || selectedRole != nil {
            return "Найдено: \(filtered.count) из \(total)"
        }
        return "Сотрудников: \(total)"
    }

    @ViewBuilder
    private var departmentFilter: some View {
        if !departments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    TeamFilterChip(title: "Все", isActive: selectedDepartmentId.isEmpty) {
                        selectedDepartmentId = ""
                        Task { await load() }
                    }
                    ForEach(departments, id: \.id) { dep in
                        TeamFilterChip(title: dep.name, isActive: selectedDepartmentId == dep.id) {
                            selectedDepartmentId = selectedDepartmentId == dep.id ? "" : dep.id
                            Task { await load() }
                        }
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private var roleFilterMenu: some View {
        if !availableRoles.isEmpty {
            Menu {
                Button {
                    selectedRole = nil
                } label: {
                    if selectedRole == nil {
                        Label("Все роли", systemImage: "checkmark")
                    } else {
                        Text("Все роли")
                    }
                }
                ForEach(availableRoles, id: \.self) { role in
                    Button {
                        selectedRole = role
                    } label: {
                        if selectedRole == role {
                            Label(role, systemImage: "checkmark")
                        } else {
                            Text(role)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.text.rectangle")
                        .font(.system(size: 12, weight: .semibold))
                    Text(selectedRole ?? "Все роли")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundColor(selectedRole == nil ? Theme.accent : .white)
                .background(
                    Capsule().fill(
                        selectedRole == nil
                            ? Theme.accent.opacity(0.12)
                            : Theme.accent
                    )
                )
            }
            .buttonStyle(DSPressScaleStyle())
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading && members.isEmpty {
            ProgressView().tint(Theme.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filtered.isEmpty && (!debouncedSearch.isEmpty || !selectedDepartmentId.isEmpty || selectedRole != nil) {
            EmptyStateView(
                icon: "magnifyingglass",
                title: "Никого не найдено",
                description: "Попробуйте уточнить запрос или фильтр"
            )
        } else if members.isEmpty {
            EmptyStateView(
                icon: "person.3",
                title: "Команда пуста",
                description: error ?? "Здесь будет список сотрудников"
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(filtered) { member in
                        NavigationLink {
                            TeamMemberProfileView(member: member)
                        } label: {
                            TeamMemberCard(member: member)
                        }
                        .buttonStyle(.plain)
                    }
                    Color.clear.frame(height: TabBarVisibility.reservedHeight)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }

    private func loadDepartments() async {
        do {
            let list: [Department] = try await APIClient.shared.get("team/departments")
            self.departments = list
        } catch {
            // Фильтр не критичен — список команды загрузится без него.
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            var query: [String: String] = ["limit": "60"]
            let q = debouncedSearch.trimmingCharacters(in: .whitespacesAndNewlines)
            if !q.isEmpty { query["search"] = q }
            if !selectedDepartmentId.isEmpty { query["departmentId"] = selectedDepartmentId }
            let resp: TeamListResponse = try await APIClient.shared.get("team", query: query)
            self.members = resp.data
            self.total = resp.meta?.total ?? resp.data.count
            self.error = nil
        } catch {
            self.error = apiUserMessage(error)
        }
    }
}

private struct TeamFilterChip: View {
    let title: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundColor(isActive ? .white : Theme.accent)
                .background(Capsule().fill(isActive ? Theme.accent : Theme.accent.opacity(0.12)))
        }
        .buttonStyle(DSPressScaleStyle())
    }
}

private struct TeamMemberCard: View {
    let member: TeamMember

    private var displayName: String {
        "\(member.firstName ?? "") \(member.lastName ?? "")"
            .trimmingCharacters(in: .whitespaces)
            .ifEmpty(or: member.username)
    }

    var body: some View {
        DSCard(radius: Radius.xl, padding: 12) {
            HStack(spacing: 12) {
                AvatarCircle(url: member.avatarUrl, name: displayName)
                    .frame(width: 50, height: 50)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(displayName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                        if member.presenceStatus == "online" {
                            Circle().fill(Theme.success).frame(width: 7, height: 7)
                        }
                    }
                    if let pos = member.position, !pos.isEmpty {
                        Text(pos)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        if let dep = member.department?.name, !dep.isEmpty {
                            Text(dep)
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textTertiary)
                                .lineLimit(1)
                        }
                        if let role = member.roles?.first?.name, !role.isEmpty {
                            Text("· \(role)")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textTertiary)
            }
        }
    }
}

// Color extension to support .tertiary literal
extension Color {
    static var tertiary: Color { Color(uiColor: .tertiaryLabel) }
}

// MARK: - Avatar

struct AvatarCircle: View {
    let url: String?
    let name: String

    var initials: String {
        let parts = name.split(separator: " ").compactMap { $0.first.map(String.init) }
        return parts.prefix(2).joined().uppercased()
    }

    var body: some View {
        ZStack {
            if let urlStr = url, let u = URL(string: ensureAbsolute(urlStr)) {
                AsyncImage(url: u) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: gradientFallback
                    }
                }
            } else {
                gradientFallback
            }
        }
        .clipShape(Circle())
    }

    private var gradientFallback: some View {
        ZStack {
            LinearGradient(colors: [Theme.accent, Theme.purple],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(initials.isEmpty ? "?" : initials)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
        }
    }
}

#Preview {
    NavigationStack { TeamView() }
}
