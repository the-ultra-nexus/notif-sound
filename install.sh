#!/bin/bash
# 安装 NotifSound：编译 -> 复制到 ~/Applications -> 写 LaunchAgent -> 启动
set -euo pipefail

cd "$(dirname "$0")"

./build.sh

DEST="$HOME/Applications"
mkdir -p "$DEST" "$HOME/.config/notif-sound" "$HOME/data/notif-sound/logs"

# 停掉旧实例（LaunchAgent 和手动启动的）
launchctl bootout "gui/$(id -u)/com.nexus.notifsound" 2>/dev/null || true
pkill -f 'NotifSound.app/Contents/MacOS/NotifSound' 2>/dev/null || true

ditto build/NotifSound.app "$DEST/NotifSound.app"

if [ ! -f "$HOME/.config/notif-sound/rules.json" ]; then
  cp config.example.json "$HOME/.config/notif-sound/rules.json"
fi

PLIST="$HOME/Library/LaunchAgents/com.nexus.notifsound.plist"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.nexus.notifsound</string>
  <key>ProgramArguments</key>
  <array><string>$DEST/NotifSound.app/Contents/MacOS/NotifSound</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>StandardOutPath</key><string>$HOME/data/notif-sound/logs/launchd.out.log</string>
  <key>StandardErrorPath</key><string>$HOME/data/notif-sound/logs/launchd.err.log</string>
</dict>
</plist>
EOF

launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "已安装到 $DEST/NotifSound.app"
echo "下一步：系统设置 -> 隐私与安全性 -> 辅助功能，勾选 NotifSound"
