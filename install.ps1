# ZCode-TPS-Footer 一键安装（Windows 移植版，对应 macOS install.command）
# 原理：解包 app.asar → 渲染层 index.html 加一行 <script> → 重打包替换（原包自动备份）
# 用法：pwsh -File install.ps1        （ZCode 更新覆盖 asar 后重跑本脚本即可，幂等）
param([switch]$Force) # -Force：已有标记也强制重打（升级注入逻辑后用）

$ErrorActionPreference = 'Stop'
$MARK = 'tps-inject/inject.js'
$HERE = $PSScriptRoot
$STAGE = Join-Path $env:USERPROFILE '.zcode\tps-inject'   # 稳定装载位（与仓库位置解耦）

# ---------- 0) 定位 ZCode 安装目录（运行中进程优先，其次常见路径探测） ----------
$RES = $null
$proc = Get-Process ZCode -ErrorAction SilentlyContinue | Where-Object Path | Select-Object -First 1
if ($proc) { $RES = Join-Path (Split-Path $proc.Path -Parent) 'resources' }
if (-not $RES -or -not (Test-Path (Join-Path $RES 'app.asar'))) {
    foreach ($p in @("$env:LOCALAPPDATA\Programs\ZCode", 'D:\Program Files\ZCode', 'C:\Program Files\ZCode', 'C:\Program Files (x86)\ZCode')) {
        if (Test-Path "$p\resources\app.asar") { $RES = "$p\resources"; break }
    }
}
if (-not $RES) { Write-Host "❌ 找不到 ZCode 安装目录（app.asar）"; exit 1 }
$ASAR = Join-Path $RES 'app.asar'
Write-Host "目标: $ASAR"

# 版本提示（注入选择器绑定 3.11.x，大版本变化时 inject.js 可能需跟进）
$ver = (Get-Item (Join-Path (Split-Path $RES -Parent) 'ZCode.exe') -ErrorAction SilentlyContinue).VersionInfo.ProductVersion
if ($ver -and $ver -notlike '3.11.*') { Write-Host "⚠️ ZCode 版本 $ver 非 3.11.x，注入选择器可能失效（继续执行，验证后即知）" }

# ---------- 1) 装载文件到稳定目录 ----------
New-Item -ItemType Directory -Force -Path $STAGE | Out-Null
Copy-Item (Join-Path $HERE 'inject.js'), (Join-Path $HERE 'tps_stats_server.py'), (Join-Path $HERE 'asar-peek.mjs') $STAGE -Force
Write-Host "✅ 文件已装载到 $STAGE"

# ---------- 2) 数据服务常驻（HKCU Run 键 + 立即拉起，仅本机 127.0.0.1:3117） ----------
# 优先真实安装目录的 pythonw（WindowsApps 别名指向 PythonManager，解析不稳定），回落 Get-Command
$pyw = if (Test-Path "$env:LOCALAPPDATA\Python\bin\pythonw.exe") { "$env:LOCALAPPDATA\Python\bin\pythonw.exe" }
       else { (Get-Command pythonw.exe -ErrorAction SilentlyContinue).Source }
if (-not $pyw) { $pyw = (Get-Command python.exe -ErrorAction SilentlyContinue).Source }
if (-not $pyw) { Write-Host "❌ 找不到 python/pythonw"; exit 1 }
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
Set-ItemProperty -Path $runKey -Name 'ZCodeTpsFooter' -Value ('"{0}" "{1}"' -f $pyw, (Join-Path $STAGE 'tps_stats_server.py'))
function Test-Server {
    try { (Invoke-WebRequest -Uri 'http://127.0.0.1:3117/healthz' -TimeoutSec 2).Content } catch { $null }
}
if ((Test-Server) -ne 'ok') {
    Start-Process -FilePath $pyw -ArgumentList ('"{0}"' -f (Join-Path $STAGE 'tps_stats_server.py')) -WindowStyle Hidden
    Start-Sleep 2
}
if ((Test-Server) -eq 'ok') { Write-Host '✅ 数据服务就绪 (127.0.0.1:3117, 开机自启)' }
else { Write-Host '⚠️ 服务未响应（重启后由 Run 键自启；也可手动重跑本脚本）' }

