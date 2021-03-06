<#
	.SYNOPSIS
		Provies shared helper functions for azure scripting
		
	.Created
		3/23/2015 - Mike Veazie
#>

if(!$__IsLoadedShared__)
{
	# Flag to keep track if we've loaded these or not
	New-Variable -Name "__IsLoadedShared__" -Option:ReadOnly -Scope "Script" -Value $true -Force
	
	. .\utils\Constants.ps1

	Function Trace-Output
	{
		Param(
			[Parameter(ValueFromPipeline=$true)]$Message,
			[MTC.Enums.TraceSeverity]$Severity = [MTC.Enums.TraceSeverity]::Medium
		)
		
		#This is only for displaying to the PS host console		
		switch($Severity)
		{
			Verbose
			{
				$Message | Write-Host -ForegroundColor:Yellow
				break
			}
			Medium
			{
				$Message | Write-Host
				break
			}
			Warning
			{
				$Message | Write-Host -ForegroundColor:DarkRed
				break
			}
			Error
			{
				$Message | Write-Host -ForegroundColor:Red
				break
			}
			Exception
			{
				$Message | Write-Host -ForegroundColor:White -BackgroundColor:Red
				break
			}
		}		
		
		$currentMessage = New-Object -TypeName 'PSObject' -Property @{
			"TimestampUTC" = [DateTime]::UtcNow.ToString()
			"Severity" = [string]$Severity
			"Message" = $Message
		}
		
		#Write this to the tsv log file
		$currentMessage | Export-Csv -Delimiter "`t" -Path $global:AzureProvisionLogFile -Append -NoTypeInformation
	}
	
	Function Import-AzurePSModules
	{
		if(!$global:AzurePSModulesLoaded)
		{		
			foreach($module in $global:AzurePSModules.Keys)
			{
				try
				{
					"Importing module '{0}'" -f $module | Trace
					Import-Module $global:AzurePSModules[$module]
					$global:AzurePSModulesLoaded = $true
				}
				catch [System.Exception]
				{
					"Exception loading Azure Module.`r`nError Message: {0}" -f $_.Exception.Message | Trace -Severity:Exception
					break
				}
			}
		}
		
		return $global:AzurePSModulesLoaded
	}

	Function Load-AzureProvisionSettings
	{
		try
		{
			#Read the settings file and make sure we read it succesfully
			$global:AzureProvisionSettings = ConvertFrom-Json -InputObject ([string](Get-Content -Path $global:AzureProvisionSettingsFile))
		}
		catch [System.Exception]
		{
			"Exception loading Azure Provision settings from '{0}'.`r`nError Message: {1}" -f $global:AzureProvisionSettingsFile, $_.Exception.Message | Trace -Severity:Exception
		}
		
		return $global:AzureProvisionSettings -ne $null
	}
	
	Function Concat-AzurePrefix
	{
		Param(
			$Prefix = $global:AzureProvisionSettings.AzurePrefix,
			$Delimiter = "",
			$Text
		)
		
		return ([String]::Concat($Prefix,$Delimiter,$Text))
	}
	
	Function Get-AzureAppSettingXmlFile
	{
		return ($appSettingsXmlLocation = Join-Path -Path $PWD -ChildPath $global:AzureProvisionSettings.AppSettingsXmlOutputLocation)
	}
	
	#Creates an Xml file with the following nodes:
	#	<?xml version="1.0" encoding="UTF-8"?>
	#	<appSettings />
	#
	Function Create-AzureAppSettingsXmlFile
	{
		Param(
			[Switch]$Overwrite
		)
		
		if($OverWrite -or !([System.IO.File]::Exists((Get-AzureAppSettingXmlFile))))
		{
			New-Item -ItemType 'File' -Path (Get-AzureAppSettingXmlFile) -Force
			$xmlWriter = New-Object System.Xml.XmlTextWriter((Get-AzureAppSettingXmlFile),[System.Text.Encoding]::UTF8)
			$xmlWriter.Formatting = [System.Xml.Formatting]::Indented
			$xmlWriter.Indentation = 4
			$xmlWriter.WriteStartDocument()
			$xmlWriter.WriteStartElement("appSettings")
			$xmlWriter.WriteEndElement()
			$xmlWriter.WriteEndDocument()
			$xmlWriter.Close()
		}
	}
	
	Function Write-AzureAppSettingValue
	{
		Param(
			$Key,
			$Value
		)
		
		try
		{
			#Load the xml doc and append the <add key="key" value="value" /> nodes to it
			$xmlDoc = New-Object System.Xml.XmlDocument
			$xmlDoc.Load((Get-AzureAppSettingXmlFile))
			
			#Lets make sure we dont overwrite anything in here
			$xpath = "/appSettings/add[@key='{0}']" -f $Key
			if($xmlDoc.SelectSingleNode($xpath) -ne $null)
			{
				"appSettings already contains a setting with key '{0}'" -f $Key | Trace
			}
			else
			{			
				$addElement = $xmlDoc.CreateElement("add")
				$addElement.SetAttribute("key",$Key)
				$addElement.SetAttribute("value",$Value)	
				$xmlDoc.SelectSingleNode("appSettings").AppendChild($addElement)			
				$xmlDoc.Save((Get-AzureAppSettingXmlFile))
			}
		}
		catch [System.Exception]
		{
			"Unable to write the Xml to the settings file. Message: {0}" -f $_.Exception.Message | Trace
		}
	}
	
	Function Get-AzureAppSettingValue
	{
		Param(
			$Key
		)
		
		#Load the xml doc and append the <add key="key" value="value" /> nodes to it
		$xmlDoc = New-Object System.Xml.XmlDocument
		$xmlDoc.Load((Get-AzureAppSettingXmlFile))
		
		#Lets make sure we dont overwrite anything in here
		$xpath = "/appSettings/add[@key='{0}']" -f $Key
		if($xmlDoc.SelectSingleNode($xpath) -eq $null)
		{
			"The key '{0}' was not found in the appSettings file" -f $Key | Trace
		}
		else
		{
			return ($xmlDoc.SelectSingleNode($xpath).Value)
		}
		
		return $null
	}
	
	Function Initialize-SharedUtils
	{
		$DebugPreference = "Continue"
		
		#Create a new or overwrite existing log file
		New-Item -Path $global:AzureProvisionLogFile -ItemType "File" -Force
		
		foreach($dll in $global:DependentGACdDLLs)
		{
			$result = [System.Reflection.Assembly]::LoadWithPartialName($dll)
			
			if($result -eq $null)
			{
				"Failed to load assembly '{0}'" -f $dll | Trace -Severity:Error
			}
		}
	}
	
	New-Alias -Name "Trace" -Value "Trace-Output" -Force

	# Do everything required on "Start Up"
	Initialize-SharedUtils
}