#!/bin/bash
# deepseek用量监控组件 — 一键打包脚本（无需 Xcode，仅需命令行工具）
# 用法：
#   ./build.sh            # 只打包 .app（生成到 ./build/）
#   ./build.sh package    # 打包并生成安装包 build/DeepSeekBalance.app.zip
#   ./build.sh install    # 打包并安装到 /Applications 并启动
set -euo pipefail
cd "$(dirname "$0")"

SRC=DeepSeekBalance.swift
ASSETS=assets
OUT=build
APP="$OUT/DeepSeekBalance.app"

echo "==> 编译（含并发告警检查）..."
mkdir -p "$OUT"
xcrun swiftc -parse-as-library -O -warn-concurrency -o "$OUT/DeepSeekBalance-bin" "$SRC" \
  -framework SwiftUI -framework AppKit -framework UserNotifications -framework Charts

echo "==> 组装 .app..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/DeepSeekBalance-bin" "$APP/Contents/MacOS/DeepSeekBalance"
cp "$ASSETS/"*.png "$APP/Contents/Resources/"

echo "==> 生成应用图标..."
ICONSET="$OUT/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
ICON_SRC="$ASSETS/deepseek-icon.png"
sips -z 16 16   "$ICON_SRC" --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z 32 32   "$ICON_SRC" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32 32   "$ICON_SRC" --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z 64 64   "$ICON_SRC" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128 128 "$ICON_SRC" --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256 256 "$ICON_SRC" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_SRC" --out "$ICONSET/icon_256x256.png"    >/dev/null
sips -z 512 512 "$ICON_SRC" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_SRC" --out "$ICONSET/icon_512x512.png"    >/dev/null
sips -z 1024 1024 "$ICON_SRC" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>DeepSeekBalance</string>
    <key>CFBundleDisplayName</key><string>deepseek用量监控组件</string>
    <key>CFBundleIdentifier</key><string>local.deepseekbalance</string>
    <key>CFBundleExecutable</key><string>DeepSeekBalance</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleVersion</key><string>1.1</string>
    <key>CFBundleShortVersionString</key><string>1.1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> 签名（ad-hoc）..."
codesign --force -s - "$APP"

echo "==> 完成：$APP"

case "${1:-}" in
  package)
    echo "==> 生成安装包..."
    PKG_TMP="$OUT/pkg-tmp"
    rm -rf "$PKG_TMP"
    mkdir -p "$PKG_TMP"
    # --noextattr + xattr -cr + zip -X：彻底避免 __MACOSX/._ AppleDouble 文件
    ditto --noextattr "$APP" "$PKG_TMP/deepseek用量监控组件.app"
    xattr -cr "$PKG_TMP/deepseek用量监控组件.app" 2>/dev/null || true
    rm -f "$OUT/DeepSeekBalance.app.zip" # zip 对已存在文件是增量更新，先删除避免残留
    (cd "$PKG_TMP" && zip -q -r -X ../DeepSeekBalance.app.zip "deepseek用量监控组件.app")
    rm -rf "$PKG_TMP"
    echo "==> 安装包：$OUT/DeepSeekBalance.app.zip"
    ;;
  install)
    echo "==> 安装到 /Applications..."
    ditto "$APP" /Applications/DeepSeekBalance.app
    echo "==> 启动..."
    killall DeepSeekBalance 2>/dev/null || true
    sleep 1
    open /Applications/DeepSeekBalance.app
    echo "==> 已安装并启动。开机自启请在应用右键菜单勾选「开机自启」。"
    ;;
esac
