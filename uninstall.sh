#!/bin/bash
# ZCode-TPS-Footer 一键回滚：恢复原始 app.asar + 卸载数据服务
set -e
RES="/Applications/ZCode.app/Contents/Resources"
launchctl bootout gui/$(id -u)/com.hpf.tps-stats-server 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.hpf.tps-stats-server.plist"
if [ -f "$RES/app.asar.tps-bak" ]; then
  cp "$RES/app.asar.tps-bak" "$RES/app.asar"
  echo "✅ 已恢复原始 app.asar。完全退出 ZCode（Cmd+Q）再打开即回到纯原生。"
else
  echo "⚠️ 没找到备份（可能从未注入过）。数据服务已卸载。"
fi
