#!/bin/bash
# 安装到 ~/Applications 并注册开机自启
set -euo pipefail

cd "$(dirname "$0")"
./build.sh

DEST="$HOME/Applications/AILock.app"
PLIST="$HOME/Library/LaunchAgents/com.laogu.ailock.plist"

# 先停掉旧实例，否则覆盖时会残留一个跑着老代码的进程
launchctl bootout "gui/$(id -u)/com.laogu.ailock" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.laogu.docklock" 2>/dev/null || true
pkill -x AILock 2>/dev/null || true
pkill -x DockLock 2>/dev/null || true

mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R build/AILock.app "$DEST"

# 临时签名(ad-hoc)每次重编 cdhash 都变，系统会当成另一个程序：
# 旧授权记录作废但仍显示为"已勾选"，还会在列表里堆重复条目。所以每次装都先清掉重授。
tccutil reset Accessibility com.laogu.ailock >/dev/null 2>&1 || true

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>com.laogu.ailock</string>
	<key>ProgramArguments</key>
	<array><string>$DEST/Contents/MacOS/AILock</string></array>
	<key>RunAtLoad</key><true/>
	<!-- 刻意不用 KeepAlive：菜单栏工具必须能被用户真正退出，否则"退出"会被 launchd 秒拉起 -->
	<key>KeepAlive</key><false/>
	<key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "✅ 已安装到 $DEST，并注册开机自启"
echo "   卸载：launchctl bootout gui/\$(id -u)/com.laogu.ailock && rm -rf \"$DEST\" \"$PLIST\""
