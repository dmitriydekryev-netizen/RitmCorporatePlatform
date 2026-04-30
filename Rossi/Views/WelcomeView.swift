//
//  WelcomeView.swift — экран онбординга для первого запуска.
//
//  Показывается над основным UI пока @AppStorage("hasSeenWelcome") == false.
//  3-4 свайпабельных слайда (TabView(.page)), на последнем — DSPrimaryButton
//  «Начать», который выставляет hasSeenWelcome = true и закрывает экран.
//

import SwiftUI

// MARK: - Slide model

struct WelcomeSlide: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let description: String
    let gradient: [Color]
}

// MARK: - View

struct WelcomeView: View {
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome: Bool = false
    @State private var pageIndex: Int = 0

    private let slides: [WelcomeSlide] = [
        WelcomeSlide(
            icon: "sparkles",
            title: "Добро пожаловать в Ритм",
            description: "Корпоративная платформа Rossi для команды: новости, задачи, общение и достижения — в одном приложении.",
            gradient: [Theme.accent, Theme.purple]
        ),
        WelcomeSlide(
            icon: "bubble.left.and.bubble.right.fill",
            title: "Чат и совместная работа",
            description: "Личные и групповые чаты, реакции, файлы и общие пространства команд — общение становится проще.",
            gradient: [Theme.info, Theme.accent]
        ),
        WelcomeSlide(
            icon: "checklist",
            title: "Задачи и график",
            description: "Управляйте своими задачами, следите за расписанием рабочих смен и не пропускайте важные дедлайны.",
            gradient: [Theme.warning, Theme.pink]
        ),
        WelcomeSlide(
            icon: "trophy.fill",
            title: "Достижения и kudos",
            description: "Благодарите коллег, получайте награды и следите за прогрессом в системе мотивации.",
            gradient: [Theme.success, Theme.accent]
        )
    ]

    var body: some View {
        ZStack {
            Theme.pageBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Skip-кнопка справа сверху на всех слайдах кроме последнего
                HStack {
                    Spacer()
                    if pageIndex < slides.count - 1 {
                        Button {
                            withAnimation(.easeInOut) {
                                pageIndex = slides.count - 1
                            }
                        } label: {
                            Text("Пропустить")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .frame(height: 32)

                TabView(selection: $pageIndex) {
                    ForEach(Array(slides.enumerated()), id: \.element.id) { idx, slide in
                        slideView(slide)
                            .tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                // Кнопки внизу: «Далее» / «Начать»
                VStack(spacing: 12) {
                    if pageIndex == slides.count - 1 {
                        DSPrimaryButton(action: complete, gradient: true) {
                            Text("Начать")
                        }
                    } else {
                        DSPrimaryButton(action: {
                            withAnimation(.easeInOut) {
                                pageIndex += 1
                            }
                        }) {
                            Text("Далее")
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .padding(.top, 12)
            }
        }
    }

    @ViewBuilder
    private func slideView(_ slide: WelcomeSlide) -> some View {
        VStack(spacing: 24) {
            Spacer(minLength: 8)

            // Большая «liquid» иконка
            ZStack {
                LinearGradient(
                    colors: slide.gradient,
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .frame(width: 140, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
                .shadow(color: slide.gradient.first?.opacity(0.35) ?? .clear,
                        radius: 24, x: 0, y: 12)
                Image(systemName: slide.icon)
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundColor(.white)
            }

            VStack(spacing: 12) {
                Text(slide.title)
                    .font(.dsH1)
                    .foregroundColor(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Text(slide.description)
                    .font(.dsBody)
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }

            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func complete() {
        hasSeenWelcome = true
    }
}

#Preview {
    WelcomeView()
}
