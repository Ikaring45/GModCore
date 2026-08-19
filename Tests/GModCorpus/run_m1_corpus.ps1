[CmdletBinding()]
param(
    [Alias("gmod-root")]
    [string] $GModRoot,

    [Alias("conformance")]
    [string] $ConformanceExecutable,

    [ValidateSet("parse", "load")]
    [string] $Gate = "parse",

    [ValidateSet("gmod", "gmod-discovery", "standalone")]
    [string] $RuntimeMode = "gmod",

    [string[]] $Cohort = @(),

    [string] $ReportDirectory,

    [ValidateRange(1, 300)]
    [int] $TimeoutSeconds = 20,

    [switch] $NoBuild,
    [switch] $AllowCorpusDrift,
    [switch] $Quiet,
    [switch] $SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$manifestPath = Join-Path $PSScriptRoot "manifest.json"
$classifierFixturePath = Join-Path $PSScriptRoot "fixtures\classifier_cases.json"
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

function Write-HarnessLine {
    param([string] $Message)

    if (-not $Quiet) {
        Write-Host $Message
    }
}

function Get-DiagnosticClassification {
    param([string] $Diagnostic)

    foreach ($rule in @($manifest.diagnosticRules)) {
        foreach ($pattern in @($rule.patterns)) {
            if ($Diagnostic -match [regex]::Escape([string] $pattern)) {
                return [pscustomobject]@{
                    category = [string] $rule.category
                    phase = [string] $rule.phase
                    confidence = [string] $rule.confidence
                }
            }
        }
    }

    return [pscustomobject]@{
        category = "UNCLASSIFIED-RUNTIME"
        phase = "load"
        confidence = "unknown"
    }
}

function Invoke-ClassifierSelfTest {
    $cases = @(Get-Content -LiteralPath $classifierFixturePath -Raw | ConvertFrom-Json)
    $failures = 0

    foreach ($case in $cases) {
        $actual = Get-DiagnosticClassification -Diagnostic ([string] $case.diagnostic)
        if ($actual.category -ne [string] $case.expectedCategory) {
            Write-Host "[FAIL][HARNESS] $($case.name): expected $($case.expectedCategory), got $($actual.category)"
            $failures += 1
        } else {
            Write-HarnessLine "[PASS][HARNESS] $($case.name) -> $($actual.category)"
        }
    }

    if ($failures -gt 0) {
        Write-Host "[FAIL][HARNESS] classifier failures: $failures"
        return $false
    }

    Write-Host "[PASS][HARNESS] classifier cases: $($cases.Count)"
    return $true
}

function Resolve-ConformanceExecutable {
    if ($ConformanceExecutable) {
        return (Resolve-Path -LiteralPath $ConformanceExecutable).Path
    }

    Push-Location $repositoryRoot
    try {
        if (-not $NoBuild) {
            Write-HarnessLine "[BUILD] swift build --product GModLuaConformance"
            & swift build --product GModLuaConformance
            if ($LASTEXITCODE -ne 0) {
                throw "GModLuaConformance build failed with exit code $LASTEXITCODE"
            }
        }

        $binPathOutput = @(& swift build --show-bin-path)
        if ($LASTEXITCODE -ne 0 -or $binPathOutput.Count -eq 0) {
            throw "Unable to resolve SwiftPM binary path"
        }
        $binPath = [string] $binPathOutput[-1]
        $executableName = if ($IsWindows) { "GModLuaConformance.exe" } else { "GModLuaConformance" }
        $candidate = Join-Path $binPath.Trim() $executableName
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "Conformance executable not found at $candidate. Build it or pass -ConformanceExecutable."
        }
        return (Resolve-Path -LiteralPath $candidate).Path
    } finally {
        Pop-Location
    }
}

function Convert-ToLogicalPath {
    param(
        [string] $Root,
        [string] $Path
    )

    return ([IO.Path]::GetRelativePath($Root, $Path) -replace "\\", "/")
}

