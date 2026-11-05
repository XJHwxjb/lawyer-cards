#Requires -Version 3.0
<#
  lawyer-cards / render.ps1
  Zero-dependency renderer. Uses only the Microsoft Edge that ships with Windows.

  NOTE: This file is intentionally ASCII-only. Windows PowerShell 5.1 parses
  extension-less/UTF8-no-BOM scripts using the system ANSI codepage, which
  corrupts non-ASCII literals and breaks string parsing. Keep it ASCII.

  Usage A (script fills the placeholders):
    powershell -ExecutionPolicy Bypass -File render.ps1 -Template 01 -Data temp/data.json

  Usage B (render an already-built html):
    powershell -ExecutionPolicy Bypass -File render.ps1 -Html temp/render.html -Out output/x.png

  Params:
    -Template  template name or file name, e.g. 01 / 01-*.html
    -Data      path to a JSON file with the content fields
    -Out       output png path (default: output/card-yyyyMMdd-HHmmss.png)
    -Width     canvas width  (default 1080)
    -Height    canvas height (default 1440)
    -KeepTemp  keep the intermediate html for debugging
#>
[CmdletBinding()]
param(
    [string]$Template = "",
    [string]$Data     = "",
    [string]$Out      = "",
    [string]$Html     = "",
    [int]$Width       = 1080,
    [int]$Height      = 1440,
    [switch]$KeepTemp
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Find-Edge {
    $cands = @()
    if (${env:ProgramFiles(x86)}) { $cands += (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe') }
    if ($env:ProgramFiles)        { $cands += (Join-Path $env:ProgramFiles        'Microsoft\Edge\Application\msedge.exe') }
    if ($env:LOCALAPPDATA)        { $cands += (Join-Path $env:LOCALAPPDATA        'Microsoft\Edge\Application\msedge.exe') }
    foreach ($c in $cands) { if (Test-Path -LiteralPath $c) { return $c } }
    return $null
}

function Write-Utf8NoBom([string]$path, [string]$text) {
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($path, $text, $utf8)
}

# ---- 1. locate Edge ------------------------------------------------------
$edge = Find-Edge
$cfgPath = Join-Path $root 'config.json'
$cfg = $null
if (Test-Path -LiteralPath $cfgPath) {
    try { $cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $cfg = $null }
}
if ($cfg -and $cfg.edge -and (Test-Path -LiteralPath $cfg.edge)) { $edge = $cfg.edge }
if (-not $edge) {
    throw 'Microsoft Edge not found. Expected one of: ' +
          'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe ; ' +
          'C:\Program Files\Microsoft\Edge\Application\msedge.exe . ' +
          'If Edge lives elsewhere, put its full msedge.exe path into config.json as "edge".'
}

# ---- 2. build the field map (defaults <- config.json <- data.json) -------
$fields = [ordered]@{
    KICKER = ''; ISSUE = ''; TITLE = ''; SUBTITLE = ''; BADGE = ''
    BODY = ''; MEMO = ''; NAME = ''; ORG = ''; PAGE = ''; BIGNUM = ''
    H1 = ''; H2 = ''; PHOTO = ''; BRAND = ''; BRANDSUB = ''; NOTE = ''
    KEYBAR = ''; CITE = ''
}
foreach ($n in 1..5) {
    $fields["POINT_$n"] = ''
    $fields["DESC_$n"]  = ''
}

$alias = @{ 'TITLE'='TITLE'; 'SUBTITLE'='SUBTITLE' }
if ($cfg) {
    if ($cfg.name)   { $fields.NAME   = [string]$cfg.name }
    if ($cfg.org)    { $fields.ORG    = [string]$cfg.org }
    if ($cfg.kicker) { $fields.KICKER = [string]$cfg.kicker }
    if ($cfg.issue)  { $fields.ISSUE  = [string]$cfg.issue }
    if ($cfg.page)   { $fields.PAGE   = [string]$cfg.page }
    # Brand defaults: explicit brand wins, otherwise fall back to the name so
    # the brand template still has a top lockup instead of an empty gap.
    if ($cfg.brand)    { $fields.BRAND    = [string]$cfg.brand }
    elseif ($cfg.name) { $fields.BRAND    = [string]$cfg.name }
    if ($cfg.brandsub) { $fields.BRANDSUB = [string]$cfg.brandsub }
}

if ($Data) {
    if (-not (Test-Path -LiteralPath $Data)) {
        throw "Data file not found: $Data . Refusing to render an empty card."
    }
    $dj = Get-Content -LiteralPath $Data -Raw -Encoding UTF8 | ConvertFrom-Json
    $matched = 0
    foreach ($p in $dj.PSObject.Properties) {
        $k = ([string]$p.Name).ToUpper().Trim()
        if ($alias.ContainsKey($k)) { $k = $alias[$k] }
        if ($fields.Contains($k)) {
            $matched++
            $v = [string]$p.Value
            if (-not [string]::IsNullOrWhiteSpace($v)) { $fields[$k] = $v }
        }
        else {
            Write-Warning "Unknown field ignored: $($p.Name)"
        }
    }
    if ($matched -eq 0) {
        throw "No recognised fields in $Data . Expected names like TITLE / POINT_1 / DESC_1 / BODY."
    }
}

# A local photo path must become a file:// URI, otherwise url('C:\...') breaks
# inside a file:// page. Also allow http(s)/data URIs to pass straight through.
if ($fields.PHOTO) {
    $p = [string]$fields.PHOTO
    if ($p -match '^(file|https?|data):') {
        $fields.PHOTO = $p
    }
    else {
        if (-not (Test-Path -LiteralPath $p)) {
            throw "Photo not found: $p . Pass an absolute path or drop the PHOTO field."
        }
        $fields.PHOTO = ([System.Uri]([System.IO.Path]::GetFullPath($p))).AbsoluteUri
    }
}

# ---- 3. load the template ----------------------------------------------
if ($Html) {
    if (-not (Test-Path -LiteralPath $Html)) { throw "HTML not found: $Html" }
    $page = Get-Content -LiteralPath $Html -Raw -Encoding UTF8
}
else {
    if (-not $Template) { throw 'Specify -Template (e.g. 01) or -Html (an existing html file).' }
    $tplDir = Join-Path $root 'templates'
    $name = $Template
    if ($name -notlike '*.html') { $name = "$name.html" }
    $tplPath = Join-Path $tplDir $name
    if (-not (Test-Path -LiteralPath $tplPath)) {
        # allow short form: "01" matches "01-*.html"
        $hit = Get-ChildItem -LiteralPath $tplDir -Filter '*.html' |
               Where-Object { $_.Name -like "$Template*" } |
               Select-Object -First 1
        if ($hit) { $tplPath = $hit.FullName }
    }
    if (-not (Test-Path -LiteralPath $tplPath)) {
        $avail = (Get-ChildItem -LiteralPath $tplDir -Filter '*.html' | ForEach-Object { $_.BaseName }) -join ', '
        throw "Template not found: $Template . Available: $avail"
    }
    $page = Get-Content -LiteralPath $tplPath -Raw -Encoding UTF8
}

# ---- 4. substitute placeholders, drop empty blocks ----------------------
foreach ($k in $fields.Keys) {
    $page = $page.Replace("{{$k}}", [string]$fields[$k])
}

# Generic conditional blocks: <!--IF:KEY--> ... <!--/IF:KEY-->
# Anything wrapped in these disappears when that field is blank.
# This is the future-proof form; the older <!--ITEM1--> / <!--MEMO--> markers
# below are kept so existing templates keep working.
foreach ($k in @($fields.Keys)) {
    if ($page -notmatch "<!--IF:$k-->") { continue }
    if ([string]::IsNullOrWhiteSpace([string]$fields[$k])) {
        $page = [regex]::Replace($page, "(?s)<!--IF:$k-->.*?<!--/IF:$k-->", "")
    }
    else {
        $page = $page.Replace("<!--IF:$k-->", "").Replace("<!--/IF:$k-->", "")
    }
}

for ($n = 1; $n -le 5; $n++) {
    if ([string]::IsNullOrWhiteSpace([string]$fields["POINT_$n"])) {
        $page = [regex]::Replace($page, "(?s)<!--ITEM$n-->.*?<!--/ITEM$n-->", "")
    }
    else {
        $page = $page.Replace("<!--ITEM$n-->", "").Replace("<!--/ITEM$n-->", "")
    }
}
if ([string]::IsNullOrWhiteSpace([string]$fields.MEMO)) {
    $page = [regex]::Replace($page, "(?s)<!--MEMO-->.*?<!--/MEMO-->", "")
}
else {
    $page = $page.Replace("<!--MEMO-->", "").Replace("<!--/MEMO-->", "")
}
if ([string]::IsNullOrWhiteSpace([string]$fields.PHOTO)) {
    $page = [regex]::Replace($page, "(?s)<!--PHOTO-->.*?<!--/PHOTO-->", "")
}
else {
    $page = $page.Replace("<!--PHOTO-->", "").Replace("<!--/PHOTO-->", "")
}
if ([string]::IsNullOrWhiteSpace([string]$fields.ORG)) {
    $page = [regex]::Replace($page, "(?s)<!--ORG-->.*?<!--/ORG-->", "")
}
else {
    $page = $page.Replace("<!--ORG-->", "").Replace("<!--/ORG-->", "")
}
# safety net: never print a raw {{...}} on the card
$page = [regex]::Replace($page, '\{\{[A-Z0-9_]+\}\}', '')

# ---- 5. write the temp html --------------------------------------------
$tempDir = Join-Path $root 'temp'
if (-not (Test-Path -LiteralPath $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$tmpHtml = Join-Path $tempDir "render-$stamp.html"
Write-Utf8NoBom $tmpHtml $page

# ---- 6. screenshot -----------------------------------------------------
if (-not $Out) {
    $outDir = Join-Path $root 'output'
    # "card" + stamp, but built from code points so this source file stays pure ASCII
    $cn = ([char]0x5361).ToString() + ([char]0x7247).ToString()
    $Out = Join-Path $outDir ("{0}-{1}.png" -f $cn, $stamp)
}
$outFull  = [System.IO.Path]::GetFullPath($Out)
$outDirF  = Split-Path -Parent $outFull
if (-not (Test-Path -LiteralPath $outDirF)) { New-Item -ItemType Directory -Path $outDirF -Force | Out-Null }

# Edge gets an ASCII-only temp path; the final (possibly CJK) name is applied by PowerShell.
$tmpPng = Join-Path $tempDir "shot-$stamp.png"
if (Test-Path -LiteralPath $tmpPng) { Remove-Item -LiteralPath $tmpPng -Force }

$profileDir = Join-Path $tempDir 'edge-profile'
if (-not (Test-Path -LiteralPath $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }

$uri = ([System.Uri]$tmpHtml).AbsoluteUri
$argList = @(
    '--headless=new'
    '--disable-gpu'
    '--hide-scrollbars'
    '--force-device-scale-factor=1'
    '--no-first-run'
    '--no-default-browser-check'
    '--disable-extensions'
    '--disable-sync'
    "--user-data-dir=`"$profileDir`""
    "--window-size=$Width,$Height"
    "--screenshot=`"$tmpPng`""
    "`"$uri`""
) -join ' '

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName               = $edge
$psi.Arguments              = $argList
$psi.UseShellExecute        = $false
$psi.CreateNoWindow         = $true
$psi.RedirectStandardError  = $true
$psi.RedirectStandardOutput = $true

$proc = [System.Diagnostics.Process]::Start($psi)
$stderr = $proc.StandardError.ReadToEnd()
$proc.StandardOutput.ReadToEnd() | Out-Null
if (-not $proc.WaitForExit(30000)) {
    try { $proc.Kill() } catch {}
    throw 'Edge render timed out after 30s.'
}

if (-not (Test-Path -LiteralPath $tmpPng)) {
    throw "Edge produced no image. stderr: $stderr"
}

# ---- 7. verify PNG header + dimensions ---------------------------------
$bytes = [System.IO.File]::ReadAllBytes($tmpPng)
if ($bytes.Length -lt 26 -or $bytes[1] -ne 0x50 -or $bytes[2] -ne 0x4E -or $bytes[3] -ne 0x47) {
    throw "Output is not a valid PNG: $tmpPng"
}
$w = [BitConverter]::ToUInt32(@($bytes[19], $bytes[18], $bytes[17], $bytes[16]), 0)
$h = [BitConverter]::ToUInt32(@($bytes[23], $bytes[22], $bytes[21], $bytes[20]), 0)

if (Test-Path -LiteralPath $outFull) { Remove-Item -LiteralPath $outFull -Force }
Move-Item -LiteralPath $tmpPng -Destination $outFull -Force

# ---- 8. cleanup --------------------------------------------------------
if (-not $KeepTemp -and (Test-Path -LiteralPath $tmpHtml)) {
    Remove-Item -LiteralPath $tmpHtml -Force
}

if ($w -ne $Width -or $h -ne $Height) {
    Write-Warning "Rendered ${w}x${h}, expected ${Width}x${Height}."
}

Write-Output "OK|$outFull|${w}x${h}"
