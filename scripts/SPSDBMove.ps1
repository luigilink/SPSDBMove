#Requires -Version 7.0

<#
.SYNOPSIS
    Backup, copy, and restore SharePoint SQL databases across SQL Server instances.

.DESCRIPTION
    SPSDBMove orchestrates three independent phases used during SharePoint
    Server 2016 / 2019 -> Subscription Edition migrations and PROD -> PREPROD
    refreshes:

      1. Backup  - BACKUP DATABASE on the source instance, written into a
                   per-database folder layout (<root>\<DbName>\FULL\*.bak)
                   using COPY_ONLY, COMPRESSION, CHECKSUM, INIT.
      2. Copy    - parallel copy of the latest .bak file per database from the
                   source backup root to the destination backup root.
      3. Restore - RESTORE DATABASE on the destination instance, with
                   RESTORE FILELISTONLY used to remap logical files to the
                   target data/log directories. REPLACE is honored when
                   OverwriteDestinationDb is true in the config (default).

    The job (which instances, which roots, which databases, all tuning
    values) is described by a JSON configuration file. The CLI surface is
    intentionally small: pick a config, pick a phase, optionally provide a
    credential and the -SkipExisting copy flag.

    Run the full pipeline with -Action All, or any single phase with
    -Action Backup | Copy | Restore.

    The SqlServer PowerShell module (Invoke-Sqlcmd) is required for the
    Backup and Restore phases. Install it once with:

        Install-Module -Name SqlServer -Scope CurrentUser -Force

    PowerShell 7.0 or later is required because the Copy phase uses
    ForEach-Object -Parallel, which is not available on Windows
    PowerShell 5.1.

.PARAMETER ConfigPath
    Path to a JSON configuration file describing the job. Required.
    See scripts/SPSDBMove.sample.json or wiki/Configuration.md for the
    schema. May also be passed as -Path.

.PARAMETER Action
    Phase(s) to execute. One of: All, Backup, Copy, Restore. Default: All.

.PARAMETER SqlCredential
    PSCredential for SQL authentication. Omit to use Windows integrated auth.
    Kept on the CLI so secrets never touch the JSON file.

.PARAMETER SkipExisting
    Copy phase only. Skip files that already exist at the destination with an
    identical length. Default: $false.

.EXAMPLE
    PS> .\SPSDBMove.ps1 -ConfigPath .\config\preprod-refresh.json

    Runs the full Backup -> Copy -> Restore pipeline described by the file.

.EXAMPLE
    PS> .\SPSDBMove.ps1 -ConfigPath .\config\preprod-refresh.json -Action Backup

    Runs just the Backup phase against the source instance from the config.

.EXAMPLE
    PS> .\SPSDBMove.ps1 -ConfigPath .\config\preprod-refresh.json -Action All -WhatIf

    Dry-run; prints every BACKUP/Copy/RESTORE that would be issued.

.NOTES
    Project : SPSDBMove
    Author  : Jean-Cyril Drouhin (luigilink)
    License : MIT - see LICENSE
    Repo    : https://github.com/luigilink/SPSDBMove

.LINK
    https://github.com/luigilink/SPSDBMove
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [Alias('Path')]
    [ValidateNotNullOrEmpty()]
    [string] $ConfigPath,

    [Parameter()]
    [ValidateSet('All', 'Backup', 'Copy', 'Restore')]
    [string] $Action = 'All',

    [Parameter()]
    [System.Management.Automation.Credential()]
    [pscredential] $SqlCredential = [pscredential]::Empty,

    [Parameter()]
    [switch] $SkipExisting
)

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

$script:LogFile = $null

function Write-SpsLog {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingWriteHost', '',
        Justification = 'Interactive script: user-facing colorized output is expected.')]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string] $Message,

        [Parameter()]
        [ValidateSet('Info', 'Warn', 'Error', 'Success', 'Verbose')]
        [string] $Level = 'Info'
    )

    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = '[{0}] [{1,-7}] {2}' -f $timestamp, $Level.ToUpperInvariant(), $Message

    switch ($Level) {
        'Warn'    { Write-Host $line -ForegroundColor Yellow }
        'Error'   { Write-Host $line -ForegroundColor Red }
        'Success' { Write-Host $line -ForegroundColor Green }
        'Verbose' { Write-Verbose $Message }
        default   { Write-Host $line -ForegroundColor Cyan }
    }

    if ($script:LogFile) {
        try {
            Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
        }
        catch {
            Write-Warning "Failed to append to log file '$script:LogFile': $($_.Exception.Message)"
        }
    }
}

