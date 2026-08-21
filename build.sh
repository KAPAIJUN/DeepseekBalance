#!/bin/bash
# DeepSeek 余额小组件 — 一键打包脚本（无需 Xcode，仅需命令行工具）
# 用法：
#   ./build.sh            # 只打包 DeepSeekBalance.app（生成到 ./build/）
#   ./build.sh install    # 打包并安装到 /Applications
set -euo pipefail
cd "$(dirname "$0")"

SRC=DeepSeekBalance.swift
ASSETS=assets
OUT=build
APP="$OUT/DeepSeekBalance.app"

echo "==> 编译..."
mkdir -p "$OUT"
xcrun swiftc -parse-as-library -O -o "$OUT/DeepSeekBalance-bin" "$SRC" \
  -framework SwiftUI -framework AppKit -framework UserNotifications -framework Charts

echo "==> 组装 .app..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/DeepSeekBalance-bin" "$APP/Contents/MacOS/DeepSeekBalance"
cp "$ASSETS/"*.png "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>DeepSeekBalance</string>
    <key>CFBundleDisplayName</key><string>DeepSeek 余额</string>
    <key>CFBundleIdentifier</key><string>local.deepseekbalance</string>
    <key>CFBundleExecutable</key><string>DeepSeekBalance</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> 签名（ad-hoc）..."
codesign --force -s - "$APP"

echo "==> 完成：$APP"

if [ "${1:-}" = "install" ]; then
    echo "==> 安装到 /Applications..."
    ditto "$APP" /Applications/DeepSeekBalance.app
    echo "==> 启动..."
    killall DeepSeekBalance 2>/dev/null || true
    sleep 1
    open /Applications/DeepSeekBalance.app
    echo "==> 已安装并启动。开机自启请在应用右键菜单勾选「开机自启」。"
fi
