[CmdletBinding()]
param (
    [string]
    $Path = $PWD,

    # Default Host Account, remove after creating domain accounts
    [Parameter(Mandatory=$true)]
    [pscredential]
    $DefaultHostAccount,

    [string]
    $ResourceGroup = "MissionPartner",

    [string]
    $Location = "East US"
)
Set-Item Env:\SuppressAzurePowerShellBreakingChangeWarnings "true"
$resultsfile = $env:TEMP + "\AzureDeployment.txt"
"Azure Deployment: $(Get-Date)" | Set-Content -Path $resultsfile

Write-Verbose -Message "Importing Data from $($path)"
$import_csv = @{path = Join-Path -ChildPath "SubNets.csv" -Path $Path}
$Subnets = Import-Csv @import_csv
$import_csv.path = Join-Path -ChildPath "Hosts.csv" -Path $Path
$Hosts = Import-Csv @import_csv

if (!(Get-AzContext)) {
    Connect-AzAccount
}

#region create Resource Group
Write-Verbose -Message "Creating $($ResourceGroup) resource group in location $($Location)"
$NewAzResourceGroupArgs = @{} #hashtable for splatting
$NewAzResourceGroupArgs.name = $ResourceGroup
$NewAzResourceGroupArgs.location = $Location
New-AzResourceGroup @NewAzResourceGroupArgs -Force -ErrorAction Stop | 
    Out-File -FilePath $resultsfile -Append -Encoding ascii
#endregion

#region create Network
Write-Verbose -Message "Creating Mission Partner Network"
$sn = @($Subnets | ForEach-Object {New-AzVirtualNetworkSubnetConfig -Name $_.name -AddressPrefix $_.subnet})
$sn += New-AzVirtualNetworkSubnetConfig -Name "AzureBastionSubnet" -AddressPrefix "10.1.0.0/27"
$sn += New-AzVirtualNetworkSubnetConfig -Name "GatewaySubnet" -AddressPrefix "10.1.0.32/27"
$addrspace = @($Subnets | Select-Object -ExpandProperty Subnet)
$addrspace += "10.1.0.0/27"
$addrspace += "10.1.0.32/27"
$NewAzVirtualNetworkArgs = @{
    Name = "MPNetwork"
    ResourceGroupName = $ResourceGroup
    Location          = $location
    AddressPrefix     = $addrspace
    Subnet            = $sn
} #hashtable for splatting
New-AzVirtualNetwork @NewAzVirtualNetworkArgs |
    Out-File -FilePath $resultsfile -Append -Encoding ascii
    
#Creating Gateway
#GW requires public IP for interconnection
$newpubipargs = @{
    Name              = "VNetGWPubIP" 
    ResourceGroupName = $ResourceGroup 
    Location          = $location 
    AllocationMethod  = "Dynamic"
}
Write-Verbose -Message "Creating GW public IP address"
$gwip = New-AzPublicIpAddress @newpubipargs -WarningAction SilentlyContinue
$nw   = Get-AzVirtualNetwork -Name "MPNetwork" -ResourceGroupName $ResourceGroup
$sn   = Get-AzVirtualNetworkSubnetConfig -Name "GatewaySubnet" -VirtualNetwork $nw -WarningAction SilentlyContinue
$newgwipconfigargs = @{
    Name            = "VNetGWIPConfig" 
    Subnet          = $sn 
    PublicIpAddress = $gwip
}
Write-Verbose -Message "Setting GW Config"
$gwipconfig = New-AzVirtualNetworkGatewayIpConfig @newgwipconfigargs
$newgwargs = @{
    name = "MPNetwork-Gateway"
    ResourceGroupName = $ResourceGroup
    Location          = $Location
    IPConfigurations = $gwipconfig
    GatewayType      = "VPN"
    VpnType          = "RouteBased"
    GatewaySku       = "VpnGw1"
    AsJob            = $true
} #Hashtable for splatting
Write-Verbose -Message "Creating Network Gateway for Mission Partner Network"
$gwJob = New-AzVirtualNetworkGateway @newgwargs

#Create the Bastion for backdoor connection to MP Hosts
$newpubipargs.Name = "BastionIP" 
$newpubipargs.sku  = "Standard"
$newpubipargs.AllocationMethod = "Static"
Write-Verbose -Message "Creating Bastion Public IP"
$bastionip = New-AzPublicIpAddress @newpubipargs
$newbastionargs = @{
    ResourceGroupName = $ResourceGroup
    Name              = "MP-Bastion"
    PublicIpAddress   = $bastionip
    VirtualNetwork    = $nw      
    AsJob             = $true
}
Write-Verbose -Message "Creating Bastion for MP Network"
$bastionjob = New-AzBastion @newbastionargs
#endregion

#region create hosts vms
$vmcreationjob = @()
foreach ($vm in $Hosts) {

    $NewNICArgs = @{
        Name              = $vm.hostname + "-NIC"
        ResourceGroupName = $ResourceGroup
        Location          = $Location
        Subnet            = Get-AzVirtualNetworkSubnetConfig -Name $vm.Subnet -VirtualNetwork $nw
    }
    Write-Verbose -Message "Creating NIC for $($vm.hostname)"
    $NIC = New-AzNetworkInterface @NewNICArgs

    Write-Verbose -Message "Creating $($vm.hostname) config"
    $virtualmachine = New-AzVMConfig -VMName $vm.hostname -VMSize $vm.size
    $OSArgs = @{
        VM = $virtualmachine
        ComputerName     = $vm.hostname
        Credential       = $DefaultHostAccount
        ProvisionVMAgent = $true
        WinRMHTTP        = $true    
    }
    switch ($vm.OSType) {
        "Windows" {$OSArgs.Windows = $true}
        "Linux"   {$OSArgs.Linux   = $true}
    }
    Write-Verbose -Message "Setting OS for $($vm.hostname)"
    $virtualmachine = Set-AzVMOperatingSystem @OSArgs
    $virtualmachine = Add-AzVMNetworkInterface -VM $virtualmachine -Id $NIC.Id
    $sourceimageargs = @{
        VM = $virtualmachine
        PublisherName = $vm.PublisherName
        Offer         = $vm.Offer
        Skus          = $vm.Skus
        Version       = "Latest"
    }
    Write-Verbose -Message "Setting $($vm.hostname) image"
    $virtualmachine = Set-AzVMSourceImage @sourceimageargs
    $NewAzVMArgs = @{
        ResourceGroupName = $ResourceGroup
        Location          = $Location
        VM                = $virtualmachine
        Verbose           = $true
        AsJob             = $true
    } #splatting hashtable
    Write-Verbose -Message "Creating $($vm.hostname) virtual machine"
    $vmcreationjob += New-AzVM @NewAzVMArgs
} 
#endregion

Write-Verbose -Message "Waiting for Bastion creation"
Wait-Job -Id ($bastionjob).Id
$bastionjob |
    Out-File -FilePath $resultsfile -Append -Encoding ascii

#wait for VM creation to complete
Write-Verbose -Message "Waiting for VM creation to complete"
Wait-Job -Id ($vmcreationjob).Id
$vmcreationjob |
    Out-File -FilePath $resultsfile -Append -Encoding ascii

#next create AD domain, domain users, join window hosts to domain, set firewall rules allow ps remoting/ICMP/Etc

Invoke-Item $resultsfile