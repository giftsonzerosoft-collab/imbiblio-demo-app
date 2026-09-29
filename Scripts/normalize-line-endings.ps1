# Normalises text files to LF and UTF-8 (no BOM).
#
# Required because Windows PowerShell's Set-Content / Out-File write CRLF by
# default, which breaks Xcode and XcodeGen. .gitattributes prevents this for
# files that travel through git, but it cannot help files edited in place.
#
# Usage (from the repository root):
#   powershell -ExecutionPolicy Bypass -File Scripts/normalize-line-endings.ps1

param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'

# Matches the text/binary rules in .gitattributes.
$textPatterns = @('*.swift', '*.yml', '*.yaml', '*.json', '*.plist', '*.pbxproj',
    '*.xcconfig', '*.entitlements', '*.md', '*.py', '*.sh', '*.xcscheme',
    '.gitattributes', '.gitignore', 'LICENSE*')

# Never touch these: rewriting them risks corrupting them.
$skipDirectories = @('.git', '.build', 'DerivedData', 'node_modules', '*.xcassets')
$binaryPatterns = @('*.png', '*.jpg', '*.jpeg', '*.gif', '*.pdf', '*.wav', '*.mp3',
    '*.m4a', '*.epub', '*.ttf', '*.otf', '*.zip')

function Test-Skipped {
    param([System.IO.FileInfo]$File)
    $relative = $File.FullName.Substring($Root.Length).TrimStart('\', '/')
    foreach ($segment in $relative -split '[\\/]') {
        foreach ($skip in $skipDirectories) {
            if ($segment -like $skip.Replace('*', '')) { return $true }
        }
    }
    foreach ($pattern in $binaryPatterns) {
        if ($File.Name -like $pattern) { return $true }
    }
    return $false
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$changed = 0

$files = Get-ChildItem -Path $Root -Recurse -File -Force |
    Where-Object { $_.FullName -notmatch '\\\.git\\|\\\.build\\' }

foreach ($file in $files) {
    $isText = $false
    foreach ($pattern in $textPatterns) {
        if ($file.Name -like $pattern) { $isText = $true; break }
    }
    if (-not $isText) { continue }
    if (Test-Skipped $file) { continue }

    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    if ($bytes.Length -eq 0) { continue }

    # Skip genuine binaries that happen to match a text glob.
    if ($bytes -contains 0) { continue }

    $text = $utf8NoBom.GetString($bytes)
    $normalized = $text -replace "`r`n", "`n" -replace "`r", "`n"

    # Strip a UTF-8 BOM if present.
    $hadBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    if ($hadBom) { $normalized = $normalized.TrimStart([char]0xFEFF) }

    $originalBytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    if ($hadBom -or $normalized -ne $text) {
        [System.IO.File]::WriteAllText($file.FullName, $normalized, $utf8NoBom)
        $changed++
        Write-Host "  normalized: $($file.FullName.Substring($Root.Length).TrimStart('\'))"
        continue
    }
    if ($originalBytes.Length -ne $bytes.Length) {
        [System.IO.File]::WriteAllText($file.FullName, $normalized, $utf8NoBom)
        $changed++
    }
}

Write-Host ""
Write-Host "Line endings normalized in $changed file(s)."
