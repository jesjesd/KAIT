<#
	.SYNOPSIS
		Provies helper functions for Event Hub scripting

	.Created
		3/23/2015 - Mike Veazie
#>

if(!$__IsLoadedEH__)
{
	# Flag to keep track if we've loaded these or not
	New-Variable -Name "__IsLoadedEH__" -Option:ReadOnly -Scope "Script" -Value $true -Force
	
	. .\utils\Constants.ps1
	. .\utils\Utils_Shared.ps1
	
	Function Add-ServiceBusAssembly
	{
		if(Test-Path $AzureSDKRegKey)
		{
			$serviceBusDll = (Join-Path -Path (Get-ItemProperty $AzureSDKRegKey).InstallLocation -ChildPath $ServiceBusAssembly)
			[Void][System.Reflection.Assembly]::LoadFrom($serviceBusDll)
		}
		else
		{
			"Unable to load service bus dll from '{0}'" -f $serviceBusDll | Trace -Severity:Error
		}
	}
		
	Function CreateSBNamespaceIfNotExists([string]$SBName, [string]$SBLocation)
	{
		# Get-AzureSBnamespace and NameSpaceManager.CreateFromConnectionString(string connStr) return different data types
		#	so we'll need to massage it a little bit
		$namespace = Get-AzureSBNamespace -Name $SBName
		if($namespace -eq $null)
		{
			try
			{
				$newNS = New-AzureSBNamespace -Name $SBName -Location $SBLocation -CreateACSNamespace:$false -NamespaceType:Messaging
				$namespace = [Microsoft.ServiceBus.NamespaceManager]::CreateFromConnectionString($newNS.ConnectionString)
				
				#Give it 15 secondcs for the namespace to be created. Sometimes it fails if you try and create event hubs immediately after creating
				"Waiting for Service Bus namespace to be ready" | Trace
				$sleepSeconds = 15
				for($i = 0;$i -lt $sleepSeconds; $i++)
				{
					"." * $i | Trace
					Start-Sleep -Seconds 1
				}				
			}
			catch [System.Exception]
			{
				"Exception creating SB Namespace '{0}'. Exception: {1}" -f $Name, $_.Exception.Message | Trace -Severity:Exception
			}
		}
		else
		{
			$namespace = [Microsoft.ServiceBus.NamespaceManager]::CreateFromConnectionString($namespace.ConnectionString)
			"Namespace '{0}' already exists or null" -f $SBName | Trace
		}
		
		return $namespace
	}
	
	Function Get-AzureEventHubAppSettingsKey
	{
		Param(
			$EventHubName,
			$PolicyName
		)
		
		#<AzurePrefix>.EventHub
		$keyPrefix = Concat-AzurePrefix -Text "EventHub" -Delimiter '.'
		$capitalizedName = [string]::Concat([char]::ToUpper($EventHubName[0]),$EventHubName.Substring(1))
		$capitalizedPolicy = [string]::Concat([char]::ToUpper($PolicyName[0]),$PolicyName.Substring(1))
		
		#<AzurePrefix>.EventHub.PolicyName
		return ([String]::Concat($keyPrefix,'.',$capitalizedName,'.',$capitalizedPolicy))
	}
	
	Function CreateSBEventHubIfNotExists
	{
		Param(
			[Microsoft.ServiceBus.NamespaceManager]$NameSpace, 
			$Path, 
			$PartitionCount, 
			$MessageRetentionInDays,
			$SharedAccessPolicySettings	
		)
		
		$eventHub = $null
		try
		{
			"Creating Event Hub '{0}'" -f $Path | Trace
			 $eHDesc = New-Object Microsoft.ServiceBus.Messaging.EventHubDescription($Path)
			 $eHDesc.PartitionCount = $PartitionCount
			 $eHDesc.MessageRetentionInDays = $MessageRetentionInDays
			 
			 if($SharedAccessPolicySettings -eq $null)
			 {
			 	"No Shared Access Policy have been defined for this event hub" | Trace
			 }
			 else
			 {
			 	"Creating Shared Access Policies" | Trace
				foreach($sharedAccessPolicy in $SharedAccessPolicySettings | ?{$_.Type -eq "SharedAccessAuthorizationRule"})
				{					
					#Need to pass this guy in as an IEnumerable					
					$type = ("System.Collections.Generic.List"+'`'+"1") -as "Type"
					$type = $type.MakeGenericType("Microsoft.ServiceBus.Messaging.AccessRights" -as "Type")
					$accessRights = [Activator]::CreateInstance($type)
					
					foreach($right in $sharedAccessPolicy.AccessRights.Replace(' ','').Split(','))
					{
						"Adding access right '{0}' to '{1}'" -f $right, $sharedAccessPolicy.Name | Trace
						$accessRights.Add([Microsoft.ServiceBus.Messaging.AccessRights]$right)
					}
					
					$primaryKey = [Microsoft.ServiceBus.Messaging.SharedAccessAuthorizationRule]::GenerateRandomKey()
					$authorizationRule = New-Object Microsoft.ServiceBus.Messaging.SharedAccessAuthorizationRule($sharedAccessPolicy.Name,$primaryKey,$accessRights)
					$eHDesc.Authorization.Add($authorizationRule)
					
					#i.e - Inception.EventHub.Telemetry.SendPolicy
					$key = Get-AzureEventHubAppSettingsKey -EventHubName $Path -PolicyName $sharedAccessPolicy.Name
					
					$value = $global:EventHubConnectionString.Replace("|NAMESPACE_ABSOLUTE_URI|",$NameSpace.Address.AbsoluteUri)
					$value = $value.Replace("|SHARED_ACCESS_KEY_NAME|",$sharedAccessPolicy.Name)
					$value = $value.Replace("|SHARED_ACCESS_KEY|",$primaryKey)
					$value = $value.Replace("|ENTITY_PATH|",$Path)
					
					Write-AzureAppSettingValue -Key $key -Value $value
				}
			 }
			 
			 "Creating event hub if it does not already exist" | Trace
			 $eventHub = $NameSpace.CreateEventHubIfNotExistsAsync($eHDesc)
		}
		catch [System.Exception]
		{
			"Exception creating event hub '{0}'`r`nMessage: {1}" -f $Path, $_.Exception.Message | Trace -Severity:Exception
		}
		
		return $eventHub
	}
	
	Function Create-SBNamespaceAndEventHubs
	{
		"Creating Service Bus Namespace and Event Hubs" | Trace
		
		$serviceBusSettings = $global:AzureProvisionSettings.ServiceBus		
		$namespaceName = [String]::Concat($global:AzureProvisionSettings.AzurePrefix,$serviceBusSettings.Namespace)
		
		#Create the service bus namespace
		$sbNamespace = CreateSBNamespaceIfNotExists -SBName $namespaceName -SBLocation $serviceBusSettings.Region
		
		if($sbNamespace -ne $null)
		{			
			"Creating event hubs in namespace '{0}'" -f $namespaceName | Trace
			
			foreach($eventhub in $serviceBusSettings.EventHubs | ?{$_.Type -eq "AzureEventHub"})	
			{
				CreateSBEventHubIfNotExists -NameSpace $sbNamespace `
					-Path $eventhub.Name `
					-PartitionCount $eventhub.PartitionCount `
					-MessageRetentionInDays $eventhub.MessageRetentionInDays `
					-SharedAccessPolicySettings $eventHub.SharedAccessPolicies
			}
		}
	}

	Function Delete-SBNamespaceAndEventHubs
	{
		"Deleting Service Bus Namespace and Event Hubs..." | Trace

		$serviceBusSettings = $global:AzureProvisionSettings.ServiceBus		
		$namespaceName = Concat-AzurePrefix -Text $serviceBusSettings.Namespace
		$namespace = Get-AzureSBNamespace -Name $namespaceName

		if($namespace -eq $null)
		{
			"SB Namespace '{0}' was not found." -f $namespaceName | Trace
		}
		else
		{
			"Deleting '{0}'." -f $namespaceName | Trace
			Remove-AzureSBNamespace -Name $namespaceName -Force
		}
	}

	
	# Do these things on load
	Add-ServiceBusAssembly
}