<# 
=========================================================================
SCCM Distribution Point Health Check
=========================================================================
Author: Enterprise SCCM Health Check
Requirements:
- SCCM Console Installed
- SMS Provider Access
- Remote WMI Access
- PowerShell 5+
=========================================================================
#>
#Import-Module SqlServer -ErrorAction Stop
function Get-DPDiskSpaceData {

    $SqlServer = "cm-sql01.contoso.com"
    $Database  = "CM_PS1"

    $Query = @"
SELECT
    UPPER(LEFT(dp.ServerName, CHARINDEX('.', dp.ServerName + '.') - 1)) AS DPName,
    SUBSTRING(
        ss.SiteObject,
        CHARINDEX('$', ss.SiteObject) - 1,
        1
    ) AS DriveLetter,
    CAST(ss.BytesTotal / 1073741824.0 AS DECIMAL(18,2)) AS TotalGB,
    CAST(ss.BytesFree / 1073741824.0 AS DECIMAL(18,2)) AS FreeGB,
    ss.PercentFree
FROM vSummarizer_SiteSystem ss
LEFT JOIN vDistributionPoints dp
    ON dp.ServerName =
       UPPER(
           SUBSTRING(
               ss.SiteSystem,
               CHARINDEX('\\', ss.SiteSystem) + 2,
               CHARINDEX('"]', ss.SiteSystem) - CHARINDEX('\\', ss.SiteSystem) - 3
           )
       )
WHERE ss.Role = 'SMS Distribution Point'
  AND SUBSTRING(
        ss.SiteObject,
        CHARINDEX('$', ss.SiteObject) - 1,
        1
      ) IN ('C','F')
      AND ss.BytesFree < (40 * 1073741824)
"@

    Invoke-Sqlcmd `
        -ServerInstance $SqlServer `
        -Database $Database `
        -Query $Query
}

#region Variables

$SiteCode = "PS1"
$ProviderMachine = "cm-prim01.contoso.com"

$ReportPath = "C:\temp\DPHealthReport.html"

Import-Module "$($ENV:SMS_ADMIN_UI_PATH)\..\ConfigurationManager.psd1"
Set-Location "$SiteCode`:"

$HealthIssues = @()

#endregion

#region Functions

function Add-HealthIssue {

 param(
 [String]$DP,
 [String]$Category,
 [String]$Severity,
 [String]$Issue,
 [String]$Recommendation
 )

 $script:HealthIssues += [PSCustomObject]@{
 DP = $DP
 Category = $Category
 Severity = $Severity
 Issue = $Issue
 Recommendation = $Recommendation
 }
}

#endregion

Write-Host "Collecting Distribution Points..."

$DPs = Get-CMDistributionPoint
try
{
    $DiskData = Get-DPDiskSpaceData
}
catch
{
    Write-Warning "Failed to retrieve DP disk data: $_"
    $DiskData = @()
}

#region DP Analysis

foreach($DP in $DPs)
{
 $Server = (($DP.NetworkOSPath -replace "\\","").Split(".")[0]).ToUpper()

 Write-Host "Checking $Server"

 #--------------------------------------------------------------
 # Connectivity
 #--------------------------------------------------------------

 if(!(Test-Connection $Server -Count 1 -Quiet))
 {
 Add-HealthIssue `
 -DP $Server `
 -Category "Availability" `
 -Severity "Critical" `
 -Issue "Distribution Point unreachable" `
 -Recommendation "Verify server availability, firewall rules, DNS and site boundaries."

 continue
 }

 #--------------------------------------------------------------
 # Disk Space
 #--------------------------------------------------------------

 $Volumes =
    $DiskData |
    Where-Object { $_.DPName -eq $Server }

foreach($Volume in $Volumes)
{
    Add-HealthIssue `
        -DP $Server `
        -Category "Disk" `
        -Severity "Critical" `
        -Issue "$($Volume.DriveLetter): drive has only $([math]::Round($Volume.FreeGB,2)) GB free" `
        -Recommendation "Free space, move content, clean logs or expand volume."
}

 #--------------------------------------------------------------
 # PXE Status
 #--------------------------------------------------------------

 if(!$DP.IsPxe)
 {
 Add-HealthIssue `
 -DP $Server `
 -Category "PXE" `
 -Severity "Warning" `
 -Issue "PXE is not enabled." `
 -Recommendation "Validate if PXE is expected. Enable PXE if this DP supports OSD."
 }

 #--------------------------------------------------------------
 # DP Group Membership
 #--------------------------------------------------------------

 $GroupMemberships =
 Get-CMDistributionPointGroup |
 Where-Object {
 $_.Members -match $Server
 }

 if($GroupMemberships.Count -lt 2)
 {
 Add-HealthIssue `
 -DP $Server `
 -Category "Design" `
 -Severity "Warning" `
 -Issue "Member of fewer than 2 DP Groups." `
 -Recommendation "Place DP into multiple regional/service groups to improve administration."
 }

 #--------------------------------------------------------------
 # Critical Services
 #--------------------------------------------------------------

 $Services =
 Invoke-Command -ComputerName $Server {

 Get-Service `
 -Name W3SVC,WDSServer,SMSExecutive `
 -ErrorAction SilentlyContinue
 }

 foreach($Svc in $Services)
 {
 if($Svc.Status -ne "Running")
 {
 Add-HealthIssue `
 -DP $Server `
 -Category "Service" `
 -Severity "Critical" `
 -Issue "$($Svc.Name) service not running" `
 -Recommendation "Restart service and review related logs."
 }
 }

 #--------------------------------------------------------------
 # Event Log Errors
 #--------------------------------------------------------------

 try
 {
 $Errors =
 Get-WinEvent `
 -ComputerName $Server `
 -FilterHashtable @{
 LogName='Application'
 StartTime=(Get-Date).AddHours(-24)
 Level=2
 } -ErrorAction SilentlyContinue

 if($Errors.Count -gt 25)
 {
 Add-HealthIssue `
 -DP $Server `
 -Category "Events" `
 -Severity "High" `
 -Issue "$($Errors.Count) application errors in last 24 hours." `
 -Recommendation "Review Application log for DP and IIS failures."
 }
 }
 catch{}
}

#endregion

#region Failed Distributions

Write-Host "Checking content distribution status..."

$Status =
Get-CMContentDistribution

foreach($Item in $Status)
{
 if($Item.State -match "Failed")
 {
 Add-HealthIssue `
 -DP $Item.ServerName `
 -Category "Content Distribution" `
 -Severity "Critical" `
 -Issue "$($Item.PackageName) distribution failed" `
 -Recommendation "Redistribute content and inspect DistMgr.log and PkgXferMgr.log."
 }
}

#endregion

#region Content Stuck >24 Hours

$DistStatus =
Get-WmiObject `
-Namespace "root\SMS\site_$SiteCode" `
-Class SMS_ObjectContentExtraInfo

foreach($Dist in $DistStatus)
{
 if(
 $Dist.LastUpdateTime -and
 ([System.Management.ManagementDateTimeConverter]::ToDateTime($Dist.LastUpdateTime)) -lt (Get-Date).AddDays(-1)
 )
 {
 Add-HealthIssue `
 -DP "Various" `
 -Category "Distribution" `
 -Severity "High" `
 -Issue "Content appears in progress longer than 24 hours." `
 -Recommendation "Review Distribution Status and redistribute stuck content."
 }
}

#endregion

#region Naming Review

$Names = $DPs.ServerName

$Prefixes = @{}

foreach($Name in $Names)
{
 if($Name -match "^([A-Z]{5})")
 {
 $Prefix = $Matches[1]

 if(!$Prefixes.ContainsKey($Prefix))
 {
 $Prefixes[$Prefix] = @()
 }

 $Prefixes[$Prefix] += $Name
 }
}

foreach($Prefix in $Prefixes.Keys)
{
 if($Prefixes[$Prefix].Count -gt 1)
 {
 Add-HealthIssue `
 -DP ($Prefixes[$Prefix] -join ",") `
 -Category "Duplicate Naming" `
 -Severity "Info" `
 -Issue "Multiple DPs share prefix $Prefix" `
 -Recommendation "Validate servers are intended regional peers and not duplicate entries."
 }
}

#endregion

#region HTML Report

$Style = @"
<style>
body{font-family:Segoe UI}
table{border-collapse:collapse;width:100%}
th{background:#0078d4;color:white}
td,th{border:1px solid #ddd;padding:8px}
.Critical{background:#ffb3b3;}
.High{background:#ffd699;}
.Warning{background:#fff2cc;}
.Info{background:#d9ead3;}
</style>
"@

$Rows = foreach($Issue in $HealthIssues)
{
 "<tr class='$($Issue.Severity)'>
 <td>$($Issue.DP)</td>
 <td>$($Issue.Category)</td>
 <td>$($Issue.Severity)</td>
 <td>$($Issue.Issue)</td>
 <td>$($Issue.Recommendation)</td>
 </tr>"
}

$Html = @"
<html>
<head>
$Style
</head>
<body>

<h1>SCCM Distribution Point Health Report</h1>

<p>Generated: $(Get-Date)</p>

<h2>Summary</h2>

<ul>
<li>Total DPs: $($DPs.Count)</li>
<li>Critical Issues: $(($HealthIssues | ? Severity -eq 'Critical').Count)</li>
<li>High Issues: $(($HealthIssues | ? Severity -eq 'High').Count)</li>
<li>Warnings: $(($HealthIssues | ? Severity -eq 'Warning').Count)</li>
</ul>

<table>
<tr>
<th>DP</th>
<th>Category</th>
<th>Severity</th>
<th>Issue</th>
<th>Recommended Remediation</th>
</tr>

$($Rows -join "`n")

</table>

</body>
</html>
"@

$Html | Out-File $ReportPath -Encoding UTF8

Write-Host ""
Write-Host "Report Created:"
Write-Host $ReportPath -ForegroundColor Green