function Initialize-SpsLogFile {
    [CmdletBinding()]
    param()

    $scriptBaseName = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
    $pathLogsFolder = Join-Path -Path $PSScriptRoot -ChildPath 'Logs'

    # Initialize logs
    if (-Not (Test-Path -Path $pathLogsFolder)) {
        New-Item -ItemType Directory -Path $pathLogsFolder -Force | Out-Null
    }
    $pathLogFile = Join-Path -Path $pathLogsFolder -ChildPath ($scriptBaseName + '.log')

    $script:LogFile = $pathLogFile
    Write-SpsLog -Level Info -Message ("Log file: {0}" -f $script:LogFile)
}

function Get-SpsConfig {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "ConfigPath '$Path' does not exist."
    }

    Write-SpsLog -Level Info -Message ("Loading config from {0}" -f $Path)

    try {
        $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Failed to parse JSON config '$Path': $($_.Exception.Message)"
    }

    # Build the config object with explicit defaults for every optional value.
    $cfg = [pscustomobject]@{
        SourceInstance            = $null
        DestinationInstance       = $null
        SourceBackupRoot          = $null
        DestinationBackupRoot     = $null
        DataFileDirectory         = $null
        LogFileDirectory          = $null
        ThrottleLimit             = 4
        OverwriteDestinationDb    = $true
        Databases                 = @()
        ExcludeDatabases          = @()
    }

    # Reject unknown top-level keys so typos surface immediately.
    $known = $cfg.PSObject.Properties.Name
    foreach ($name in $json.PSObject.Properties.Name) {
        if ($known -notcontains $name) {
            throw "Unknown config key '$name' in '$Path'. Allowed: $($known -join ', ')."
        }
    }

    # Array-shaped keys are normalised below; everything else is a scalar copy.
    $arrayKeys = @('Databases', 'ExcludeDatabases')
    foreach ($name in $known) {
        if ($json.PSObject.Properties.Name -contains $name -and $arrayKeys -notcontains $name) {
            $cfg.$name = $json.$name
        }
    }

    if ($json.PSObject.Properties.Name -contains 'Databases') {
        $cfg.Databases = @($json.Databases | ForEach-Object {
                if ($_ -is [string]) {
                    [pscustomobject]@{ Name = $_; DestinationName = $null }
                }
                elseif ($_ -is [pscustomobject] -or $_ -is [hashtable]) {
                    $entry = if ($_ -is [hashtable]) { [pscustomobject] $_ } else { $_ }
                    if ([string]::IsNullOrWhiteSpace($entry.Name)) {
                        throw "Each entry in 'Databases' must have a non-empty 'Name'."
                    }
                    [pscustomobject]@{
                        Name            = [string] $entry.Name
                        DestinationName = if ($entry.PSObject.Properties.Name -contains 'DestinationName') { $entry.DestinationName } else { $null }
                    }
                }
                else {
                    throw "Each entry in 'Databases' must be a string or an object with a 'Name' property."
                }
            })
    }

    if ($json.PSObject.Properties.Name -contains 'ExcludeDatabases') {
        $cfg.ExcludeDatabases = @($json.ExcludeDatabases | ForEach-Object {
                if ($_ -is [string]) {
                    $_
                }
                elseif ($_ -is [pscustomobject] -or $_ -is [hashtable]) {
                    $entry = if ($_ -is [hashtable]) { [pscustomobject] $_ } else { $_ }
                    if ([string]::IsNullOrWhiteSpace($entry.Name)) {
                        throw "Each entry in 'ExcludeDatabases' must be a non-empty string or an object with a 'Name' property."
                    }
                    [string] $entry.Name
                }
                else {
                    throw "Each entry in 'ExcludeDatabases' must be a string or an object with a 'Name' property."
                }
            } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    # Range / type validation for the numeric fields.
    if ($cfg.ThrottleLimit -lt 1 -or $cfg.ThrottleLimit -gt 64) {
        throw "ThrottleLimit must be between 1 and 64 (got $($cfg.ThrottleLimit))."
    }
    $cfg.ThrottleLimit = [int] $cfg.ThrottleLimit
    $cfg.OverwriteDestinationDb = [bool] $cfg.OverwriteDestinationDb

    return $cfg
}

function Assert-SpsConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Config,

        [Parameter(Mandatory = $true)]
        [ValidateSet('All', 'Backup', 'Copy', 'Restore')]
        [string] $Action
    )

    $needSource = $Action -in @('All', 'Backup')
    $needDest   = $Action -in @('All', 'Restore')
    $needCopy   = $Action -in @('All', 'Copy')

    $missing = New-Object 'System.Collections.Generic.List[string]'
    if ($needSource -and [string]::IsNullOrWhiteSpace($Config.SourceInstance))                        { $missing.Add('SourceInstance') }
    if ($needDest   -and [string]::IsNullOrWhiteSpace($Config.DestinationInstance))                   { $missing.Add('DestinationInstance') }
    if (($needSource -or $needCopy) -and [string]::IsNullOrWhiteSpace($Config.SourceBackupRoot))      { $missing.Add('SourceBackupRoot') }
    if (($needDest   -or $needCopy) -and [string]::IsNullOrWhiteSpace($Config.DestinationBackupRoot)) { $missing.Add('DestinationBackupRoot') }

    if ($missing.Count -gt 0) {
        throw "Missing required config key(s) for -Action $Action : $($missing -join ', ')"
    }

    if ($Action -ne 'Copy' -and $Config.Databases.Count -eq 0) {
        throw "Config 'Databases' array is empty. Add at least one database entry."
    }
}

