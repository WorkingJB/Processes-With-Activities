<#
.SYNOPSIS
    Generates a CSV report of processes using Nintex Promapp OData API and Process Manager API.

.DESCRIPTION
    This script queries the Nintex Promapp OData API to get a list of processes, then uses the
    Process Manager API to get detailed information about each process including role owners
    and system tags. The results are exported to a CSV file.

    The script supports incremental updates - on subsequent runs, it only queries the Process
    Manager API for processes that have changed since the last run (based on StateChangeDate).

.PARAMETER ConfigPath
    Path to the configuration JSON file. Defaults to config.json in the script directory.

.PARAMETER FullRefresh
    Forces a full refresh of all processes, ignoring the last run timestamp. Use this to rebuild
    the entire dataset from scratch.

.EXAMPLE
    .\Get-ProcessReport.ps1

.EXAMPLE
    .\Get-ProcessReport.ps1 -ConfigPath "C:\Config\myconfig.json"

.EXAMPLE
    .\Get-ProcessReport.ps1 -FullRefresh

.NOTES
    Author: Nintex Process Manager Report Script
    Version: 2.0
    Requires: PowerShell 5.1 or higher
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigPath = (Join-Path $PSScriptRoot "config.json"),

    [Parameter(Mandatory=$false)]
    [switch]$FullRefresh
)

# Set error action preference to stop on all errors
$ErrorActionPreference = "Stop"

# Global error handler for unhandled exceptions
trap {
    Write-Host "`n========================================" -ForegroundColor Red
    Write-Host "CRITICAL ERROR: Unhandled exception" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "`nPress Enter to exit..." -ForegroundColor Yellow
    $null = Read-Host
    exit 1
}

# Helper function to provide null-coalescing behavior (PowerShell 5.1 compatible)
function Coalesce {
    param([object[]]$Values)

    foreach ($value in $Values) {
        if ($null -ne $value -and $value -ne "") {
            return $value
        }
    }
    return ""
}

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

# Function to get the last run timestamp
function Get-LastRunTimestamp {
    param([string]$ScriptRoot)

    $timestampFile = Join-Path $ScriptRoot ".lastrun"

    if (Test-Path $timestampFile) {
        try {
            $timestamp = Get-Content $timestampFile -Raw
            $dateTime = [DateTime]::Parse($timestamp)
            Write-Host "Last run timestamp: $dateTime" -ForegroundColor Cyan
            return $dateTime
        }
        catch {
            Write-Warning "Could not parse last run timestamp file. Performing full refresh."
            return $null
        }
    }
    else {
        Write-Host "No previous run detected. Performing full refresh." -ForegroundColor Cyan
        return $null
    }
}

# Function to save the current run timestamp
function Save-LastRunTimestamp {
    param(
        [string]$ScriptRoot,
        [DateTime]$Timestamp
    )

    $timestampFile = Join-Path $ScriptRoot ".lastrun"

    try {
        $Timestamp.ToString("o") | Set-Content $timestampFile -NoNewline
        Write-Verbose "Saved last run timestamp: $Timestamp"
    }
    catch {
        Write-Warning "Failed to save last run timestamp: $_"
    }
}

# Function to get cached process data
function Get-CachedProcessData {
    param([string]$ScriptRoot)

    $cacheFile = Join-Path $ScriptRoot ".processcache.json"

    if (Test-Path $cacheFile) {
        try {
            $cachedData = Get-Content $cacheFile -Raw | ConvertFrom-Json
            Write-Host "Loaded $($cachedData.Count) processes from cache" -ForegroundColor Cyan
            return $cachedData
        }
        catch {
            Write-Warning "Could not load cached process data: $_"
            return @()
        }
    }
    else {
        Write-Verbose "No cache file found"
        return @()
    }
}

# Function to save process data to cache
function Save-ProcessDataCache {
    param(
        [string]$ScriptRoot,
        [array]$ProcessData
    )

    $cacheFile = Join-Path $ScriptRoot ".processcache.json"

    try {
        $ProcessData | ConvertTo-Json -Depth 10 | Set-Content $cacheFile -Encoding UTF8
        Write-Verbose "Saved $($ProcessData.Count) processes to cache"
    }
    catch {
        Write-Warning "Failed to save process cache: $_"
    }
}

