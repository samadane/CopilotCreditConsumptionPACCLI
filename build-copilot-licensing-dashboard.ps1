<#
.SYNOPSIS
Collects Power Platform Copilot licensing data and builds an interactive HTML dashboard.

.EXAMPLE
.\build-copilot-licensing-dashboard.ps1 -OpenDashboard

.EXAMPLE
.\build-copilot-licensing-dashboard.ps1 -FromDate '2026-09-01' -ToDate '2026-09-30' -ThrottleLimit 8

.EXAMPLE
.\build-copilot-licensing-dashboard.ps1 -UseExistingData -OpenDashboard
#>
[CmdletBinding()]
param(
    [string]$TenantDomain = 'TenantDomain.onmicrosoft.com',
    [datetime]$FromDate = (Get-Date -Day 1).Date,
    [datetime]$ToDate = (Get-Date).Date,
    [ValidateRange(1, 20)]
    [int]$ThrottleLimit = 6,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'output'),
    [string]$PacPath,
    [switch]$UseExistingData,
    [switch]$OpenDashboard
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-PacPath {
    if ($PacPath) {
        if (-not (Test-Path -LiteralPath $PacPath)) {
            throw "PAC executable not found at '$PacPath'."
        }
        return (Resolve-Path -LiteralPath $PacPath).Path
    }

    $dotnetPac = Join-Path $env:USERPROFILE '.dotnet\tools\pac.exe'
    if (Test-Path -LiteralPath $dotnetPac) {
        return $dotnetPac
    }

    $command = Get-Command pac -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) {
        throw 'PAC CLI was not found. Install it with: dotnet tool install --global Microsoft.PowerApps.CLI.Tool'
    }
    return $command.Source
}

function Invoke-PacJson {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [Parameter(Mandatory)]
        [string]$OutputPath
    )

    $raw = & $script:ResolvedPac @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "pac $($Arguments -join ' ') failed:`n$($raw -join [Environment]::NewLine)"
    }

    $text = $raw -join [Environment]::NewLine
    $parsed = $text | ConvertFrom-Json
    [IO.File]::WriteAllText($OutputPath, $text, [Text.UTF8Encoding]::new($false))
    return $parsed
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)]
        $Value,
        [Parameter(Mandatory)]
        [string]$Path,
        [int]$Depth = 20
    )

    [IO.File]::WriteAllText(
        $Path,
        ($Value | ConvertTo-Json -Depth $Depth),
        [Text.UTF8Encoding]::new($false)
    )
}

function Get-NestedValue {
    param($Value, [string]$Path)

    $current = $Value
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $current) {
            return 0
        }
        $current = $current.$part
    }
    if ($null -eq $current) {
        return 0
    }
    return $current
}

$script:ResolvedPac = Resolve-PacPath
$resolvedPac = $script:ResolvedPac
$from = $FromDate.ToString('yyyy-MM-dd')
$to = $ToDate.ToString('yyyy-MM-dd')
$templatePath = Join-Path $PSScriptRoot 'copilot-paygo.template.html'

