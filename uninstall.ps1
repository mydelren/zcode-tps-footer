# ZCode-TPS-Footer 卸载（Windows 移植版，对应 macOS uninstall.sh）
# 回滚 asar（用安装时备份）+ 停服务 + 删自启项。加 -Purge 连稳定装载目录一起删。
param([switch]$Purge)
$ErrorActionPreference = 'Continue'
$STAGE = Join-Path $env:USERPROFILE '.zcode\tps-inject'

# ---------- 1) 回滚 app.asar ----------
$RES = $null
$proc = Get-Process ZCode -ErrorAction SilentlyContinue | Where-Object Path | Select-Object -First 1
if ($proc) { $RES = Join-Path (Split-Path $proc.Path -Parent) 'resources' }
if (-not $RES -or -not (Test-Path (Join-Path $RES 'app.asar'))) {
    foreach ($p in @("$env:LOCALAPPDATA\Programs\ZCode", 'D:\Program Files\ZCode', 'C:\Program Files\ZCode', 'C:\Program Files (x86)\ZCode')) {
        if (Test-Path "$p\resources\app.asar") { $RES = "$p\resources"; break }
    }
}
if ($RES) {
    if (Test-Path "$RES\app.asar.tps-bak") {
        Copy-Item "$RES\app.asar.tps-bak" (Join-Path $RES 'app.asar') -Force
        Write-Host '✅ app.asar 已回滚为原包'
        if (Test-Path "$RES\app.asar.unpacked.tps-bak") {
            if (Test-Path "$RES\app.asar.unpacked") { Remove-Item "$RES\app.asar.unpacked" -Recurse -Force }
            Copy-Item "$RES\app.asar.unpacked.tps-bak" "$RES\app.asar.unpacked" -Recurse
            Write-Host '✅ app.asar.unpacked 已回滚'
        }
    } else { Write-Host 'ℹ️ 无备份（未打过补丁或备份已被清理），asar 未改动' }
}

# ---------- 2) 停服务 + 删自启 ----------
Get-CimInstance Win32_Process -Filter "Name like 'python%'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*tps_stats_server.py*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force; Write-Host "✅ 已停数据服务 (PID $($_.ProcessId))" }
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'ZCodeTpsFooter' -ErrorAction SilentlyContinue
Write-Host '✅ 已删开机自启项'

# ---------- 3) 可选清理 ----------
if ($Purge) {
    if (Test-Path $STAGE) { Remove-Item $STAGE -Recurse -Force; Write-Host "✅ 已删除 $STAGE" }
    if ($RES -and (Test-Path "$RES\app.asar.tps-bak")) {
        Remove-Item "$RES\app.asar.tps-bak" -Force
        if (Test-Path "$RES\app.asar.unpacked.tps-bak") { Remove-Item "$RES\app.asar.unpacked.tps-bak" -Recurse -Force }
        Write-Host '✅ 已删除安装备份（不可再回滚，原包已在位）'
    }
}
Write-Host ''
Write-Host '🎉 卸载完成。完全退出 ZCode 再打开即恢复原状。'
