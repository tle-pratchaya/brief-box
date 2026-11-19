#!/bin/sh
# สร้าง dist/BriefBox.app (ชื่อที่แสดง: กล่องบรีฟ) จาก Swift package
# ใช้: scripts/build-app.sh
set -eu
cd "$(dirname "$0")/.."

VERSION="0.1.0"
BUILD="$(date +%Y%m%d%H%M)"
APP="dist/BriefBox.app"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/BriefBox"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BriefBox"
[ -f scripts/AppIcon.icns ] && cp scripts/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.briefbox.app</string>
  <key>CFBundleName</key><string>BriefBox</string>
  <key>CFBundleDisplayName</key><string>กล่องบรีฟ</string>
  <key>CFBundleExecutable</key><string>BriefBox</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>CFBundleDevelopmentRegion</key><string>th</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSRemindersFullAccessUsageDescription</key><string>กล่องบรีฟสร้างรายการเตือนเดดไลน์ในแอป Reminders เพื่อให้เด้งเตือนบน iPhone ด้วย (ส่งแค่ชื่องานกับวันที่)</string>
  <key>NSRemindersUsageDescription</key><string>กล่องบรีฟสร้างรายการเตือนเดดไลน์ในแอป Reminders</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Email Message</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>com.apple.mail.email</string><string>public.email-message</string></array>
      <key>CFBundleTypeExtensions</key><array><string>eml</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "สร้างแล้ว: $APP ($(du -sh "$APP" | cut -f1))"
