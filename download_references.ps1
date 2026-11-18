<#
.SYNOPSIS
    Downloads the authoritative reference manuals listed in REFERENCES.md into downloaded_references/.

.DESCRIPTION
    Parses REFERENCES.md for all entries containing "**Web Source:**" and "**Local File:**" markdown links,
    and downloads each reference manual to its specified local path. Keeps REFERENCES.md as the single
    source of truth.

.PARAMETER Force
    Re-download files even if they already exist locally.
#>
[CmdletBinding()]
param (
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

$RepoRoot = $PSScriptRoot
$ReferencesMdPath = Join-Path $RepoRoot 'REFERENCES.md'

if (-not (Test-Path $ReferencesMdPath)) {
    throw "Could not find REFERENCES.md at: $ReferencesMdPath"
}

# Parse REFERENCES.md line-by-line to extract (Title, WebUrl, LocalPath) tuples
$lines = Get-Content -Path $ReferencesMdPath -Encoding UTF8
$entries = @()
$currentTitle = $null
$currentWebUrl = $null
$currentLocalPath = $null

foreach ($line in $lines) {
    if ($line -match '^###\s+(.+)$') {
        $currentTitle = $Matches[1].Trim()
        $currentWebUrl = $null
        $currentLocalPath = $null
    }
    elseif ($line -match '\*\*Web Source:\*\*\s*\[[^\]]+\]\(([^)]+)\)') {
        $currentWebUrl = $Matches[1].Trim()
    }
    elseif ($line -match '\*\*Local File:\*\*\s*\[[^\]]+\]\(([^)]+)\)') {
        $currentLocalPath = $Matches[1].Trim()
        if ($currentTitle -and $currentWebUrl -and $currentLocalPath) {
            $entries += [PSCustomObject]@{
                Title     = $currentTitle
                WebUrl    = $currentWebUrl
                LocalPath = $currentLocalPath
            }
            $currentWebUrl = $null
            $currentLocalPath = $null
        }
    }
}

if ($entries.Count -eq 0) {
    throw "No reference entries with '**Web Source:**' and '**Local File:**' were found in REFERENCES.md."
}

Write-Host "Found $($entries.Count) reference manuals in REFERENCES.md.`n" -ForegroundColor Cyan

$headers = @{
    'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
}

$succeeded = 0
$skipped = 0
$failed = 0

foreach ($entry in $entries) {
    $destPath = Join-Path $RepoRoot ($entry.LocalPath -replace '/', [IO.Path]::DirectorySeparatorChar)
    $destDir = Split-Path -Parent $destPath

    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    if ((Test-Path $destPath) -and -not $Force) {
        $sizeMB = [Math]::Round((Get-Item $destPath).Length / 1MB, 2)
        Write-Host "[SKIP] $($entry.Title)" -ForegroundColor DarkGray
        Write-Host "       Already exists at $($entry.LocalPath) ($sizeMB MB). Use -Force to re-download." -ForegroundColor DarkGray
        $skipped++
        continue
    }

    Write-Host "[DOWN] $($entry.Title)" -ForegroundColor Yellow
    Write-Host "       From: $($entry.WebUrl)" -ForegroundColor Gray
    Write-Host "       To:   $($entry.LocalPath)" -ForegroundColor Gray

    $downloadUrl = $entry.WebUrl
    $tempFile = "$destPath.part"

    try {
        # Special handling for WCH datasheet HTML landing pages (e.g., https://www.wch-ic.com/downloads/CH9350DS_PDF.html)
        if ($downloadUrl -match '^https?://(www\.)?wch(-ic\.com|\.cn)/downloads/.+_PDF\.html$') {
            $pageResp = Invoke-WebRequest -Uri $downloadUrl -Headers $headers -UseBasicParsing
            if ($pageResp.Content -match 'href="(/downloads/file/\d+\.html)"') {
                $uri = [Uri]$downloadUrl
                $downloadUrl = "$($uri.Scheme)://$($uri.Host)$($Matches[1])"
                Write-Host "       Resolved WCH file link: $downloadUrl" -ForegroundColor DarkCyan
            }
        }

        Invoke-WebRequest -Uri $downloadUrl -OutFile $tempFile -Headers $headers -UseBasicParsing

        # Verify the downloaded file starts with the %PDF- magic header (compatible with both PS 5.1 and PS 7+)
        $firstBytes = New-Object byte[] 5
        $fs = [System.IO.File]::OpenRead($tempFile)
        try {
            $bytesRead = $fs.Read($firstBytes, 0, 5)
        }
        finally {
            $fs.Close()
        }
        $magic = [System.Text.Encoding]::ASCII.GetString($firstBytes, 0, $bytesRead)
        if ($magic -ne '%PDF-') {
            Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
            throw "Downloaded file did not have a valid '%PDF-' header (got '$magic'). The source URL may require manual browser download."
        }

        Move-Item -Path $tempFile -Destination $destPath -Force
        $sizeMB = [Math]::Round((Get-Item $destPath).Length / 1MB, 2)
        Write-Host "       [OK] Saved ($sizeMB MB)`n" -ForegroundColor Green
        $succeeded++
    }
    catch {
        if (Test-Path $tempFile) {
            Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
        }
        Write-Host "       [ERROR] Failed to download $($entry.Title): $($_.Exception.Message)`n" -ForegroundColor Red
        $failed++
    }
}

Write-Host "Summary: $succeeded downloaded, $skipped skipped, $failed failed." -ForegroundColor Cyan
if ($failed -gt 0) {
    exit 1
}
