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
    -Theme     named palette: purple (default) / navy / emerald / wine
    -BgColor   custom base colour, any hex (#1B3A5C). Wins over -Theme.
    -AccentColor  custom metallic colour, any hex (#C9A45E). Wins over -Theme.
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
    [string]$Theme    = "",
    [string]$BgColor  = "",
    [string]$AccentColor = "",
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

# ---- 4.5 colour theme ---------------------------------------------------
# Templates carry the default palette as :root custom properties. A palette
# (named, or generated from two custom colours) is injected as a second
# :root block just before </head>; the later declaration wins, so switching
# colours never needs a template edit.
#
# The design has two colour families that travel together:
#   ink / gray / other  -> the dark base  (outer band, headlines on paper)
#   gold                -> the metallic accent (rules, numerals, wordmark)
# cream / neutral are the paper itself and never move - that is what keeps
# the type readable on every palette.

function ConvertFrom-HexColor([string]$hex) {
    if (-not $hex) { return $null }
    $h = $hex.Trim()
    if ($h.StartsWith('#')) { $h = $h.Substring(1) }
    if ($h.Length -eq 3) { $h = ([string]$h[0]) + ([string]$h[0]) + ([string]$h[1]) + ([string]$h[1]) + ([string]$h[2]) + ([string]$h[2]) }
    if ($h -notmatch '^[0-9A-Fa-f]{6}$') { return $null }
    return @{
        R = ([Convert]::ToInt32($h.Substring(0, 2), 16)) / 255.0
        G = ([Convert]::ToInt32($h.Substring(2, 2), 16)) / 255.0
        B = ([Convert]::ToInt32($h.Substring(4, 2), 16)) / 255.0
    }
}

function Get-Hsl($c) {
    $max = [Math]::Max($c.R, [Math]::Max($c.G, $c.B))
    $min = [Math]::Min($c.R, [Math]::Min($c.G, $c.B))
    $l = ($max + $min) / 2.0
    $d = $max - $min
    if ($d -lt 0.00001) { return @{ H = 0.0; S = 0.0; L = $l } }
    $s = $d / (1.0 - [Math]::Abs(2 * $l - 1))
    if ($s -gt 1.0) { $s = 1.0 }
    if ($max -eq $c.R) { $h = 60 * ((($c.G - $c.B) / $d) % 6) }
    elseif ($max -eq $c.G) { $h = 60 * ((($c.B - $c.R) / $d) + 2) }
    else { $h = 60 * ((($c.R - $c.G) / $d) + 4) }
    if ($h -lt 0) { $h += 360 }
    return @{ H = $h; S = $s; L = $l }
}

function ConvertTo-HexColor([double]$h, [double]$s, [double]$l) {
    $h = (($h % 360) + 360) % 360
    if ($s -lt 0) { $s = 0.0 }
    if ($s -gt 0.95) { $s = 0.95 }
    if ($l -lt 0) { $l = 0.0 }
    if ($l -gt 1) { $l = 1.0 }
    $c = (1 - [Math]::Abs(2 * $l - 1)) * $s
    $x = $c * (1 - [Math]::Abs((($h / 60) % 2) - 1))
    $m = $l - $c / 2
    $r = 0.0; $g = 0.0; $b = 0.0
    if     ($h -lt 60)  { $r = $c; $g = $x }
    elseif ($h -lt 120) { $r = $x; $g = $c }
    elseif ($h -lt 180) { $g = $c; $b = $x }
    elseif ($h -lt 240) { $g = $x; $b = $c }
    elseif ($h -lt 300) { $r = $x; $b = $c }
    else                { $r = $c; $b = $x }
    $bytes = @()
    foreach ($v in @(($r + $m), ($g + $m), ($b + $m))) {
        $n = [int][Math]::Round($v * 255)
        if ($n -lt 0) { $n = 0 }
        if ($n -gt 255) { $n = 255 }
        $bytes += $n
    }
    return ('#{0:X2}{1:X2}{2:X2}' -f $bytes[0], $bytes[1], $bytes[2])
}

function Get-Family([string]$name) {
    $n = $name.TrimStart('-')
    $i = $n.LastIndexOf('-')
    if ($i -lt 0) { return 'other' }
    return $n.Substring(0, $i)
}

# Rebuild every token from two anchors. Lightness steps of the original
# ramp are preserved and only shifted by one delta, so the type hierarchy
# (which is mostly a lightness ladder) survives any hue change.
function New-CustomPalette([string]$bgHex, [string]$acHex, $base) {
    $inkRef  = Get-Hsl (ConvertFrom-HexColor $base.'--ink-10')
    $goldRef = Get-Hsl (ConvertFrom-HexColor $base.'--gold-18')

    $bgHsl = $null
    $acHsl = $null
    if ($bgHex) {
        $bgHsl = Get-Hsl (ConvertFrom-HexColor $bgHex)
        if ($bgHsl.L -gt 0.40) {
            Write-Warning ("BgColor {0} is a mid/light colour (L={1:P0}). This card is a dark-base design, so only its hue was borrowed - the base stays dark. Pick something around #2A2350 / #1B3A5C / #1E4A3A for a real match." -f $bgHex, $bgHsl.L)
        }
    }
    if ($acHex) { $acHsl = Get-Hsl (ConvertFrom-HexColor $acHex) }
    if ($bgHsl -and $acHsl) {
        $dh = [Math]::Abs($bgHsl.H - $acHsl.H)
        if ($dh -gt 180) { $dh = 360 - $dh }
        if ($dh -lt 14) {
            Write-Warning ("BgColor and AccentColor are only {0:N0} deg apart in hue. The gold rules will sink into the background. Try an accent in the 35-50 deg (champagne/sand) range." -f $dh)
        }
    }

    $inkDelta = 0.0
    if ($bgHsl) {
        $inkDelta = $bgHsl.L - $inkRef.L
        if ($bgHsl.L -gt 0.40) { $inkDelta = 0.0 }   # keep it dark, only borrow the hue
        if ($inkDelta -lt -0.10) { $inkDelta = -0.10 }
        if ($inkDelta -gt 0.10)  { $inkDelta = 0.10 }
    }
    $goldDelta = 0.0
    if ($acHsl) {
        $goldDelta = $acHsl.L - $goldRef.L
        if ($goldDelta -lt -0.20) { $goldDelta = -0.20 }
        if ($goldDelta -gt 0.14)  { $goldDelta = 0.14 }
    }

    $pal = [ordered]@{}
    foreach ($p in $base.PSObject.Properties) {
        $name = [string]$p.Name
        $hex  = [string]$p.Value
        $fam  = Get-Family $name
        $t    = Get-Hsl (ConvertFrom-HexColor $hex)
        if ($fam -in @('cream', 'neutral')) { $pal[$name] = $hex; continue }

        if ($fam -eq 'gold') {
            if (-not $acHsl) { $pal[$name] = $hex; continue }
            $sr = 1.0
            if ($goldRef.S -gt 0.02) { $sr = $t.S / $goldRef.S }
            $s2 = $acHsl.S * $sr
            if ($s2 -gt 0.72) { $s2 = 0.72 }
            $l2 = $t.L + $goldDelta
            if ($l2 -lt 0.28) { $l2 = 0.28 }
            if ($l2 -gt 0.92) { $l2 = 0.92 }
            $pal[$name] = ConvertTo-HexColor $acHsl.H $s2 $l2
            continue
        }

        # ink / gray / other
        if (-not $bgHsl) { $pal[$name] = $hex; continue }
        $sr = 1.0
        if ($inkRef.S -gt 0.02) { $sr = $t.S / $inkRef.S }
        $s2 = $bgHsl.S * $sr
        if ($s2 -gt 0.62) { $s2 = 0.62 }
        $l2 = $t.L + $inkDelta
        if ($l2 -lt 0.03) { $l2 = 0.03 }
        if ($l2 -gt 0.40) { $l2 = 0.40 }
        $pal[$name] = ConvertTo-HexColor $bgHsl.H $s2 $l2
    }
    return $pal
}

$themeName = 'purple'
if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'theme') -and $cfg.theme) {
    $themeName = [string]$cfg.theme
}
if ($Theme) { $themeName = $Theme }