function Get-CohortFiles {
    param(
        [object] $CohortDefinition,
        [string] $Root
    )

    $selection = $CohortDefinition.selection
    $files = @()

    switch ([string] $selection.kind) {
        "files" {
            foreach ($logicalPath in @($selection.paths)) {
                $nativePath = Join-Path $Root (([string] $logicalPath) -replace "/", [IO.Path]::DirectorySeparatorChar)
                if (Test-Path -LiteralPath $nativePath -PathType Leaf) {
                    $files += Get-Item -LiteralPath $nativePath
                }
            }
        }
        "recursive" {
            $nativeRoot = Join-Path $Root (([string] $selection.root) -replace "/", [IO.Path]::DirectorySeparatorChar)
            if (Test-Path -LiteralPath $nativeRoot -PathType Container) {
                $extension = ([string] $selection.extension).ToLowerInvariant()
                $files += Get-ChildItem -LiteralPath $nativeRoot -Recurse -File |
                    Where-Object { $_.Extension.ToLowerInvariant() -eq $extension }
            }
        }
        default {
            throw "Unknown corpus selection kind '$($selection.kind)' in cohort '$($CohortDefinition.id)'"
        }
    }

    return @($files | Sort-Object { Convert-ToLogicalPath -Root $Root -Path $_.FullName })
}

