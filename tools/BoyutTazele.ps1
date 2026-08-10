#Requires -Version 5.1
<#
.SYNOPSIS
    apps.json'daki her programin indirme boyutunu olcup "boyutTahmini" alanina yazar.

.DESCRIPTION
    Dosya indirilmez: scriptin kendi motoru (TopluIndir.Engine.Probe) ile
    Range: bytes=0-0 istegi atilir, sunucunun bildirdigi toplam boyut alinir.
    Boyut ogrenilemeyen kayitlarin alani 0 kalir; GUI o satirda boyut gostermez.

    "cozucu" isaretli kayitlar (ornek: GPU-Z) her calistirmada yeni imzali link
    urettigi icin -CozuculuDahil verilmedikce atlanir.

.EXAMPLE
    pwsh -File .\tools\BoyutTazele.ps1
#>

[CmdletBinding()]
param(
    [string]$AppsJson,
    [switch]$CozuculuDahil
)

$ErrorActionPreference = 'Stop'
$kok = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $AppsJson) { $AppsJson = Join-Path $kok 'apps.json' }

. (Join-Path $kok 'ProgramIndir.ps1') -SadeceYukle
Initialize-Motor

$veri = Get-Content -LiteralPath $AppsJson -Raw -Encoding UTF8 | ConvertFrom-Json
$apps = Get-Programlar -Yol $AppsJson

$basarili = 0
$atlanan  = 0

foreach ($app in $apps) {
    $kayit = $veri.programlar | Where-Object { $_.ad -eq $app.ad } | Select-Object -First 1
    if (-not $kayit) { continue }

    if ($app.cozucu -and -not $CozuculuDahil) {
        Write-Host ('  {0,-38} atlandi (cozucu: {1})' -f $app.ad, $app.cozucu) -ForegroundColor DarkGray
        $atlanan++
        continue
    }

    try {
        $urls = [string[]](Resolve-AppUrls -App $app)
        $job  = [TopluIndir.Engine]::Probe($urls, [string]$app.referer)
        $boyut = [long]$job.Total

        if ($boyut -gt 0) {
            $kayit | Add-Member -NotePropertyName 'boyutTahmini' -NotePropertyValue $boyut -Force
            Write-Host ('  {0,-38} {1,10:N0} bayt' -f $app.ad, $boyut) -ForegroundColor Gray
            $basarili++
        } else {
            Write-Host ('  {0,-38} boyut bildirilmedi' -f $app.ad) -ForegroundColor DarkYellow
            $atlanan++
        }
    } catch {
        Write-Host ('  {0,-38} HATA: {1}' -f $app.ad, (ConvertTo-SadeHata $_.Exception.Message)) -ForegroundColor DarkRed
        $atlanan++
    }
}

[IO.File]::WriteAllText($AppsJson, ($veri | ConvertTo-Json -Depth 6) + "`r`n",
    (New-Object Text.UTF8Encoding $true))

Write-Host ''
Write-Host ('  Yazildi: {0} - {1} boyut guncellendi, {2} atlandi' -f $AppsJson, $basarili, $atlanan) -ForegroundColor Green
