<#
	.SYNOPSIS
		Provies helper functions for Azure Storage scripting
		
	.Created
		3/23/2015 - Mike Veazie
#>

if(!$__IsLoadedDF__)
{
	# Flag to keep track if we've loaded these or not
	New-Variable -Name "__IsLoadedStorage__" -Option:ReadOnly -Scope "Script" -Value $true -Force
	
	. .\utils\Constants.ps1
	. .\utils\Utils_Shared.ps1
	
	Function Add-AzureStorageAssembly
	{
		if(Test-Path $AzureSDKRegKey)
		{
			$storageDll = (Join-Path -Path (Get-ItemProperty $AzureSDKRegKey).InstallLocation -ChildPath $AzureStorageAssembly)
			[Void][System.Reflection.Assembly]::LoadFrom($storageDll)
		}
		else
		{
			"Unable to load service bus dll from '{0}'" -f $storageDll | Trace -Severity:Error
		}
	}
	
	Function Concat-AzureStorageDNSSuffix
	{
		Param(
			$Text,
			$Suffix = ".blob.core.windows.net"
		)
		
		return ([string]::Concat($Text,$Suffix))
	}
	
	Function Create-AzureStorageAccountsAndContainers
	{
		Param(
			[Switch]$UploadFiles = $true
		)
		
		"Creating storage accounts and containers" | Trace
		
		foreach($storageAccount in $global:AzureProvisionSettings.Storage | ?{$_.Type -eq 'AzureStorageAccount'})
		{			
			$prefixedName = (Concat-AzurePrefix -Text $storageAccount.Name).ToLower()
			
			if($prefixedName.Length -gt $global:MaxStorageAccountNameLength)
			{
				"The Azure name prefix and storage account name must be {0} characters or less." -f $global:MaxStorageNameLength | Trace -Severity:Warning
				continue
			}
			
			#Checking to see if it's already been created
			$existingAccount = Get-AzureStorageAccount $prefixedName -ErrorAction:SilentlyContinue
			
			if($existingAccount -ne $null)
			{
				"The storage account '{0}' already exists" -f $prefixedName | Trace
			}
			else
			{				
				if($storageAccount.Region -ne $null)
				{
					"Creating storage account '{0}' in data center '{1}'" -f $prefixedName, $storageAccount.Region | Trace
					#Remove all whitespace, hyphens, and underscores to minimize spelling and case issues
					$formattedReplication = [string]$storageAccount.Replication.Replace(" ","").Replace("-","").Replace("_","").ToLower()
					
					if([string]::IsNullOrEmpty($global:ReplicationTypes[$formattedReplication]))
					{
						"'{0} ({1})' was not found in the supported replication types. This storage account will not be created." -f $storageAccount.Replication, $formattedReplication | Trace -Severity:Error
						continue
					}
					else
					{
						$cmdWithParams = "New-AzureStorageAccount -StorageAccountName '{0}' -Description '{1}' -Type '{2}' -Location '{3}'" -f $prefixedName, $storageAccount.Description, $global:ReplicationTypes[$formattedReplication], $storageAccount.Region						
						"Executing PowerShell Cmdlet: '{0}'" -f $cmdWithParams | Trace
						Invoke-Expression -Command $cmdWithParams -ErrorAction:Continue
						
						if(!$?)
						{
							"Error creating storage account. Continuing with script execution" | Trace -Severity:Warning
							continue
						}
					}					
				}
				else
				{
					"Location for the storage account needs to be defined in the settings." | Trace -Severity:Error
				}
			}			
			
			#At this point we know that the storage account already exists, or we succesfully created a new one
			#	Time to add the specified containere. We need the storage key in order to do anything past this point			
			$primaryStorageKey = (Get-AzureStorageKey -StorageAccountName $prefixedName -ErrorAction:Continue).Primary
			
			if([string]::IsNullOrEmpty($primaryStorageKey))
			{
				"The storage account key could not be retrieved. No containers will be created on this account" | Trace -Severity:Warning
			}
			else
			{
				$storageConnString = Get-AzureStorageConnectionString -StorageAccountName $prefixedName
				
				$appKey = [String]::Concat("Microsoft.Azure.Storage.",$prefixedName)
				Write-AzureAppSettingValue -Key $appKey -Value $storageConnString
				
				"Getting cloud blob client with connection string '{0}'" -f $storageConnString | Trace				
				$cloudStorageAccount = [Microsoft.WindowsAzure.Storage.CloudStorageAccount]::Parse($storageConnString)
				$cloudBlobClient = $cloudStorageAccount.CreateCloudBlobClient()
				
				$storageContext = New-AzureStorageContext -StorageAccountKey $primaryStorageKey -StorageAccountName $prefixedName
				
				foreach($storageContainer in $storageAccount.Containers | ?{$_.Type -eq "StorageContainer"})
				{
					#Check if this container already exists
					$currentContainer = Get-AzureStorageContainer -Name $storageContainer.Name.ToLower() -Context $storageContext -ErrorAction:SilentlyContinue
					if($currentContainer -eq $null)
					{
						#Container names can contain numbers, lowercase letters, and hyphens. They can't contain more than two consecutive hyphens
						$formattedContainerAccess = [string]$storageContainer.Access.Replace(" ","").Replace("_","").Replace("--","-").ToLower()
						
						if($storageContainer.Name.Length -gt $global:MaxStorageContainerNameLength)
						{
							"The Azure storage container name must be {0} characters or less." -f $global:MaxStorageContainerNameLength | Trace -Severity:Warning
							continue
						}
						
						if([Enum]::GetNames([Microsoft.WindowsAzure.Storage.Blob.BlobContainerPublicAccessType]).Contains($global:ContainerAccessTypes[$formattedContainerAccess]))
						{
							#$access = [Microsoft.WindowsAzure.Storage.Blob.BlobContainerPublicAccessType]$global:ContainerAccessTypes[$formattedContainerAccess]
							"Setting container access to '{0}'" -f $global:ContainerAccessTypes[$formattedContainerAccess] | Trace
						}
						else
						{
							"'{0} ({1})' was not found in the supported access types. Skipping this container." -f $storageContainer.Access, $formattedContainerAccess | Trace -Severity:Error
							continue
						}
						
						New-AzureStorageContainer -Name $storageContainer.Name.ToLower() -Context $storageContext -Permission $global:ContainerAccessTypes[$formattedContainerAccess] -ErrorAction:Continue
						
					}#End container is null
					else
					{
						"Storage container '{0}' already exists." -f $storageContainer.Name.ToLower() | Trace
					}
						
					if($UploadFiles)
					{
						"Uploading files to specified containers" | Trace
						
						foreach($uploadNode in $storageContainer.Upload | ?{$_.Type -eq 'AzureBlockBlob'})
						{
							$containerRef = $cloudBlobClient.GetContainerReference($storageContainer.Name.ToLower())
							
							if($containerRef -eq $null)
							{
								"Unable to get a container reference for '{0}'. Continuing to next container." -f $storageContainer.Name.ToLower() | Trace -Severity:Error
								continue
							}
							
							#Upload all files from the local directory
							$dirPath = Join-Path -Path $PWD -ChildPath $uploadNode.LocalDirectory
							
							foreach($file in (Get-ChildItem -Path $dirPath))
							{
								$fileName = [System.IO.Path]::GetFileName($file.FullName)
								
								if(!([System.IO.File]::Exists($file.FullName)))
								{
									"Unable to find local file '{0}'" -f $file.FullName | Trace -Severity:Error
								}
								else
								{
									if(!([string]::IsNullOrEmpty($uploadNode.AzureDirectory)))
									{
										$fileName = [string]::Concat($uploadNode.AzureDirectory,'/',$fileName)
										"Azure directory specified. Destination location changed to '{0}'" -f $fileName | Trace
									}
									
									$blockBlob = $containerRef.GetBlockBlobReference($fileName)
									
									#Only upload this guy if the blob doesn't already exist or if the overwrite flag is set to true
									if(!$blockBlob.Exists() -or (([string]$uploadNode.Overwrite).ToLower() -eq [bool]::TrueString.ToLower()))
									{
										"Uploading local file '{0}' to container '{1}'" -f $fileName, $storageContainer.Name.ToLower() | Trace
										$blockBlob.UploadFromStream([System.IO.File]::OpenRead($file.FullName))
									}
									else
									{
										"Local file '{0}' already exists in container '{1}'" -f $fileName, $storageContainer.Name.ToLower() | Trace
									}
								}
							}
						}#End foreach			
					}#End upload files
				}#End foreach container
			}#End else key is null
		}#End foreach storage account
	}#End create storage function

	Function Get-AzureStorageConnectionString
	{
		Param(
			$StorageAccountName
		)
		
		$primaryStorageKey = (Get-AzureStorageKey -StorageAccountName $StorageAccountName -ErrorAction:Continue).Primary
		return $global:StorageConnectionString.Replace("|ACCOUNT_NAME|",$StorageAccountName).Replace("|ACCOUNT_KEY|",$primaryStorageKey)
	}

	Function Delete-AzureStorageAccounts
	{	
		"Deleting storage accounts..." | Trace
		
		foreach($storageAccount in $global:AzureProvisionSettings.Storage | ?{$_.Type -eq 'AzureStorageAccount'})
		{			
			$prefixedName = (Concat-AzurePrefix -Text $storageAccount.Name).ToLower()
			
			#Checking to see if it's already been created
			$existingAccount = Get-AzureStorageAccount $prefixedName -ErrorAction:SilentlyContinue
			
			if($existingAccount -eq $null)
			{
				"The storage account '{0}' was not found." -f $prefixedName | Trace
			}
			else
			{			
				"Deleting '{0}'." -f $prefixedName | Trace
				Remove-AzureStorageAccount -StorageAccountName $prefixedName
			}			
		}
	}

	
	#Do these things on load
	Add-AzureStorageAssembly
}