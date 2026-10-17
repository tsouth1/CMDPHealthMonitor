[CmdletBinding()]
param (
    # Site Server
    [Parameter()]
    [String]
    $SiteServer = 'cm-prim01.contoso.com', 

    # Site Code
    [Parameter()]
    [String]
    $SiteCode = 'PS1', 

    # Target Distribution Point
    [Parameter()]
    [String]
    $DistributionPoint , 

    # Target content of supplied Distribution Point Group
    [Parameter()]
    [String]
    $DistributionPointGroup , 

    # Target content of supplied Distribution Point Group
    [Parameter()]
    [String]
    $SourceDP,

    # Length of time to pause between each run default 5 minutes / 300 seconds
    [Parameter()]
    [String]
    $DistributionPause = 45, 

    # Number of minutes to run a single package before time out
    [Parameter()]
    [Int]
    $DistributionTimeout = 120
)

function ConvertTo-PackageIDCIID {
    <#
    .SYNOPSIS
        Get a Configuration Manager Application's CI_ID property from the given PackageID property
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String]$PackageID,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String]$SiteServer,
        
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String]$SiteCode
    )
    begin {
        $Namespace = "ROOT/SMS/Site_{0}" -f $SiteCode
    }
    process {
        $Query = "SELECT SMS_ApplicationLatest.CI_ID 
        FROM SMS_ApplicationLatest
        WHERE SMS_ApplicationLatest.ModelName in (
            SELECT SMS_PackageStatusDistPointsSummarizer.SecureObjectID 
            FROM SMS_PackageStatusDistPointsSummarizer 
            WHERE PackageID = '{0}'
        )" -f $PackageID
        (Get-CimInstance -ComputerName $SiteServer -Namespace $Namespace -Query $Query).CI_ID
    }
    end {

    }
}

function ConvertTo-ModelNameCIID {
    <#
    .SYNOPSIS
        Get a Configuration Manager Application's CI_ID property from the given ModelName property
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String]$ModelName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String]$SiteServer,
        
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String]$SiteCode
    )
    begin {
        $Namespace = "ROOT/SMS/Site_{0}" -f $SiteCode
    }
    process {
        $Query = "SELECT CI_ID FROM SMS_ApplicationLatest WHERE ModelName = '{0}'" -f $ModelName
        (Get-CimInstance -ComputerName $SiteServer -Namespace $Namespace -Query $Query).CI_ID
    }
    end {

    }
}

