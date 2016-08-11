﻿#region Variable Declarations
$SecPassword = ConvertTo-SecureString "$ENV:SAPassword" -AsPlainText -Force
$GLOCred = New-Object System.Management.Automation.PSCredential ($ENV:SAUsername, $SecPassword)
$Date = Get-Date -Uformat %Y-%m-%d
$Reportpath = "D:\Job Output\Automated Security Groups\SGCReport - $Date.xlsx"
#endregion

#region Import Modules
Import-Module ActiveDirectory
Import-Module PSExcel
#endregion

#region Gather SQl Data
$Session = New-PsSession -ComputerName 'am1mfdb001' -Credential $GLOCred

If (!$Session){
    Write-output "Unable to connect to the remote machine."
    exit;
}

$Query = Invoke-Command -ComputerName 'am1mfdb001' -Credential $GLOCred -ScriptBlock {

		$bJobStatus = 0
		
		#SQL Statement
		$cSQLStmt = @"
            SELECT [PersonID]
      ,[LoginID]
      ,[GivenName]
      ,[FamilyName]
      ,[EmailAddress]
      ,[PhysicalOfficeCode]
      ,[OfficeName]
      ,[RegionalSectionID]
      ,[Description]
      ,[PublicTitle]
  FROM [dbo].[vw_SecurityGroup]

"@
		
		$SqlCon = New-Object System.Data.SqlClient.SqlConnection
		$SqlCon.ConnectionString = "Server = am1mfdb001\wcdata; Database = ODS; Integrated Security = True; Trusted_Connection = True"
		$SqlCon.Open()
		
		#-- SQL command to get instance list
		$SqlCmd = New-Object System.Data.SqlClient.SqlCommand
		$SqlCmd.CommandTimeout = 10
		$SqlCmd.CommandText = $cSQLStmt
		$SqlCmd.Connection = $SqlCon
		$SqlAdapter = New-Object System.Data.SqlClient.SqlDataAdapter
		$SqlAdapter.SelectCommand = $SqlCmd
		
		$DataSet = New-Object System.Data.DataSet
		[Void]$SqlAdapter.Fill($DataSet)
		$Result = $DataSet.tables[0]
		$SqlCon.close()
		$Result
	}

Get-PSSession | Remove-PSSession
#endregion

#region Verify SQL Data
If(!$Query[0].OfficeName -or !$Query[0].emailaddress)
{
    Write-output "Returned Data appears to be in the wrong format."
    exit;
}
#endregion

#region Gather Unique offices and Security Groups

$UniqueOffices = $Query.officename | select -Unique | Sort-Object
Write-output "$($Uniqueoffices.count) unique office names detected."
$SecurityGroups = Get-ADGroup -Filter {Name -like "*(ASG)*"}
Write-output "$($SecurityGroups.count) Security Groups detected."
#endregion

#region Create Missing Security Groups

$newgroups = @()

Foreach ($Office in $UniqueOffices)
{
    If((($SecurityGroups | Where-Object {$_.samaccountname -eq $Office + '(ASG)'} | measure-object).count) -gt 0)
    {}

    Else
    {
        $NewGroups += $Office
        
        New-ADGroup -Name "$Office(ASG)" `
			-SamAccountName "$Office(ASG)" `
			-GroupCategory Security `
			-GroupScope Global `
			-DisplayName "$Office(ASG)" `
			-Path "OU=ODSBased Groups,OU=Security Groups,OU=FIRMWIDE,DC=WCNET,DC=whitecase,DC=com" `
			-Description "Members of this group are in the $Office Location" `
			-Credential $GLOCred
    }
}
#endregion

#region Verify New Creations

If($NewGroups)
{
    Write-output "Checking new creations."

    Foreach($Group in $NewGroups)
    {
        $Created = Get-ADgroup -Identity "$Group(ASG)"

        If($Created)
        {
            Write-output "$($Group + '(ASG)') Created Successfully"
        }

        Else
        {
            Write-output "Failed to create $($Group + '(ASG)')"
        }
    }
}

#endregion

#region Determine Valid AD Users
$ADUsers = @()
$nonadusers = @()

Foreach($User in $Query)
{
    Try
    {
        $UserCheck = Get-ADUser -Identity $User.LoginID -ErrorAction Stop -ErrorVariable UserError
    }

    Catch
    {
        $UserError = $_.exception.message
        Continue;
    }

    Finally
    {
        If($UserError)
        {
            $nonadusers += $User
        }

        Else
        {
            Add-Member -InputObject $UserCheck -MemberType NoteProperty -Name ODSOffice -Value $User.OfficeName -Force
            $adusers += $UserCheck
        }
    }
        
} 

#endregion

#region Add missing members to each group

$ADGroups = Get-ADGroup -Filter {Name -like "*(ASG)*"}

Foreach($Group in $ADGroups)
{
    $LocationUsers = $ADUsers | Where-Object {$Group.name -like "*$($_.ODSOffice)*"}

    Try
    {
        Add-ADGroupMember -Identity $Group -Members $LocationUsers -Credential $GLOCred -ErrorAction Stop
    }

    Catch
    {
        Continue;
    }
}

#endregion

#region Reporting Stuff

$Madegroups = get-adgroup -Filter {name -like "*(ASG)*"}

Foreach($Group in $MadeGroups)
{
    $Members = Get-ADGroupMember -Identity $Group | select -Property Name,SamAccountName
    $members | Export-XLSX -Path $Reportpath -worksheetname $Group.Name
}

#endregion

#To Delete the test groups
#get-adgroup -Filter {name -like "*(ASG)*"} | Remove-ADGroup -Confirm:$False -Credential $GLOCred