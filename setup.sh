#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Find the Python that actually has rumps installed (Finder uses a minimal PATH)
PYTHON=""
for _py in "/opt/anaconda3/bin/python3" "/opt/homebrew/bin/python3" "/usr/local/bin/python3" "$(which python3)"; do
    if "$_py" -c "import rumps" 2>/dev/null; then PYTHON="$_py"; break; fi
done
[ -z "$PYTHON" ] && { echo "ERROR: no Python with 'rumps' found"; exit 1; }

echo "==> 检查 Python: $PYTHON"

echo "==> 安装依赖 …"
"$PYTHON" -m pip install --quiet rumps flask pyobjc-framework-WebKit

echo "==> 创建数据目录 …"
mkdir -p "$HOME/.activity_tracker"

# LaunchAgent plist
PLIST="$HOME/Library/LaunchAgents/com.activitytracker.tracker.plist"
echo "==> 写入 LaunchAgent: $PLIST"
cat > "$PLIST" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.activitytracker.tracker</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PYTHON</string>
        <string>$DIR/tracker.py</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>$HOME/.activity_tracker/error.log</string>
    <key>StandardOutPath</key>
    <string>$HOME/.activity_tracker/output.log</string>
</dict>
</plist>
PLIST_EOF

# Load / reload
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

# App bundle → Applications
echo "==> 安装 ActivityTracker.app …"
chmod +x "$DIR/ActivityTracker.app/Contents/MacOS/ActivityTracker"
cp -r "$DIR/ActivityTracker.app" "$HOME/Applications/" 2>/dev/null \
  || cp -r "$DIR/ActivityTracker.app" "/Applications/" 2>/dev/null \
  || echo "    （跳过 Applications 复制，请手动拖入）"

echo ""
echo "✓ 安装完成！"
echo ""
echo "  • 菜单栏 ⏱ 图标 — 登录后自动启动（已注册 LaunchAgent）"
echo "  • 一键启动 — 双击 Applications/ActivityTracker.app，或拖入程序坞"
echo ""
echo "卸载: launchctl unload $PLIST && rm $PLIST"
