#Requires -Version 5.1
<#
    ===========================================================================
    Telif Hakki (c) 2026 Alper Ibrahimagaoglu - Tum Haklari Saklidir.
    Copyright (c) 2026 Alper Ibrahimagaoglu - All Rights Reserved.

    Bu dosya tescilli (proprietary) yazilimdir. Yalnizca kisisel ve egitim
    amacli olarak GORUNTULENEBILIR ve DEGISTIRILMEDEN calistirilabilir.

    Telif sahibinin yazili izni olmadan YASAKTIR:
      * Degistirme, uyarlama, turev eser olusturma (No Derivatives)
      * Kopyalama, yeniden dagitma, aynalama, baska bir depoda/platformda
        yayimlama (No Redistribution)
      * Ticari kullanim, satis, kiralama, alt lisanslama (No Commercial Use)
      * Bu telif basligini kaldirma veya degistirme

    Tum kosullar icin depodaki LICENSE dosyasina bakiniz.
    https://github.com/alperagaoglu61/toplu-uygulama-indir

    GARANTI YOKTUR. Yazilim internetten dosya indirir; indirilen dosyalarin
    icerigi ve guvenligi telif sahibinin sorumlulugunda degildir. Tum risk
    kullaniciya aittir.
    ===========================================================================
#>
<#
.SYNOPSIS
    apps.json'daki ikon sluglarindan WPF ikon kaynagi uretir.

.DESCRIPTION
    Simge kaynagi: simple-icons (CC0). Her slug icin SVG path verisi ve markanin
    resmi hex rengi indirilip tek bir ResourceDictionary'ye yazilir. GUI bu sozlugu
    derleme zamaninda gomer, calisma aninda internet gerekmez.

    Slug'i olmayan (simple-icons'ta bulunmayan) programlar GUI'de harf kutucugu ile
    gosterilir; bu script onlari sadece raporlar.

    Cikti: src\ToplulIndirGui\Assets\Ikonlar.xaml

.EXAMPLE
    pwsh -File .\tools\IkonUret.ps1
#>

[CmdletBinding()]
param(
    [string]$AppsJson,
    [string]$Cikti
)

$ErrorActionPreference = 'Stop'
$kok = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

if (-not $AppsJson) { $AppsJson = Join-Path $kok 'apps.json' }
if (-not $Cikti)    { $Cikti    = Join-Path $kok 'src\ToplulIndirGui\Assets\Ikonlar.xaml' }

$veriUrl = 'https://raw.githubusercontent.com/simple-icons/simple-icons/master/data/simple-icons.json'
$svgUrl  = 'https://raw.githubusercontent.com/simple-icons/simple-icons/master/icons/{0}.svg'
$ua      = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'

# simple-icons baslik -> slug donusumu (kutuphanenin kendi kurali).
function ConvertTo-Slug {
    param([string]$Baslik)
    $s = $Baslik.ToLowerInvariant()
    $s = $s -replace '\+', 'plus'
    $s = $s -replace '\.', 'dot'
    $s = $s -replace '&', 'and'
    $s = $s -replace 'đ', 'd'
    $s = $s -replace 'ħ', 'h'
    $s = $s -replace 'ı', 'i'
    $s = $s -replace 'ĸ', 'k'
    $s = $s -replace 'ŀ', 'l'
    $s = $s -replace 'ł', 'l'
    $s = $s -replace 'ß', 'ss'
    $s = $s -replace 'ŧ', 't'
    $s = [Text.Encoding]::ASCII.GetString(
        [Text.Encoding]::GetEncoding('Cyrillic').GetBytes(
            $s.Normalize([Text.NormalizationForm]::FormD)))
    $s = $s -replace '[^a-z0-9]', ''
    return $s
}

Write-Host '  simple-icons verisi indiriliyor...' -ForegroundColor DarkGray
$veri = Invoke-RestMethod -Uri $veriUrl -UserAgent $ua -TimeoutSec 120

$renkler = @{}
foreach ($e in $veri) {
    $slug = if ($e.PSObject.Properties['slug'] -and $e.slug) { [string]$e.slug } else { ConvertTo-Slug $e.title }
    if (-not $renkler.ContainsKey($slug)) { $renkler[$slug] = [string]$e.hex }
}
Write-Host ("  {0} marka kaydi okundu." -f $renkler.Count) -ForegroundColor DarkGray

$apps = (Get-Content -LiteralPath $AppsJson -Raw -Encoding UTF8 | ConvertFrom-Json).programlar
$sluglar = $apps | Where-Object { $_.ikon } | ForEach-Object { [string]$_.ikon } | Sort-Object -Unique

