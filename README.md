# Ритм — iOS-клиент корпоративной платформы 

Нативный SwiftUI-клиент для корпоративного портала Ритм.
Backend — общий с веб-версией: `https://rossihelp.ru/api/v1`.

## Стек
- **Swift 5.9 / SwiftUI**, минимальная версия iOS 16
- Зависимости через SwiftPackageManager (`Socket.IO`)
- Project-файл генерируется через [xcodegen](https://github.com/yonaskolb/XcodeGen) из `project.yml`

## Установить зависимости

```bash
brew install xcodegen
```

## Сборка проекта в Xcode

```bash
cd apps/ios
xcodegen generate
open Rossi.xcodeproj
```

## Сборка неподписанного `.ipa` из терминала

```bash
cd apps/ios && \
xcodegen generate && \
rm -rf build && \
xcodebuild -scheme Rossi -configuration Release -sdk iphoneos \
  -derivedDataPath build -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM="" build && \
mkdir -p dist build/Payload && \
rm -rf build/Payload/Rossi.app dist/Rossi-unsigned.ipa && \
cp -R build/Build/Products/Release-iphoneos/Rossi.app build/Payload/ && \
(cd build && zip -qry ../dist/Rossi-unsigned.ipa Payload) && \
ls -lh dist/Rossi-unsigned.ipa
```

Готовый `.ipa` появится в `apps/ios/dist/Rossi-unsigned.ipa`.
Установить можно через Xcode → Window → Devices, AltStore, sideloadly или Apple Configurator 2.

## Структура

```
Rossi/
├── RossiApp.swift              — точка входа (App + RootView)
├── Models/                     — DTO для backend ответов
├── Networking/
│   ├── APIClient.swift         — HTTP-клиент, JWT auto-refresh
│   ├── DemoMode.swift          — оффлайновый демо-режим (синтетика)
│   └── Keychain.swift
├── Services/
│   ├── AuthStore.swift         — состояние авторизации
│   ├── CallManager.swift       — звонки (WebRTC + Socket.IO)
│   ├── CacheManager.swift      — управление URLCache
│   ├── ChatRealtime.swift      — Socket.IO для чата
│   └── AppDelegate.swift       — APNs push
├── Views/                      — экраны (~70 SwiftUI views)
├── Calls/                      — UI звонков
└── Resources/                  — Info.plist, Assets.xcassets
```

## Ключевые экраны
- `MainTabView` — кастомный плавающий tab-bar (5 табов, как в мобильном вебе)
- `DashboardView` — главная (новости, задачи, команда, дни рождения, статистика)
- `NewsListView` / `NewsDetailView` — лента и детали новости с реакциями/комментариями
- `AIChatView` — Ритм AI (стримминг)
- `ChatsListView` / `ChatDetailView` — чаты (DM/группы), Saved Messages, голосовые, медиа, опросы, звонки
- `MoreScreen` — раздел «Ещё» (статус-picker, разделы)
- `AdminHubView` — админ-панель (роли, пользователи, модерация Rossi, аналитика, здоровье)
