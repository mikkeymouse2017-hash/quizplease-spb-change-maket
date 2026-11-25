#!/bin/zsh
set -e
cd "$(dirname "$0")"

APP="QuizPlease SPB.app"
echo "Сборка $APP ..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>QuizPlease SPB</string>
  <key>CFBundleDisplayName</key><string>QuizPlease SPB</string>
  <key>CFBundleIdentifier</key><string>ru.quizplease.spb.converter</string>
  <key>CFBundleExecutable</key><string>quizplease_spb</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>logo.icns</string>
  <key>CFBundleVersion</key><string>2.1</string>
  <key>LSMinimumSystemVersion</key><string>10.15</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Приложению нужен доступ к диалогам выбора файла.</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key><true/>
    <key>NSAllowsLocalNetworking</key><true/>
  </dict>
</dict>
</plist>
PLIST

cat > "$APP/Contents/MacOS/quizplease_spb" <<'LAUNCH'
#!/bin/zsh
# Finder does not pass a UTF-8 locale to .app bundles; set it explicitly
# so Russian file names and dialogs work correctly.
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"
cd "$(dirname "$0")/../Resources" || exit 1

LOG="$HOME/Library/Logs/QuizPleaseSPB-server.log"
mkdir -p "$(dirname "$LOG")"

# Pick a free local port so several copies of the app never conflict.
PORT=$(/usr/bin/ruby -rsocket -e '
  p = 4567
  40.times do
    begin
      s = TCPServer.new("127.0.0.1", p)
      s.close
      puts p
      exit
    rescue Errno::EADDRINUSE
      p += 1
    end
  end
  puts p
')
export PORT
export QP_PORT="$PORT"

/usr/bin/ruby server.rb >>"$LOG" 2>&1 &
SERVER_PID=$!

cleanup() {
  kill "$SERVER_PID" 2>/dev/null
  wait "$SERVER_PID" 2>/dev/null
}
trap cleanup EXIT INT TERM

for i in {1..60}; do
  /usr/bin/curl -fsS "http://127.0.0.1:$PORT/" >/dev/null 2>&1 && break
  sleep 0.25
done

/usr/bin/osascript -l JavaScript app_window.jxa >>"$LOG" 2>&1
LAUNCH
chmod +x "$APP/Contents/MacOS/quizplease_spb"

cp render_template.jsx "$APP/Contents/Resources/"
cp render_diploma.jsx "$APP/Contents/Resources/"
cp QR_SPB.png "$APP/Contents/Resources/"
cp server.rb "$APP/Contents/Resources/"
cp index.html "$APP/Contents/Resources/"
cp app_window.jxa "$APP/Contents/Resources/"
cp choose_inputs.jxa "$APP/Contents/Resources/"
cp logo.icns "$APP/Contents/Resources/"
cp logo.png "$APP/Contents/Resources/"
cp desktop.rb "$APP/Contents/Resources/"

# Clean metadata that prevents ad-hoc signing on copied files.
xattr -cr "$APP" 2>/dev/null || true
codesign --force --deep -s - "$APP" 2>/dev/null || true

echo "Готово: $(pwd)/$APP"
echo "Скопируйте эту папку на другой Mac и запустите двойным щелчком."