function Get-DPContent {
    <#
    .SYNOPSIS
        Get all content distributed to a given distribution point.
    .DESCRIPTION
        Get all content distributed to a given distribution point.

        By default this function returns all content object types that match the given distribution point in the SMS_DPContentInfo class on the site server.

        You can filter the content objects by cumulatively using the available switches, e.g. using -Package -DriverPackage will return packages and driver packages.

        Properties returned are: ObjectName, Description, ObjectType, ObjectID, SourceSize, DistributionPoint.
    .PARAMETER DistributionPoint
        Name of distribution point (as it appears in Configuration Manager, usually FQDN) you want to query.
    .PARAMETER Package
        Filter on packages
    .PARAMETER DriverPackage
        Filter on driver packages
    .PARAMETER DeploymentPackage
        Filter on deployment packages
    .PARAMETER OperatingSystemImage
        Filter on Operating System images
    .PARAMETER OperatingSystemInstaller
        Filter on Operating System upgrade images
    .PARAMETER BootImage
        Filter on boot images
    .PARAMETER Application
        Filter on applications
    .PARAMETER SiteServer
        FQDN address of the site server (SMS Provider). 
        
        You only need to use this parameter once for any function of PSCMContentMgmt that also has a -SiteServer parameter. PSCMContentMgmt remembers the site server for subsequent commands, unless you specify the parameter again to change site server.
    .PARAMETER SiteCode
        Site code of which the server specified by -SiteServer belongs to.

        You only need to use this parameter once for any function of PSCMContentMgmt that also has a -SiteCode parameter. PSCMContentMgmt remembers the site code for subsequent commands, unless you specify the parameter again to change site code.
    .INPUTS
        System.String[]
    .OUTPUTS
        System.Management.Automation.PSObject
    .EXAMPLE
        PS C:\> Get-DPContent -Name dp.contoso.com -Package -Application

        Return all packages and applications found on dp.contoso.com.s
    .EXAMPLE
        PS C:\> Get-DP -Name "London%" | Get-DPContent

        Return all content objects found on distribution points where their ServerName starts with "London".
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Alias("Name")]
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [String]$DistributionPoint,

        [Parameter()]
        [Switch]$Package,

        [Parameter()]
        [Switch]$DriverPackage,
        
        [Parameter()]
        [Switch]$DeploymentPackage,
        
        [Parameter()]
        [Switch]$OperatingSystemImage,
        
        [Parameter()]
        [Switch]$OperatingSystemInstaller,
        
        [Parameter()]
        [Switch]$BootImage,
        
        [Parameter()]
        [Switch]$Application,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [String]$SiteServer,
        
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [String]$SiteCode
    )
    begin {
        # Set-SiteServerAndSiteCode -SiteServer $Local:SiteServer -SiteCode $Local:SiteCode
    }
    process {
            $Namespace = "ROOT/SMS/Site_{0}" -f $SiteCode
            $Query = "SELECT * FROM SMS_DPContentInfo WHERE NALPath like '%{0}%'" -f $DistributionPoint
        
            $conditions = switch ($true) {
                $Package                    { "ObjectType = '{0}'" -f [Int][SMS_DPContentInfo]"Package" }
                $DriverPackage              { "ObjectType = '{0}'" -f [Int][SMS_DPContentInfo]"DriverPackage" }
                $DeploymentPackage          { "ObjectType = '{0}'" -f [Int][SMS_DPContentInfo]"DeploymentPackage" }
                $OperatingSystemImage       { "ObjectType = '{0}'" -f [Int][SMS_DPContentInfo]"OperatingSystemImage" }
                $OperatingSystemInstaller   { "ObjectType = '{0}'" -f [Int][SMS_DPContentInfo]"OperatingSystemInstaller" }
                $BootImage                  { "ObjectType = '{0}'" -f [Int][SMS_DPContentInfo]"BootImage" }
                $Application                { "ObjectType = '{0}'" -f [Int][SMS_DPContentInfo]"Application" }
            }
        
            if ($conditions) { 
                $Query = "{0} AND ( {1} )" -f $Query, ([String]::Join(" OR ", $conditions)) 
            }
        
            Get-CimInstance -ComputerName $SiteServer -Namespace $Namespace -Query $Query | ForEach-Object {
                [PSCustomObject]@{
                    PSTypeName        = "PSCMContentMgmt"
                    ObjectName        = $_.Name
                    Description       = $_.Description
                    ObjectType        = ([SMS_DPContentInfo]$_.ObjectType).ToString()
                    ObjectID          = $(if ($_.ObjectType -eq [SMS_DPContentInfo]"Application") {
                        ConvertTo-ModelNameCIID -ModelName $_.ObjectID -SiteServer $SiteServer -SiteCode $SiteCode
                    }
                    else {
                        $_.ObjectID
                    })
                    SourceSize        = $_.SourceSize
                    DistributionPoint = $DistributionPoint
                }
            }
        
    }
    end {
    }
}

