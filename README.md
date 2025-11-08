# Process Data CSV Report Generator

This PowerShell script generates a comprehensive CSV report of processes using the Nintex Promapp OData API and Process Manager API.

## Features

- Queries the Nintex Promapp OData Reporting API to retrieve a list of processes
- Authenticates with the Process Manager API using OAuth2
- Retrieves detailed information for each process including:
  - Role owners (semicolon-delimited)
  - System tags (semicolon-delimited)
- Generates a CSV report with customizable output
- **Incremental updates**: On subsequent runs, only queries the API for processes that have changed since the last run (based on `StateChangeDate`)
- Local caching of process data for faster incremental updates
- Full refresh option to rebuild the entire dataset

## Prerequisites

- PowerShell 5.1 or higher
- Valid Nintex Promapp OData API key
- Valid Process Manager API credentials
- Network access to Nintex Promapp APIs

## Setup

### 1. Configure the config.json file

Edit the `config.json` file with your credentials and endpoints:

```json
{
  "ODataAPI": {
    "Region": "au",
    "BaseUrl": "https://au-reporting.promapp.io/odata/",
    "Username": "Promaster",
    "ApiKey": "YOUR_ODATA_API_KEY_HERE"
  },
  "ProcessManagerAPI": {
    "BaseUrl": "https://your-tenant.promapp.io",
    "AutomationTenant": "your-tenant-name",
    "Username": "YOUR_USERNAME_HERE",
    "Password": "YOUR_PASSWORD_HERE",
    "ClientId": "promappwebclient",
    "ClientSecret": "",
    "GrantType": "password"
  },
  "Output": {
    "CsvFileName": "ProcessReport.csv"
  }
}
```

#### Configuration Parameters:

**ODataAPI Section:**
- `Region`: Your datacenter region (e.g., "au", "us", "eu")
- `BaseUrl`: The OData API endpoint for your region
  - Australia: `https://au-reporting.promapp.io/odata/`
  - US: `https://us-reporting.promapp.io/odata/`
  - Europe: `https://eu-reporting.promapp.io/odata/`
- `Username`: Always "Promaster" (universal username)
- `ApiKey`: Your OData API key (obtain from Nintex Promapp admin)

**ProcessManagerAPI Section:**
- `BaseUrl`: Your Process Manager instance URL (e.g., `https://yourcompany.promapp.io`)
- `AutomationTenant`: Your tenant identifier
- `Username`: Your Process Manager username
- `Password`: Your Process Manager password
- `ClientId`: OAuth client ID (default: "promappwebclient")
- `ClientSecret`: OAuth client secret (leave empty if not required)
- `GrantType`: OAuth grant type (default: "password")

**Output Section:**
- `CsvFileName`: Name of the output CSV file

### 2. Obtaining API Credentials

#### OData API Key:
1. Log in to Nintex Promapp as an administrator
2. Navigate to Settings > Integrations > API
3. Generate or copy your API key

#### Process Manager API Credentials:
Use your standard Nintex Promapp login credentials.

## Usage

### Basic Usage

Run the script from PowerShell:

```powershell
.\Get-ProcessReport.ps1
```

On the first run, the script will retrieve all processes. On subsequent runs, it will automatically perform an incremental update, only querying the Process Manager API for processes that have changed since the last run.

### Using a Custom Config File

```powershell
.\Get-ProcessReport.ps1 -ConfigPath "C:\MyConfig\custom-config.json"
```

### Full Refresh

To force a complete refresh of all process data (ignoring the cache):

```powershell
.\Get-ProcessReport.ps1 -FullRefresh
```

Use this option when:
- You want to rebuild the entire dataset from scratch
- There were errors in previous runs
- You suspect the cache is out of sync

### Verbose Output

For detailed logging and troubleshooting:

```powershell
.\Get-ProcessReport.ps1 -Verbose
```

## Incremental Updates

The script uses intelligent caching to minimize API calls and improve performance on subsequent runs.