function Test-SpsSqlServerModule {
    [CmdletBinding()]
    param()

    if (Get-Module -Name SqlServer) {
        return
    }
    if (Get-Module -ListAvailable -Name SqlServer) {
        Import-Module -Name SqlServer -ErrorAction Stop -DisableNameChecking
        return
    }
    throw "The 'SqlServer' PowerShell module is required for Backup and Restore phases. Install it with: Install-Module -Name SqlServer -Scope CurrentUser -Force"
}

function Get-SpsInvokeSqlcmdSplat {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ServerInstance,

        [Parameter()]
        [pscredential] $Credential
    )

    # QueryTimeout = 0 means "no timeout". BACKUP / RESTORE durations on
    # multi-TB SharePoint databases are inherently unpredictable; let SQL
    # Server manage the operation itself instead of imposing an arbitrary cap.
    $splat = @{
        ServerInstance         = $ServerInstance
        QueryTimeout           = 0
        TrustServerCertificate = $true
        ErrorAction            = 'Stop'
    }

    if ($Credential -and $Credential -ne [pscredential]::Empty) {
        $splat['Credential'] = $Credential
    }

    return $splat
}

function ConvertTo-SpsSafeFileName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    $invalid = [IO.Path]::GetInvalidFileNameChars()
    $sb = [System.Text.StringBuilder]::new()
    foreach ($ch in $Name.ToCharArray()) {
        if ($invalid -contains $ch) {
            [void] $sb.Append('_')
        }
        else {
            [void] $sb.Append($ch)
        }
    }
    return $sb.ToString()
}

function Get-SpsLatestBackupFile {
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $RootPath,

        [Parameter(Mandatory = $true)]
        [string] $DatabaseName
    )

    $fullDir = Join-Path -Path (Join-Path -Path $RootPath -ChildPath $DatabaseName) -ChildPath 'FULL'
    if (-not (Test-Path -LiteralPath $fullDir)) {
        return $null
    }

    return Get-ChildItem -LiteralPath $fullDir -Filter '*.bak' -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Get-SpsBackupFileList {
    [CmdletBinding()]
    [OutputType([System.Data.DataRow[]])]
    param(
        [Parameter(Mandatory = $true)] [hashtable] $InvokeSplat,
        [Parameter(Mandatory = $true)] [string]    $BackupFile
    )

    $query = "RESTORE FILELISTONLY FROM DISK = N'$BackupFile';"
    return Invoke-Sqlcmd @InvokeSplat -Query $query
}

