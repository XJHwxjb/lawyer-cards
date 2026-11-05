#Requires -Version 5.0
<#
  朋友圈发图 · 一键安装
  把当前文件夹复制到 %USERPROFILE%\.workbuddy\skills\lawyer-cards
  （文件夹名固定，WorkBuddy 技能面板里显示的名字是「朋友圈发图」）

  用法：
    powershell -ExecutionPolicy Bypass -File .\install.ps1
#>

$ErrorActionPreference = 'Stop'

Write-Host ''
Write-Host '  朋友圈发图 · 安装程序' -ForegroundColor Cyan
Write-Host '  技能名：朋友圈发图    文件夹：lawyer-cards' -ForegroundColor DarkGray
Write-Host '  ------------------------------------' -ForegroundColor DarkGray
Write-Host ''

$src = $PSScriptRoot
if (-not $src) { $src = (Get-Location).Path }

if (-not (Test-Path -LiteralPath (Join-Path $src 'SKILL.md'))) {
    Write-Host '  [×] 这个脚本必须和 SKILL.md 放在同一个文件夹里。' -ForegroundColor Red
    Write-Host '      请确认你解压完整，没有只移动单个文件。' -ForegroundColor Red
    exit 1
}

$dst = Join-Path $env:USERPROFILE '.workbuddy\skills\lawyer-cards'

# 已经装在这个位置了（用户直接 git clone 进来的情况）
$same = $false
try {
    $a = [System.IO.Path]::GetFullPath($src).TrimEnd('\')
    $b = [System.IO.Path]::GetFullPath($dst).TrimEnd('\')
    if ($a -ieq $b) { $same = $true }
} catch { }

if ($same) {
    Write-Host '  [√] 已经安装在正确的位置了，不需要再复制。' -ForegroundColor Green
} else {
    if (Test-Path -LiteralPath $dst) {
        $bak = "$dst.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Move-Item -LiteralPath $dst -Destination $bak
        Write-Host "  [!] 旧版本已备份到：$bak" -ForegroundColor Yellow
    }

    $parent = Split-Path -Parent $dst
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    New-Item -ItemType Directory -Path $dst -Force | Out-Null

    # 只复制该复制的东西
    $skip = @('.git', 'temp', 'output', 'config.json')
    Get-ChildItem -LiteralPath $src -Force | ForEach-Object {
        if ($skip -contains $_.Name) { return }
        Copy-Item -LiteralPath $_.FullName -Destination $dst -Recurse -Force
    }
    Write-Host "  [√] 已复制到：$dst" -ForegroundColor Green

    $cfg = Join-Path $dst 'config.json'
    if (-not (Test-Path -LiteralPath $cfg)) {
        $example = Join-Path $dst 'config.example.json'
        if (Test-Path -LiteralPath $example) {
            Copy-Item -LiteralPath $example -Destination $cfg -Force
            Write-Host '  [√] 已生成 config.json（署名还没填，第一次用 AI 会问你）' -ForegroundColor Green
        }
    }
}

# ---- 自检 ----
Write-Host ''
Write-Host '  自检：' -ForegroundColor DarkGray
$tplDir = Join-Path $dst 'templates'
$tplCount = 0
if (Test-Path -LiteralPath $tplDir) {
    $tplCount = (Get-ChildItem -LiteralPath $tplDir -Filter '*.html').Count
}
Write-Host "    模板数量：$tplCount / 14" -ForegroundColor DarkGray

$themeFile = Join-Path $dst 'themes.json'
if (Test-Path -LiteralPath $themeFile) {
    try {
        $names = (Get-Content -LiteralPath $themeFile -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties.Name
        Write-Host ("    配色：{0} 套（{1}）" -f $names.Count, ($names -join ' / ')) -ForegroundColor DarkGray
    } catch {
        Write-Host '    配色：themes.json 读不出来' -ForegroundColor Yellow
    }
} else {
    Write-Host '    配色：themes.json 缺失，只能用默认紫金' -ForegroundColor Yellow
}

$edge = $null
$cands = @()
if (${env:ProgramFiles(x86)}) { $cands += (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe') }
if ($env:ProgramFiles)        { $cands += (Join-Path $env:ProgramFiles        'Microsoft\Edge\Application\msedge.exe') }
foreach ($c in $cands) { if (Test-Path -LiteralPath $c) { $edge = $c; break } }
if ($edge) { Write-Host "    Edge：已找到" -ForegroundColor DarkGray }
else       { Write-Host "    Edge：未找到，出图会失败（先装一个 Edge）" -ForegroundColor Yellow }

Write-Host ''
Write-Host '  ------------------------------------' -ForegroundColor DarkGray
Write-Host '  装好了。接下来：' -ForegroundColor Cyan
Write-Host '    1. 重启 WorkBuddy'
Write-Host '    2. 直接说：「用朋友圈发图，今天想讲讲竞业限制」'
Write-Host '    3. 它会给你三个标题，挑一个就出图'
Write-Host ''
Write-Host '  头像和二维码在 assets 文件夹里，换成自己的即可。' -ForegroundColor DarkGray
Write-Host ''
