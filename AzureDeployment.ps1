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

Connect-AzAccount

#region create Resource Group
Write-Verbose -Message "Creating $($_.ResourceGroup) resource group in location $($_.Location)"
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
Write-Verbose -Message "Building Network Gateway for Mission Partner Network"
#GW requires public IP for interconnection
$newpubipargs = @{
    Name              = "VNetGWPubIP" 
    ResourceGroupName = $ResourceGroup 
    Location          = $location 
    AllocationMethod  = "Dynamic"
}
$gwip = New-AzPublicIpAddress @newpubipargs -WarningAction SilentlyContinue
$nw   = Get-AzVirtualNetwork -Name "MPNetwork" -ResourceGroupName $ResourceGroup
$sn   = Get-AzVirtualNetworkSubnetConfig -Name "GatewaySubnet" -VirtualNetwork $nw -WarningAction SilentlyContinue
$newgwipconfigargs = @{
    Name            = "VNetGWIPConfig" 
    Subnet          = $sn 
    PublicIpAddress = $gwip
}
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
$gwJob = New-AzVirtualNetworkGateway @newgwargs

#Create the Bastion for backdoor connection to MP Hosts
$newpubipargs.Name              = "BastionIP" 
$bastionip = New-AzPublicIpAddress @newpubipargs
$newbastionargs = @{
    ResourceGroupName = $ResourceGroup
    Name              = "MP-Bastion"
    PublicIpAddress   = $bastionip
    VirtualNetwork   = $nw      
    AsJob            = $true
}
$bastionjob = New-AzBastion @newbastionargs
#endregion

#wait for network gateway creation to complete
Write-Verbose -Message "Waiting for gateway creation to complete"
Wait-Job -Id $gwJob.Id
$gwJob |
    Out-File -FilePath $resultsfile -Append -Encoding ascii 

Write-Verbose -Message "Waiting for bastion creation"
Wait-Job -Id ($bastionjob).Id
$bastionjob |
    Out-File -FilePath $resultsfile -Append -Encoding ascii

#region create hosts vms
$vmcreationjob = @()
foreach ($vm in $Hosts) {
    $NewNICArgs = @{
        Name              = $vm.name + "-NIC"
        ResourceGroupName = $ResourceGroup
        Location          = $Location
        $Subnet           = Get-AzVirtualNetworkSubnetConfig -Name $vm.Subnet -VirtualNetwork $nw
    }
    $NIC = New-AzNetworkInterface @NewNICArgs

    $virtualmachine = New-AzVMConfig -VMName $vm.hostname -VMSize $vm.size
    $OSArgs = @{
        VM = $virtualmachine
        ComputerName = $vm.hostname
        Credential   = $Credential
        ProvisionVMAgent = $true
        WinRMHTTP        = $true
        WinRMHTTPs       = $true      
    }
    switch ($vm.OSType) {
        "Windows" {$OSArgs.Windows = $true}
        "Linux"   {$OSArgs.Linux   = $true}
    }
    $virtualmachine = Set-AzVMOperatingSystem @OSArgs
    $virtualmachine = Add-AzVMNetworkInterface -VM $virtualmachine -Id $NIC.Id
    $sourceimageargs = @{
        VM = $virtualmachine
        PublisherName = $vm.PublisherName
        Offer         = $vm.Offer
        Skus          = $vm.Skus
        Version       = "Latest"
    }
    $virtualmachine = Set-AzVMSourceImage @sourceimageargs
    $NewAzVMArgs = @{
        ResourceGroupName = $ResourceGroup
        Location          = $Location
        VirtualMachine    = $virtualmachine
        Verbose           = $true
    } #splatting hashtable
    $vmcreationjob = New-AzVM @NewAzVMArgs
}
#endregion

Wait-Job -Id ($vmcreationjob).Id
$vmcreationjob |
    Out-File -FilePath $resultsfile -Append -Encoding ascii

#next create AD domain, domain users, join window hosts to domain, set firewall rules allow ps remoting/ICMP/Etc


Invoke-Item $resultsfile