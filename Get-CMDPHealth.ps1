<#
.SYNOPSIS
    Configuration Manager Distribution Point health check (SQL based).

.DESCRIPTION
    Reads Configuration Manager site database views directly over SQL instead of
    live-querying WMI/WinRM on each DP. One SQL round-trip per data source, so
    run time is roughly constant whether there are 10 DPs or 1000.

    Current checks (select with -Check):
      DiskSpace       - Free space and % used on C: / F: (configurable) for every DP.
                        Primary source: hardware inventory (v_GS_LOGICAL_DISK).
                        Fallback: site system status polling (v_SiteSystemSummarizer)
                        when a DP has no inventory or its inventory is stale.
      ContentFailures - Content in Failed / Retrying state on any DP
                        (v_PackageStatusDistPointsSumm).

    Adding a check:
      1. Write a Get-<Thing>Data function that runs ONE SQL query for all DPs.
      2. Write a Test-<Thing> function that turns that data into findings with
         New-DPFinding.
      3. Register it in $CheckRegistry and add its name to the -Check ValidateSet.

.PARAMETER SqlServer
    SQL instance hosting the site database (server or server\instance).

.PARAMETER Database
    Site database name (CM_<SiteCode>).

.PARAMETER Check
    Which checks to run. Defaults to all.

.PARAMETER DriveThresholds
    Hashtable keyed by drive letter. Each value supports:
      MinFreeGB      - Critical when free space is below this.
      CritPctUsed    - High when % used is at or above this.
      WarnPctUsed    - Warning when % used is at or above this.
      Required       - $true to raise a finding when the DP has no such drive.

.PARAMETER MaxInventoryAgeDays
    Hardware inventory older than this is considered stale; the site status
    summarizer is used instead when it has data for that drive.

.PARAMETER ExcludeDP
    Wildcard patterns of DP server names to skip (cloud DPs, CMG, source DPs...).

.PARAMETER IncludeRetrying
    Also report content in Retrying state (as Warning). Off = only hard failures.

.PARAMETER ReportPath
    Optional output file. Extension picks the format: .html or .csv.

.EXAMPLE
    .\Get-CMDPHealth.ps1 -ReportPath C:\Temp\DPHealth.html

.EXAMPLE
    .\Get-CMDPHealth.ps1 -Check DiskSpace | Where-Object Severity -eq 'Critical' | Format-Table

.EXAMPLE
    $r = .\Get-CMDPHealth.ps1 -PassThruData
    $r.Data.Disk | Export-Csv C:\Temp\AllDPDisks.csv -NoTypeInformation

.NOTES
    Requires: db_datareader (or the CM 'smsschm_users' / reporting role) on the
    site database. No ConfigurationManager module or remote WMI needed.
    Runs on Windows PowerShell 5.1 and PowerShell 7+.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [String]$SqlServer = 'cm-sql01.contoso.com',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [String]$Database = 'CM_PS1',

    [Parameter()]
    [ValidateSet('DiskSpace', 'ContentFailures')]
    [String[]]$Check = @('DiskSpace', 'ContentFailures'),

    [Parameter()]
    [Hashtable]$DriveThresholds = @{
        C = @{ MinFreeGB = 20; WarnPctUsed = 70; CritPctUsed = 80; Required = $true }
        F = @{ MinFreeGB = 50; WarnPctUsed = 70; CritPctUsed = 80; Required = $true }
    },

    [Parameter()]
    [ValidateRange(1, 365)]
    [Int]$MaxInventoryAgeDays = 7,

    [Parameter()]
    [String[]]$ExcludeDP = @('*.cloudapp.net', '*.cloudapp.azure.com'),

    [Parameter()]
    [Switch]$IncludeRetrying,

    # Drives above this % used are listed in the report's 'Take Immediate Action' section.
    [Parameter()]
    [ValidateRange(1, 100)]
    [Int]$ImmediateActionPctUsed = 90,

    [Parameter()]
    [String]$ReportPath,

    # Return an object with both findings and the raw data sets instead of just findings.
    [Parameter()]
    [Switch]$PassThruData,

    [Parameter()]
    [ValidateRange(30, 3600)]
    [Int]$QueryTimeoutSeconds = 300
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

