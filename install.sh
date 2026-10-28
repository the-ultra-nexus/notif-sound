#!/bin/bash
# 安装 NotifSound：编译 -> 复制到 ~/Applications -> 写 LaunchAgent -> 启动
set -euo pipefail

cd "$(dirname "$0")"

./build.sh

DEST="$HOME/Applications"
ROOT="$HOME/Library/Application Support/NotifSound"
mkdir -p "$DEST" "$ROOT/logs" "$ROOT/sounds"

# 停掉旧实例（LaunchAgent 和手动启动的）
launchctl bootout "gui/$(id -u)/com.nexus.notifsound" 2>/dev/null || true
pkill -f 'NotifSound.app/Contents/MacOS/NotifSound' 2>/dev/null || true

ditto build/NotifSound.app "$DEST/NotifSound.app"

# 全新安装才放示例；老用户由 App 启动时从 ~/.config/notif-sound 和 ~/data/notif-sound 自动迁移，
# 这里抢先写一份反而会让迁移跳过，把人家的规则留在旧位置。
if [ ! -f "$ROOT/rules.json" ] && [ ! -f "$HOME/.config/notif-sound/rules.json" ]; then
  cp config.example.json "$ROOT/rules.json"
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
  <key>StandardOutPath</key><string>$ROOT/logs/launchd.out.log</string>
  <key>StandardErrorPath</key><string>$ROOT/logs/launchd.err.log</string>
</dict>
</plist>
EOF

launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "已安装到 $DEST/NotifSound.app"
echo "配置在 $ROOT/rules.json"
echo "下一步：系统设置 -> 隐私与安全性 -> 辅助功能，勾选 NotifSound"
