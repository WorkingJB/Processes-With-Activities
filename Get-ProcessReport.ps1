<#
.SYNOPSIS
    Generates a CSV report of processes using Nintex Promapp OData API and Process Manager API.

.DESCRIPTION
    This script queries the Nintex Promapp OData API to get a list of processes, then uses the
    Process Manager API to get detailed information about each process including role owners
    and system tags. The results are exported to a CSV file.

.PARAMETER ConfigPath
    Path to the configuration JSON file. Defaults to config.json in the script directory.

.EXAMPLE
    .\Get-ProcessReport.ps1

.EXAMPLE
    .\Get-ProcessReport.ps1 -ConfigPath "C:\Config\myconfig.json"

.NOTES
    Author: Nintex Process Manager Report Script
    Version: 1.0
    Requires: PowerShell 5.1 or higher
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigPath = (Join-Path $PSScriptRoot "config.json")
)

# Function to load configuration
function Get-Configuration {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Configuration file not found at: $Path"
    }

    try {
        $config = Get-Content $Path -Raw | ConvertFrom-Json
        Write-Host "Configuration loaded successfully from: $Path" -ForegroundColor Green
        return $config
    }
    catch {
        throw "Failed to parse configuration file: $_"
    }
}

# Function to get OData processes using Basic Authentication
function Get-ODataProcesses {
    param(
        [string]$BaseUrl,
        [string]$Username,
        [string]$ApiKey
    )

    Write-Host "`nQuerying OData API for process list..." -ForegroundColor Cyan

    # Create Basic Auth header
    $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $Username, $ApiKey)))
    $headers = @{
        Authorization = "Basic $base64AuthInfo"
        Accept = "application/json"
    }

    try {
        # Query the Processes endpoint - adjust the endpoint based on actual OData schema
        $url = "${BaseUrl}Processes"
        Write-Verbose "Requesting: $url"

        $response = Invoke-RestMethod -Uri $url -Method Get -Headers $headers -ErrorAction Stop

        # OData responses typically have a 'value' property containing the array of results
        if ($response.value) {
            $processes = $response.value
        } else {
            $processes = $response
        }

        Write-Host "Successfully retrieved $($processes.Count) processes from OData API" -ForegroundColor Green
        return $processes
    }
    catch {
        Write-Error "Failed to retrieve processes from OData API: $_"
        throw
    }
}

# Function to authenticate with Process Manager API and get OAuth token
function Get-ProcessManagerToken {
    param(
        [string]$BaseUrl,
        [string]$AutomationTenant,
        [string]$Username,
        [string]$Password,
        [string]$ClientId,
        [string]$ClientSecret,
        [string]$GrantType
    )

    Write-Host "`nAuthenticating with Process Manager API..." -ForegroundColor Cyan

    $tokenUrl = "${BaseUrl}/${AutomationTenant}/oauth2/token"

    $body = @{
        grant_type = $GrantType
        username = $Username
        password = $Password
        client_id = $ClientId
    }

    if ($ClientSecret) {
        $body.client_secret = $ClientSecret
    }

    try {
        Write-Verbose "Token URL: $tokenUrl"
        $response = Invoke-RestMethod -Uri $tokenUrl -Method Post -Body $body -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop

        Write-Host "Successfully obtained authentication token (expires in $($response.expires_in) seconds)" -ForegroundColor Green
        return $response.access_token
    }
    catch {
        Write-Error "Failed to obtain authentication token: $_"
        throw
    }
}

# Function to get process details from Process Manager API
function Get-ProcessDetails {
    param(
        [string]$BaseUrl,
        [string]$AutomationTenant,
        [string]$ProcessUniqueId,
        [string]$AccessToken
    )

    $processUrl = "${BaseUrl}/${AutomationTenant}/Api/v1/Processes/${ProcessUniqueId}"

    $headers = @{
        Authorization = "Bearer $AccessToken"
        Accept = "application/json"
    }

    try {
        Write-Verbose "Requesting process details: $processUrl"
        $response = Invoke-RestMethod -Uri $processUrl -Method Get -Headers $headers -ErrorAction Stop
        return $response
    }
    catch {
        Write-Warning "Failed to retrieve details for process $ProcessUniqueId : $_"
        return $null
    }
}

# Function to extract role names from process details
function Get-RoleNames {
    param($ProcessDetails)

    $roleNames = @()

    if ($ProcessDetails.Activities) {
        foreach ($activity in $ProcessDetails.Activities) {
            if ($activity.Ownerships -and $activity.Ownerships.Role) {
                foreach ($role in $activity.Ownerships.Role) {
                    if ($role.Name -and $roleNames -notcontains $role.Name) {
                        $roleNames += $role.Name
                    }
                }
            }
        }
    }

    return ($roleNames -join "; ")
}