#region Lookups

# SMS_PackageStatusDistPointsSummarizer.State
$ContentStateName = @{
    0 = 'Installed'
    1 = 'InstallPending'
    2 = 'InstallRetrying'
    3 = 'InstallFailed'
    4 = 'RemovalPending'
    5 = 'RemovalRetrying'
    6 = 'RemovalFailed'
    7 = 'ContentUpdating'
    8 = 'ContentMonitoring'
}

# SMS_PackageBaseclass.PackageType
$PackageTypeName = @{
    0   = 'Package'
    3   = 'DriverPackage'
    4   = 'TaskSequence'
    5   = 'SoftwareUpdatePackage'
    6   = 'DeviceSettingPackage'
    7   = 'VirtualApplication'
    8   = 'Application'
    257 = 'OperatingSystemImage'
    258 = 'BootImage'
    259 = 'OperatingSystemInstaller'
}

$SeverityRank = @{ Critical = 0; High = 1; Warning = 2; Info = 3 }

#endregion

#region Helpers

function Invoke-CMSqlQuery {
    <#
    .SYNOPSIS
        Run a read-only query against the site DB and return PSCustomObjects.
        Uses System.Data.SqlClient so the SqlServer module is not required.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][String]$Query,
        [Hashtable]$Parameters = @{}
    )

    $connString = "Server=$SqlServer;Database=$Database;Integrated Security=SSPI;Application Name=Get-CMDPHealth;ApplicationIntent=ReadOnly"
    $conn = New-Object System.Data.SqlClient.SqlConnection $connString
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        # Dirty reads are the CM reporting norm: avoids blocking site processing on busy tables.
        $cmd.CommandText = "SET NOCOUNT ON; SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;`n$Query"
        $cmd.CommandTimeout = $QueryTimeoutSeconds
        foreach ($key in $Parameters.Keys) {
            [void]$cmd.Parameters.AddWithValue("@$key", $Parameters[$key])
        }

        $table = New-Object System.Data.DataTable
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
        [void]$adapter.Fill($table)

        $columns = @($table.Columns | ForEach-Object ColumnName)
        foreach ($row in $table.Rows) {
            $obj = [ordered]@{}
            foreach ($col in $columns) {
                $obj[$col] = if ($row[$col] -is [DBNull]) { $null } else { $row[$col] }
            }
            [PSCustomObject]$obj
        }
    }
    finally {
        $conn.Dispose()
    }
}

function Get-ServerFromNALPath {
    # ["Display=\\SERVER.contoso.com\"]MSWNET:["SMS_SITE=PS1"]\\SERVER.contoso.com\  ->  SERVER.CONTOSO.COM
    param([String]$NALPath)
    if ($NALPath -match '\\\\([^\\"\]]+)') { $Matches[1].ToUpper() } else { $NALPath }
}

function Test-ExcludedDP {
    param([String]$ServerName)
    foreach ($pattern in $ExcludeDP) {
        if ($ServerName -like $pattern) { return $true }
    }
    $false
}

function New-DPFinding {
    param(
        [Parameter(Mandatory)][String]$DP,
        [Parameter(Mandatory)][String]$Category,
        [Parameter(Mandatory)][ValidateSet('Critical', 'High', 'Warning', 'Info')][String]$Severity,
        [Parameter(Mandatory)][String]$Issue,
        [String]$Recommendation,
        [String]$Source
    )
    [PSCustomObject]@{
        PSTypeName     = 'CMDPHealth.Finding'
        DP             = $DP
        Category       = $Category
        Severity       = $Severity
        Issue          = $Issue
        Recommendation = $Recommendation
        Source         = $Source
    }
}

#endregion

#region Data collection (one SQL query per data set)

function Get-DPList {
    <#
        Every DP in the hierarchy. v_DistributionPoints is one row per DP.
    #>
    $query = @'
SELECT DISTINCT
    UPPER(dp.ServerName) AS ServerName,
    UPPER(LEFT(dp.ServerName, CHARINDEX('.', dp.ServerName + '.') - 1)) AS NetbiosName,
    dp.SMSSiteCode AS SiteCode
FROM v_DistributionPoints dp
'@
    Invoke-CMSqlQuery -Query $query | Where-Object { -not (Test-ExcludedDP $_.ServerName) }
}

