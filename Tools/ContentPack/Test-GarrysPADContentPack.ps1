[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Convert-BytesToLowerHex {
    param([byte[]] $Bytes)

    return -join @($Bytes | ForEach-Object { $_.ToString('x2') })
}

$resolved = [System.IO.Path]::GetFullPath($Path)
if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
    throw "Content pack does not exist: $resolved"
}

Add-Type -AssemblyName System.IO.Compression
$stream = [System.IO.File]::OpenRead($resolved)
$archive = [System.IO.Compression.ZipArchive]::new(
    $stream,
    [System.IO.Compression.ZipArchiveMode]::Read,
    $false
)
try {
    $entries = @($archive.Entries)
    $manifestEntries = @($entries | Where-Object { $_.FullName -ceq 'GarrysPADContentManifest.json' })
    if ($manifestEntries.Count -ne 1) {
        throw 'Content pack must contain exactly one root manifest.'
    }

    $unsafe = @(
        $entries | Where-Object {
            [System.IO.Path]::IsPathRooted($_.FullName) -or
            $_.FullName.Contains('\') -or
            $_.FullName -match '(^|/)\.\.(/|$)' -or
            $_.FullName -eq '.git' -or
            $_.FullName.StartsWith('.git/')
        }
    )
    if ($unsafe.Count -ne 0) {
        throw "Unsafe ZIP entry: $($unsafe[0].FullName)"
    }

    $reader = [System.IO.StreamReader]::new(
        $manifestEntries[0].Open(),
        [System.Text.UTF8Encoding]::new($false),
        $true
    )
    try {
        $manifest = $reader.ReadToEnd() | ConvertFrom-Json
    }
    finally {
        $reader.Dispose()
    }

    if ([int] $manifest.schemaVersion -ne 1 -or [string] $manifest.format -cne 'GarrysPADContentPack') {
        throw 'Unsupported content-pack manifest.'
    }
    if ([string] $manifest.profile -notin @('Playground', 'Playable', 'CompleteBase')) {
        throw "Unsupported content-pack profile: $($manifest.profile)"
    }

    $payloadEntries = @($entries | Where-Object { $_.FullName -cne 'GarrysPADContentManifest.json' })
    $manifestFiles = @($manifest.files)
    if ([int] $manifest.fileCount -ne $manifestFiles.Count -or $payloadEntries.Count -ne $manifestFiles.Count) {
        throw 'Manifest and ZIP file counts disagree.'
    }

    $byName = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($entry in $payloadEntries) {
        if ($entry.FullName.EndsWith('/')) {
            throw "Unexpected directory entry: $($entry.FullName)"
        }
        if ($byName.ContainsKey($entry.FullName)) {
            throw "Duplicate ZIP entry: $($entry.FullName)"
        }
        $byName.Add($entry.FullName, $entry)
    }

    $totalBytes = [int64] 0
    $checked = 0
    foreach ($declared in $manifestFiles) {
        $logicalPath = [string] $declared.path
        if (-not $byName.ContainsKey($logicalPath)) {
            throw "Manifest entry is absent from ZIP: $logicalPath"
        }
        $entry = [System.IO.Compression.ZipArchiveEntry] $byName[$logicalPath]
        if ($entry.Length -ne [int64] $declared.byteCount) {
            throw "Byte-count mismatch: $logicalPath"
        }

        $entryStream = $entry.Open()
        $hasher = [System.Security.Cryptography.IncrementalHash]::CreateHash(
            [System.Security.Cryptography.HashAlgorithmName]::SHA256
        )
        $buffer = [byte[]]::new(4MB)
        try {
            while (($read = $entryStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $hasher.AppendData($buffer, 0, $read)
            }
            $actualHash = Convert-BytesToLowerHex -Bytes $hasher.GetHashAndReset()
        }
        finally {
            $hasher.Dispose()
            $entryStream.Dispose()
        }
        if ($actualHash -cne [string] $declared.sha256) {
            throw "SHA-256 mismatch: $logicalPath"
        }
        $totalBytes += $entry.Length
        $checked += 1
        if ($checked % 250 -eq 0 -or $checked -eq $manifestFiles.Count) {
            Write-Host "Verified $checked/$($manifestFiles.Count) files"
        }
    }

    if ($totalBytes -ne [int64] $manifest.byteCount) {
        throw 'Manifest aggregate byte count is incorrect.'
    }

    $requiredPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($required in @(
        'garrysmod/html/menu.html',
        'garrysmod/maps/gm_construct.bsp',
        'garrysmod/maps/gm_flatgrass.bsp'
    )) {
        $requiredPaths.Add($required)
    }
    if ([string] $manifest.profile -ne 'Playground') {
        foreach ($required in @(
            'garrysmod/garrysmod_dir.vpk',
            'sourceengine/content_hl2_dir.vpk',
            'sourceengine/hl2_misc_dir.vpk',
            'sourceengine/hl2_sound_misc_dir.vpk',
            'sourceengine/hl2_textures_dir.vpk',
            'platform/platform_misc_dir.vpk'
        )) {
            $requiredPaths.Add($required)
        }
    }
    foreach ($required in $requiredPaths) {
        if (-not $byName.ContainsKey($required)) {
            throw "Required playable content is missing: $required"
        }
    }

    $forbiddenPrefixes = @(
        'garrysmod/addons/',
        'garrysmod/cache/',
        'garrysmod/cfg/',
        'garrysmod/data/',
        'garrysmod/demos/',
        'garrysmod/downloadlists/',
        'garrysmod/dupes/',
        'garrysmod/saves/',
        'garrysmod/screenshots/',
        'garrysmod/settings/'
    )
    foreach ($name in $byName.Keys) {
        foreach ($prefix in $forbiddenPrefixes) {
            if ($name.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Excluded content is present: $name"
            }
        }
    }

    $zipHash = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Host 'Garry''s PAD content pack: PASS'
    Write-Host "Profile: $($manifest.profile)"
    Write-Host "Files: $($manifest.fileCount)"
    Write-Host "Payload bytes: $($manifest.byteCount)"
    Write-Host "ZIP bytes: $((Get-Item -LiteralPath $resolved).Length)"
    Write-Host "ZIP SHA-256: $zipHash"
}
finally {
    $archive.Dispose()
    $stream.Dispose()
}