function Get-SpsSystemDatabaseName {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    # SQL Server's hard-coded system databases. SPSDBMove never touches
    # these regardless of what the config says: backing them up cross-
    # instance is unsafe and restoring them over a live destination would
    # corrupt the engine.
    return @('master', 'model', 'msdb', 'tempdb')
}

function Select-SpsFilteredDatabase {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [pscustomobject[]] $Database,

        [Parameter()]
        [AllowEmptyCollection()]
        [string[]] $ExcludeName = @()
    )

    $system       = Get-SpsSystemDatabaseName
    $userExcludes = @($ExcludeName | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $kept = New-Object 'System.Collections.Generic.List[pscustomobject]'
    foreach ($db in $Database) {
        $name = $db.Name

        if ($system -contains $name) {
            Write-SpsLog -Level Warn -Message ("Skipping '{0}' (system database)." -f $name)
            continue
        }

        if ($userExcludes -contains $name) {
            Write-SpsLog -Level Warn -Message ("Skipping '{0}' (matched ExcludeDatabases)." -f $name)
            continue
        }

        $kept.Add($db)
    }

    return @($kept.ToArray())
}

# ---------------------------------------------------------------------------
# Phase: Backup
# ---------------------------------------------------------------------------

function Invoke-SpsBackupPhase {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)] [string]            $ServerInstance,
        [Parameter(Mandatory = $true)] [string]            $BackupRoot,
        [Parameter(Mandatory = $true)] [pscustomobject[]]  $Databases,
        [Parameter()]                  [pscredential]      $Credential
    )

    Write-SpsLog -Level Info -Message ("=== BACKUP phase ({0} database(s)) ===" -f $Databases.Count)
    Test-SpsSqlServerModule

    $splat = Get-SpsInvokeSqlcmdSplat -ServerInstance $ServerInstance -Credential $Credential
    $stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')

    foreach ($db in $Databases) {
        $dbName = $db.Name
        $safeName = ConvertTo-SpsSafeFileName -Name $dbName
        $fullDir = Join-Path -Path (Join-Path -Path $BackupRoot -ChildPath $safeName) -ChildPath 'FULL'

        if (-not (Test-Path -LiteralPath $fullDir)) {
            if ($PSCmdlet.ShouldProcess($fullDir, 'Create backup directory')) {
                New-Item -ItemType Directory -Path $fullDir -Force | Out-Null
            }
        }

        $backupFile = Join-Path -Path $fullDir -ChildPath ("{0}_{1}.bak" -f $safeName, $stamp)

        $tsql = @"
BACKUP DATABASE [$dbName]
TO DISK = N'$backupFile'
WITH COPY_ONLY, COMPRESSION, CHECKSUM, INIT, FORMAT, STATS = 10,
     NAME = N'SPSDBMove-$safeName-$stamp';
"@

        $target = "[$ServerInstance] BACKUP DATABASE [$dbName] -> $backupFile"
        if (-not $PSCmdlet.ShouldProcess($target, 'BACKUP DATABASE')) {
            continue
        }

        Write-SpsLog -Level Info -Message $target
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            Invoke-Sqlcmd @splat -Query $tsql
            $sw.Stop()
            Write-SpsLog -Level Success -Message ("[{0}] backup completed in {1:N1}s" -f $dbName, $sw.Elapsed.TotalSeconds)
        }
        catch {
            $sw.Stop()
            Write-SpsLog -Level Error -Message ("[{0}] backup FAILED after {1:N1}s: {2}" -f $dbName, $sw.Elapsed.TotalSeconds, $_.Exception.Message)
            throw
        }
    }
}

# ---------------------------------------------------------------------------
# Phase: Copy
# ---------------------------------------------------------------------------