$bulunan = @()
$eksik   = @()

foreach ($slug in $sluglar) {
    try {
        $svg = Invoke-WebRequest -Uri ($svgUrl -f $slug) -UseBasicParsing -UserAgent $ua -TimeoutSec 60
    } catch {
        $eksik += $slug
        continue
    }

    $m = [regex]::Match([string]$svg.Content, '<path\s+d="([^"]+)"')
    if (-not $m.Success) { $eksik += $slug; continue }

    $hex = if ($renkler.ContainsKey($slug)) { $renkler[$slug] } else { '8A8A86' }

    $bulunan += [pscustomobject]@{
        Slug = $slug
        Path = $m.Groups[1].Value
        Hex  = '#FF' + $hex.TrimStart('#').ToUpperInvariant()
    }
}

$satirlar = New-Object Collections.Generic.List[string]
$satirlar.Add('<!--')
$satirlar.Add('    ===========================================================================')
$satirlar.Add('    Telif Hakki (c) 2026 Alper Ibrahimagaoglu - Tum Haklari Saklidir.')
$satirlar.Add('    Copyright (c) 2026 Alper Ibrahimagaoglu - All Rights Reserved.')
$satirlar.Add('')
$satirlar.Add('    Bu dosya tescilli (proprietary) yazilimdir. Yalnizca kisisel ve egitim')
$satirlar.Add('    amacli olarak GORUNTULENEBILIR ve DEGISTIRILMEDEN calistirilabilir.')
$satirlar.Add('')
$satirlar.Add('    Telif sahibinin yazili izni olmadan YASAKTIR:')
$satirlar.Add('      * Degistirme, uyarlama, turev eser olusturma (No Derivatives)')
$satirlar.Add('      * Kopyalama, yeniden dagitma, aynalama, baska bir depoda/platformda')
$satirlar.Add('        yayimlama (No Redistribution)')
$satirlar.Add('      * Ticari kullanim, satis, kiralama, alt lisanslama (No Commercial Use)')
$satirlar.Add('      * Bu telif basligini kaldirma veya degistirme')
$satirlar.Add('')
$satirlar.Add('    Tum kosullar icin depodaki LICENSE dosyasina bakiniz.')
$satirlar.Add('    https://github.com/alperagaoglu61/toplu-uygulama-indir')
$satirlar.Add('')
$satirlar.Add('    GARANTI YOKTUR. Yazilim internetten dosya indirir; indirilen dosyalarin')
$satirlar.Add('    icerigi ve guvenligi telif sahibinin sorumlulugunda degildir. Tum risk')
$satirlar.Add('    kullaniciya aittir.')
$satirlar.Add('    ===========================================================================')
$satirlar.Add('')
$satirlar.Add('    URETILMIS DOSYA - elle duzenleme, tools\IkonUret.ps1 ile yeniden uret.')
$satirlar.Add('    Kaynak: simple-icons (CC0). Marka ikonlari kendi resmi hex rengiyle cizilir.')
$satirlar.Add(('    Uretim: {0} - {1} ikon' -f (Get-Date -Format 'yyyy-MM-dd'), $bulunan.Count))
$satirlar.Add('-->')
$satirlar.Add('<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"')
$satirlar.Add('                    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">')
$satirlar.Add('')

foreach ($b in ($bulunan | Sort-Object Slug)) {
    $satirlar.Add(('  <Geometry x:Key="ikon.{0}">{1}</Geometry>' -f $b.Slug, $b.Path))
    $satirlar.Add(('  <SolidColorBrush x:Key="renk.{0}" Color="{1}" />' -f $b.Slug, $b.Hex))
}

$satirlar.Add('')
$satirlar.Add('</ResourceDictionary>')

$klasor = Split-Path -Parent $Cikti
if (-not (Test-Path -LiteralPath $klasor)) { New-Item -ItemType Directory -Path $klasor -Force | Out-Null }
[IO.File]::WriteAllText($Cikti, ($satirlar -join "`r`n") + "`r`n", (New-Object Text.UTF8Encoding $false))

Write-Host ''
Write-Host ('  Yazildi: {0}' -f $Cikti) -ForegroundColor Green
Write-Host ('  Ikon: {0} bulundu, {1} eksik' -f $bulunan.Count, $eksik.Count) -ForegroundColor Gray
if ($eksik) {
    Write-Host ('  Eksik slug (harf kutucugu kullanilacak): {0}' -f ($eksik -join ', ')) -ForegroundColor Yellow
}
