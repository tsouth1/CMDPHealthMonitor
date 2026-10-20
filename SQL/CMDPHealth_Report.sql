/*
=============================================================================
 Configuration Manager - Distribution Point Health (report dataset)
=============================================================================
 Single result set combining the checks in Get-CMDPHealth.ps1:
   - Disk     : C: / F: free space and % used for every DP (all drives returned,
                healthy ones with Severity = 'OK')
   - Inventory: DPs with no or stale hardware inventory
   - Content  : content in Failed (and optionally Retrying) state on any DP

 Report Builder / SSRS usage
   - Data source : the site's shared ConfigMgr data source (the GUID-named
                   data source in the ConfigMgr reporting folder).
   - Dataset     : Query type = Text, paste this whole file.
   - 'Take Immediate Action' section: filter on [Immediate Action] = 'Yes'
       * Disk rows    -> drives over @ImmediateActionPctUsed % used
       * Content rows -> InstallFailed content that needs a redistribute
     Group content rows on [Content ID] to get one line per item with its DPs.
   - Sort on [Severity Rank] (0 = Critical ... 4 = OK).

 Settings are local variables (DECLARE), so this runs as-is in SSMS and Report
 Builder will not prompt for them. To expose one as a report parameter, delete
 its DECLARE line; Report Builder then creates the parameter automatically.

 Disk data source per DP/drive: hardware inventory (v_GS_LOGICAL_DISK) when it
 is newer than @MaxInventoryAgeDays, otherwise site status polling
 (v_SiteSystemSummarizer, reported in KB), otherwise the stale inventory.
=============================================================================
*/
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

-- Guard: fail fast with a clear message when the data source points at the
-- wrong database (e.g. master) instead of the ConfigMgr site database.
IF OBJECT_ID('dbo.v_DistributionPoints') IS NULL
BEGIN
    DECLARE @GuardDb    nvarchar(128) = DB_NAME();
    DECLARE @GuardLogin nvarchar(128) = SUSER_SNAME();
    RAISERROR(N'Connected to database [%s] as [%s], which is not a ConfigMgr site database (v_DistributionPoints not found). Use the ConfigMgr shared data source in the ConfigMgr_<SiteCode> folder, or point the connection at CM_<SiteCode>.',
              16, 1, @GuardDb, @GuardLogin);
    RETURN;
END;

DECLARE @MaxInventoryAgeDays    int          = 7;    -- inventory older than this is stale
DECLARE @ImmediateActionPctUsed decimal(5,1) = 90;   -- drives above this % used -> Immediate Action
DECLARE @IncludeRetrying        bit          = 0;    -- 1 = also list content in Retrying state

