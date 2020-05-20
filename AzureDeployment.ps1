[CmdletBinding()]
param (
    [string]
    $Path = $PWD,

    # Parameter help description
    [Parameter(Mandatory=$true)]
    [pscredential]
    $DefaultHostAccount
)

$resultsfile = $env:TEMP + "\AzureDeployment.txt"
"Azure Deployment: $(Get-Date)" | Set-Content -Path $resultsfile

#This will prompt for azure credentials including multi-factor if enabled
#Connect-AzAccount
Write-Verbose -Message "Importing Data from $($path)"
$import_csv = @{path = Join-Path -ChildPath "Networks.csv" -Path $Path}
$Networks = Import-Csv @import_csv
$import_csv.path = Join-Path -ChildPath "Hosts.csv" -Path $Path
$Hosts = Import-Csv @import_csv

#create Resource Groups
$ResourceGroups = $Networks | Select-Object ResourceGroup, Location -Unique
$ResourceGroups | ForEach-Object {
    Write-Verbose -Message "Creating $($_.ResourceGroup) resource group in location $($_.Location)"
    New-AzResourceGroup -Name $_.ResourceGroup -Location $_.Location -Force -ErrorAction Stop | 
        Out-File -FilePath $resultsfile -Append -Encoding ascii
}

foreach ($N in $Networks) {
    
}

Invoke-Item $resultsfile