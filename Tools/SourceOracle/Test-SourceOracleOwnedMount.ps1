[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Assert-OwnedMount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [bool]$Condition,
        [Parameter(Mandatory)] [string]$Message
    )
    if (-not $Condition) { throw $Message }
}

function Assert-OwnedMountThrows {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [scriptblock]$Action,
        [Parameter(Mandatory)] [string]$Message
    )

    $didThrow = $false
    try { & $Action }
    catch { $didThrow = $true }
    if (-not $didThrow) { throw $Message }
}

function Write-OwnedMountFixture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Contents
    )
    $parent = [IO.Path]::GetDirectoryName($Path)
    if (-not [IO.Directory]::Exists($parent)) {
        [void][IO.Directory]::CreateDirectory($parent)
    }
    [IO.File]::WriteAllText(
        $Path,
        $Contents,
        [Text.UTF8Encoding]::new($false, $true)
    )
}

function New-OwnedMountMarkerText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$RunID,
        [Parameter(Mandatory)] [string]$MountToken
    )
    return "SOURCE_ORACLE_OWNED_MOUNT_V1`nrun_id=$RunID`nmount_token=$MountToken`n"
}

$sourcePath = Join-Path $PSScriptRoot 'SourceOracleOwnedMount.cs'
if ($null -eq ('SourceOracleOwnedMount' -as [type])) {
    Add-Type -Path $sourcePath
}
if ($null -eq ('SourceOracleOwnedMountReparseProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class SourceOracleOwnedMountReparseProbe
{
    private const uint GenericWrite = 0x40000000;
    private const uint FileShareRead = 0x00000001;
    private const uint FileShareWrite = 0x00000002;
    private const uint FileShareDelete = 0x00000004;
    private const uint OpenExisting = 3;
    private const uint FileFlagOpenReparsePoint = 0x00200000;
    private const uint FileFlagBackupSemantics = 0x02000000;
    private const uint FsctlSetReparsePoint = 0x000900A4;
    private const uint IoReparseTagMountPoint = 0xA0000003;

    public static bool TrySetJunction(
        string existingDirectory,
        string targetDirectory,
        out int error)
    {
        error = 0;
        IntPtr handle = CreateFile(
            Path.GetFullPath(existingDirectory),
            GenericWrite,
            FileShareRead | FileShareWrite | FileShareDelete,
            IntPtr.Zero,
            OpenExisting,
            FileFlagOpenReparsePoint | FileFlagBackupSemantics,
            IntPtr.Zero);
        if (handle == new IntPtr(-1))
        {
            error = Marshal.GetLastWin32Error();
            return false;
        }

        try
        {
            string target = Path.GetFullPath(targetDirectory).TrimEnd('\\');
            string substitute = target.StartsWith("\\\\", StringComparison.Ordinal)
                ? "\\??\\UNC\\" + target.Substring(2)
                : "\\??\\" + target;
            string print = target;
            byte[] substituteBytes = Encoding.Unicode.GetBytes(substitute);
            byte[] printBytes = Encoding.Unicode.GetBytes(print);
            int printOffset = substituteBytes.Length + 2;
            int pathBytesLength = printOffset + printBytes.Length + 2;
            int reparseDataLength = 8 + pathBytesLength;
            byte[] buffer = new byte[8 + reparseDataLength];

            WriteUInt32(buffer, 0, IoReparseTagMountPoint);
            WriteUInt16(buffer, 4, checked((ushort)reparseDataLength));
            WriteUInt16(buffer, 6, 0);
            WriteUInt16(buffer, 8, 0);
            WriteUInt16(buffer, 10, checked((ushort)substituteBytes.Length));
            WriteUInt16(buffer, 12, checked((ushort)printOffset));
            WriteUInt16(buffer, 14, checked((ushort)printBytes.Length));
            Buffer.BlockCopy(substituteBytes, 0, buffer, 16, substituteBytes.Length);
            Buffer.BlockCopy(printBytes, 0, buffer, 16 + printOffset, printBytes.Length);

            uint returned;
            bool result = DeviceIoControl(
                handle,
                FsctlSetReparsePoint,
                buffer,
                (uint)buffer.Length,
                IntPtr.Zero,
                0,
                out returned,
                IntPtr.Zero);
            if (!result)
            {
                error = Marshal.GetLastWin32Error();
            }
            return result;
        }
        finally
        {
            CloseHandle(handle);
        }
    }

    private static void WriteUInt16(byte[] buffer, int offset, ushort value)
    {
        byte[] bytes = BitConverter.GetBytes(value);
        Buffer.BlockCopy(bytes, 0, buffer, offset, bytes.Length);
    }

    private static void WriteUInt32(byte[] buffer, int offset, uint value)
    {
        byte[] bytes = BitConverter.GetBytes(value);
        Buffer.BlockCopy(bytes, 0, buffer, offset, bytes.Length);
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFile(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DeviceIoControl(
        IntPtr device,
        uint controlCode,
        byte[] input,
        uint inputSize,
        IntPtr output,
        uint outputSize,
        out uint bytesReturned,
        IntPtr overlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);
}
'@
}

$temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$temporaryRoot = [IO.Path]::Combine(
    $temporaryBase,
    'SourceOracleOwnedMountTest_' + [guid]::NewGuid().ToString('N')
)
$gameRoot = Join-Path $temporaryRoot 'game'
$addonsRoot = Join-Path $gameRoot 'addons'
$sourceRoot = Join-Path $temporaryRoot 'source'
$unrelatedPath = Join-Path $addonsRoot 'unrelated_user_addon'
$swapCandidate = Join-Path $addonsRoot 'unrelated_swap_candidate'
$junctionSource = Join-Path $temporaryRoot 'source_with_reparse'
$junctionPath = Join-Path $junctionSource 'external_link'
$junctionTarget = Join-Path $temporaryRoot 'junction_target'
$junctionSentinel = Join-Path $junctionTarget 'outside_sentinel.txt'
$unguardedProbe = Join-Path $temporaryRoot 'unguarded_reparse_probe'
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$mounts = [Collections.Generic.List[IDisposable]]::new()
$safeToRecursivelyRemove = $false

$runNormal = '11111111111111111111111111111111'
$runMarkerMismatch = '22222222222222222222222222222222'
$runIDMismatch = '33333333333333333333333333333333'
$runReparse = '44444444444444444444444444444444'
$runUnknown = '55555555555555555555555555555555'

try {
    [void][IO.Directory]::CreateDirectory($addonsRoot)
    [void][IO.Directory]::CreateDirectory($sourceRoot)
    [void][IO.Directory]::CreateDirectory($unrelatedPath)
    [void][IO.Directory]::CreateDirectory($swapCandidate)
    [void][IO.Directory]::CreateDirectory((Join-Path $sourceRoot 'copy_guard_probe'))
    [void][IO.Directory]::CreateDirectory((Join-Path $sourceRoot 'generated_parent'))
    [void][IO.Directory]::CreateDirectory($junctionTarget)
    Write-OwnedMountFixture -Path $junctionSentinel -Contents 'outside'
    Write-OwnedMountFixture `
        -Path (Join-Path $sourceRoot 'lua\garryspad_oracle\init.lua') `
        -Contents 'return "owned-mount-fixture"'
    Write-OwnedMountFixture `
        -Path (Join-Path $sourceRoot 'materials\fixture.vmt') `
        -Contents '"UnlitGeneric" { "$basetexture" "fixture" }'
    Write-OwnedMountFixture `
        -Path (Join-Path $unrelatedPath 'keep.txt') `
        -Contents 'must survive mount cleanup'
    Write-OwnedMountFixture `
        -Path (Join-Path $swapCandidate 'keep.txt') `
        -Contents 'must not become the owned target'

    # Prove that the test probe can perform an actual in-place
    # FSCTL_SET_REPARSE_POINT against an unguarded empty directory.
    [void][IO.Directory]::CreateDirectory($unguardedProbe)
    $unguardedError = 0
    $unguardedResult = [SourceOracleOwnedMountReparseProbe]::TrySetJunction(
        $unguardedProbe,
        $junctionTarget,
        [ref]$unguardedError
    )
    Assert-OwnedMount `
        -Condition $unguardedResult `
        -Message "Reparse safety probe control failed with Win32 error $unguardedError"
    Assert-OwnedMount `
        -Condition (([IO.File]::GetAttributes($unguardedProbe) -band
            [IO.FileAttributes]::ReparsePoint) -ne 0) `
        -Message 'Reparse safety probe control did not create a junction'
    [IO.Directory]::Delete($unguardedProbe)
    Assert-OwnedMount `
        -Condition ([IO.File]::Exists($junctionSentinel)) `
        -Message 'Removing the probe junction affected its target'

    # Normal lifecycle, generated token registration, and target rename refusal.
    $normal = [SourceOracleOwnedMount]::Create(
        $gameRoot,
        $addonsRoot,
        $runNormal
    )
    $mounts.Add($normal)
    $normal.CopyTree($sourceRoot)

    # These two empty directories were created by CopyTree. Their retained
    # SHARE_READ-only handles must reject an in-place reparse conversion both
    # for a copied directory and immediately before generated-file creation.
    $copyGuardDestination = Join-Path $normal.TargetPath 'copy_guard_probe'
    $copyGuardError = 0
    $copyGuardResult = [SourceOracleOwnedMountReparseProbe]::TrySetJunction(
        $copyGuardDestination,
        $junctionTarget,
        [ref]$copyGuardError
    )
    Assert-OwnedMount `
        -Condition (-not $copyGuardResult -and $copyGuardError -eq 32) `
        -Message "Copy destination accepted/inconclusively refused reparse: $copyGuardError"
    Assert-OwnedMount `
        -Condition (([IO.File]::GetAttributes($copyGuardDestination) -band
            [IO.FileAttributes]::ReparsePoint) -eq 0) `
        -Message 'Copy destination became a reparse point'

    $generatedParent = Join-Path $normal.TargetPath 'generated_parent'
    $generatedParentError = 0
    $generatedParentResult = [SourceOracleOwnedMountReparseProbe]::TrySetJunction(
        $generatedParent,
        $junctionTarget,
        [ref]$generatedParentError
    )
    Assert-OwnedMount `
        -Condition (-not $generatedParentResult -and $generatedParentError -eq 32) `
        -Message "Generated-file parent accepted/inconclusively refused reparse: $generatedParentError"
    $normal.WriteGeneratedFile(
        'generated_parent\generated.txt',
        'guarded generated content'
    )
    $normal.WriteGeneratedFile(
        'lua\garryspad_oracle\run_token.txt',
        $runNormal
    )

    Assert-OwnedMount `
        -Condition ([IO.Path]::GetDirectoryName($normal.TargetPath) -eq $addonsRoot) `
        -Message 'Owned target is not a direct addons child'
    Assert-OwnedMount `
        -Condition ([IO.Path]::GetFileName($normal.TargetPath).Contains($runNormal)) `
        -Message 'Owned target leaf does not contain runID'
    Assert-OwnedMount `
        -Condition ([IO.File]::ReadAllText(
            (Join-Path $normal.TargetPath 'lua\garryspad_oracle\run_token.txt'),
            $utf8
        ) -ceq $runNormal) `
        -Message 'Generated run token did not round-trip'
    Assert-OwnedMount `
        -Condition ($normal.VolumeSerialNumber -is [uint64]) `
        -Message 'Volume serial was not captured as 64-bit FILE_ID_INFO data'

    $renamedTarget = $normal.TargetPath + '.renamed'
    Assert-OwnedMountThrows `
        -Message 'The retained target handle allowed a rename/swap first step' `
        -Action { [IO.Directory]::Move($normal.TargetPath, $renamedTarget) }
    Assert-OwnedMount `
        -Condition ([IO.Directory]::Exists($normal.TargetPath)) `
        -Message 'Owned target disappeared after rejected rename'
    Assert-OwnedMount `
        -Condition ([IO.Directory]::Exists($swapCandidate)) `
        -Message 'Unrelated swap candidate was changed'

    $normalTarget = $normal.TargetPath
    $normal.Cleanup()
    Assert-OwnedMount `
        -Condition (-not [IO.Directory]::Exists($normalTarget)) `
        -Message 'Normal cleanup did not remove the exact owned root'
    Assert-OwnedMount `
        -Condition ([IO.File]::Exists((Join-Path $unrelatedPath 'keep.txt'))) `
        -Message 'Normal cleanup removed an unrelated addon'
    Assert-OwnedMount `
        -Condition ([IO.File]::Exists((Join-Path $swapCandidate 'keep.txt'))) `
        -Message 'Normal cleanup removed the unrelated swap candidate'

    # Correct runID with a wrong per-mount token must refuse every deletion.
    $markerMismatch = [SourceOracleOwnedMount]::Create(
        $gameRoot,
        $addonsRoot,
        $runMarkerMismatch
    )
    $mounts.Add($markerMismatch)
    $markerMismatch.CopyTree($sourceRoot)
    $markerMismatchPath = Join-Path `
        $markerMismatch.TargetPath `
        ([SourceOracleOwnedMount]::MarkerFileName)
    [IO.File]::WriteAllText(
        $markerMismatchPath,
        (New-OwnedMountMarkerText `
            -RunID $runMarkerMismatch `
            -MountToken '00000000000000000000000000000000'),
        $utf8
    )
    Assert-OwnedMountThrows `
        -Message 'Cleanup accepted a mismatched per-mount marker token' `
        -Action { $markerMismatch.Cleanup() }
    Assert-OwnedMount `
        -Condition ([IO.Directory]::Exists($markerMismatch.TargetPath)) `
        -Message 'Token mismatch did not leave the target in place'
    [IO.File]::WriteAllText(
        $markerMismatchPath,
        $markerMismatch.ExpectedMarkerContents,
        $utf8
    )
    $markerMismatchTarget = $markerMismatch.TargetPath
    $markerMismatch.Cleanup()
    Assert-OwnedMount `
        -Condition (-not [IO.Directory]::Exists($markerMismatchTarget)) `
        -Message 'Restored marker token did not permit exact cleanup'

    # Correct token with the wrong runID must also refuse every deletion.
    $runIDMismatch = [SourceOracleOwnedMount]::Create(
        $gameRoot,
        $addonsRoot,
        $runIDMismatch
    )
    $mounts.Add($runIDMismatch)
    $runIDMismatch.CopyTree($sourceRoot)
    $runIDMismatchPath = Join-Path `
        $runIDMismatch.TargetPath `
        ([SourceOracleOwnedMount]::MarkerFileName)
    [IO.File]::WriteAllText(
        $runIDMismatchPath,
        (New-OwnedMountMarkerText `
            -RunID 'ffffffffffffffffffffffffffffffff' `
            -MountToken $runIDMismatch.MountToken),
        $utf8
    )
    Assert-OwnedMountThrows `
        -Message 'Cleanup accepted a mismatched marker runID' `
        -Action { $runIDMismatch.Cleanup() }
    Assert-OwnedMount `
        -Condition ([IO.Directory]::Exists($runIDMismatch.TargetPath)) `
        -Message 'RunID mismatch did not leave the target in place'
    [IO.File]::WriteAllText(
        $runIDMismatchPath,
        $runIDMismatch.ExpectedMarkerContents,
        $utf8
    )
    $runIDMismatchTarget = $runIDMismatch.TargetPath
    $runIDMismatch.Cleanup()
    Assert-OwnedMount `
        -Condition (-not [IO.Directory]::Exists($runIDMismatchTarget)) `
        -Message 'Restored marker runID did not permit exact cleanup'

    # A source junction is detected from its OPEN_REPARSE_POINT handle. Nothing
    # beyond it is copied or followed, and the outside sentinel remains intact.
    [void][IO.Directory]::CreateDirectory($junctionSource)
    Write-OwnedMountFixture -Path $junctionSentinel -Contents 'outside'
    [void](New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget)
    $reparseMount = [SourceOracleOwnedMount]::Create(
        $gameRoot,
        $addonsRoot,
        $runReparse
    )
    $mounts.Add($reparseMount)
    Assert-OwnedMountThrows `
        -Message 'CopyTree accepted a source reparse point' `
        -Action { $reparseMount.CopyTree($junctionSource) }
    Assert-OwnedMount `
        -Condition ([IO.File]::Exists($junctionSentinel)) `
        -Message 'CopyTree followed or damaged the reparse target'
    $reparseTarget = $reparseMount.TargetPath
    $reparseMount.Cleanup()
    Assert-OwnedMount `
        -Condition (-not [IO.Directory]::Exists($reparseTarget)) `
        -Message 'Safe marker-only cleanup failed after reparse refusal'

    # An injected path was never created by this object. Cleanup must not open,
    # follow, or delete it, and must leave the whole mount for inspection.
    $unknownMount = [SourceOracleOwnedMount]::Create(
        $gameRoot,
        $addonsRoot,
        $runUnknown
    )
    $mounts.Add($unknownMount)
    $unknownMount.CopyTree($sourceRoot)
    $unknownPath = Join-Path $unknownMount.TargetPath 'unknown_external.txt'
    Write-OwnedMountFixture -Path $unknownPath -Contents 'not in manifest'
    Assert-OwnedMountThrows `
        -Message 'Cleanup accepted an unknown target entry' `
        -Action { $unknownMount.Cleanup() }
    Assert-OwnedMount `
        -Condition ([IO.File]::Exists($unknownPath)) `
        -Message 'Unknown entry refusal still deleted the unknown path'
    Assert-OwnedMount `
        -Condition ([IO.File]::Exists((Join-Path $unrelatedPath 'keep.txt'))) `
        -Message 'A refused cleanup affected an unrelated addon'

    $safeToRecursivelyRemove = $true
    [pscustomobject]@{
        test = 'SourceOracleOwnedMount ownership and cleanup isolation'
        atomic_unique_run_directory = $true
        file_id_info_128 = $true
        generated_file_manifest = $true
        copy_destination_in_place_reparse_refused = $true
        generated_parent_in_place_reparse_refused = $true
        target_rename_swap_refused = $true
        marker_token_mismatch_refused = $true
        marker_run_id_mismatch_refused = $true
        source_reparse_refused = $true
        unknown_entry_refused_and_left = $true
        normal_owned_cleanup = $true
        unrelated_directory_survived = $true
        status = 'PASS'
    } | ConvertTo-Json -Compress
}
finally {
    for ($index = $mounts.Count - 1; $index -ge 0; $index--) {
        $mounts[$index].Dispose()
    }

    if ([IO.Directory]::Exists($unguardedProbe) -and
        (([IO.File]::GetAttributes($unguardedProbe) -band
            [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        [IO.Directory]::Delete($unguardedProbe)
    }

    # Never let recursive test-fixture cleanup traverse a junction. Remove only
    # the verified reparse entry itself, then confirm its target still exists.
    if ([IO.Directory]::Exists($junctionPath)) {
        $attributes = [IO.File]::GetAttributes($junctionPath)
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
            throw 'Test junction path unexpectedly became a plain directory'
        }
        [IO.Directory]::Delete($junctionPath)
    }
    if ([IO.File]::Exists($junctionSentinel) -eq $false -and
        [IO.Directory]::Exists($junctionTarget)) {
        throw 'Junction target sentinel was removed'
    }

    if ([IO.Directory]::Exists($temporaryRoot)) {
        $resolvedRoot = [IO.Path]::GetFullPath($temporaryRoot)
        $resolvedBase = [IO.Path]::GetFullPath($temporaryBase).TrimEnd('\') + '\'
        $safeLeaf = [IO.Path]::GetFileName($resolvedRoot).StartsWith(
            'SourceOracleOwnedMountTest_',
            [StringComparison]::Ordinal
        )
        if (-not $resolvedRoot.StartsWith(
            $resolvedBase,
            [StringComparison]::OrdinalIgnoreCase
        ) -or -not $safeLeaf) {
            throw "Refusing unsafe fixture cleanup path: $resolvedRoot"
        }
        if (-not $safeToRecursivelyRemove) {
            Write-Warning "Leaving failed owned-mount fixture for inspection: $resolvedRoot"
        }
        else {
            [IO.Directory]::Delete($resolvedRoot, $true)
        }
    }
}