function Get-DPDistributionStatus {
    <#
    .SYNOPSIS
        Retrieve the content distribution status of all content objects for a distribution point.
    .DESCRIPTION
        Retrieve the content distribution status of all content objects for a distribution point.
    .PARAMETER DistributionPoint
        Name of distribution point(s) (as it appears in Configuration Manager, usually FQDN) you want to query.
    .PARAMETER Distributed
        Filter on content objects in distributed state
    .PARAMETER DistributionPending
        Filter on content objects in distribution pending state
    .PARAMETER DistributionRetrying
        Filter on content objects in distribution retrying state
    .PARAMETER DistributionFailed
        Filter on content objects in distribution failed state
    .PARAMETER RemovalPending
        Filter on content objects in removal pending state
    .PARAMETER RemovalRetrying
        Filter on content objects in removal retrying state
    .PARAMETER RemovalFailed
        Filter on content objects in removal failed state
    .PARAMETER ContentUpdating
        Filter on content objects in content updating state
    .PARAMETER ContentMonitoring
        Filter on content objects in content monitoring state
    .PARAMETER SiteServer
        FQDN address of the site server (SMS Provider). 
        
        You only need to use this parameter once for any function of PSCMContentMgmt that also has a -SiteServer parameter. PSCMContentMgmt remembers the site server for subsequent commands, unless you specify the parameter again to change site server.
    .PARAMETER SiteCode
        Site code of which the server specified by -SiteServer belongs to.

        You only need to use this parameter once for any function of PSCMContentMgmt that also has a -SiteCode parameter. PSCMContentMgmt remembers the site code for subsequent commands, unless you specify the parameter again to change site code.
    .INPUTS
        System.String[]
    .OUTPUTS
        System.Management.Automation.PSObject
    .EXAMPLE
        PS C:\> Get-DPDistributionStatus -DistributionPoint "dp1.contoso.com"

        Gets the content distribution status for all content objects on dp1.contoso.com.
    .EXAMPLE
        PS C:\> Get-DPDistributionStatus -DistributionPoint "dp1.contoso.com" | Start-DPContentRedistribution

        Gets the content distribution status for content objects in DistributionFailed state on dp1.contoso.com and initiates redisitribution for each of those content objects.
    .EXAMPLE
        PS C:\> Get-DP | Get-DPDistributionStatus -DistributionFailed | Group-Object -Property DistributionPoint

        Return all distribution points, their associated failed distribution tasks and group the results by distribution point name for an overview.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Alias("Name", "ServerName")]
        [ParameteR(Mandatory, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [String]$DistributionPoint,

        [Parameter()]
        [Switch]$Distributed,

        [Parameter()]
        [Switch]$DistributionPending,

        [Parameter()]
        [Switch]$DistributionRetrying,

        [Parameter()]
        [Switch]$DistributionFailed,

        [Parameter()]
        [Switch]$RemovalPending,

        [Parameter()]
        [Switch]$RemovalRetrying,

        [Parameter()]
        [Switch]$RemovalFailed,

        [Parameter()]
        [Switch]$ContentUpdating,

        [Parameter()]
        [Switch]$ContentMonitoring,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [String]$SiteServer,
        
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [String]$SiteCode
    )
    begin {
        #Set-SiteServerAndSiteCode -SiteServer $Local:SiteServer -SiteCode $Local:SiteCode
    }
    process {
        $Namespace = "ROOT/SMS/Site_{0}" -f $SiteCode
        $Query = "SELECT PackageID,PackageType,State,SourceVersion FROM SMS_PackageStatusDistPointsSummarizer WHERE ServerNALPath like '%{0}%'" -f $DistributionPoint

        $conditions = switch ($true) {
            $Distributed          { "State = '{0}'" -f [Int][SMS_PackageStatusDistPointsSummarizer_State]"DISTRIBUTED" }
            $DistributionPending  { "State = '{0}'" -f [Int][SMS_PackageStatusDistPointsSummarizer_State]"DISTRIBUTION_PENDING" }
            $DistributionRetrying { "State = '{0}'" -f [Int][SMS_PackageStatusDistPointsSummarizer_State]"DISTRIBUTION_RETRYING" }
            $DistributionFailed   { "State = '{0}'" -f [Int][SMS_PackageStatusDistPointsSummarizer_State]"DISTRIBUTION_FAILED" }
            $RemovalPending       { "State = '{0}'" -f [Int][SMS_PackageStatusDistPointsSummarizer_State]"REMOVAL_PENDING" }
            $RemovalRetrying      { "State = '{0}'" -f [Int][SMS_PackageStatusDistPointsSummarizer_State]"REMOVAL_RETRYING" }
            $RemovalFailed        { "State = '{0}'" -f [Int][SMS_PackageStatusDistPointsSummarizer_State]"REMOVAL_FAILED" }
            $ContentUpdating      { "State = '{0}'" -f [Int][SMS_PackageStatusDistPointsSummarizer_State]"CONTENT_UPDATING" }
            $ContentMonitoring    { "State = '{0}'" -f [Int][SMS_PackageStatusDistPointsSummarizer_State]"CONTENT_MONITORING" }
        }

        if ($conditions) {
            $Query = "{0} AND ( {1} )" -f $Query, ([String]::Join(" OR ", $conditions)) 
        }

        Get-CimInstance -ComputerName $SiteServer -Namespace $Namespace -Query $Query | ForEach-Object {
            [PSCustomObject]@{
                PSTypeName        = "PSCMContentMgmt"
                ObjectID          = $(if ($_.PackageType -eq [SMS_PackageStatusDistPointsSummarizer_PackageType]"Application") { 
                    ConvertTo-PackageIDCIID -PackageID $_.PackageID -SiteServer $SiteServer -SiteCode $SiteCode
                }
                else {
                    $_.PackageID
                })
                ObjectType        = ([SMS_PackageStatusDistPointsSummarizer_PackageType]$_.PackageType).ToString()
                State             = [SMS_PackageStatusDistPointsSummarizer_State]$_.State
                SourceVersion     = $_.SourceVersion
                DistributionPoint = $DistributionPoint
            }
        }        
    }
    end {
    }
}