function Get-DPDiskInventory {
    <#
        Fixed-disk hardware inventory for every DP that has a CM client.
        v_GS_LOGICAL_DISK Size0 / FreeSpace0 are in MB.
        When a DP name maps to multiple client records, the one with the newest
        hardware scan wins.
    #>
    param([String[]]$DriveLetters)

    # Letters are validated to a single A-Z char, so inlining them is safe.
    $letters = ($DriveLetters | ForEach-Object { "'$($_.ToUpper())'" }) -join ','

    $query = @"
WITH DP AS (
    SELECT DISTINCT
        UPPER(dp.ServerName) AS ServerName,
        UPPER(LEFT(dp.ServerName, CHARINDEX('.', dp.ServerName + '.') - 1)) AS NetbiosName
    FROM v_DistributionPoints dp
),
Sys AS (
    SELECT
        s.ResourceID,
        UPPER(s.Name0) AS NetbiosName,
        ws.LastHWScan,
        ROW_NUMBER() OVER (PARTITION BY s.Name0 ORDER BY ws.LastHWScan DESC) AS rn
    FROM v_R_System s
    LEFT JOIN v_GS_WORKSTATION_STATUS ws ON ws.ResourceID = s.ResourceID
    WHERE ISNULL(s.Obsolete0, 0) = 0
      AND ISNULL(s.Decommissioned0, 0) = 0
)
SELECT
    dp.ServerName,
    sys.ResourceID,
    sys.LastHWScan,
    LEFT(ld.DeviceID0, 1)  AS DriveLetter,
    ld.VolumeName0         AS VolumeName,
    ld.Size0               AS SizeMB,
    ld.FreeSpace0          AS FreeMB
FROM DP dp
LEFT JOIN Sys sys
       ON sys.NetbiosName = dp.NetbiosName
      AND sys.rn = 1
LEFT JOIN v_GS_LOGICAL_DISK ld
       ON ld.ResourceID = sys.ResourceID
      AND ld.DriveType0 = 3
      AND LEFT(ld.DeviceID0, 1) IN ($letters)
"@
    Invoke-CMSqlQuery -Query $query
}

function Get-DPSiteSystemStorage {
    <#
        Site system status polling (Monitoring > Site Status). Refreshed by the
        site server roughly hourly, so it is fresher than hardware inventory but
        typically only covers drives the DP role uses (content library drive).
        BytesTotal / BytesFree in this view are reported in KB.
    #>
    $query = @'
SELECT
    ss.SiteSystem,
    ss.SiteObject,
    ss.BytesTotal,
    ss.BytesFree,
    ss.PercentFree,
    ss.TimeReported
FROM v_SiteSystemSummarizer ss
WHERE ss.Role = 'SMS Distribution Point'
'@
    foreach ($row in Invoke-CMSqlQuery -Query $query) {
        if ($row.SiteObject -notmatch '([A-Za-z])\$') { continue }
        $drive = $Matches[1].ToUpper()
        [PSCustomObject]@{
            ServerName   = Get-ServerFromNALPath $row.SiteSystem
            DriveLetter  = $drive
            SizeMB       = [Math]::Round([double]$row.BytesTotal / 1KB, 0)
            FreeMB       = [Math]::Round([double]$row.BytesFree / 1KB, 0)
            TimeReported = $row.TimeReported
        }
    }
}

