<#
	.SYNOPSIS
		Creates Azure Storage Accounts, Containers, ServiceBus Namespace, Event Hubs, Stream Analytics, and Data Factory Services.
		This script is driven by the configuration file located at .\conf\Azureprovisionsettings.json
		
	.Created
		3/23/2015 - Mike Veazie
#>

Param(
	[switch]$CreateStorageAccounts,
	[switch]$CreateHDInsightCluster,
	[switch]$CreateEventHubs,
	[switch]$CreateASA,
	[switch]$CreateDataFactory
)

#Region References & Param Validation

	cls
	
	#Change the directory to the location we're running the script from so we can use relative paths
	Set-Location -LiteralPath ([System.IO.Directory]::GetParent($MyInvocation.MyCommand.Path))

	. .\utils\Constants.ps1
	. .\utils\Utils_Shared.ps1
	. .\utils\Utils_Storage.ps1 # Azure Storage
	. .\utils\Utils_HDI.ps1	# HDInsight
	. .\utils\Utils_EH.ps1	# Event Hub and Service Bus
	. .\utils\Utils_ASA.ps1	# Stream Analytics
	. .\utils\Utils_DF.ps1 	# Data Factory
	
	# If no switch parameters are specified, we'll create everything. Otherwise, only create the services specified
	if(($CreateStorageAccounts.ToBool() -bor $CreateHDInsightCluster.ToBool() -bor $CreateEventHubs.ToBool() -bor $CreateASA.ToBool() -bor $CreateDataFactory.ToBool()) -eq 0)
	{
		"No parameters were specified. Creating all available services" | Trace
		
		$CreateStorageAccounts = $true
		$CreateHDInsightCluster = $true
		$CreateEventHubs = $true
		$CreateASA = $true
		$CreateDataFactory = $true
	}
	
	"Create Storage Accounts: {0}" -f $CreateStorageAccounts | Trace
	"Create HDInsight Cluster: {0}" -f $CreateHDInsightCluster | Trace
	"Create Event Hubs: {0}" -f $CreateEventHubs | Trace
	"Create Stream Analytics: {0}" -f $CreateASA | Trace
	"Create Data Factory: {0}" -f $CreateDataFactory | Trace
	
#EndRegion References & Param Validation

if(!(Import-AzurePSModules))
{
	"Unable to import Azure PowerShell Modules. Have you installed the Azure SDK with Microsoft Azure PowerShell?" | Trace -Severity:Error
}
else
{
	#Get all of the settings for storage accounts, event hubs, etc. If we can't get them, stop the script
	if(!(Load-AzureProvisionSettings))
	{
		"There was an issue loading the settings file."  | Trace -Severity:Error
	}
	else
	{
		#This file will be populated during execution with the storage account connection strings and event hub connection strings
		#	It is stored on the conf folder
		Create-AzureAppSettingsXmlFile -Overwrite:$true
		
		# The Remove-AzureAccount cmdlet deletes an Azure account and its subscriptions from the subscription data file in your roaming user profile. It does not delete the account from Microsoft Azure, or change 
		# the actual account in any way.
	    #
		#Using this cmdlet is a lot like logging out of your Azure account. And, if you want to log into the account again, use the Add-AzureAccount or Import-AzurePublishSettingsFile to add the account to 
		#Windows PowerShell again.
		#
		#We are doing this to reset the authentication to Azure before running the script in case something is still cached.
		Get-AzureAccount | %{Remove-AzureAccount -Name $_.Id -Force | Out-Null}	
		Add-AzureAccount -ErrorAction:Stop		
		Select-AzureSubscription -SubscriptionId $global:AzureProvisionSettings.AzureSubscriptionId -ErrorAction:Stop
		
		if($CreateStorageAccounts)
		{
			#Creates all storage accounts and containers defined in the configuration settings. Also uploads block blobs if they're defined.
			Create-AzureStorageAccountsAndContainers -UploadFiles:$true
		}
		
		if($CreateHDInsightCluster)
		{
			#Creates the Hadoop cluster as defined in the settings
			Create-AzureHDInsightCluster -SetConfigurationValues:$true
		}
		
		if($CreateEventHubs)
		{
			#Creates the Service bus namespace and event hubs (If they don't exist) and assigned send and listen Shared Access Policies
			Create-SBNamespaceAndEventHubs
		}
		
		if($CreateASA)
		{
			#Creates the Stream Analytics jobs with input, outputs, and queries
			Create-AzureStreamAnalyticsJobs
		}
		
		if($CreateDataFactory)
		{
			#Creates the inception data factory with all linked services, datasets, and pipelines
			Create-AzureDataFactoryAndPipelines
		}
	}
}

Read-Host "The script has completed. Press any button to continue" -ErrorAction:SilentlyContinue