function Get-DPGroupContent {
    <#
    .SYNOPSIS
        Get all content distributed to a given distribution point group.
    .DESCRIPTION
        Get all content distributed to a given distribution point group.

        By default this function returns all content object types that match the given distribution point group in the SMS_DPGroupContentInfo class on the site server.

        You can filter the content objects by cumulatively using the available switches, e.g. using -Package -DriverPackage will return packages and driver packages.

        Properties returned are: ObjectName, Description, ObjectType, ObjectID, SourceSize, DistributionPoint.
    .PARAMETER DistributionPointGroup
        Name of distribution point group you want to query.
    .PARAMETER Package
        Filter on packages
    .PARAMETER DriverPackage
        Filter on driver packages
    .PARAMETER DeploymentPackage
        Filter on deployment packages
    .PARAMETER OperatingSystemImage
        Filter on Operating System images
    .PARAMETER OperatingSystemInstaller
        Filter on Operating System upgrade images
    .PARAMETER BootImage
        Filter on boot images
    .PARAMETER Application
        Filter on applications
    .PARAMETER SiteServer
        FQDN address of the site server (SMS Provider). 
        
        You only need to use this parameter once for any function of PSCMContentMgmt that also has a -SiteServer parameter. PSCMContentMgmt remembers the site server for subsequent commands, unless you specify the parameter again to change site server.
    .PARAMETER SiteCode
        Site code of which the server specified by -SiteServer belongs to.

        You only need to use this parameter once for any function of PSCMContentMgmt that also has a -SiteCode parameter. PSCMContentMgmt remembers the site code for subsequent commands, unless you specify the parameter again to change site code.
    .INPUTS
        System.String[]
    .OUTPUTS
        System.Management.Automation.PSObject
    .EXAMPLE
        PS C:\> Get-DPGroupContent -DistributionPointGroup "Asia DPs" -Package -Application

        Return all packages and applications found in the distribution point group "Asia DPs"
    .EXAMPLE
        PS C:\> Get-DPGroup -Name "All DPs" | Get-DPGroupContent

        Get all the content associated with the distribution point group "All DPs".
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Alias("Name")]
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [String[]]$DistributionPointGroup,

        [Parameter()]
        [Switch]$Package,

        [Parameter()]
        [Switch]$DriverPackage,
        
        [Parameter()]
        [Switch]$DeploymentPackage,
        
        [Parameter()]
        [Switch]$OperatingSystemImage,
        
        [Parameter()]
        [Switch]$OperatingSystemInstaller,
        
        [Parameter()]
        [Switch]$BootImage,
        
        [Parameter()]
        [Switch]$Application,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [String]$SiteServer,
        
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [String]$SiteCode
    )
    begin {
        # Set-SiteServerAndSiteCode -SiteServer $Local:SiteServer -SiteCode $Local:SiteCode
    }
    process {
            $Namespace = "ROOT/SMS/Site_{0}" -f $SiteCode
            $Query = "SELECT * 
            FROM SMS_DPGroupContentInfo 
            WHERE SMS_DPGroupContentInfo.GroupID in (
                SELECT SMS_DPGroupInfo.GroupID
                FROM SMS_DPGroupInfo
                WHERE Name = '{0}'
            )" -f $DistributionPointGroup
        
            $conditions = switch ($true) {
                $Package                    { "ObjectType = '{0}'" -f [Int][SMS_DPContentInfo]"Package" }
                $DriverPackage              { "ObjectType = '{0}'" -f [Int][SMS_DPContentInfo]"DriverPackage" }
                $DeploymentPackage          { "ObjectType = '{0}'" -f [Int][SMS_DPContentInfo]"DeploymentPackage" }
                $OperatingSystemImage       { "ObjectType = '{0}'" -f [Int][SMS_DPContentInfo]"OperatingSystemImage" }
                $OperatingSystemInstaller   { "ObjectType = '{0}'" -f [Int][SMS_DPContentInfo]"OperatingSystemInstaller" }
                $BootImage                  { "ObjectType = '{0}'" -f [Int][SMS_DPContentInfo]"BootImage" }
                $Application                { "ObjectType = '{0}'" -f [Int][SMS_DPContentInfo]"Application" }
            }
        
            if ($conditions) { 
                $Query = "{0} AND ( {1} )" -f $Query, ([String]::Join(" OR ", $conditions)) 
            }
        
            Get-CimInstance -ComputerName $SiteServer -Namespace $Namespace -Query $Query | ForEach-Object {
                [PSCustomObject]@{
                    PSTypeName             = "PSCMContentMgmt"
                    ObjectName             = $_.Name
                    Description            = $_.Description
                    ObjectType             = ([SMS_DPContentInfo]$_.ObjectType).ToString()
                    ObjectID               = $(if ($_.ObjectType -eq [SMS_DPContentInfo]"Application") {
                        ConvertTo-ModelNameCIID -ModelName $_.ObjectID -SiteServer $SiteServer -SiteCode $SiteCode
                    }
                    else {
                        $_.ObjectID
                    })
                    SourceSize             = $_.SourceSize
                    DistributionPointGroup = $DistributionPointGroup
                }
            }
        
    }
    end {
    }
}