### How It Works

1. **First Run**:
   - Retrieves all processes from the OData API
   - Queries the Process Manager API for details on each process
   - Saves process data to `.processcache.json`
   - Records the run timestamp in `.lastrun`

2. **Subsequent Runs**:
   - Reads the last run timestamp from `.lastrun`
   - Queries the OData API with a filter: `StateChangeDate > [last run time]`
   - Only retrieves details for processes that have changed
   - Merges updated data with cached data
   - Updates the cache and timestamp

3. **Benefits**:
   - Dramatically faster execution for large process sets
   - Reduces load on the Process Manager API
   - Automatic - no configuration needed
   - Can be overridden with `-FullRefresh` when needed

### Cache Files

The script maintains two cache files in the script directory:

- `.lastrun` - Timestamp of the last successful run (ISO 8601 format)
- `.processcache.json` - Cached process data from the last run

These files are automatically created and updated by the script. They are excluded from git via `.gitignore`.

**Note**: If you delete these cache files, the next run will perform a full refresh automatically.

## Output

The script generates a CSV file with the following columns:

| Column Name | Description |
|-------------|-------------|
| Process Group Path | The hierarchical path of the process group |
| Process Name | Name of the process |
| Process Status | Current status of the process |
| Process Version | Version number of the process |
| Process Expert | Name of the process expert |
| Process Owner | Name of the process owner |
| Assigned Roles | Semicolon-delimited list of role names |
| Assigned System | Semicolon-delimited list of system tags |

### Example Output:

```csv
Process Group Path,Process Name,Process Status,Process Version,Process Expert,Process Owner,Assigned Roles,Assigned System
Sales/CRM,Customer Onboarding,Active,2.1,John Smith,Jane Doe,Account Executive; Sales Manager,CRM System; Email Platform
```

## Troubleshooting

### Authentication Errors

**OData API:**
- Verify your API key is correct
- Ensure you're using "Promaster" as the username
- Check that the BaseUrl matches your region

**Process Manager API:**
- Verify your username and password
- Ensure the BaseUrl and AutomationTenant are correct
- Check that your account has API access permissions

### No Processes Retrieved

- Verify your OData API permissions
- Check the OData endpoint URL
- Review the API key permissions in Nintex Promapp admin

### Script Execution Policy

If you encounter execution policy errors:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### Missing Process Details

- Some processes may not have detailed information available
- Check the verbose output to see which processes are being skipped
- Verify API permissions for accessing process details

### Cache Issues

If you suspect the cache is corrupted or out of sync:

1. Delete the cache files:
   ```powershell
   Remove-Item .lastrun, .processcache.json
   ```

2. Run a full refresh:
   ```powershell
   .\Get-ProcessReport.ps1 -FullRefresh
   ```

3. Alternatively, just use the `-FullRefresh` parameter without deleting files

## Field Mapping Notes

The script attempts to map fields from both APIs. If certain fields are not populating:

1. Run the script with `-Verbose` to see API responses
2. Check the OData API schema to verify field names
3. Update the field mappings in the script if necessary (lines with `??` operators)

## API Rate Limiting

Be aware of API rate limits:
- The script processes each process sequentially to avoid overwhelming the API
- For large numbers of processes, the script may take several minutes to complete
- A progress bar displays the current status

## Support

For issues related to:
- **API access**: Contact Nintex Support
- **Script functionality**: Check the verbose output and error messages
- **Configuration**: Review the config.json file format

## Version History

- **2.0**: Incremental updates feature
  - Added intelligent caching based on StateChangeDate
  - Automatic incremental updates on subsequent runs
  - Full refresh option via `-FullRefresh` parameter
  - Significant performance improvements for large datasets
  - Local cache management (.lastrun and .processcache.json)

- **1.0**: Initial release
  - OData API integration
  - Process Manager API integration
  - CSV report generation
  - Role and system tag extraction

## License

This script is provided as-is for use with Nintex Promapp services.