# ---------- 3) 已注入过？（ZCode 更新后 asar 被覆盖 → 标记消失 → 重打） ----------
$peek = @('node', (Join-Path $STAGE 'asar-peek.mjs'), $ASAR, 'out/renderer/index.html')
$cur = & node $peek[1] $peek[2] $peek[3] 2>$null
if ($LASTEXITCODE -eq 0 -and $cur -is [string] -and $cur.Contains($MARK) -and -not $Force) {
    Write-Host '✅ 当前 asar 已含注入标记，无需重打。（升级注入请加 -Force）'
    Write-Host ''
    Write-Host '🎉 完成！完全退出 ZCode（托盘右键退出）再打开，每条回答下方即出现统计行。'
    exit 0
}

# ---------- 4) 备份 → 解包 → 注入 → 重打包 → 替换 ----------
$repack = Join-Path $STAGE 'repack'
New-Item -ItemType Directory -Force -Path $repack | Out-Null
Push-Location $repack

Write-Host '① 备份原包 ...'
if (-not (Test-Path "$ASAR.tps-bak")) { Copy-Item $ASAR "$ASAR.tps-bak" }
if (-not (Test-Path "$RES\app.asar.unpacked.tps-bak") -and (Test-Path "$RES\app.asar.unpacked")) {
    Copy-Item "$RES\app.asar.unpacked" "$RES\app.asar.unpacked.tps-bak" -Recurse
}

Write-Host '② 解包 ...（首次约 1-2 分钟）'
if (Test-Path unpacked) { Remove-Item unpacked -Recurse -Force }
npx -y @electron/asar extract $ASAR unpacked
if ($LASTEXITCODE -ne 0) { throw 'asar 解包失败' }

Write-Host '③ 注入 script 标签 ...'
$idx = 'unpacked\out\renderer\index.html'
$s = [IO.File]::ReadAllText((Join-Path $repack $idx), [Text.UTF8Encoding]::new($false))
if (-not $s.Contains($MARK)) {
    $stageUrl = ($STAGE -replace '\\', '/')
    $tag = "    <script defer src=`"file:///$stageUrl/inject.js`"></script>"
    if (-not $s.Contains('  </head>')) { throw 'index.html 中找不到 </head> 注入点' }
    $s = $s.Replace('  </head>', "$tag`r`n  </head>")
    [IO.File]::WriteAllText((Join-Path $repack $idx), $s, [Text.UTF8Encoding]::new($false))
}

Write-Host '④ 重打包 ...'
# unpack 集合必须覆盖原包的 node-pty/ssh2 二进制(.node/.dll/.exe)——原包 12 个 unpacked
# 条目含 9 个 dll/exe(conpty/winpty/pagent),漏掉会收进包内,终端 spawn 有失效风险
npx -y @electron/asar pack unpacked app.asar.patched --unpack '{**/*.node,**/*.dll,**/*.exe}'
if ($LASTEXITCODE -ne 0) { throw 'asar 重打包失败' }

# 替换前验证补丁包里确实带标记，防白替换
$chk = & node (Join-Path $STAGE 'asar-peek.mjs') (Join-Path $repack 'app.asar.patched') 'out/renderer/index.html' 2>$null
if ($LASTEXITCODE -ne 0 -or -not ($chk -is [string] -and $chk.Contains($MARK))) { throw '补丁包校验失败（未检出标记），已中止替换' }

Write-Host '⑤ 替换 ...'
Copy-Item (Join-Path $repack 'app.asar.patched') $ASAR -Force
if (Test-Path "$RES\app.asar.unpacked") { Remove-Item "$RES\app.asar.unpacked" -Recurse -Force }
if (Test-Path (Join-Path $repack 'app.asar.patched.unpacked')) {
    Copy-Item (Join-Path $repack 'app.asar.patched.unpacked') "$RES\app.asar.unpacked" -Recurse
}
Pop-Location
Write-Host '✅ 注入完成。'
Write-Host ''
Write-Host '🎉 完成！完全退出 ZCode（托盘右键退出）再打开，每条回答下方即出现统计行。'
Write-Host '   回滚：pwsh -File uninstall.ps1 ｜ ZCode 更新后：重跑本脚本即可'
