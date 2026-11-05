#Requires -Version 5.0
<#
  把本地仓库推送到 GitHub

  用法一（推荐）：先在 github.com 上建一个空的公开仓库，名字叫 lawyer-cards，
                 然后运行：  .\push.ps1 -Repo "https://github.com/你的用户名/lawyer-cards.git"

  用法二：直接运行 .\push.ps1 ，它会问你地址。

  推送时会弹出浏览器让你登录 GitHub，登录一次即可。
#>
param(
    [string]$Repo = "",
    [string]$Branch = "main"
)

$ErrorActionPreference = 'Stop'
Write-Host ''

# 必须在仓库根目录
if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot '.git'))) {
    Write-Host '  [×] 当前文件夹不是 git 仓库。' -ForegroundColor Red
    exit 1
}
Set-Location $PSScriptRoot

if (-not $Repo) {
    Write-Host '  请粘贴你刚建好的仓库地址，例如：' -ForegroundColor DarkGray
    Write-Host '  https://github.com/yourname/lawyer-cards.git' -ForegroundColor DarkGray
    $Repo = Read-Host '  仓库地址'
}

$Repo = $Repo.Trim()
if ($Repo -notmatch '^https://github\.com/.+/.+\.git$' -and $Repo -notmatch '^git@github\.com:.+/.+\.git$') {
    Write-Host '  [×] 这个地址看起来不对。应该是 https://github.com/用户名/lawyer-cards.git' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host "  目标仓库：$Repo" -ForegroundColor Cyan
Write-Host ''

$existing = git remote 2>$null
if ($existing -contains 'origin') {
    git remote set-url origin $Repo
} else {
    git remote add origin $Repo
}

Write-Host '  正在推送……（如果弹出浏览器，登录一下你的 GitHub 账号）' -ForegroundColor DarkGray
git push -u origin $Branch
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host '  [×] 推送失败。常见原因：' -ForegroundColor Red
    Write-Host '      · 仓库还没建 —— 先去 github.com 点 New repository' -ForegroundColor Red
    Write-Host '      · 仓库里已有 README，导致历史冲突 —— 那就先 git pull --rebase' -ForegroundColor Red
    Write-Host '      · 登录没成功 —— 重新跑一次这个脚本' -ForegroundColor Red
    exit 1
}

$web = $Repo -replace '\.git$', ''
Write-Host ''
Write-Host '  [√] 推上去了。' -ForegroundColor Green
Write-Host ''
Write-Host '  把这个链接发给黄律师：' -ForegroundColor Cyan
Write-Host "  $web" -ForegroundColor White
Write-Host ''
Write-Host '  他的安装命令（在 PowerShell 里跑一次）：' -ForegroundColor Cyan
Write-Host "  git clone $Repo `"`$env:USERPROFILE\.workbuddy\skills\lawyer-cards`"" -ForegroundColor White
Write-Host ''