function Get-DPContentFailure {
    <#
        Per-DP content state. v_PackageStatusDistPointsSumm is the SQL side of
        SMS_PackageStatusDistPointsSummarizer (same class the content script uses).
        v_Package supplies name/type; anything not found there falls back to PackageID.
    #>
    param([Int[]]$States)

    $stateList = $States -join ','
    $query = @"
SELECT
    psd.PackageID,
    pkg.Name          AS PackageName,
    pkg.PackageType,
    psd.ServerNALPath,
    psd.State,
    psd.InstallStatus,
    psd.SummaryDate,
    psd.SourceVersion AS DPVersion,
    pkg.SourceVersion AS CurrentVersion
FROM v_PackageStatusDistPointsSumm psd
LEFT JOIN v_Package pkg ON pkg.PackageID = psd.PackageID
WHERE psd.State IN ($stateList)
"@
    foreach ($row in Invoke-CMSqlQuery -Query $query) {
        $server = Get-ServerFromNALPath $row.ServerNALPath
        if (Test-ExcludedDP $server) { continue }

        $type = if ($null -ne $row.PackageType -and $PackageTypeName.ContainsKey([Int]$row.PackageType)) {
            $PackageTypeName[[Int]$row.PackageType]
        } else { 'Unknown' }

        [PSCustomObject]@{
            ServerName     = $server
            PackageID      = $row.PackageID
            PackageName    = if ($row.PackageName) { $row.PackageName } else { $row.PackageID }
            PackageType    = $type
            State          = $ContentStateName[[Int]$row.State]
            StateCode      = [Int]$row.State
            InstallStatus  = $row.InstallStatus
            SummaryDate    = $row.SummaryDate
            DPVersion      = $row.DPVersion
            CurrentVersion = $row.CurrentVersion
        }
    }
}

#endregion

#region Checks

