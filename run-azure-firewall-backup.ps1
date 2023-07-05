<#

****************************************************************************************************************************
Created by: Neel Borghs - The Collective Consulting
Last update: 05 - July - 2023
Website: https://neelborghs.com

This Azure Automation runbook automates Azure Firewall backups. It takes snashots and saves it to a Blob storage container. 
It also deletes old backups from blob storage.

Based on https://techcommunity.microsoft.com/t5/azure-network-security-blog/runbook-to-manage-azure-firewall-back-ups/ba-p/3066035
****************************************************************************************************************************

#>

param(
    [parameter(Mandatory=$true)]
	[String] $ResourceGroupName="",
    [parameter(Mandatory=$true)]
	[String] $AzureFirewallName="",
    [parameter(Mandatory=$true)]
	[String] $AzureFirewallPolicy="",
    [parameter(Mandatory=$true)]
    [String]$StorageAccountName="",
	[parameter(Mandatory=$false)]
    [string]$BlobContainerName="Azure-Firewall-Backup",
	[parameter(Mandatory=$false)]
    [Int32]$RetentionDays=30
)

$ErrorActionPreference = 'stop'

function Login() {
	try
	{    
		Write-Verbose "Logging in to Azure..." -Verbose
        # Ensures you do not inherit an AzContext in your runbook
        Disable-AzContextAutosave -Scope Process
        # Connect to Azure with system-assigned managed identity
        $AzureContext = (Connect-AzAccount -Identity).context
        # Set and store context
        $AzureContext = Set-AzContext -SubscriptionName $AzureContext.Subscription -DefaultProfile $AzureContext
	}
    #Send out message if login fails
	catch {
		Write-Error -Message $_.Exception
		throw $_.Exception
	}
}

function Create-newContainer([string]$blobContainerName, $storageContext) {
	Write-Verbose "Creating '$blobContainerName' blob container space for storage..." -Verbose
    #Check if blob container already exists
	if (Get-AzStorageContainer -ErrorAction "Stop" -Context $storageContext | Where-Object { $_.Name -eq $blobContainerName }) {
		Write-Verbose "Container '$blobContainerName' already exists" -Verbose
	} else {
        #Create new container with name mentioned in parameters
		New-AzStorageContainer -ErrorAction "Stop" -Name $blobContainerName -Permission Off -Context $storageContext
		Write-Verbose "Container '$blobContainerName' created" -Verbose
	}
}

function Export-To-Storageaccount([string]$resourceGroupName, [string]$AzureFirewallName, [string]$storageKey, [string]$blobContainerName,$storageContext) {
	Write-Verbose "Starting Azure Firewall current configuration export in json..." -Verbose
    try
    {
        #Create filename
        $BackupFilename = $AzureFirewallName + (Get-Date).ToString("yyyyMMddHHmm") + ".json"
        #Set backup file path
        $BackupFilePath = ($env:TEMP + "\" + $BackupFilename)
        #Get Azure Firewall ID
        $AzureFirewallId = (Get-AzFirewall -Name $AzureFirewallName -ResourceGroupName $resourceGroupName).id
        #Get Azure Firewall Policy ID
        $FirewallPolicyID = (Get-AzFirewallPolicy -Name $AzureFirewallPolicy -ResourceGroupName $resourceGroupName).id
        #Export Azure Firewall and Policy
        Export-AzResourceGroup -ResourceGroupName $resourceGroupName -SkipAllParameterization -Resource @($AzureFirewallId, $FirewallPolicyID) -Path $BackupFilePath
	    
        
        Write-Output "Submitting request to dump Azure Firewall configuration"
        #Set blobname to the same value as BackupFilename
        $blobname = $BackupFilename
        #Export file to chosen Storage Account
        $output = Set-AzStorageBlobContent -File $BackupFilePath -Blob $blobname -Container $blobContainerName -Context $storageContext -Force -ErrorAction continue


    }
	#Send out message if backup fails
    catch {
		   $ErrorMessage = "BackUp not created. Please check the input values."
           throw $ErrorMessage
        }
    
}

function Remove-Older-Backups([int]$retentionDays, [string]$blobContainerName, $storageContext) {
	Write-Output "Removing backups older than '$retentionDays' days from blob: '$blobContainerName'"
	#Get retention date (today - retention period)
    $isOldDate = [DateTime]::UtcNow.AddDays(-$retentionDays)
    #Get date of blobs in Storage Account
	$blobs = Get-AzStorageBlob -Container $blobContainerName -Context $storageContext
    #Remove each blobs that are older than the allowed retention period
	foreach ($blob in ($blobs | Where-Object { $_.LastModified.UtcDateTime -lt $isOldDate -and $_.BlobType -eq "BlockBlob" })) {
		Write-Verbose ("Removing blob: " + $blob.Name) -Verbose
		Remove-AzStorageBlob -Blob $blob.Name -Container $blobContainerName -Context $storageContext
	}
}

Write-Verbose "Starting database backup..." -Verbose
#Import needed modules
Import-Module Az.Network
Import-Module Az.Resources

#Start login function
Login

#Set Storage Account context
$StorageContext = New-AzStorageContext -StorageAccountName $storageAccountName

#Start Create-newContainer function
Create-newContainer `
	-blobContainerName $blobContainerName `
	-storageContext $storageContext
	
#Start Export-To-Storageaccount function
Export-To-Storageaccount `
	-resourceGroupName $ResourceGroupName `
	-AzureFirewallName $AzureFirewallName `
	-storageKey $StorageKey `
	-blobContainerName $BlobContainerName `
	-storageContext $storageContext
	
#Start Remove-Older-Backups function
Remove-Older-Backups `
	-retentionDays $RetentionDays `
	-storageContext $StorageContext `
	-blobContainerName $BlobContainerName
	
Write-Verbose "Azure Firewall current configuration back up completed." -Verbose