enum SMS_PackageStatusDistPointsSummarizer_PackageType {
    Package
    DriverPackage               = 3
    DeploymentPackage           = 5
    Application                 = 8
    OperatingSystemImage        = 257
    OperatingSystemInstaller    = 259
    BootImage                   = 258
}

enum SMS_DPContentInfo {
    Package
    DriverPackage               = 3
    TaskSequence                = 4
    DeploymentPackage           = 5
    OperatingSystemImage        = 257
    OperatingSystemInstaller    = 259
    BootImage                   = 258
    Application                 = 512
}

enum SMS_PackageStatusDistPointsSummarizer_State {
    DISTRIBUTED
    DISTRIBUTION_PENDING        = 1
    DISTRIBUTION_RETRYING       = 2
    DISTRIBUTION_FAILED         = 3
    REMOVAL_PENDING             = 4
    REMOVAL_RETRYING            = 5
    REMOVAL_FAILED              = 6
    CONTENT_UPDATING            = 7
    CONTENT_MONITORING          = 8
}

<#
$SiteServer = 'cm-prim02.contoso.com'
$SiteCode = 'PS1'
$DistributionPoint = 'dp01.contoso.com'
$DistributionPointGroup = 'All DPs - Exclude Source and CMG' #'Windows Updates - All Distribution Points'
$DistributionPause = 300 # Default 5 minutes pause with each distribution status check
$DistributionTimeout = 10 # Default 10 minute duration for current package resulting in error
#>

# get package list 	Windows Updates - All Distribution Points
# $dpGroupContent = Get-DPGroupContent -DistributionPointGroup $DistributionPointGroup -SiteServer $SiteServer -SiteCode $SiteCode #-DeploymentPackage
# Write-Output "DP Content Group: $DistributionPointGroup Total: $($dpGroupContent.Count)"

if ($SourceDP) {
    $dpGroupContent = Get-DPDistributionStatus -DistributionPoint $SourceDP -SiteServer $SiteServer -SiteCode $SiteCode -Distributed
    Write-Output "DP Source: $SourceDP Total: $($dpGroupContent.Count)"
}
else {
    $dpGroupContent = Get-DPGroupContent -DistributionPointGroup $DistributionPointGroup -SiteServer $SiteServer -SiteCode $SiteCode #-DeploymentPackage
    Write-Output "DP Content Group: $DistributionPointGroup Total: $($dpGroupContent.Count)"
}