function Test-DPDiskSpace {
    param(
        [Object[]]$DPs,
        [Object[]]$Inventory,
        [Object[]]$SiteStatus
    )

    $staleCutoff = (Get-Date).AddDays(-$MaxInventoryAgeDays)

    # Index both sources: "SERVER|F" -> row
    $invByKey = @{}
    $lastScanByDP = @{}
    foreach ($row in $Inventory) {
        $lastScanByDP[$row.ServerName] = $row.LastHWScan
        if ($row.DriveLetter) { $invByKey["$($row.ServerName)|$($row.DriveLetter)"] = $row }
    }
    $statusByKey = @{}
    foreach ($row in $SiteStatus) { $statusByKey["$($row.ServerName)|$($row.DriveLetter)"] = $row }

    $diskRows = New-Object System.Collections.Generic.List[Object]
    $findings = New-Object System.Collections.Generic.List[Object]

    foreach ($dp in $DPs) {
        $server = $dp.ServerName
        $lastScan = $lastScanByDP[$server]
        $inventoryStale = (-not $lastScan) -or ($lastScan -lt $staleCutoff)

        if (-not $lastScan) {
            $findings.Add((New-DPFinding -DP $server -Category 'Inventory' -Severity 'Warning' `
                -Issue 'No hardware inventory for this DP (no client, client unhealthy, or name mismatch).' `
                -Recommendation 'Install/repair the CM client on the DP; disk data falls back to site status polling.' `
                -Source 'v_GS_WORKSTATION_STATUS'))
        }
        elseif ($inventoryStale) {
            $findings.Add((New-DPFinding -DP $server -Category 'Inventory' -Severity 'Warning' `
                -Issue ("Hardware inventory is {0:N0} days old (last {1:yyyy-MM-dd})." -f ((Get-Date) - $lastScan).TotalDays, $lastScan) `
                -Recommendation 'Check InventoryAgent.log on the DP and client health; trigger a hardware inventory cycle.' `
                -Source 'v_GS_WORKSTATION_STATUS'))
        }

        foreach ($letter in $DriveThresholds.Keys) {
            $t = $DriveThresholds[$letter]
            $key = "$server|$($letter.ToUpper())"
            $inv = $invByKey[$key]
            $sts = $statusByKey[$key]

            # Prefer inventory; use site status when inventory is missing or stale.
            $src = $null
            if ($inv -and -not $inventoryStale) { $src = $inv; $srcName = 'HardwareInventory'; $asOf = $lastScan }
            elseif ($sts)                       { $src = $sts; $srcName = 'SiteStatus';        $asOf = $sts.TimeReported }
            elseif ($inv)                       { $src = $inv; $srcName = 'HardwareInventory'; $asOf = $lastScan }

            if (-not $src) {
                if ($t.Required -and $lastScan) {
                    $findings.Add((New-DPFinding -DP $server -Category 'Disk' -Severity 'Info' `
                        -Issue "No $($letter): fixed drive reported." `
                        -Recommendation 'Confirm the DP build standard; content library may be on another drive.' `
                        -Source 'v_GS_LOGICAL_DISK'))
                }
                continue
            }

            $totalGB = [Math]::Round([double]$src.SizeMB / 1024, 1)
            $freeGB  = [Math]::Round([double]$src.FreeMB / 1024, 1)
            $pctUsed = if ($totalGB -gt 0) { [Math]::Round(100 * (1 - $freeGB / $totalGB), 1) } else { $null }

            $diskRows.Add([PSCustomObject]@{
                DP          = $server
                Drive       = "$($letter.ToUpper()):"
                TotalGB     = $totalGB
                FreeGB      = $freeGB
                PctUsed     = $pctUsed
                Source      = $srcName
                AsOf        = $asOf
            })

            $detail = "$($letter.ToUpper()): $freeGB GB free of $totalGB GB ($pctUsed% used)"
            $rec = if ($letter -eq 'C') {
                'Clean IIS logs, CCMCache, WinSxS (DISM /StartComponentCleanup), temp; verify content is not landing on C: (NO_SMS_ON_DRIVE.SMS).'
            } else {
                'Remove orphaned/retired content, review DP group assignments, or extend the volume.'
            }

            if ($freeGB -lt $t.MinFreeGB) {
                $findings.Add((New-DPFinding -DP $server -Category 'Disk' -Severity 'Critical' `
                    -Issue "$detail - below $($t.MinFreeGB) GB minimum." -Recommendation $rec -Source $srcName))
            }
            elseif ($null -ne $pctUsed -and $pctUsed -ge $t.CritPctUsed) {
                $findings.Add((New-DPFinding -DP $server -Category 'Disk' -Severity 'High' `
                    -Issue "$detail - at/over $($t.CritPctUsed)% used." -Recommendation $rec -Source $srcName))
            }
            elseif ($null -ne $pctUsed -and $pctUsed -ge $t.WarnPctUsed) {
                $findings.Add((New-DPFinding -DP $server -Category 'Disk' -Severity 'Warning' `
                    -Issue "$detail - at/over $($t.WarnPctUsed)% used." -Recommendation $rec -Source $srcName))
            }
        }
    }

    [PSCustomObject]@{ Findings = $findings; Data = $diskRows }
}

function Test-DPContentFailure {
    param([Object[]]$Content)

    $findings = foreach ($c in $Content) {
        $severity = switch ($c.StateCode) {
            3 { 'Critical' }   # InstallFailed
            6 { 'High' }       # RemovalFailed
            default { 'Warning' }  # Retrying
        }
        $rec = if ($c.StateCode -in 5, 6) {
            'Removal stuck: check smsdpprov.log on the DP and distmgr.log on the site server; Remove-CMContentDistribution again or clear from the content library.'
        } else {
            'Redistribute (Invoke-CMContentRedistribution / console Redistribute); check distmgr.log + PkgXferMgr.log on the site server and smsdpprov.log on the DP.'
        }
        $status = if ($c.InstallStatus) { " - $($c.InstallStatus)" } else { '' }

        New-DPFinding -DP $c.ServerName -Category 'Content' -Severity $severity `
            -Issue ("{0} {1} '{2}' ({3}) since {4:yyyy-MM-dd HH:mm}{5}" -f $c.PackageType, $c.State, $c.PackageName, $c.PackageID, $c.SummaryDate, $status) `
            -Recommendation $rec -Source 'v_PackageStatusDistPointsSumm'
    }

    [PSCustomObject]@{ Findings = @($findings); Data = $Content }
}

#endregion

#region Check registry

# Each entry: scriptblock that returns @{ Findings; Data }. Shared data sets
# (like the DP list) are passed in via $Context so they are queried once.
$CheckRegistry = [ordered]@{
    DiskSpace = {
        param($Context)
        foreach ($l in $DriveThresholds.Keys) {
            if ($l -notmatch '^[A-Za-z]$') { throw "DriveThresholds key '$l' must be a single drive letter." }
        }
        Write-Verbose 'Querying hardware inventory disks...'
        $inv = @(Get-DPDiskInventory -DriveLetters @($DriveThresholds.Keys))
        Write-Verbose 'Querying site system status storage...'
        $sts = @(try { Get-DPSiteSystemStorage } catch { Write-Warning "Site status storage query failed, inventory only: $_" })
        Test-DPDiskSpace -DPs $Context.DPs -Inventory $inv -SiteStatus $sts
    }
    ContentFailures = {
        param($Context)
        $states = @(3, 6)
        if ($IncludeRetrying) { $states += 2, 5 }
        Write-Verbose "Querying content states $($states -join ',')..."
        Test-DPContentFailure -Content @(Get-DPContentFailure -States $states)
    }
}

#endregion

#region Report

function Export-DPHealthReport {
    param(
        [Object[]]$Findings,
        [Hashtable]$Data,
        [Int]$DPCount,
        [String]$Path
    )

    if ($Path -like '*.csv') {
        $Findings | Select-Object DP, Category, Severity, Issue, Recommendation, Source |
            Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
        return
    }

    $enc = { param($s) [System.Net.WebUtility]::HtmlEncode([String]$s) }

    $findingRows = foreach ($f in $Findings) {
        "<tr class='$($f.Severity)'><td>$(& $enc $f.DP)</td><td>$(& $enc $f.Category)</td><td>$(& $enc $f.Severity)</td><td>$(& $enc $f.Issue)</td><td>$(& $enc $f.Recommendation)</td><td>$(& $enc $f.Source)</td></tr>"
    }

    $diskRows = ''
    if ($Data.ContainsKey('DiskSpace')) {
        $diskRows = ($Data.DiskSpace | Sort-Object FreeGB | ForEach-Object {
            "<tr><td>$(& $enc $_.DP)</td><td>$($_.Drive)</td><td>$($_.TotalGB)</td><td>$($_.FreeGB)</td><td>$($_.PctUsed)</td><td>$($_.Source)</td><td>$($_.AsOf)</td></tr>"
        }) -join "`n"
    }

    # --- Take Immediate Action: drives over the threshold, and failed content to redistribute ---
    $urgentDiskRows = ''
    if ($Data.ContainsKey('DiskSpace')) {
        $urgentDiskRows = ($Data.DiskSpace |
            Where-Object { $null -ne $_.PctUsed -and $_.PctUsed -gt $ImmediateActionPctUsed } |
            Sort-Object PctUsed -Descending | ForEach-Object {
                "<tr class='Critical'><td>$(& $enc $_.DP)</td><td>$($_.Drive)</td><td>$($_.PctUsed)</td><td>$($_.FreeGB)</td><td>$($_.TotalGB)</td><td>$($_.Source)</td><td>$($_.AsOf)</td></tr>"
            }) -join "`n"
    }

    # Only InstallFailed (3) needs a redistribute; removal failures and retries are in Findings.
    # One row per content object so each can be redistributed once to all its failed DPs.
    $redistRows = ''
    if ($Data.ContainsKey('ContentFailures')) {
        $redistRows = ($Data.ContentFailures | Where-Object StateCode -eq 3 |
            Group-Object PackageID | Sort-Object Count -Descending | ForEach-Object {
                $first = $_.Group[0]
                $dpList = ($_.Group | ForEach-Object ServerName | Sort-Object -Unique | ForEach-Object { & $enc $_ }) -join '<br>'
                $oldest = ($_.Group | Sort-Object SummaryDate | Select-Object -First 1).SummaryDate
                "<tr class='Critical'><td>$(& $enc $first.PackageName)</td><td>$(& $enc $first.PackageID)</td><td>$(& $enc $first.PackageType)</td><td>$($_.Count)</td><td>$dpList</td><td>$(if ($oldest -is [DateTime]) { $oldest.ToString('yyyy-MM-dd HH:mm') })</td></tr>"
            }) -join "`n"
    }

    $diskSection = if ($urgentDiskRows) {
        "<table><tr><th>DP</th><th>Drive</th><th>% Used</th><th>Free GB</th><th>Total GB</th><th>Source</th><th>As of</th></tr>`n$urgentDiskRows`n</table>"
    } elseif ($Data.ContainsKey('DiskSpace')) {
        "<p class='ok'>No DP drives over $ImmediateActionPctUsed% used.</p>"
    } else {
        "<p>Disk check not run.</p>"
    }

    $redistSection = if ($redistRows) {
        "<table><tr><th>Content</th><th>ID</th><th>Type</th><th># DPs failed</th><th>Failed on</th><th>Failing since</th></tr>`n$redistRows`n</table>"
    } elseif ($Data.ContainsKey('ContentFailures')) {
        "<p class='ok'>No failed content distributions.</p>"
    } else {
        "<p>Content check not run.</p>"
    }

    $count = { param($sev) @($Findings | Where-Object Severity -eq $sev).Count }

    @"
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>CM DP Health</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:20px}
table{border-collapse:collapse;width:100%;margin-bottom:24px;font-size:13px}
th{background:#0078d4;color:#fff;text-align:left}
td,th{border:1px solid #ddd;padding:6px}
.Critical{background:#ffb3b3}.High{background:#ffd699}.Warning{background:#fff2cc}.Info{background:#e8f0e3}
.action{border:2px solid #c00;padding:4px 16px 8px;margin-bottom:24px}
.action h2{color:#c00}.ok{color:#2a7a2a}
</style></head><body>
<h1>Configuration Manager DP Health</h1>
<p>Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') from $(& $enc $SqlServer)/$(& $enc $Database)</p>
<div class="action">
<h2>Take Immediate Action</h2>
<h3>DP drives over $ImmediateActionPctUsed% used</h3>
$diskSection
<h3>Failed content to redistribute</h3>
$redistSection
</div>
<ul>
<li>Distribution points evaluated: $DPCount</li>
<li>Critical: $(& $count 'Critical') &middot; High: $(& $count 'High') &middot; Warning: $(& $count 'Warning') &middot; Info: $(& $count 'Info')</li>
</ul>
<h2>Findings</h2>
<table><tr><th>DP</th><th>Category</th><th>Severity</th><th>Issue</th><th>Recommendation</th><th>Source</th></tr>
$($findingRows -join "`n")
</table>
$(if ($diskRows) { "<h2>All DP drives (lowest free first)</h2><table><tr><th>DP</th><th>Drive</th><th>Total GB</th><th>Free GB</th><th>% Used</th><th>Source</th><th>As of</th></tr>`n$diskRows`n</table>" })
</body></html>
"@ | Out-File -FilePath $Path -Encoding UTF8
}

#endregion

#region Main

$sw = [System.Diagnostics.Stopwatch]::StartNew()

Write-Verbose "Connecting to $SqlServer/$Database"
$context = @{ DPs = @(Get-DPList) }
Write-Verbose "$($context.DPs.Count) distribution points in scope."

$allFindings = New-Object System.Collections.Generic.List[Object]
$allData = @{}

foreach ($name in $CheckRegistry.Keys) {
    if ($name -notin $Check) { continue }
    $checkSw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $result = & $CheckRegistry[$name] $context
        foreach ($f in $result.Findings) { $allFindings.Add($f) }
        $allData[$name] = $result.Data
    }
    catch {
        Write-Warning "Check '$name' failed: $_"
        $allFindings.Add((New-DPFinding -DP '(all)' -Category $name -Severity 'High' `
            -Issue "Check failed to run: $($_.Exception.Message)" -Recommendation 'Verify SQL permissions and view names for this CM version.' -Source 'Script'))
    }
    Write-Verbose ("{0} finished in {1:N1}s" -f $name, $checkSw.Elapsed.TotalSeconds)
}

$sorted = @($allFindings | Sort-Object { $SeverityRank[$_.Severity] }, DP, Category)

if ($ReportPath) {
    Export-DPHealthReport -Findings $sorted -Data $allData -DPCount $context.DPs.Count -Path $ReportPath
    Write-Host "Report written: $ReportPath" -ForegroundColor Green
}

$summary = $sorted | Group-Object Severity | ForEach-Object { "$($_.Name): $($_.Count)" }
Write-Host ("{0} DPs checked in {1:N1}s. {2}" -f $context.DPs.Count, $sw.Elapsed.TotalSeconds, ($summary -join ', '))

if ($PassThruData) {
    [PSCustomObject]@{ Findings = $sorted; Data = $allData; DPs = $context.DPs }
} else {
    $sorted
}

#endregion