if ($FromDate.Date -gt $ToDate.Date) {
    throw 'FromDate must be on or before ToDate.'
}
if (-not (Test-Path -LiteralPath $templatePath)) {
    throw "Dashboard template not found at '$templatePath'."
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

$licensingHelp = & $script:ResolvedPac licensing help 2>&1
if ($LASTEXITCODE -ne 0 -or ($licensingHelp -join "`n") -notmatch 'get-tenant-user-consumption-by-resource') {
    throw "The selected PAC CLI does not support the required licensing commands: $script:ResolvedPac"
}

$authList = & $script:ResolvedPac auth list 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Unable to read PAC authentication profiles:`n$($authList -join [Environment]::NewLine)"
}
$activeAuth = @($authList | Where-Object { $_ -match '\*' }) -join ' '
if ($activeAuth -notmatch [regex]::Escape($TenantDomain)) {
    throw "The active PAC profile is not for '$TenantDomain'. Select or create the correct profile before running this script."
}

$paths = @{
    Environments = Join-Path $OutputDirectory 'environments.json'
    Allocations = Join-Path $OutputDirectory 'allocations-by-environment.json'
    Policies = Join-Path $OutputDirectory 'billing-policies.json'
    Entitlements = Join-Path $OutputDirectory 'copilot-environment-entitlements.json'
    EnvironmentFailures = Join-Path $OutputDirectory 'query-failures.json'
    TenantUsers = Join-Path $OutputDirectory 'mcsmessage-tenant-users.json'
    ResourcesByUser = Join-Path $OutputDirectory 'mcsmessage-resources-by-user.json'
    ResourceDiscoveryFailures = Join-Path $OutputDirectory 'mcsmessage-resource-discovery-failures.json'
    UsersByResource = Join-Path $OutputDirectory 'mcsmessage-users-by-resource.json'
    UserConsumptionFailures = Join-Path $OutputDirectory 'mcsmessage-user-consumption-failures.json'
}

if (-not $UseExistingData) {
    Write-Host "Collecting tenant metadata and licensing configuration..."
    $environments = @(Invoke-PacJson -Arguments @('admin', 'list', '--json') -OutputPath $paths.Environments)
    $allocations = @(Invoke-PacJson -Arguments @('licensing', 'list-allocations-by-environment', '--json') -OutputPath $paths.Allocations)
    $billingPolicyResponse = Invoke-PacJson -Arguments @('licensing', 'list-billing-policies', '--json') -OutputPath $paths.Policies

    Write-Host "Collecting Copilot entitlement snapshots from $($environments.Count) environments..."
    $environmentResults = $environments.EnvironmentId | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        $pac = $using:resolvedPac
        $environmentId = $_
        $lastError = $null
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            $raw = & $pac licensing get-many-environment-entitlements --environment $environmentId --json 2>&1
            if ($LASTEXITCODE -eq 0) {
                try {
                    $data = ($raw -join [Environment]::NewLine) | ConvertFrom-Json
                    [pscustomobject]@{ EnvironmentId = $environmentId; Success = $true; Data = @($data); Error = $null }
                    return
                } catch {
                    $lastError = "Invalid JSON: $($_.Exception.Message)"
                }
            } else {
                $lastError = $raw -join [Environment]::NewLine
            }
            Start-Sleep -Seconds (2 * $attempt)
        }
        [pscustomobject]@{ EnvironmentId = $environmentId; Success = $false; Data = @(); Error = $lastError }
    }
    $entitlements = @(
        $environmentResults |
            Where-Object Success |
            ForEach-Object { $_.Data } |
            Where-Object { $_.entitlementId -in @('AI', 'MCSMessages', 'MCSSessions') }
    )
    $environmentFailures = @($environmentResults | Where-Object { -not $_.Success } | Select-Object EnvironmentId, Error)
    Write-JsonFile -Value $entitlements -Path $paths.Entitlements
    Write-JsonFile -Value $environmentFailures -Path $paths.EnvironmentFailures

    Write-Host 'Collecting MCSMessages users...'
    $tenantUsersResponse = Invoke-PacJson -Arguments @(
        'licensing', 'get-tenant-users',
        '--entitlement-id', 'MCSMessages',
        '--from-date', $from,
        '--to-date', $to,
        '--page-size', '500',
        '--json'
    ) -OutputPath $paths.TenantUsers
    $tenantUsers = @($tenantUsersResponse.value.users)
    $userIds = @($tenantUsers.userId | Where-Object { $_ -and $_ -ne 'NA' } | Sort-Object -Unique)

    Write-Host "Discovering Copilot resources for $($userIds.Count) users..."
    $userResourceResults = $userIds | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        $pac = $using:resolvedPac
        $userId = $_
        $raw = & $pac licensing get-tenant-resource-consumption-by-user --entitlement-id MCSMessages --user-id $userId --from-date $using:from --to-date $using:to --page-size 500 --json 2>&1
        if ($LASTEXITCODE -eq 0) {
            try {
                [pscustomobject]@{ UserId = $userId; Success = $true; Data = (($raw -join [Environment]::NewLine) | ConvertFrom-Json); Error = $null }
            } catch {
                [pscustomobject]@{ UserId = $userId; Success = $false; Data = $null; Error = "Invalid JSON: $($_.Exception.Message)" }
            }
        } else {
            [pscustomobject]@{ UserId = $userId; Success = $false; Data = $null; Error = ($raw -join [Environment]::NewLine) }
        }
    }
    $resourcesByUser = @(
        $userResourceResults |
            Where-Object Success |
            ForEach-Object {
                $userId = $_.UserId
                $_.Data.value.resources | ForEach-Object {
                    $_ | Add-Member -NotePropertyName sourceUserId -NotePropertyValue $userId -PassThru
                }
            }
    )
    $resourceDiscoveryFailures = @($userResourceResults | Where-Object { -not $_.Success } | Select-Object UserId, Error)
    Write-JsonFile -Value $resourcesByUser -Path $paths.ResourcesByUser
    Write-JsonFile -Value $resourceDiscoveryFailures -Path $paths.ResourceDiscoveryFailures

    $resourceIds = @($resourcesByUser.resourceId | Where-Object { $_ } | Sort-Object -Unique)
    Write-Host "Collecting MCSMessages user consumption for $($resourceIds.Count) resources..."
    $resourceUserResults = $resourceIds | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        $pac = $using:resolvedPac
        $resourceId = $_
        $raw = & $pac licensing get-tenant-user-consumption-by-resource --entitlement-id MCSMessages --resource-id $resourceId --from-date $using:from --to-date $using:to --page-size 500 --json 2>&1
        if ($LASTEXITCODE -eq 0) {
            try {
                [pscustomobject]@{ ResourceId = $resourceId; Success = $true; Data = (($raw -join [Environment]::NewLine) | ConvertFrom-Json); Error = $null }
            } catch {
                [pscustomobject]@{ ResourceId = $resourceId; Success = $false; Data = $null; Error = "Invalid JSON: $($_.Exception.Message)" }
            }
        } else {
            [pscustomobject]@{ ResourceId = $resourceId; Success = $false; Data = $null; Error = ($raw -join [Environment]::NewLine) }
        }
    }
    $usersByResource = @(
        $resourceUserResults |
            Where-Object Success |
            ForEach-Object {
                $resourceId = $_.ResourceId
                $_.Data.value.users | ForEach-Object {
                    $_ | Add-Member -NotePropertyName resourceId -NotePropertyValue $resourceId -PassThru
                }
            }
    )
    $userConsumptionFailures = @($resourceUserResults | Where-Object { -not $_.Success } | Select-Object ResourceId, Error)
    Write-JsonFile -Value $usersByResource -Path $paths.UsersByResource
    Write-JsonFile -Value $userConsumptionFailures -Path $paths.UserConsumptionFailures
} else {
    Write-Host 'Using existing JSON exports...'
    foreach ($path in $paths.Values) {
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Required existing data file not found: $path"
        }
    }
    $environments = @(Get-Content -Raw $paths.Environments | ConvertFrom-Json)
    $allocations = @(Get-Content -Raw $paths.Allocations | ConvertFrom-Json)
    $billingPolicyResponse = Get-Content -Raw $paths.Policies | ConvertFrom-Json
    $entitlements = @(Get-Content -Raw $paths.Entitlements | ConvertFrom-Json)
    $environmentFailures = @(Get-Content -Raw $paths.EnvironmentFailures | ConvertFrom-Json)
    $tenantUsersResponse = Get-Content -Raw $paths.TenantUsers | ConvertFrom-Json
    $tenantUsers = @($tenantUsersResponse.value.users)
    $resourcesByUser = @(Get-Content -Raw $paths.ResourcesByUser | ConvertFrom-Json)
    $resourceDiscoveryFailures = @(Get-Content -Raw $paths.ResourceDiscoveryFailures | ConvertFrom-Json)
    $usersByResource = @(Get-Content -Raw $paths.UsersByResource | ConvertFrom-Json)
    $userConsumptionFailures = @(Get-Content -Raw $paths.UserConsumptionFailures | ConvertFrom-Json)
}

Write-Host 'Processing environment, resource, and user reports...'
$entitlementMap = @{}
foreach ($row in $entitlements) {
    $entitlementMap["$($row.environmentId)|$($row.entitlementId)"] = $row
}

$allocationMap = @{}
foreach ($environmentAllocation in $allocations) {
    foreach ($currency in $environmentAllocation.currencyAllocations) {
        if ($currency.currencyType -in @('AI', 'MCSMessages', 'MCSSessions')) {
            $allocationMap["$($environmentAllocation.environmentId)|$($currency.currencyType)"] = $currency
        }
    }
}

$policyMap = @{}
foreach ($policy in $billingPolicyResponse.value) {
    $mcsPayGoEnabled = @(
        $policy.payGoEntitlements |
            Where-Object { $_.entitlementId -eq 'MCSMessages' -and $_.payAsYouGoState }
    ).Count -gt 0
    if ($mcsPayGoEnabled) {
        foreach ($environmentId in $policy.environmentIds) {
            if (-not $policyMap.ContainsKey($environmentId)) {
                $policyMap[$environmentId] = @()
            }
            $policyMap[$environmentId] += $policy.name
        }
    }
}

$failedEnvironmentIds = @($environmentFailures | ForEach-Object { $_.EnvironmentId })
$environmentReport = foreach ($environment in $environments) {
    $id = $environment.EnvironmentId
    $ai = $entitlementMap["$id|AI"]
    $messages = $entitlementMap["$id|MCSMessages"]
    $sessions = $entitlementMap["$id|MCSSessions"]
    $aiAllocation = $allocationMap["$id|AI"]
    $messageAllocation = $allocationMap["$id|MCSMessages"]
    $sessionAllocation = $allocationMap["$id|MCSSessions"]
    $region = if ($ai) { $ai.location } elseif ($messages) { $messages.location } elseif ($sessions) { $sessions.location } else { '' }
    $policyNames = if ($policyMap.ContainsKey($id)) { ($policyMap[$id] | Sort-Object -Unique) -join '; ' } else { '' }

    [pscustomobject][ordered]@{
        EnvironmentName = $environment.DisplayName
        EnvironmentId = $id
        Type = $environment.Type
        Region = $region
        QueryStatus = if ($id -in $failedEnvironmentIds) { 'Failed' } else { 'Success' }
        AI_Set = Get-NestedValue $aiAllocation 'allocated'
        AI_AutoSet = Get-NestedValue $aiAllocation 'autoAllocated'
        AI_Consumed = Get-NestedValue $ai 'entitlement.capacity.consumed.value'
        AI_PAYG_Consumed = Get-NestedValue $ai 'entitlement.payGo.consumed.value'
        CopilotMessages_Set = Get-NestedValue $messageAllocation 'allocated'
        CopilotMessages_AutoSet = Get-NestedValue $messageAllocation 'autoAllocated'
        CopilotMessages_Consumed = Get-NestedValue $messages 'entitlement.capacity.consumed.value'
        CopilotMessages_PAYG_Entitled = Get-NestedValue $messages 'entitlement.payGo.entitled.value'
        CopilotMessages_PAYG_Consumed = Get-NestedValue $messages 'entitlement.payGo.consumed.value'
        CopilotSessions_Set = Get-NestedValue $sessionAllocation 'allocated'
        CopilotSessions_AutoSet = Get-NestedValue $sessionAllocation 'autoAllocated'
        CopilotSessions_Consumed = Get-NestedValue $sessions 'entitlement.capacity.consumed.value'
        CopilotSessions_PAYG_Consumed = Get-NestedValue $sessions 'entitlement.payGo.consumed.value'
        PAYG_Configured = $policyMap.ContainsKey($id)
        PAYG_Policies = $policyNames
    }
}

$environmentReportPath = Join-Path $OutputDirectory 'environment-report.json'
$environmentCsvPath = Join-Path $OutputDirectory 'copilot-credit-paygo-by-environment.csv'
Write-JsonFile -Value $environmentReport -Path $environmentReportPath
$environmentReport | Sort-Object EnvironmentName | Export-Csv -NoTypeInformation -Encoding utf8 $environmentCsvPath

$environmentNameMap = @{}
foreach ($environment in $environments) {
    $environmentNameMap[$environment.EnvironmentId] = $environment.DisplayName
}

$failedResourceIds = @($userConsumptionFailures | ForEach-Object { $_.ResourceId })
$resourceSummary = foreach ($group in ($resourcesByUser | Group-Object resourceId)) {
    $resourceId = $group.Name
    $resourceUsers = @($usersByResource | Where-Object resourceId -eq $resourceId)
    $environmentIds = @($group.Group.environmentId | Sort-Object -Unique)
    $environmentNames = @(
        $environmentIds | ForEach-Object {
            if ($environmentNameMap.ContainsKey($_)) { $environmentNameMap[$_] } else { $_ }
        }
    )
    $resourceName = $group.Group.metadata.ResourceName | Where-Object { $_ } | Select-Object -First 1
    $consumedMeasure = $resourceUsers | Measure-Object consumed -Sum
    $nonBillableMeasure = $resourceUsers | ForEach-Object { $_.metadata.NonBillableQuantity } | Measure-Object -Sum
    $consumedTotal = if ($consumedMeasure) { $consumedMeasure.Sum } else { 0 }
    $nonBillableTotal = if ($nonBillableMeasure) { $nonBillableMeasure.Sum } else { 0 }

    [pscustomobject][ordered]@{
        ResourceId = $resourceId
        ResourceName = if ($resourceName) { $resourceName } else { $resourceId }
        Environments = $environmentNames -join '; '
        EnvironmentCount = $environmentIds.Count
        UserCount = @($resourceUsers | ForEach-Object { $_.userId } | Where-Object { $_ -and $_ -ne 'NA' } | Sort-Object -Unique).Count
        Consumed = $consumedTotal
        NonBillable = $nonBillableTotal
        Features = ($group.Group.metadata.FeatureName | Where-Object { $_ } | Sort-Object -Unique) -join '; '
        AsOfDate = $resourceUsers | ForEach-Object { $_.asOfDate } | Sort-Object -Descending | Select-Object -First 1
        QueryStatus = if ($resourceId -in $failedResourceIds) { 'Failed' } else { 'Success' }
    }
}
$resourceSummary = @($resourceSummary | Sort-Object Consumed -Descending)
$resourceSummaryPath = Join-Path $OutputDirectory 'resource-summary.json'
$resourceCsvPath = Join-Path $OutputDirectory 'mcsmessages-by-resource.csv'
Write-JsonFile -Value $resourceSummary -Path $resourceSummaryPath
$resourceSummary | Export-Csv -NoTypeInformation -Encoding utf8 $resourceCsvPath

$userSummary = @(
    $tenantUsers |
        ForEach-Object {
            [pscustomobject][ordered]@{
                UserId = $_.userId
                Consumed = $_.consumed
                NonBillable = $_.metadata.NonBillableQuantity
                ResourceCount = $_.metadata.Resources
                Unit = $_.unit
                AsOfDate = $_.asOfDate
                Attribution = if ($_.userId -eq 'NA' -or $_.userId -eq '00000000-0000-0000-0000-000000000000') { 'Unattributed/System' } else { 'User' }
            }
        } |
        Sort-Object Consumed -Descending
)
$userSummaryPath = Join-Path $OutputDirectory 'user-summary.json'
$userCsvPath = Join-Path $OutputDirectory 'mcsmessages-by-user.csv'
Write-JsonFile -Value $userSummary -Path $userSummaryPath
$userSummary | Export-Csv -NoTypeInformation -Encoding utf8 $userCsvPath

$template = [IO.File]::ReadAllText($templatePath)
$replacements = @{
    '__REPORT_DATA__' = [IO.File]::ReadAllText($environmentReportPath).Replace('</', '<\/')
    '__RESOURCE_DATA__' = [IO.File]::ReadAllText($resourceSummaryPath).Replace('</', '<\/')
    '__USER_DATA__' = [IO.File]::ReadAllText($userSummaryPath).Replace('</', '<\/')
    '__TENANT_DOMAIN__' = $TenantDomain
    '__FROM_DATE__' = $from
    '__TO_DATE__' = $to
}
foreach ($replacement in $replacements.GetEnumerator()) {
    $template = $template.Replace($replacement.Key, $replacement.Value)
}
if ($template -match '__[A-Z_]+__') {
    throw 'The dashboard contains unresolved data placeholders.'
}

$dashboardPath = Join-Path $OutputDirectory 'copilot-credit-paygo-dashboard.html'
[IO.File]::WriteAllText($dashboardPath, $template, [Text.UTF8Encoding]::new($false))

$summary = [pscustomobject][ordered]@{
    Tenant = $TenantDomain
    FromDate = $from
    ToDate = $to
    Environments = $environmentReport.Count
    EnvironmentQueriesSucceeded = @($environmentReport | Where-Object QueryStatus -eq 'Success').Count
    EnvironmentQueriesFailed = @($environmentReport | Where-Object QueryStatus -eq 'Failed').Count
    PAYGConfiguredEnvironments = @($environmentReport | Where-Object PAYG_Configured).Count
    MCSUsers = $userSummary.Count
    MCSResources = $resourceSummary.Count
    MCSConsumedByUser = ($userSummary | Measure-Object Consumed -Sum).Sum
    MCSNonBillableByUser = ($userSummary | Measure-Object NonBillable -Sum).Sum
    MCSConsumedMappedToResources = ($resourceSummary | Measure-Object Consumed -Sum).Sum
    ResourceQueriesFailed = @($resourceSummary | Where-Object QueryStatus -eq 'Failed').Count
    Dashboard = $dashboardPath
}
Write-JsonFile -Value $summary -Path (Join-Path $OutputDirectory 'summary.json')
$summary | Format-List

if ($OpenDashboard) {
    Start-Process $dashboardPath
}
