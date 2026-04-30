#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  build-ipa.sh — собрать неподписанный .ipa из текущего состояния исходников.
#
#  Запуск из директории проекта:
#      cd apps/ios && bash build-ipa.sh
#
#  Что делает:
#   1. Перегенерирует Rossi.xcodeproj через xcodegen (подхватывает новые .swift)
#   2. Собирает Release-конфигурацию для iphoneos без code-signing
#   3. Упаковывает .app в Payload/ и зипует в Rossi-unsigned.ipa
#
#  Готовый ipa: apps/ios/dist/Rossi-unsigned.ipa
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[0;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $*"; }
info() { echo -e "${BLUE}[→]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

SCHEME="Rossi"
CONFIG="Release"
DERIVED="$SCRIPT_DIR/build"
DIST="$SCRIPT_DIR/dist"
IPA_NAME="Rossi-unsigned.ipa"

# ── 1. xcodegen ────────────────────────────────────────────────────────────
if ! command -v xcodegen >/dev/null 2>&1; then
  warn "xcodegen не установлен — ставлю через brew"
  brew install xcodegen
fi
info "Перегенерирую Rossi.xcodeproj…"
xcodegen generate

# ── 2. xcodebuild ──────────────────────────────────────────────────────────
info "Собираю $SCHEME ($CONFIG, iphoneos, без подписи)…"
rm -rf "$DERIVED"
mkdir -p "$DERIVED" "$DIST"

xcodebuild \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -sdk iphoneos \
  -derivedDataPath "$DERIVED" \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" \
  DEVELOPMENT_TEAM="" \
  ONLY_ACTIVE_ARCH=NO \
  build \
  | tee "$DERIVED/build.log" \
  | xcpretty 2>/dev/null || cat "$DERIVED/build.log" | tail -40

APP_PATH="$DERIVED/Build/Products/${CONFIG}-iphoneos/${SCHEME}.app"
if [ ! -d "$APP_PATH" ]; then
  echo "❌ .app не найден: $APP_PATH" >&2
  echo "   Проверьте $DERIVED/build.log" >&2
  exit 1
fi
log "Собрано: $APP_PATH ($(du -sh "$APP_PATH" | cut -f1))"

# ── 3. Упаковка в .ipa ─────────────────────────────────────────────────────
info "Упаковываю в $IPA_NAME…"
PAYLOAD="$DERIVED/Payload"
rm -rf "$PAYLOAD"
mkdir -p "$PAYLOAD"
cp -R "$APP_PATH" "$PAYLOAD/"

cd "$DERIVED"
rm -f "$DIST/$IPA_NAME"
zip -qry "$DIST/$IPA_NAME" Payload
cd "$SCRIPT_DIR"

SIZE=$(du -sh "$DIST/$IPA_NAME" | cut -f1)
log "Готово: $DIST/$IPA_NAME ($SIZE)"
echo
echo "  Установить на устройство:"
echo "    • Xcode → Window → Devices → перетащите .ipa"
echo "    • или Apple Configurator 2 / sideloadly / AltStore"
echo
echo "  ВАЖНО: ipa неподписан. Для App Store / TestFlight нужен"
echo "         CODE_SIGN_IDENTITY и DEVELOPMENT_TEAM в project.yml,"
echo "         тогда команда сборки будет:"
echo "         xcodebuild archive -scheme $SCHEME -archivePath build/Rossi.xcarchive"
echo "         xcodebuild -exportArchive -archivePath build/Rossi.xcarchive \\"
echo "                    -exportOptionsPlist build/export.plist \\"
echo "                    -exportPath dist/"
