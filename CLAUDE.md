# CMDPHealthCheck

Health monitoring for ~265 Configuration Manager (SCCM/MECM) distribution points. Site `PS1`,
provider `cm-prim01.contoso.com`, site DB `CM_PS1` on `cm-sql01.contoso.com`.

## Files
- `Get-CMDPHealth.ps1` — current health check. SQL-only against the site DB (no remote WMI/WinRM).
  Checks are registered in `$CheckRegistry`; each check = one bulk SQL query + a `Test-*` function
  that emits `New-DPFinding` objects. Add new DP health checks the same way.
- `SCCMDPHealthCheck.ps1` — original attempt, kept for history. Slow (per-DP ping/WinRM/event log,
  `Get-CMDistributionPointGroup` inside the loop) and has bugs; do not extend it.
- `Start-NewDPContent06.ps1` — reference for content cmdlets/WMI (SMS_DPContentInfo,
  SMS_PackageStatusDistPointsSummarizer, Start-CMContentDistribution, state/type enums).

## Targets
- C: at least ~20 GB free; F: (content library) at least ~50 GB free; warn at 70% used, high at 80%.

## Reference: microsoft/configmgr-hub
Microsoft's official ConfigMgr community repo (https://github.com/microsoft/configmgr-hub) is
shallow-cloned to `.reference/configmgr-hub` (git-ignored; refresh with `git -C .reference/configmgr-hub pull`).
Useful parts: `samples/CommonFunctions.ps1` (AdminService/OData connection helpers),
`objects/CMPivotQuery`, `objects/ConfigurationItem` (e.g. Prune IIS Logs, TFTP settings for PXE DPs),
`objects/Script`. It has little DP-specific code, so verify SQL view/column names against the
site DB (`sp_help '<view>'`) before relying on them.

## Conventions
- Must run on Windows PowerShell 5.1 (no `??`, ternary, or `-Parallel`).
- Prefer site-DB views (`v_*`) over provider WMI over remote calls, in that order, for speed.
- Read-only: queries use READ UNCOMMITTED; never write to the site DB.
