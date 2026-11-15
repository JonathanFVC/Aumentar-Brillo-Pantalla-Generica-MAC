#!/bin/bash
# Compila e instala la app de barra de menu en ~/Applications/Pantalla.app y la abre. Detalle: README.md
set -euo pipefail
cd "$(dirname "$0")"
APP="$HOME/Applications/Pantalla.app"
swiftc -O -swift-version 5 pantalla_jh207_barra_menu_app.swift -o Pantalla
pkill -x Pantalla 2>/dev/null || true
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
mv Pantalla "$APP/Contents/MacOS/Pantalla"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Pantalla</string>
<key>CFBundleExecutable</key><string>Pantalla</string>
<key>CFBundleIdentifier</key><string>local.pantalla.menubar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
open "$APP"
echo "instalada y abierta: $APP"
