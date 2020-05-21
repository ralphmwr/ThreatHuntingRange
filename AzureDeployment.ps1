[CmdletBinding()]
param (
    [string]
    $Path = $PWD,

    # Default Host Account, remove after creating domain accounts
    [Parameter(Mandatory=$true)]
    [pscredential]
    $DefaultHostAccount
)

$resultsfile = $env:TEMP + "\AzureDeployment.txt"
"Azure Deployment: $(Get-Date)" | Set-Content -Path $resultsfile

Write-Verbose -Message "Importing Data from $($path)"
$import_csv = @{path = Join-Path -ChildPath "Networks.csv" -Path $Path}
$Networks = Import-Csv @import_csv
$import_csv.path = Join-Path -ChildPath "Hosts.csv" -Path $Path
$Hosts = Import-Csv @import_csv

#region create Resource Groups
$ResourceGroups = $Networks | Select-Object ResourceGroup, Location -Unique
$ResourceGroups | ForEach-Object {
    Write-Verbose -Message "Creating $($_.ResourceGroup) resource group in location $($_.Location)"
    $NewAzResourceGroupArgs = @{} #hashtable for splatting
    $NewAzResourceGroupArgs.name = $_.ResourceGroup
    $NewAzResourceGroupArgs.location = $_.Location
    New-AzResourceGroup @NewAzResourceGroupArgs -Force -ErrorAction Stop | 
        Out-File -FilePath $resultsfile -Append -Encoding ascii
}
#endregion


#region create networks
$gwJob = @()
$bastionjob = @()
foreach ($N in $Networks) {
    Write-Verbose -Message "Creating $($N.name)"
    $hostSubnet    = New-AzVirtualNetworkSubnetConfig -Name "HostSubnet" -AddressPrefix $N.HostSubnet
    $bastionSubnet = New-AzVirtualNetworkSubnetConfig -Name "BastionSubnet" -AddressPrefix $N.BastionSubnet
    $gatewaySubnet = New-AzVirtualNetworkSubnetConfig -Name "GatewaySubnet" -AddressPrefix $N.GatewaySubnet

    $NewAzVirtualNetworkArgs = @{
        Name = $N.Name
        ResourceGroupName = $N.ResourceGroup
        Location          = $N.location
        AddressPrefix     = $N.range
        Subnet            = $hostSubnet, $bastionSubnet, $gatewaySubnet
    } #hashtable for splatting
    New-AzVirtualNetwork @NewAzVirtualNetworkArgs |
        Out-File -FilePath $resultsfile -Append -Encoding ascii
    
    #Creating Gateway
    Write-Verbose -Message "Building Network Gateway for $($N.name)"
    #GW requires public IP for interconnection
    $newpubipargs = @{
        Name              = "VNetGWPubIP" 
        ResourceGroupName = $N.Resource 
        Location          = $N.location 
        AllocationMethod  = "Dynamic"
    }
    $gwip = New-AzPublicIpAddress @newpubipargs
    $nw   = Get-AzVirtualNetwork -Name $N.name -ResourceGroupName $N.resource
    $sn   = Get-AzVirtualNetworkSubnetConfig -Name "GatewaySubnet" -VirtualNetwork $nw
    $newgwipconfigargs = @{
        Name            = "VNetGWIPConfig" 
        Subnet          = $sn 
        PublicIpAddress = $gwip
    }
    $gwipconfig = New-AzVirtualNetworkGatewayIpConfig @newgwipconfigargs

    $newgwargs = @{
        name = "{0}-GW" -f $N.name
        ResourceGroup = $N.resource
        Location      = $N.location
        IPConfigurations = $gwipconfig
        GatewayType      = "VPN"
        VpnType          = "RouteBased"
        GatewaySku       = "VpnGw1"
        AsJob            = $true
    }
    $gwJob += New-AzVirtualNetworkGateway @newgwargs

    #Create the Bastion for backdoor connection to MP Hosts

    $bastionip = New-AzPublicIpAddress -Name "BastionIP" -ResourceGroupName $N.resource -Location $N.location
    $newbastionargs = @{
        ResourceGroupName = $N.resource
        Name              = $N.resource + "-Bastion"
        PublicIpAddress   = $bastionip
        VirtualNetwork   = $nw      
        AsJob            = $true
    }
    $bastionjob += New-AzBastion @newbastionargs
}
#endregion

#wait for network gateway creation to complete
Write-Verbose -Message "Waiting for gateway creation to complete"
Wait-Job -Id ($gwJob).Id
$gwJob |
    Out-File -FilePath $resultsfile -Append -Encoding ascii 

#region create virtual network connections
foreach ($N in $Networks) {
    $gw = Get-AzVirtualNetworkGateway -Name "$($N.Name)-GW" -ResourceGroupName $N.resource
    foreach ($CN in $Networks | Where-Object {$_.name -ne $N.Name}) {
        $conname = $N.name + "-" + $CN.name
        $reverse = $CN.name + "-" + $N.name
        if (Get-AzVirtualNetworkGatewayConnection -Name $conname -ResourceGroupName "*") {Continue}
        Write-Verbose -Message "Creating $conname connection"
        $cgw = Get-AzVirtualNetworkGateway -Name "$($CN.Name)-GW" -ResourceGroupName $CN.resource
        $nconnargs = @{
            name = $conname
            ResourceGroupName = $N.Resource
            VirtualNetworkGateway1 = $gw
            VirtualNetworkGateway2 = $cgw
            Location               = $N.location
            ConnectionType         = "Vnet2Vnet"
            SharedKey              = "AzureA1b2C3"
        }
        New-AzVirtualNetworkGatewayConnection @nconnargs |
            Out-File -FilePath $resultsfile -Append -Encoding ascii
        
        Write-Verbose -Message "Creating $reverse connection"
        $nconnargs.name                   = $reverse
        $nconnargs.ResourceGroupName      = $CN.resource
        $nconnargs.VirtualNetworkGateway1 = $cgw
        $nconnargs.VirtualNetworkGateway2 = $gw
        $nconnargs.location               = $CN.Location
        New-AzVirtualNetworkGatewayConnection @nconnargs |
            Out-File -FilePath $resultsfile -Append -Encoding ascii
    }
}
#endregion
Write-Verbose -Message "Waiting for bastion creation"
Wait-Job -Id ($bastionjob).Id
$bastionjob |
    Out-File -FilePath $resultsfile -Append -Encoding ascii

#region create hosts vms
$vmcreationjob = @()
foreach ($vm in $Hosts) {
    $NewAzVMArgs = @{} #splatting hashtable
    $vmcreationjob += New-AzVM @NewAzVMArgs
}
#endregion

Wait-Job -Id ($vmcreationjob).Id
$vmcreationjob |
    Out-File -FilePath $resultsfile -Append -Encoding ascii

#next create AD domain, domain users, join window hosts to domain, set firewall rules allow ps remoting/ICMP/Etc


Invoke-Item $resultsfile