# Garry's PAD content pack

`New-GarrysPADContentPack.ps1` creates a portable ZIP from a user-owned Steam
Garry's Mod installation. The default `Playable` profile contains GMod's base
Lua, gamemodes, HTML menu, backgrounds, UI resources, particles and scenes;
the stock `gm_construct` and `gm_flatgrass` payloads; and the GMod, HL2,
platform, texture, model, and non-voice sound VPK families needed by the iPad
runtime.

It deliberately excludes personal and mutable content:

- addons and Workshop/download content;
- cache, data, demos, dupes, saves, and screenshots;
- cfg, settings, logs, databases, and user configuration; and
- unlisted loose maps and generated navigation graphs.

Every payload is streamed directly into a Zip64 archive and recorded by path,
size, and SHA-256 in `GarrysPADContentManifest.json`. Source VPKs and compressed
images are stored without a redundant recompression pass. Reparse points and
unsafe archive paths are rejected.

## Create the recommended pack

```powershell
pwsh -NoProfile -File .\Tools\ContentPack\New-GarrysPADContentPack.ps1 `
  -GModInstallRoot 'C:\Program Files (x86)\Steam\steamapps\common\GarrysMod' `
  -OutputPath 'H:\GarrysPAD_Content_Playable.zip'
```

Use `-PlanOnly` to print the file and byte counts without writing a ZIP.

The optional `CompleteBase` profile additionally includes the Counter-Strike
content and English HL2 voice VPK families shipped in this installation:

```powershell
pwsh -NoProfile -File .\Tools\ContentPack\New-GarrysPADContentPack.ps1 `
  -GModInstallRoot 'C:\Program Files (x86)\Steam\steamapps\common\GarrysMod' `
  -OutputPath 'H:\GarrysPAD_Content_CompleteBase.zip' `
  -Profile CompleteBase
```

## Verify a pack

Verification rereads and hashes every uncompressed payload, checks the exact
manifest/file relationship, rejects unsafe or excluded paths, and requires the
GMod, HL2, texture, sound, platform, HTML, and two-map roots:

```powershell
pwsh -NoProfile -File .\Tools\ContentPack\Test-GarrysPADContentPack.ps1 `
  -Path 'H:\GarrysPAD_Content_Playable.zip'
```

The ZIP contains no game executable and cannot be launched by itself. It is a
content source for Garry's PAD's importer. Keep it private unless the project
owner has separately approved redistribution of the packed game data.