$dpStatus = Get-DPDistributionStatus -DistributionPoint $DistributionPoint -SiteServer $SiteServer -SiteCode $SiteCode
Write-Output "DP Content Status: $DistributionPoint Existing Total: $($dpStatus.Count)"

$dpRemainingIDs = Compare-Object -ReferenceObject $dpGroupContent -DifferenceObject $dpStatus -Property ObjectID | ? { $_.SideIndicator -eq '<=' } | Select-Object -ExpandProperty ObjectID # | Select-Object -First 5
Write-Output "Remaining Total: $($dpRemainingIDs.Count)"

#while ($dpRemainingIDs) {
$i = 0
foreach ($targetContentID in $dpRemainingIDs) {
    $targetContentObj = $dpGroupContent | ? { $_.ObjectID -eq "$targetContentID" } | Select-Object -First 1
    $currentStart = Get-Date
    $i++
    Write-Output "Initiating Content: $targetContentID at $currentStart | $i of $($dpRemainingIDs.Count) | $(Get-Date)"

    $dpContentUpdating = Get-DPDistributionStatus -DistributionPoint $DistributionPoint -SiteServer $SiteServer -SiteCode $SiteCode -ContentUpdating -DistributionPending
    Write-Output "Inflight Count: $(($dpContentUpdating | measure-object).Count)"

    #while ($dpContentUpdating) { 
    while ( $(($dpContentUpdating | measure-object).Count) -ge 5 ) {
        Write-Output "Pause, existing Content Inflight.  Distributing: $(($dpContentUpdating | measure-object).Count) | $i of $($dpRemainingIDs.Count) | $(Get-Date)" 
        Write-Output "Sleep $DistributionPause seconds  Current Package: $targetContentID Total Sleep Time: $(((get-date) - $currentStart).TotalMinutes)"
        Start-Sleep -Seconds $DistributionPause # pause 5 minutes to allow package to send
        $dpContentUpdating = Get-DPDistributionStatus -DistributionPoint $DistributionPoint -SiteServer $SiteServer -SiteCode $SiteCode -ContentUpdating -DistributionPending
        
        if ($(((get-date) - $currentStart).TotalMinutes) -gt $DistributionTimeout) { Write-Output "exit over $DistributionTimeout minutes on package $targetContentID Total Minutes: $(((get-date) - $currentStart).TotalMinutes)" }
    }    

    Write-Output "*** Send Content $targetContentID to DistributionPointName $DistributionPoint Start: $(($currentStart).ToString("yyyyMMdd_hhmmsshhh")) | $i of $($dpRemainingIDs.Count) | $(Get-Date)"
    try {
        switch ($($targetContentObj.ObjectType)) {
            Package { Start-CMContentDistribution -PackageId @("$targetContentID") -DistributionPointName @("$DistributionPoint") }
            DriverPackage { Start-CMContentDistribution -DriverPackageId @("$targetContentID") -DistributionPointName @("$DistributionPoint") }
            DeploymentPackage { Start-CMContentDistribution -DeploymentPackageId @("$targetContentID") -DistributionPointName @("$DistributionPoint") }
            OperatingSystemImage { Start-CMContentDistribution -OperatingSystemImageId @("$targetContentID") -DistributionPointName @("$DistributionPoint") }
            OperatingSystemInstaller { Start-CMContentDistribution -OperatingSystemInstallerId @("$targetContentID") -DistributionPointName @("$DistributionPoint") }
            BootImage { Start-CMContentDistribution -BootImageId @("$targetContentID") -DistributionPointName @("$DistributionPoint") }
            Application { Start-CMContentDistribution -ApplicationId @("$targetContentID") -DistributionPointName @("$DistributionPoint") }
            Default { Write-Output "Unknown Content ObjectID $targetContentID Object Type $($targetContentObj.ObjectType) Not Supported" }
        }
    }
    catch {
        Write-Output "Skipping Content: $targetContentID Type: $($targetContentObj.ObjectType) | $i of $($dpRemainingIDs.Count) | $(Get-Date)"
    }    

    Write-Output "Sleep $DistributionPause Seconds then recheck"
    Start-Sleep -Seconds $DistributionPause # pause 5 minutes to allow package to send
}