# Function to get OData processes using Basic Authentication
function Get-ODataProcesses {
    param(
        [string]$BaseUrl,
        [string]$Username,
        [string]$ApiKey,
        [DateTime]$SinceDate = $null
    )

    Write-Host "`nQuerying OData API for process list..." -ForegroundColor Cyan

    # Create Basic Auth header
    $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $Username, $ApiKey)))
    $headers = @{
        Authorization = "Basic $base64AuthInfo"
        Accept = "application/json"
    }

    try {
        # Build the URL with optional date filter
        $url = "${BaseUrl}Processes"

        # Add OData filter for StateChangeDate if provided
        if ($SinceDate) {
            $filterDate = $SinceDate.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            $filter = "`$filter=StateChangeDate gt $filterDate"
            $url = "${url}?${filter}"
            Write-Host "Filtering for processes changed since: $SinceDate" -ForegroundColor Cyan
        }

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

# Function to build a complete process report row
function New-ProcessReportRow {
    param(
        [PSCustomObject]$ODataProcess,
        [PSCustomObject]$ProcessDetails
    )

    # Extract role names and system tags
    $roleNames = Get-RoleNames -ProcessDetails $ProcessDetails
    $systemTags = Get-SystemTagNames -ProcessDetails $ProcessDetails

    # Build the report row
    # Map OData fields to output columns - adjust field names based on actual OData schema
    $reportRow = [PSCustomObject]@{
        "ProcessId" = Coalesce $ODataProcess.Id, $ODataProcess.UniqueId, $ODataProcess.ProcessId, $ODataProcess.Guid
        "Process Group Path" = Coalesce $ODataProcess.ProcessGroupPath, $ODataProcess.GroupPath
        "Process Name" = Coalesce $ODataProcess.Name, $ProcessDetails.Name
        "Process Status" = Coalesce $ODataProcess.Status, $ProcessDetails.Status
        "Process Version" = Coalesce $ODataProcess.Version, $ProcessDetails.Version
        "Process Expert" = Coalesce $ODataProcess.ProcessExpert, $ODataProcess.Expert, $ProcessDetails.Expert
        "Process Owner" = Coalesce $ODataProcess.ProcessOwner, $ODataProcess.Owner, $ProcessDetails.Owner
        "Assigned Roles" = $roleNames
        "Assigned System" = $systemTags
        "StateChangeDate" = $ODataProcess.StateChangeDate
    }

    return $reportRow
}

# Main script execution
try {
    $scriptStartTime = Get-Date

    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host "Process Report Generator" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Yellow

    # Load configuration
    $config = Get-Configuration -Path $ConfigPath

    # Determine if we should do incremental update
    $lastRunDate = $null
    $cachedProcesses = @()

    if (-not $FullRefresh) {
        $lastRunDate = Get-LastRunTimestamp -ScriptRoot $PSScriptRoot
        if ($lastRunDate) {
            $cachedProcesses = Get-CachedProcessData -ScriptRoot $PSScriptRoot
        }
    }
    else {
        Write-Host "Full refresh requested - ignoring cache" -ForegroundColor Yellow
    }

    # Get processes from OData API (filtered by date if incremental)
    $odataProcesses = Get-ODataProcesses -BaseUrl $config.ODataAPI.BaseUrl `
                                          -Username $config.ODataAPI.Username `
                                          -ApiKey $config.ODataAPI.ApiKey `
                                          -SinceDate $lastRunDate

    if ($odataProcesses.Count -eq 0 -and $lastRunDate) {
        Write-Host "`n========================================" -ForegroundColor Green
        Write-Host "No processes have changed since last run" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "Last run: $lastRunDate" -ForegroundColor White
        Write-Host "Cached processes: $($cachedProcesses.Count)" -ForegroundColor White
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "`nPress Enter to exit..." -ForegroundColor Yellow
        $null = Read-Host
        exit 0
    }

    if ($odataProcesses.Count -eq 0 -and -not $lastRunDate) {
        Write-Warning "No processes found in OData API"
        Write-Host "`nPress Enter to exit..." -ForegroundColor Yellow
        $null = Read-Host
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

    # Process each changed/new process and gather details
    Write-Host "`nRetrieving detailed information for $($odataProcesses.Count) processes..." -ForegroundColor Cyan
    $updatedProcesses = @()
    $processedCount = 0
    $totalProcesses = $odataProcesses.Count

    foreach ($odataProcess in $odataProcesses) {
        $processedCount++
        Write-Progress -Activity "Processing processes" -Status "Process $processedCount of $totalProcesses" -PercentComplete (($processedCount / $totalProcesses) * 100)

        # Get the process unique ID from OData response
        # The field name may vary - common options: Id, UniqueId, ProcessId, Guid
        $processId = Coalesce $odataProcess.Id, $odataProcess.UniqueId, $odataProcess.ProcessId, $odataProcess.Guid

        if (-not $processId) {
            $processName = Coalesce $odataProcess.Name, 'Unknown'
            Write-Warning "Could not determine process ID for process: $processName"
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

        # Build the report row
        $reportRow = New-ProcessReportRow -ODataProcess $odataProcess -ProcessDetails $processDetails
        $updatedProcesses += $reportRow
    }

    Write-Progress -Activity "Processing processes" -Completed

    # Merge with cached data if doing incremental update
    if ($lastRunDate -and $cachedProcesses.Count -gt 0) {
        Write-Host "`nMerging with cached data..." -ForegroundColor Cyan

        # Create a hashtable for quick lookup of updated processes
        $updatedProcessIds = @{}
        foreach ($process in $updatedProcesses) {
            $updatedProcessIds[$process.ProcessId] = $process
        }

        # Build final dataset: keep cached processes that weren't updated, add updated ones
        $finalProcesses = @()
        foreach ($cachedProcess in $cachedProcesses) {
            if (-not $updatedProcessIds.ContainsKey($cachedProcess.ProcessId)) {
                # Process hasn't changed, keep cached version
                $finalProcesses += $cachedProcess
            }
        }

        # Add all updated processes
        $finalProcesses += $updatedProcesses

        Write-Host "Merged: $($cachedProcesses.Count - $updatedProcesses.Count) cached + $($updatedProcesses.Count) updated = $($finalProcesses.Count) total" -ForegroundColor Green
        $reportData = $finalProcesses
    }
    else {
        # First run or full refresh - use only the newly fetched data
        $reportData = $updatedProcesses
    }

    # Save cache for next run
    Save-ProcessDataCache -ScriptRoot $PSScriptRoot -ProcessData $reportData

    # Save timestamp for next run
    Save-LastRunTimestamp -ScriptRoot $PSScriptRoot -Timestamp $scriptStartTime

    # Export to CSV (exclude internal fields)
    $outputPath = Join-Path $PSScriptRoot $config.Output.CsvFileName
    Write-Host "`nExporting report to CSV..." -ForegroundColor Cyan

    $reportData | Select-Object "Process Group Path", "Process Name", "Process Status", "Process Version", `
                                "Process Expert", "Process Owner", "Assigned Roles", "Assigned System" |
        Export-Csv -Path $outputPath -NoTypeInformation -Encoding UTF8

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "Report generated successfully!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    if ($lastRunDate) {
        Write-Host "Last run: $lastRunDate" -ForegroundColor White
        Write-Host "Updated processes: $($updatedProcesses.Count)" -ForegroundColor White
    }
    else {
        Write-Host "Total processes: $totalProcesses" -ForegroundColor White
    }
    Write-Host "Processes in report: $($reportData.Count)" -ForegroundColor White
    Write-Host "Output file: $outputPath" -ForegroundColor White
    Write-Host "========================================" -ForegroundColor Green
}
catch {
    Write-Host "`n========================================" -ForegroundColor Red
    Write-Host "ERROR: Script execution failed" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Error $_
}
finally {
    # This block ALWAYS executes, regardless of success or failure
    Write-Host "`nPress Enter to exit..." -ForegroundColor Yellow
    $null = Read-Host
}