function Invoke-ConformanceFile {
    param(
        [string] $Executable,
        [string] $FilePath,
        [string] $LogicalPath,
        [string] $Root,
        [string] $Mode,
        [int] $Timeout
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Executable
    if ($Mode -eq "gmod" -or $Mode -eq "gmod-discovery") {
        $startInfo.ArgumentList.Add("--gmod-file")
        $startInfo.ArgumentList.Add($Root)
        $startInfo.ArgumentList.Add($LogicalPath)
        $startInfo.ArgumentList.Add("server")
        $startInfo.ArgumentList.Add($(if ($Mode -eq "gmod-discovery") { "discovery" } else { "strict" }))
    } else {
        $startInfo.ArgumentList.Add("--file")
        $startInfo.ArgumentList.Add($FilePath)
    }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $null = $process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $finished = $process.WaitForExit($Timeout * 1000)

    if (-not $finished) {
        try {
            $process.Kill($true)
        } catch {
            $process.Kill()
        }
        $process.WaitForExit()
    }

    $stopwatch.Stop()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $exitCode = if ($finished) { $process.ExitCode } else { $null }
    $process.Dispose()

    return [pscustomobject]@{
        timedOut = -not $finished
        exitCode = $exitCode
        elapsedMilliseconds = $stopwatch.ElapsedMilliseconds
        stdout = $stdout.TrimEnd()
        stderr = $stderr.TrimEnd()
    }
}

function Add-MarkdownEscapes {
    param([AllowEmptyString()][string] $Value)

    return (($Value -replace "\|", "\\|") -replace "`r?`n", " ")
}

if ($SelfTest) {
    if (Invoke-ClassifierSelfTest) {
        exit 0
    }
    exit 1
}

if (-not $GModRoot) {
    throw "-GModRoot is required unless -SelfTest is used"
}

$resolvedGModRoot = (Resolve-Path -LiteralPath $GModRoot).Path
if (-not (Test-Path -LiteralPath (Join-Path $resolvedGModRoot "lua") -PathType Container) -or
    -not (Test-Path -LiteralPath (Join-Path $resolvedGModRoot "gamemodes") -PathType Container)) {
    throw "GModRoot must be the garrysmod data directory containing both lua/ and gamemodes/: $resolvedGModRoot"
}

$selectedCohorts = @($manifest.cohorts)
if ($Cohort.Count -gt 0) {
    $unknownCohorts = @($Cohort | Where-Object { $_ -notin @($manifest.cohorts.id) })
    if ($unknownCohorts.Count -gt 0) {
        throw "Unknown cohort(s): $($unknownCohorts -join ', ')"
    }
    $selectedCohorts = @($selectedCohorts | Where-Object { $_.id -in $Cohort })
}
$selectedCohorts = @($selectedCohorts | Sort-Object priority)

$executable = Resolve-ConformanceExecutable
$timestamp = [DateTimeOffset]::Now.ToString("yyyyMMdd-HHmmss")
if (-not $ReportDirectory) {
    $ReportDirectory = Join-Path ([IO.Path]::GetTempPath()) "GarrysPAD-GModCorpus-$timestamp"
}
$resolvedReportDirectory = [IO.Path]::GetFullPath($ReportDirectory)
$null = New-Item -ItemType Directory -Path $resolvedReportDirectory -Force

Write-HarnessLine "[CORPUS] root: $resolvedGModRoot"
Write-HarnessLine "[CORPUS] executable: $executable"
Write-HarnessLine "[CORPUS] gate: $Gate"
Write-HarnessLine "[CORPUS] runtime: $RuntimeMode"

$results = [Collections.Generic.List[object]]::new()
$cohortSummaries = [Collections.Generic.List[object]]::new()
$corpusDrift = [Collections.Generic.List[object]]::new()

foreach ($cohortDefinition in $selectedCohorts) {
    $files = @(Get-CohortFiles -CohortDefinition $cohortDefinition -Root $resolvedGModRoot)
    $expectedCount = [int] $cohortDefinition.expectedFileCount
    if ($files.Count -ne $expectedCount) {
        $drift = [pscustomobject]@{
            scope = [string] $cohortDefinition.id
            expected = $expectedCount
            actual = $files.Count
        }
        $corpusDrift.Add($drift)
        Write-Host "[FAIL][CORPUS-DRIFT] $($drift.scope): expected $($drift.expected), found $($drift.actual)"
    } else {
        Write-HarnessLine "[PASS][CORPUS] $($cohortDefinition.id): $($files.Count) files"
    }

    $cohortStart = $results.Count
    foreach ($file in $files) {
        $logicalPath = Convert-ToLogicalPath -Root $resolvedGModRoot -Path $file.FullName
        $invocation = Invoke-ConformanceFile `
            -Executable $executable `
            -FilePath $file.FullName `
            -LogicalPath $logicalPath `
            -Root $resolvedGModRoot `
            -Mode $RuntimeMode `
            -Timeout $TimeoutSeconds
        $diagnostic = (@($invocation.stdout, $invocation.stderr) | Where-Object { $_ }) -join "`n"

        if ($invocation.timedOut) {
            $category = "TIMEOUT"
            $phase = "unknown"
            $confidence = "exact"
            $parsePassed = $false
            $loadPassed = $false
            $label = "[FAIL][TIMEOUT]"
        } elseif ($invocation.exitCode -eq 0 -and $RuntimeMode -eq "gmod-discovery" -and $diagnostic -match "compatibilityGaps=[1-9]") {
            # Discovery shims intentionally expose later blockers, but a file
            # that needed them is never promoted to a production load PASS.
            $category = "DISCOVERY-SCAFFOLD"
            $phase = "load"
            $confidence = "exact"
            $parsePassed = $true
            $loadPassed = $false
            $label = "[SKIP][DISCOVERY]"
        } elseif ($invocation.exitCode -eq 0) {
            $category = "PASS"
            $phase = "load"
            $confidence = "exact"
            $parsePassed = $true
            $loadPassed = $true
            $label = "[PASS][LOAD]"
        } elseif ([string]::IsNullOrWhiteSpace($diagnostic)) {
            # A Windows loader failure (for example a missing Swift runtime DLL)
            # can terminate before main() without producing stderr. Never count
            # that as a parsed Lua chunk.
            $category = "HARNESS"
            $phase = "parse"
            $confidence = "exact"
            $parsePassed = $false
            $loadPassed = $false
            $label = "[FAIL][HARNESS]"
        } else {
            $classification = Get-DiagnosticClassification -Diagnostic $diagnostic
            $category = $classification.category
            $phase = $classification.phase
            $confidence = $classification.confidence
            $parsePassed = $phase -ne "parse"
            $loadPassed = $false
            $label = "[FAIL][$category]"
        }

        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $result = [pscustomobject]@{
            cohort = [string] $cohortDefinition.id
            priority = [int] $cohortDefinition.priority
            declaredRealm = [string] $cohortDefinition.realm
            logicalPath = $logicalPath
            sha256 = $hash
            byteCount = $file.Length
            parsePassed = $parsePassed
            loadPassed = $loadPassed
            category = $category
            phase = $phase
            confidence = $confidence
            elapsedMilliseconds = $invocation.elapsedMilliseconds
            exitCode = $invocation.exitCode
            diagnostic = $diagnostic
        }
        $results.Add($result)
        Write-HarnessLine "$label $logicalPath"
    }

    $cohortResults = @($results | Select-Object -Skip $cohortStart)
    $cohortSummaries.Add([pscustomobject]@{
        id = [string] $cohortDefinition.id
        priority = [int] $cohortDefinition.priority
        expectedFileCount = $expectedCount
        actualFileCount = $files.Count
        parsePassed = @($cohortResults | Where-Object parsePassed).Count
        loadPassed = @($cohortResults | Where-Object loadPassed).Count
        blockers = $files.Count - @($cohortResults | Where-Object loadPassed).Count
    })
}

foreach ($aggregate in @($manifest.aggregateChecks)) {
    $aggregateCohorts = @($aggregate.cohorts | Where-Object { $_ -in @($selectedCohorts.id) })
    if ($aggregateCohorts.Count -ne @($aggregate.cohorts).Count) {
        continue
    }
    $actual = @($results | Where-Object { $_.cohort -in $aggregateCohorts }).Count
    $expected = [int] $aggregate.expectedFileCount
    if ($actual -ne $expected) {
        $drift = [pscustomobject]@{
            scope = [string] $aggregate.id
            expected = $expected
            actual = $actual
        }
        $corpusDrift.Add($drift)
        Write-Host "[FAIL][CORPUS-DRIFT] $($drift.scope): expected $($drift.expected), found $($drift.actual)"
    } else {
        Write-HarnessLine "[PASS][CORPUS] $($aggregate.id): $actual files"
    }
}

$parseFailures = @($results | Where-Object { -not $_.parsePassed })
$loadFailures = @($results | Where-Object { -not $_.loadPassed })
$categorySummary = @(
    $results |
        Group-Object category |
        Sort-Object Name |
        ForEach-Object {
            [pscustomobject]@{
                category = $_.Name
                count = $_.Count
            }
        }
)

$gateFailed = if ($Gate -eq "parse") {
    $parseFailures.Count -gt 0
} else {
    $loadFailures.Count -gt 0
}
if (-not $AllowCorpusDrift -and $corpusDrift.Count -gt 0) {
    $gateFailed = $true
}

$deferredGates = @(
    $manifest.deferredGates | ForEach-Object {
        [pscustomobject]@{
            category = [string] $_.category
            status = [string] $_.status
            reason = [string] $_.reason
        }
    }
)

$report = [ordered]@{
    schemaVersion = 1
    milestone = [string] $manifest.milestone
    generatedAt = [DateTimeOffset]::Now.ToString("o")
    gmodRoot = $resolvedGModRoot
    conformanceExecutable = $executable
    gate = $Gate
    runtimeMode = $RuntimeMode
    gatePassed = -not $gateFailed
    allowCorpusDrift = [bool] $AllowCorpusDrift
    totals = [ordered]@{
        files = $results.Count
        parsePassed = @($results | Where-Object parsePassed).Count
        parseFailed = $parseFailures.Count
        loadPassed = @($results | Where-Object loadPassed).Count
        loadFailed = $loadFailures.Count
    }
    corpusDrift = @($corpusDrift)
    categories = $categorySummary
    cohorts = @($cohortSummaries)
    deferredGates = $deferredGates
    results = @($results)
}

$jsonPath = Join-Path $resolvedReportDirectory "gmod-corpus-report.json"
$markdownPath = Join-Path $resolvedReportDirectory "gmod-corpus-report.md"
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $jsonPath -Encoding utf8

$markdown = [Text.StringBuilder]::new()
$null = $markdown.AppendLine("# GLua Gameplay Bootstrap M1 corpus report")
$null = $markdown.AppendLine()
$null = $markdown.AppendLine("- Gate: ``$Gate``")
$null = $markdown.AppendLine("- Runtime: ``$RuntimeMode``")
$null = $markdown.AppendLine("- Result: **$(if ($gateFailed) { 'FAIL' } else { 'PASS' })**")
$null = $markdown.AppendLine("- Files: $($results.Count)")
$null = $markdown.AppendLine("- Parse: $(@($results | Where-Object parsePassed).Count) pass / $($parseFailures.Count) fail")
$null = $markdown.AppendLine("- Load: $(@($results | Where-Object loadPassed).Count) pass / $($loadFailures.Count) fail")
$null = $markdown.AppendLine()
$null = $markdown.AppendLine("## Cohorts")
$null = $markdown.AppendLine()
$null = $markdown.AppendLine("| Cohort | Files | Parse pass | Load pass | Blockers |")
$null = $markdown.AppendLine("|---|---:|---:|---:|---:|")
foreach ($summary in $cohortSummaries) {
    $null = $markdown.AppendLine("| $($summary.id) | $($summary.actualFileCount) | $($summary.parsePassed) | $($summary.loadPassed) | $($summary.blockers) |")
}
$null = $markdown.AppendLine()
$null = $markdown.AppendLine("## Diagnostic categories")
$null = $markdown.AppendLine()
$null = $markdown.AppendLine("| Category | Count |")
$null = $markdown.AppendLine("|---|---:|")
foreach ($category in $categorySummary) {
    $null = $markdown.AppendLine("| $($category.category) | $($category.count) |")
}
$null = $markdown.AppendLine()
$null = $markdown.AppendLine("## First load blockers")
$null = $markdown.AppendLine()
$null = $markdown.AppendLine("| Category | Cohort | Path | Diagnostic |")
$null = $markdown.AppendLine("|---|---|---|---|")
foreach ($failure in @($loadFailures | Select-Object -First 30)) {
    $firstDiagnosticLine = ([string] $failure.diagnostic -split "`r?`n" | Select-Object -First 1)
    $null = $markdown.AppendLine("| $($failure.category) | $($failure.cohort) | ``$($failure.logicalPath)`` | $(Add-MarkdownEscapes $firstDiagnosticLine) |")
}
$null = $markdown.AppendLine()
$null = $markdown.AppendLine("## Deferred gates")
$null = $markdown.AppendLine()
foreach ($deferred in $deferredGates) {
    $null = $markdown.AppendLine("- [$($deferred.status)][$($deferred.category)] $($deferred.reason)")
}
$null = $markdown.AppendLine()
$null = $markdown.AppendLine("The report contains hashes and diagnostics only; no Garry's Mod Lua source is copied.")
$markdown.ToString() | Set-Content -LiteralPath $markdownPath -Encoding utf8

foreach ($deferred in $deferredGates) {
    Write-Host "[$($deferred.status)][$($deferred.category)] $($deferred.reason)"
}

$gateLabel = if ($gateFailed) { "FAIL" } else { "PASS" }
Write-Host "[$gateLabel][GATE] ${Gate}: parse $(@($results | Where-Object parsePassed).Count)/$($results.Count), load $(@($results | Where-Object loadPassed).Count)/$($results.Count)"
Write-Host "[REPORT] $jsonPath"
Write-Host "[REPORT] $markdownPath"

if ($gateFailed) {
    exit 1
}
exit 0
