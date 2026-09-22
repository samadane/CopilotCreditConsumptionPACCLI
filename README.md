# Copilot Credit Consumption with PAC CLI

This repository contains a PowerShell 7 script that collects Power Platform licensing data with the Power Platform CLI (`pac`) and builds a self-contained HTML dashboard.

The report covers:

- Copilot/AI credit allocation and consumption by environment
- Copilot Studio message allocation, automatic allocation, licensed consumption, and PAYG consumption
- Copilot Studio session allocation and consumption
- PAYG billing-policy configuration by environment
- MCS message consumption by Copilot resource
- MCS message consumption by user
- CSV and JSON exports for further analysis

## Prerequisites

- Windows PowerShell 7 or later (`pwsh`)
- A current .NET SDK
- Power Platform CLI installed as a .NET global tool
- An account with access to the target Power Platform tenant and its environments
- Permission to read tenant licensing, billing policy, and environment data

Install or update PAC CLI:

```powershell
dotnet tool install --global Microsoft.PowerApps.CLI.Tool
```

If it is already installed:

```powershell
dotnet tool update --global Microsoft.PowerApps.CLI.Tool
```

The script prefers `%USERPROFILE%\.dotnet\tools\pac.exe`. This avoids accidentally using an older MSI installation that appears earlier in `PATH`.

## Authenticate

Create a PAC authentication profile for the tenant:

```powershell
pac auth create --tenant TenantDomain.onmicrosoft.com
```

Review the profiles and select the correct one:

```powershell
pac auth list
pac auth select --index <profile-number>
```

The active profile must show a user in the tenant passed to `-TenantDomain`.

## Run

From this repository:

```powershell
.\build-copilot-licensing-dashboard.ps1 -OpenDashboard
```

By default, the script:

- Targets `TenantDomain.onmicrosoft.com`
- Uses the first day of the current month through today
- Runs up to six independent PAC queries concurrently
- Writes generated files under `output\`
- Opens the completed dashboard when `-OpenDashboard` is supplied

Specify a reporting period:

```powershell
.\build-copilot-licensing-dashboard.ps1 `
  -FromDate "2026-09-01" `
  -ToDate "2026-09-30" `
  -OpenDashboard
```

Specify another tenant and concurrency level:

```powershell
.\build-copilot-licensing-dashboard.ps1 `
  -TenantDomain "contoso.onmicrosoft.com" `
  -ThrottleLimit 8 `
  -OpenDashboard
```

If PAC is installed elsewhere:

```powershell
.\build-copilot-licensing-dashboard.ps1 `
  -PacPath "C:\path\to\pac.exe" `
  -OpenDashboard
```

Rebuild the CSV files and dashboard from existing JSON exports without calling PAC again:

```powershell
.\build-copilot-licensing-dashboard.ps1 -UseExistingData -OpenDashboard
```

## Output

The script creates these files under `output\`:

| File | Description |
|---|---|
| `copilot-credit-paygo-dashboard.html` | Interactive, self-contained dashboard |
| `copilot-credit-paygo-by-environment.csv` | Allocation, consumption, and PAYG status by environment |
| `mcsmessages-by-resource.csv` | MCS message consumption by Copilot resource |
| `mcsmessages-by-user.csv` | MCS message consumption by user ID |
| `summary.json` | Run summary and coverage counts |
| `query-failures.json` | Environment queries that could not be completed |
| `mcsmessage-resource-discovery-failures.json` | User-to-resource discovery failures |
| `mcsmessage-user-consumption-failures.json` | Resource-to-user query failures |
| Other `.json` files | Raw PAC responses and normalized dashboard data |

Generated reports can contain tenant identifiers, environment names, user object IDs, resource names, and consumption data. The `output\` directory is excluded from Git.

## Data collection flow

The script uses these PAC commands:

```text
pac admin list
pac licensing list-allocations-by-environment
pac licensing list-billing-policies
pac licensing get-many-environment-entitlements
pac licensing get-tenant-users
pac licensing get-tenant-resource-consumption-by-user
pac licensing get-tenant-user-consumption-by-resource
```

`get-many-environment-entitlements` runs once per environment. User-to-resource and resource-to-user queries also fan out, so a large tenant can take several minutes to complete.

## Troubleshooting

### The active PAC profile is for the wrong tenant

Run:

```powershell
pac auth list
pac auth select --index <profile-number>
```

Then rerun the script with the matching `-TenantDomain`.

### `pac licensing` is not recognized

An older PAC executable may be taking precedence. Update the .NET global tool and either rerun the script or provide its path explicitly:

```powershell
dotnet tool update --global Microsoft.PowerApps.CLI.Tool
.\build-copilot-licensing-dashboard.ps1 `
  -PacPath "$env:USERPROFILE\.dotnet\tools\pac.exe"
```

### Some environment or resource queries fail

The script retries environment entitlement calls once and records remaining failures in JSON. Common causes include missing permissions, deleted environments, transient service failures, and preview API limitations. Failed environments remain visible in the generated environment report rather than being reported as zero usage.

### Rebuild without querying the tenant

Keep the previous raw JSON files in the selected output directory and run:

```powershell
.\build-copilot-licensing-dashboard.ps1 `
  -OutputDirectory ".\output" `
  -UseExistingData `
  -OpenDashboard
```