WITH Thresholds AS (
    -- Edit / add drives here: letter, minimum free GB, warn % used, high % used
    SELECT DriveLetter, MinFreeGB, WarnPctUsed, CritPctUsed
    FROM (VALUES
        ('C', 20, CAST(70 AS decimal(5,1)), CAST(80 AS decimal(5,1))),
        ('F', 50, CAST(70 AS decimal(5,1)), CAST(80 AS decimal(5,1)))
    ) AS t (DriveLetter, MinFreeGB, WarnPctUsed, CritPctUsed)
),
DP AS (
    SELECT DISTINCT
        UPPER(dp.ServerName)                                                AS ServerName,
        UPPER(LEFT(dp.ServerName, CHARINDEX('.', dp.ServerName + '.') - 1)) AS NetbiosName,
        dp.SMSSiteCode                                                      AS SiteCode
    FROM v_DistributionPoints dp
    WHERE dp.ServerName NOT LIKE '%.cloudapp.net'
      AND dp.ServerName NOT LIKE '%.cloudapp.azure.com'
),
Sys AS (
    -- Newest non-obsolete client record per NetBIOS name
    SELECT
        s.ResourceID,
        UPPER(s.Name0) AS NetbiosName,
        ws.LastHWScan,
        ROW_NUMBER() OVER (PARTITION BY s.Name0 ORDER BY ws.LastHWScan DESC) AS rn
    FROM v_R_System s
    LEFT JOIN v_GS_WORKSTATION_STATUS ws ON ws.ResourceID = s.ResourceID
    WHERE ISNULL(s.Obsolete0, 0) = 0
      AND ISNULL(s.Decommissioned0, 0) = 0
),
DPSys AS (
    SELECT
        dp.ServerName,
        dp.SiteCode,
        sys.ResourceID,
        sys.LastHWScan,
        CASE
            WHEN sys.LastHWScan IS NULL THEN 1
            WHEN sys.LastHWScan < DATEADD(DAY, -@MaxInventoryAgeDays, GETDATE()) THEN 1
            ELSE 0
        END AS InventoryStale
    FROM DP dp
    LEFT JOIN Sys sys
           ON sys.NetbiosName = dp.NetbiosName
          AND sys.rn = 1
),
Inv AS (
    -- Hardware inventory, Size0 / FreeSpace0 in MB
    SELECT
        ds.ServerName,
        LEFT(ld.DeviceID0, 1)        AS DriveLetter,
        CAST(ld.Size0 AS float)      AS SizeMB,
        CAST(ld.FreeSpace0 AS float) AS FreeMB
    FROM DPSys ds
    INNER JOIN v_GS_LOGICAL_DISK ld
            ON ld.ResourceID = ds.ResourceID
           AND ld.DriveType0 = 3
    INNER JOIN Thresholds t ON t.DriveLetter = LEFT(ld.DeviceID0, 1)
),
SiteStatusRaw AS (
    -- SiteSystem: ["Display=\\SERVER.contoso.com\"]MSWNET:["SMS_SITE=PS1"]\\SERVER.contoso.com\
    -- SiteObject: ...\\SERVER.contoso.com\F$\...
    SELECT
        ss.SiteSystem,
        ss.SiteObject,
        ss.BytesTotal,
        ss.BytesFree,
        ss.TimeReported,
        CHARINDEX('\\', ss.SiteSystem) AS PosServer,
        CHARINDEX('$', ss.SiteObject)  AS PosDollar
    FROM v_SiteSystemSummarizer ss
    WHERE ss.Role = 'SMS Distribution Point'
),
SiteStatus AS (
    SELECT
        UPPER(SUBSTRING(r.SiteSystem, r.PosServer + 2,
              CHARINDEX('\', r.SiteSystem + '\', r.PosServer + 2) - r.PosServer - 2)) AS ServerName,
        UPPER(SUBSTRING(r.SiteObject, r.PosDollar - 1, 1)) AS DriveLetter,
        CAST(r.BytesTotal AS float) / 1024 AS SizeMB,   -- KB -> MB
        CAST(r.BytesFree  AS float) / 1024 AS FreeMB,
        r.TimeReported
    FROM SiteStatusRaw r
    WHERE r.PosServer > 0
      AND r.PosDollar > 1
),
SiteStatusLatest AS (
    SELECT
        s.*,
        ROW_NUMBER() OVER (PARTITION BY s.ServerName, s.DriveLetter ORDER BY s.TimeReported DESC) AS rn
    FROM SiteStatus s
),
Disk AS (
    -- One row per DP per threshold drive, picking the best available source
    SELECT
        ds.ServerName,
        ds.SiteCode,
        ds.LastHWScan,
        t.DriveLetter,
        t.MinFreeGB,
        t.WarnPctUsed,
        t.CritPctUsed,
        CASE
            WHEN i.ServerName IS NOT NULL AND ds.InventoryStale = 0 THEN 'Hardware Inventory'
            WHEN ss.ServerName IS NOT NULL                          THEN 'Site Status'
            WHEN i.ServerName IS NOT NULL                           THEN 'Hardware Inventory (stale)'
        END AS DataSource,
        CASE
            WHEN i.ServerName IS NOT NULL AND ds.InventoryStale = 0 THEN i.SizeMB
            WHEN ss.ServerName IS NOT NULL                          THEN ss.SizeMB
            ELSE i.SizeMB
        END AS SizeMB,
        CASE
            WHEN i.ServerName IS NOT NULL AND ds.InventoryStale = 0 THEN i.FreeMB
            WHEN ss.ServerName IS NOT NULL                          THEN ss.FreeMB
            ELSE i.FreeMB
        END AS FreeMB,
        CASE
            WHEN i.ServerName IS NOT NULL AND ds.InventoryStale = 0 THEN ds.LastHWScan
            WHEN ss.ServerName IS NOT NULL                          THEN ss.TimeReported
            ELSE ds.LastHWScan
        END AS AsOf
    FROM DPSys ds
    CROSS JOIN Thresholds t
    LEFT JOIN Inv i
           ON i.ServerName  = ds.ServerName
          AND i.DriveLetter = t.DriveLetter
    LEFT JOIN SiteStatusLatest ss
           ON ss.ServerName  = ds.ServerName
          AND ss.DriveLetter = t.DriveLetter
          AND ss.rn = 1
),
DiskCalc AS (
    SELECT
        d.*,
        CAST(ROUND(d.SizeMB / 1024, 1) AS decimal(10,1)) AS TotalGB,
        CAST(ROUND(d.FreeMB / 1024, 1) AS decimal(10,1)) AS FreeGB,
        CAST(CASE WHEN d.SizeMB > 0 THEN ROUND(100.0 * (1 - d.FreeMB / d.SizeMB), 1) END AS decimal(5,1)) AS PctUsed
    FROM Disk d
),
DiskEval AS (
    SELECT
        c.*,
        CASE
            WHEN c.DataSource IS NULL       THEN 'Info'      -- drive not reported
            WHEN c.FreeGB  < c.MinFreeGB    THEN 'Critical'
            WHEN c.PctUsed >= c.CritPctUsed THEN 'High'
            WHEN c.PctUsed >= c.WarnPctUsed THEN 'Warning'
            ELSE 'OK'
        END AS Severity
    FROM DiskCalc c
    -- DPs with no inventory at all are reported once in the Inventory rows instead
    WHERE c.DataSource IS NOT NULL
       OR c.LastHWScan IS NOT NULL
),
Content AS (
    SELECT
        dp.ServerName,
        dp.SiteCode,
        psd.PackageID,
        COALESCE(pkg.Name, psd.PackageID) AS PackageName,
        CASE pkg.PackageType
            WHEN 0   THEN 'Package'
            WHEN 3   THEN 'Driver Package'
            WHEN 4   THEN 'Task Sequence'
            WHEN 5   THEN 'Software Update Package'
            WHEN 6   THEN 'Device Setting Package'
            WHEN 7   THEN 'Virtual Application'
            WHEN 8   THEN 'Application'
            WHEN 257 THEN 'Operating System Image'
            WHEN 258 THEN 'Boot Image'
            WHEN 259 THEN 'Operating System Installer'
            ELSE 'Unknown'
        END AS PackageType,
        psd.State,
        CASE psd.State
            WHEN 2 THEN 'Install Retrying'
            WHEN 3 THEN 'Install Failed'
            WHEN 5 THEN 'Removal Retrying'
            WHEN 6 THEN 'Removal Failed'
        END AS StateName,
        psd.InstallStatus,
        psd.SummaryDate
    FROM v_PackageStatusDistPointsSumm psd
    INNER JOIN DP dp
            ON psd.ServerNALPath LIKE '%\\' + dp.ServerName + '\%'
    LEFT JOIN v_Package pkg ON pkg.PackageID = psd.PackageID
    WHERE psd.State IN (3, 6)
       OR (@IncludeRetrying = 1 AND psd.State IN (2, 5))
)

/* ---------------- Disk ---------------- */
SELECT
    CASE WHEN e.PctUsed > @ImmediateActionPctUsed THEN 'Yes' ELSE 'No' END AS [Immediate Action],
    e.Severity                                                             AS [Severity],
    CASE e.Severity WHEN 'Critical' THEN 0 WHEN 'High' THEN 1 WHEN 'Warning' THEN 2 WHEN 'Info' THEN 3 ELSE 4 END
                                                                           AS [Severity Rank],
    CAST('Disk' AS varchar(20))                                            AS [Category],
    e.ServerName                                                           AS [DP Server],
    e.SiteCode                                                             AS [Site Code],
    e.DriveLetter + ':'                                                    AS [Drive],
    e.TotalGB                                                              AS [Total GB],
    e.FreeGB                                                               AS [Free GB],
    e.PctUsed                                                              AS [Percent Used],
    e.MinFreeGB                                                            AS [Min Free GB],
    CAST(NULL AS nvarchar(512))                                            AS [Content Name],
    CAST(NULL AS nvarchar(16))                                             AS [Content ID],
    CAST(NULL AS varchar(40))                                              AS [Content Type],
    CAST(NULL AS varchar(40))                                              AS [Content State],
    CAST(NULL AS nvarchar(1024))                                           AS [Status Message],
    CAST(CASE
        WHEN e.DataSource IS NULL THEN CONCAT('No ', e.DriveLetter, ': fixed drive reported.')
        ELSE CONCAT(e.DriveLetter, ': ', e.FreeGB, ' GB free of ', e.TotalGB, ' GB (', e.PctUsed, '% used)',
            CASE e.Severity
                WHEN 'Critical' THEN CONCAT(' - below ', e.MinFreeGB, ' GB minimum')
                WHEN 'High'     THEN CONCAT(' - at/over ', e.CritPctUsed, '% used')
                WHEN 'Warning'  THEN CONCAT(' - at/over ', e.WarnPctUsed, '% used')
                ELSE ''
            END)
    END AS nvarchar(1024))                                                 AS [Issue],
    CAST(CASE
        WHEN e.Severity = 'OK'   THEN ''
        WHEN e.DataSource IS NULL THEN 'Confirm the DP build standard; content library may be on another drive.'
        WHEN e.DriveLetter = 'C' THEN 'Clean IIS logs, CCMCache, WinSxS (DISM /StartComponentCleanup), temp; verify content is not landing on C: (NO_SMS_ON_DRIVE.SMS).'
        ELSE 'Remove orphaned/retired content, review DP group assignments, or extend the volume.'
    END AS nvarchar(1024))                                                 AS [Recommendation],
    CAST(ISNULL(e.DataSource, 'Hardware Inventory') AS varchar(40))        AS [Data Source],
    e.AsOf                                                                 AS [Data As Of]
FROM DiskEval e

UNION ALL

/* ---------------- Inventory ---------------- */
SELECT
    'No',
    'Warning',
    2,
    'Inventory',
    ds.ServerName,
    ds.SiteCode,
    NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL,
    CASE
        WHEN ds.LastHWScan IS NULL THEN 'No hardware inventory for this DP (no client, client unhealthy, or name mismatch).'
        ELSE CONCAT('Hardware inventory is ', DATEDIFF(DAY, ds.LastHWScan, GETDATE()), ' days old.')
    END,
    CASE
        WHEN ds.LastHWScan IS NULL THEN 'Install/repair the CM client on the DP; disk data falls back to site status polling.'
        ELSE 'Check InventoryAgent.log on the DP and client health; trigger a hardware inventory cycle.'
    END,
    'Hardware Inventory',
    ds.LastHWScan
FROM DPSys ds
WHERE ds.InventoryStale = 1

UNION ALL

/* ---------------- Content ---------------- */
SELECT
    CASE WHEN c.State = 3 THEN 'Yes' ELSE 'No' END,
    CASE c.State WHEN 3 THEN 'Critical' WHEN 6 THEN 'High' ELSE 'Warning' END,
    CASE c.State WHEN 3 THEN 0 WHEN 6 THEN 1 ELSE 2 END,
    'Content',
    c.ServerName,
    c.SiteCode,
    NULL, NULL, NULL, NULL, NULL,
    c.PackageName,
    c.PackageID,
    c.PackageType,
    c.StateName,
    c.InstallStatus,
    CONCAT(c.PackageType, ' ', c.StateName, ': ', c.PackageName, ' (', c.PackageID, ')'),
    CASE
        WHEN c.State IN (5, 6) THEN 'Removal stuck: check smsdpprov.log on the DP and distmgr.log on the site server; remove the content again or clear it from the content library.'
        ELSE 'Redistribute (console Redistribute / Invoke-CMContentRedistribution); check distmgr.log + PkgXferMgr.log on the site server and smsdpprov.log on the DP.'
    END,
    'Content Status',
    c.SummaryDate
FROM Content c

ORDER BY
    [Immediate Action] DESC,
    [Severity Rank],
    [Category],
    [DP Server],
    [Drive],
    [Content Name];