function Invoke-SpsCopyPhase {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)] [string]            $SourceRoot,
        [Parameter(Mandatory = $true)] [string]            $DestinationRoot,
        [Parameter(Mandatory = $true)] [pscustomobject[]]  $Databases,
        [Parameter()]                  [int]               $Throttle = 4,
        [Parameter()]                  [switch]            $SkipExistingFiles
    )

    Write-SpsLog -Level Info -Message ("=== COPY phase ({0} database(s), throttle={1}) ===" -f $Databases.Count, $Throttle)

    if (-not (Test-Path -LiteralPath $SourceRoot)) {
        throw "SourceBackupRoot '$SourceRoot' does not exist."
    }

    if (-not (Test-Path -LiteralPath $DestinationRoot)) {
        if ($PSCmdlet.ShouldProcess($DestinationRoot, 'Create destination backup root')) {
            New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null
        }
    }

    # Build the list of (source -> destination) pairs first so the parallel
    # block can iterate over plain data.
    $jobs = foreach ($db in $Databases) {
        $dbName = $db.Name
        $latest = Get-SpsLatestBackupFile -RootPath $SourceRoot -DatabaseName $dbName

        if (-not $latest) {
            Write-SpsLog -Level Warn -Message ("[{0}] no .bak file found under {1}\{0}\FULL; skipping" -f $dbName, $SourceRoot)
            continue
        }

        $destDir = Join-Path -Path (Join-Path -Path $DestinationRoot -ChildPath $dbName) -ChildPath 'FULL'
        $destFile = Join-Path -Path $destDir -ChildPath $latest.Name

        [pscustomobject]@{
            DatabaseName = $dbName
            Source       = $latest.FullName
            SourceLength = $latest.Length
            DestDir      = $destDir
            DestFile     = $destFile
        }
    }

    if (-not $jobs -or $jobs.Count -eq 0) {
        Write-SpsLog -Level Warn -Message 'COPY phase: nothing to copy.'
        return
    }

    $skip   = [bool] $SkipExistingFiles
    $whatIf = [bool] $WhatIfPreference

    $jobs | ForEach-Object -ThrottleLimit $Throttle -Parallel {
        $job          = $_
        $skipExisting = $using:skip
        $whatIfMode   = $using:whatIf

        if (-not (Test-Path -LiteralPath $job.DestDir)) {
            if (-not $whatIfMode) {
                New-Item -ItemType Directory -Path $job.DestDir -Force | Out-Null
            }
        }

        if ($skipExisting -and (Test-Path -LiteralPath $job.DestFile)) {
            $existing = Get-Item -LiteralPath $job.DestFile
            if ($existing.Length -eq $job.SourceLength) {
                Write-Output ("[{0}] SKIPPED (already present, {1:N0} bytes)" -f $job.DatabaseName, $existing.Length)
                return
            }
        }

        if ($whatIfMode) {
            Write-Output ("[{0}] WHATIF: copy {1} -> {2}" -f $job.DatabaseName, $job.Source, $job.DestFile)
            return
        }

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            Copy-Item -LiteralPath $job.Source -Destination $job.DestFile -Force
            $sw.Stop()
            Write-Output ("[{0}] copied {1:N0} bytes in {2:N1}s" -f $job.DatabaseName, $job.SourceLength, $sw.Elapsed.TotalSeconds)
        }
        catch {
            $sw.Stop()
            Write-Output ("[{0}] COPY FAILED after {1:N1}s: {2}" -f $job.DatabaseName, $sw.Elapsed.TotalSeconds, $_.Exception.Message)
            throw
        }
    } | ForEach-Object { Write-SpsLog -Level Info -Message $_ }
}

# ---------------------------------------------------------------------------
# Phase: Restore
# ---------------------------------------------------------------------------

