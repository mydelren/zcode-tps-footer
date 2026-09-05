#!/bin/bash
# ZCode-TPS-Footer 一键安装（macOS，ZCode 3.11.x，arm64/x64 通用）
# 用法：克隆本仓库后双击本文件（或 bash install.command）
# 原理：解包 app.asar → 渲染层 index.html 加一行 <script> → 重打包替换（原包自动备份）
set -e
RES="/Applications/ZCode.app/Contents/Resources"
ASAR="$RES/app.asar"
STAGE="$HOME/.zcode/tps-inject"          # 稳定装载位（与仓库位置解耦）
HERE="$(cd "$(dirname "$0")" && pwd)"
MARK="tps-inject/inject.js"

[ -f "$ASAR" ] || { echo "❌ 找不到 $ASAR（请确认 ZCode 装在 /Applications）"; exit 1; }

# 1) 装载文件到稳定目录
mkdir -p "$STAGE"
cp "$HERE/inject.js" "$HERE/tps_stats_server.py" "$STAGE/"

# 2) 数据服务（launchd 常驻，仅本机 127.0.0.1:3117）
cat > "$HOME/Library/LaunchAgents/com.zcode-tps-footer.server.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.zcode-tps-footer.server</string>
<key>ProgramArguments</key><array>
<string>/usr/bin/python3</string><string>$STAGE/tps_stats_server.py</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>StandardOutPath</key><string>$STAGE/server.log</string>
<key>StandardErrorPath</key><string>$STAGE/server.log</string>
</dict></plist>
PLIST
launchctl bootout gui/$(id -u)/com.zcode-tps-footer.server 2>/dev/null || true
launchctl bootstrap gui/$(id -u) "$HOME/Library/LaunchAgents/com.zcode-tps-footer.server.plist" 2>/dev/null || true
sleep 1
curl -s --max-time 2 http://127.0.0.1:3117/healthz | grep -q ok && echo "✅ 数据服务就绪" || echo "⚠️ 服务未响应（launchd 会自动重试）"

# 3) 已注入过？（ZCode 更新后 asar 被覆盖会走到这里 → 重打）
mkdir -p "$STAGE/repack" && cd "$STAGE/repack"
npx -y @electron/asar extract-file "$ASAR" out/renderer/index.html >/dev/null 2>&1 || true
if [ -f index.html ] && grep -q "$MARK" index.html; then
  echo "✅ 当前 asar 已含注入标记，无需重打。"
else
  echo "① 备份原包 ..."
  [ -f "$RES/app.asar.tps-bak" ] || cp "$ASAR" "$RES/app.asar.tps-bak"
  echo "② 解包 ...（首次约 1-2 分钟）"
  rm -rf unpacked && npx -y @electron/asar extract "$ASAR" unpacked
  echo "③ 注入 script 标签 ..."
  python3 - << PYEOF
p = 'unpacked/out/renderer/index.html'
s = open(p, encoding='utf-8').read()
tag = '    <script defer src="file://$STAGE/inject.js"></script>'
if '$MARK' not in s:
    s = s.replace('  </head>', tag + '\n  </head>', 1)
    open(p, 'w', encoding='utf-8').write(s)
PYEOF
  echo "④ 重打包 ..."
  npx -y @electron/asar pack unpacked app.asar.patched --unpack "{**/*.node,**/spawn-helper}"
  echo "⑤ 替换 ..."
  cp app.asar.patched "$ASAR"
  rm -rf "$RES/app.asar.unpacked"
  cp -R app.asar.patched.unpacked "$RES/app.asar.unpacked"
  echo "✅ 注入完成。"
fi
echo ""
echo "🎉 完成！完全退出 ZCode（Cmd+Q）再打开，每条回答下方即出现统计行。"
echo "   回滚：bash $(dirname "$0")/uninstall.sh ｜ ZCode 更新后：重新双击本脚本即可"