$bgHex = ''
$acHex = ''
if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'themeCustom') -and $cfg.themeCustom) {
    if ($cfg.themeCustom.PSObject.Properties.Name -contains 'bg' -and $cfg.themeCustom.bg)     { $bgHex = [string]$cfg.themeCustom.bg }
    if ($cfg.themeCustom.PSObject.Properties.Name -contains 'accent' -and $cfg.themeCustom.accent) { $acHex = [string]$cfg.themeCustom.accent }
}
if ($BgColor)     { $bgHex = $BgColor }
if ($AccentColor) { $acHex = $AccentColor }
if ($bgHex -and -not (ConvertFrom-HexColor $bgHex)) {
    Write-Warning "BgColor '$bgHex' is not a hex colour, ignored."
    $bgHex = ''
}
if ($acHex -and -not (ConvertFrom-HexColor $acHex)) {
    Write-Warning "AccentColor '$acHex' is not a hex colour, ignored."
    $acHex = ''
}

if ($bgHex -or $acHex) {
    $themePath = Join-Path $root 'themes.json'
    if (Test-Path -LiteralPath $themePath) {
        $themes = Get-Content -LiteralPath $themePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $pal = New-CustomPalette $bgHex $acHex $themes.purple
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('<style id="card-theme">:root{')
        foreach ($k in $pal.Keys) {
            [void]$sb.Append($k).Append(':').Append([string]$pal[$k]).Append(';')
        }
        [void]$sb.Append('}</style>')
        if ($page -match '</head>') { $page = $page.Replace('</head>', $sb.ToString() + '</head>') }
    }
    else {
        Write-Warning "themes.json not found, custom colours ignored."
    }
}
elseif ($themeName -ne 'purple') {
    $themePath = Join-Path $root 'themes.json'
    if (Test-Path -LiteralPath $themePath) {
        $themes = Get-Content -LiteralPath $themePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $pal = $null
        if ($themes.PSObject.Properties.Name -contains $themeName) {
            $pal = $themes.$themeName
        }
        if ($pal) {
            $sb = New-Object System.Text.StringBuilder
            [void]$sb.Append('<style id="card-theme">:root{')
            foreach ($p in $pal.PSObject.Properties) {
                [void]$sb.Append($p.Name).Append(':').Append([string]$p.Value).Append(';')
            }
            [void]$sb.Append('}</style>')
            if ($page -match '</head>') {
                $page = $page.Replace('</head>', $sb.ToString() + '</head>')
            }
        }
        else {
            Write-Warning "Unknown theme '$themeName'. Known: $(( $themes.PSObject.Properties.Name ) -join ', ')"
        }
    }
    else {
        Write-Warning "themes.json not found, falling back to the default palette."
    }
}

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