function Invoke-SpsRestorePhase {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)] [string]            $ServerInstance,
        [Parameter(Mandatory = $true)] [string]            $BackupRoot,
        [Parameter(Mandatory = $true)] [pscustomobject[]]  $Databases,
        [Parameter()]                  [pscredential]      $Credential,
        [Parameter()]                  [string]            $DataDirectory,
        [Parameter()]                  [string]            $LogDirectory,
        [Parameter()]                  [bool]              $Replace = $true
    )

    Write-SpsLog -Level Info -Message ("=== RESTORE phase ({0} database(s)) ===" -f $Databases.Count)
    Test-SpsSqlServerModule

    $splat = Get-SpsInvokeSqlcmdSplat -ServerInstance $ServerInstance -Credential $Credential

    foreach ($db in $Databases) {
        $sourceName = $db.Name

        $targetName = if (-not [string]::IsNullOrWhiteSpace($db.DestinationName)) {
            $db.DestinationName
        }
        else {
            $sourceName
        }

        $safeSource = ConvertTo-SpsSafeFileName -Name $sourceName
        $latest = Get-SpsLatestBackupFile -RootPath $BackupRoot -DatabaseName $safeSource

        if (-not $latest) {
            Write-SpsLog -Level Warn -Message ("[{0}] no .bak file found under {1}\{0}\FULL; skipping restore" -f $sourceName, $BackupRoot)
            continue
        }

        Write-SpsLog -Level Info -Message ("[{0}] reading FILELISTONLY from {1}" -f $sourceName, $latest.FullName)

        try {
            $fileList = Get-SpsBackupFileList -InvokeSplat $splat -BackupFile $latest.FullName
        }
        catch {
            Write-SpsLog -Level Error -Message ("[{0}] RESTORE FILELISTONLY failed: {1}" -f $sourceName, $_.Exception.Message)
            throw
        }

        $moveClauses = foreach ($row in $fileList) {
            $logicalName = $row.LogicalName
            $type = $row.Type  # 'D' for data, 'L' for log
            $originalExt = [IO.Path]::GetExtension($row.PhysicalName)
            if ([string]::IsNullOrEmpty($originalExt)) {
                $originalExt = if ($type -eq 'L') { '.ldf' } else { '.mdf' }
            }

            $newLogicalSegment = if ($logicalName -ieq $sourceName) {
                $targetName
            }
            elseif ($logicalName.StartsWith($sourceName, [StringComparison]::OrdinalIgnoreCase)) {
                $targetName + $logicalName.Substring($sourceName.Length)
            }
            else {
                $logicalName
            }

            $safeSegment = ConvertTo-SpsSafeFileName -Name $newLogicalSegment

            $targetDir = if ($type -eq 'L') {
                if ($LogDirectory)  { $LogDirectory }  else { [IO.Path]::GetDirectoryName($row.PhysicalName) }
            }
            else {
                if ($DataDirectory) { $DataDirectory } else { [IO.Path]::GetDirectoryName($row.PhysicalName) }
            }

            $newPhysical = Join-Path -Path $targetDir -ChildPath ($safeSegment + $originalExt)
            "MOVE N'{0}' TO N'{1}'" -f $logicalName, $newPhysical
        }

        $withClauses = New-Object 'System.Collections.Generic.List[string]'
        $moveClauses | ForEach-Object { $withClauses.Add($_) }
        if ($Replace) { $withClauses.Add('REPLACE') }
        $withClauses.Add('RECOVERY')
        $withClauses.Add('STATS = 10')

        $tsqlSingle = @"
ALTER DATABASE [$targetName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
"@
        $tsqlRestore = @"
RESTORE DATABASE [$targetName]
FROM DISK = N'$($latest.FullName)'
WITH
$($withClauses -join ",`n");
"@
        $tsqlMulti = @"
ALTER DATABASE [$targetName] SET MULTI_USER;
"@

        $target = "[$ServerInstance] RESTORE DATABASE [$targetName] FROM $($latest.FullName)"
        if (-not $PSCmdlet.ShouldProcess($target, 'RESTORE DATABASE')) {
            continue
        }

        Write-SpsLog -Level Info -Message $target

        # Best-effort SINGLE_USER if target DB exists (so RESTORE can take it).
        try {
            $exists = Invoke-Sqlcmd @splat -Query "SELECT 1 AS X FROM sys.databases WHERE name = N'$targetName';"
            if ($exists) {
                Write-SpsLog -Level Verbose -Message ("[{0}] setting SINGLE_USER" -f $targetName)
                Invoke-Sqlcmd @splat -Query $tsqlSingle
            }
        }
        catch {
            Write-SpsLog -Level Warn -Message ("[{0}] could not set SINGLE_USER (continuing): {1}" -f $targetName, $_.Exception.Message)
        }

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            Invoke-Sqlcmd @splat -Query $tsqlRestore
            $sw.Stop()
            Write-SpsLog -Level Success -Message ("[{0}] restore completed in {1:N1}s" -f $targetName, $sw.Elapsed.TotalSeconds)
        }
        catch {
            $sw.Stop()
            Write-SpsLog -Level Error -Message ("[{0}] restore FAILED after {1:N1}s: {2}" -f $targetName, $sw.Elapsed.TotalSeconds, $_.Exception.Message)
            throw
        }
        finally {
            try { Invoke-Sqlcmd @splat -Query $tsqlMulti } catch { Write-SpsLog -Level Warn -Message ("[{0}] could not set MULTI_USER: {1}" -f $targetName, $_.Exception.Message) }
        }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
    Initialize-SpsLogFile

    Write-SpsLog -Level Info -Message "SPSDBMove starting (Action=$Action, PS $($PSVersionTable.PSVersion))"

    $cfg = Get-SpsConfig -Path $ConfigPath
    Assert-SpsConfig -Config $cfg -Action $Action

    $dbList = $cfg.Databases

    # For Copy when no DB list was supplied, discover from SourceBackupRoot.
    if ($Action -eq 'Copy' -and $dbList.Count -eq 0) {
        if (-not (Test-Path -LiteralPath $cfg.SourceBackupRoot)) {
            throw "SourceBackupRoot '$($cfg.SourceBackupRoot)' does not exist."
        }
        $dbList = @(Get-ChildItem -LiteralPath $cfg.SourceBackupRoot -Directory |
                ForEach-Object { [pscustomobject]@{ Name = $_.Name; DestinationName = $null } })
        Write-SpsLog -Level Info -Message ("Discovered {0} database folder(s) under {1}" -f $dbList.Count, $cfg.SourceBackupRoot)
    }

    # Apply exclusions once for every phase: SQL Server system databases are
    # always skipped; ExcludeDatabases lets the operator opt out specific
    # user databases without removing them from the JSON 'Databases' list.
    $beforeCount = $dbList.Count
    $dbList = @(Select-SpsFilteredDatabase -Database $dbList -ExcludeName $cfg.ExcludeDatabases)
    if ($beforeCount -gt 0 -and $dbList.Count -eq 0) {
        Write-SpsLog -Level Warn -Message 'All databases were filtered out by system / ExcludeDatabases rules; nothing to do.'
    }

    $overall = [System.Diagnostics.Stopwatch]::StartNew()

    if ($Action -in @('All', 'Backup')) {
        Invoke-SpsBackupPhase `
            -ServerInstance $cfg.SourceInstance `
            -BackupRoot     $cfg.SourceBackupRoot `
            -Databases      $dbList `
            -Credential     $SqlCredential
    }

    if ($Action -in @('All', 'Copy')) {
        Invoke-SpsCopyPhase `
            -SourceRoot        $cfg.SourceBackupRoot `
            -DestinationRoot   $cfg.DestinationBackupRoot `
            -Databases         $dbList `
            -Throttle          $cfg.ThrottleLimit `
            -SkipExistingFiles:$SkipExisting
    }

    if ($Action -in @('All', 'Restore')) {
        Invoke-SpsRestorePhase `
            -ServerInstance  $cfg.DestinationInstance `
            -BackupRoot      $cfg.DestinationBackupRoot `
            -Databases       $dbList `
            -Credential      $SqlCredential `
            -DataDirectory   $cfg.DataFileDirectory `
            -LogDirectory    $cfg.LogFileDirectory `
            -Replace         $cfg.OverwriteDestinationDb
    }

    $overall.Stop()
    Write-SpsLog -Level Success -Message ("SPSDBMove finished in {0:N1}s" -f $overall.Elapsed.TotalSeconds)
}
catch {
    Write-SpsLog -Level Error -Message ("SPSDBMove aborted: {0}" -f $_.Exception.Message)
    throw
}
