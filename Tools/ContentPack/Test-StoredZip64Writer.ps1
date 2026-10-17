$ErrorActionPreference = 'Stop'
Add-Type -Path (Join-Path $PSScriptRoot 'StoredZip64Writer.cs')
Add-Type -AssemblyName System.IO.Compression
$fixtureDirectory = Join-Path $PSScriptRoot '../ContentPackGUI/dist/writer-tests'
New-Item -ItemType Directory -Force -Path $fixtureDirectory | Out-Null
$path = Join-Path $fixtureDirectory ([guid]::NewGuid().ToString('N') + '.zip')
$stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew)
$archive = [GarrysPADStoredZip64Writer]::new($stream)
$expected = [ordered]@{
    'empty.bin' = [byte[]]@()
    'materials/test.bin' = [Text.Encoding]::UTF8.GetBytes('123456789')
    ('unicode/' + [char]0x65e5 + '.txt') = [Text.Encoding]::UTF8.GetBytes('owned-fixture')
}
try {
    foreach ($name in $expected.Keys) {
        $entry = $archive.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal)
        $payload = $entry.Open()
        try { $payload.Write($expected[$name], 0, $expected[$name].Length) }
        finally { $payload.Dispose() }
    }
    $archive.Dispose()
} finally { $stream.Dispose() }
$readStream = [IO.File]::OpenRead($path)
$readArchive = [IO.Compression.ZipArchive]::new($readStream, [IO.Compression.ZipArchiveMode]::Read)
try {
    if ($readArchive.Entries.Count -ne $expected.Count) { throw 'Wrong entry count' }
    foreach ($name in $expected.Keys) {
        $entry = $readArchive.GetEntry($name)
        if (!$entry -or $entry.Length -ne $expected[$name].Length) { throw "Wrong size/name: $name" }
        $memory = [IO.MemoryStream]::new()
        $reader = $entry.Open()
        try { $reader.CopyTo($memory); $actual = $memory.ToArray() }
        finally { $reader.Dispose(); $memory.Dispose() }
        if ([Convert]::ToBase64String($actual) -ne [Convert]::ToBase64String($expected[$name])) { throw "Payload mismatch: $name" }
    }
} finally { $readArchive.Dispose(); $readStream.Dispose() }
Write-Host "Stored Zip64 round-trip passed: $path"