# Function to extract system tag names from process details
function Get-SystemTagNames {
    param($ProcessDetails)

    $systemTags = @()

    # Check for AutomatedSystemTagId in various locations
    if ($ProcessDetails.Configuration -and $ProcessDetails.Configuration.AutomatedSystemTagId) {
        # Note: This returns the ID. To get the actual tag name, you may need to query a tags endpoint
        # For now, we'll include the ID. You may need to enhance this based on available data
        $tagId = $ProcessDetails.Configuration.AutomatedSystemTagId
        if ($tagId -and $systemTags -notcontains $tagId) {
            $systemTags += "TagId:$tagId"
        }
    }

    # Check Activities for system information
    if ($ProcessDetails.Activities) {
        foreach ($activity in $ProcessDetails.Activities) {
            if ($activity.Ownerships -and $activity.Ownerships.Tag) {
                foreach ($tag in $activity.Ownerships.Tag) {
                    if ($tag.Name -and $systemTags -notcontains $tag.Name) {
                        $systemTags += $tag.Name
                    }
                }
            }
        }
    }

    return ($systemTags -join "; ")
}

# Main script execution
try {
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host "Process Report Generator" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Yellow

    # Load configuration
    $config = Get-Configuration -Path $ConfigPath

    # Get processes from OData API
    $odataProcesses = Get-ODataProcesses -BaseUrl $config.ODataAPI.BaseUrl `
                                          -Username $config.ODataAPI.Username `
                                          -ApiKey $config.ODataAPI.ApiKey

    if ($odataProcesses.Count -eq 0) {
        Write-Warning "No processes found in OData API"
        exit 0
    }

    # Authenticate with Process Manager API
    $accessToken = Get-ProcessManagerToken -BaseUrl $config.ProcessManagerAPI.BaseUrl `
                                            -AutomationTenant $config.ProcessManagerAPI.AutomationTenant `
                                            -Username $config.ProcessManagerAPI.Username `
                                            -Password $config.ProcessManagerAPI.Password `
                                            -ClientId $config.ProcessManagerAPI.ClientId `
                                            -ClientSecret $config.ProcessManagerAPI.ClientSecret `
                                            -GrantType $config.ProcessManagerAPI.GrantType

    # Process each process and gather details
    Write-Host "`nRetrieving detailed information for each process..." -ForegroundColor Cyan
    $reportData = @()
    $processedCount = 0
    $totalProcesses = $odataProcesses.Count

    foreach ($odataProcess in $odataProcesses) {
        $processedCount++
        Write-Progress -Activity "Processing processes" -Status "Process $processedCount of $totalProcesses" -PercentComplete (($processedCount / $totalProcesses) * 100)

        # Get the process unique ID from OData response
        # The field name may vary - common options: Id, UniqueId, ProcessId, Guid
        $processId = $odataProcess.Id ?? $odataProcess.UniqueId ?? $odataProcess.ProcessId ?? $odataProcess.Guid

        if (-not $processId) {
            Write-Warning "Could not determine process ID for process: $($odataProcess.Name ?? 'Unknown')"
            continue
        }

        Write-Verbose "Processing: $($odataProcess.Name) (ID: $processId)"

        # Get detailed process information
        $processDetails = Get-ProcessDetails -BaseUrl $config.ProcessManagerAPI.BaseUrl `
                                              -AutomationTenant $config.ProcessManagerAPI.AutomationTenant `
                                              -ProcessUniqueId $processId `
                                              -AccessToken $accessToken

        if ($null -eq $processDetails) {
            Write-Verbose "Skipping process $processId due to API error"
            continue
        }

        # Extract role names and system tags
        $roleNames = Get-RoleNames -ProcessDetails $processDetails
        $systemTags = Get-SystemTagNames -ProcessDetails $processDetails

        # Build the report row
        # Map OData fields to output columns - adjust field names based on actual OData schema
        $reportRow = [PSCustomObject]@{
            "Process Group Path" = $odataProcess.ProcessGroupPath ?? $odataProcess.GroupPath ?? ""
            "Process Name" = $odataProcess.Name ?? $processDetails.Name ?? ""
            "Process Status" = $odataProcess.Status ?? $processDetails.Status ?? ""
            "Process Version" = $odataProcess.Version ?? $processDetails.Version ?? ""
            "Process Expert" = $odataProcess.ProcessExpert ?? $odataProcess.Expert ?? $processDetails.Expert ?? ""
            "Process Owner" = $odataProcess.ProcessOwner ?? $odataProcess.Owner ?? $processDetails.Owner ?? ""
            "Assigned Roles" = $roleNames
            "Assigned System" = $systemTags
        }

        $reportData += $reportRow
    }

    Write-Progress -Activity "Processing processes" -Completed

    # Export to CSV
    $outputPath = Join-Path $PSScriptRoot $config.Output.CsvFileName
    Write-Host "`nExporting report to CSV..." -ForegroundColor Cyan

    $reportData | Export-Csv -Path $outputPath -NoTypeInformation -Encoding UTF8

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "Report generated successfully!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "Total processes: $totalProcesses" -ForegroundColor White
    Write-Host "Processes in report: $($reportData.Count)" -ForegroundColor White
    Write-Host "Output file: $outputPath" -ForegroundColor White
    Write-Host "========================================" -ForegroundColor Green
}
catch {
    Write-Host "`n========================================" -ForegroundColor Red
    Write-Host "ERROR: Script execution failed" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Error $_
    exit 1
}
