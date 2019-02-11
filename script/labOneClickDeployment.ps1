﻿#####################################################################
#----------- SQL DW Lab Resource Deployment Script ------------------
#----------- Version 2.0.0 -----------------------------------------
####################################################################



function SetGlobalParameters{

if($global:datePart -eq $null)
     {
         $global:datePart = Get-Date -format 'ddMMyy'
     }

     $global:sourceBlobAccountName = 'sqldwholdata'
     $global:sourceBlobAccountKey = '?sv=2018-03-28&ss=bfqt&srt=sco&sp=rwlcu&st=2019-01-03T00%3A01%3A51Z&se=2021-01-01T07%3A59%3A00Z&sig=EUGo%2FSQ4TVMy%2BT3AQeMBykWu50rQHEFjMJmnFPLbBek%3D&sr=b'
     $global:sourceContainerName = 'mattsqldwlab'

     $global:sqlDb = 'retaildb'
     $global:labContainer = 'labdata'
	 $global:sqlDwTempContainer = 'dwtemp'

     $global:subscriptionID = $null
}


function InitSubscription{
    #login
    $account = Login-AzAccount
	Write-Host You are signed-in with $account.Context.Account.Id
	
	If ($account.Context.Account.Id -eq $null)
	{
		Add-AzAccount -WarningAction SilentlyContinue | out-null
	}
    if($global:subscriptionID -eq $null -or $global:subscriptionID -eq ''){
        $subList = Get-AzSubscription

        if($subList.Length -lt 1){
            throw 'Your azure account does not have any subscriptions.  A subscription is required to run this tool'
        } 

        $subCount = 0
        foreach($sub in $subList){
            $subCount++
            $sub | Add-Member -type NoteProperty -name RowNumber -value $subCount
        }

        Write-Host ''
        Write-Host 'Your Azure Subscriptions: '
        $subList | Format-Table RowNumber,Id,Name -AutoSize
        $rowNum = Read-Host 'Enter the row number (1 -'$subCount') of a subscription'

        while( ([int]$rowNum -lt 1) -or ([int]$rowNum -gt [int]$subCount)){
            Write-Host 'Invalid subscription row number. Please enter a row number from the list above'
            $rowNum = Read-Host 'Enter subscription row number'                     
        }
        $global:subscriptionID = $subList[$rowNum-1].Id;
        $global:subscriptionDefaultAccount = $account.Context.Account.Id.Split('@')[0]
    }

    #switch to appropriate subscription
    try{
        Select-AzSubscription -SubscriptionId $global:subscriptionID       
        
    } catch {
        throw 'Subscription ID provided is invalid: ' + $global:subscriptionID 
    }
}


function IfSourceBlobExist{
    $blobExist = $true
	
	$SourceStorageContext = New-AzStorageContext –StorageAccountName $global:sourceBlobAccountName -SasToken $global:sourceBlobAccountKey -ErrorAction SilentlyContinue	
	
    if($SourceStorageContext -eq $null)
    {
        $blobExist = $false
    }
    else
    {
        $blobExist = $true
    }

    return $blobExist
}


function GetResourceGroupName{
    $ResourceGroup = $null
    $NumberOfAttempts = 0

    while($ResourceGroup -eq $null)
    {
        if($NumberOfAttempts -gt 3)
        {
            Write-Host 'Exceeded number of attempts.'
            exit
        }

        $ResourceGroupName = Read-Host "Enter Resource Group name created for the lab"

        try{
            $ResourceGroup = Get-AzResourceGroup -Name $ResourceGroupName
        }
        catch
        {
            $ResourceGroup = $null
        }

        $NumberOfAttempts = $NumberOfAttempts + 1
    }

    if($ResourceGroup -ne $null)
    {
        $global:ResourceGroup = $ResourceGroup
        $global:resourceGroupName = $ResourceGroup.ResourceGroupName

        InitVariables
    }
    else
    {
        $global:ResourceGroup = $null
    }    
}

function InitVariables{
    $global:useCaseName = $global:resourceGroupName.ToLower()
	$global:useCaseName = $global:useCaseName.Replace('.','')
    $global:useCaseName = $global:useCaseName.Replace('_','')
    $global:useCaseName = $global:useCaseName.Replace('-','')
    $global:useCaseName = $global:useCaseName.Replace('(','')
    $global:useCaseName = $global:useCaseName.Replace(')','')
    $global:dataName = $global:useCaseName + 'data' + $global:datePart
    if($global:dataName.Length -gt 22)
     {
        $global:dataName = $global:dataName.Substring(0,22)
     }

     $global:storageContainerName = $global:labContainer
     $global:storageAccountName = $global:useCaseName + "store" + $global:datePart
     if($global:storageAccountName.Length -gt 22)
     {
        $global:storageAccountName = $global:storageAccountName.Substring(0,22)
     }
     
     [string]$global:location = $global:ResourceGroup.Location  
     
     ProvisionBlobStorage   
}


function ProvisionBlobStorage{  
        
	Write-Host 'Creating Storage Account [' $global:storageAccountName '] ....' -NoNewline 
	
	$storage = Get-AzStorageAccount -ResourceGroupName $global:resourceGroupName -AccountName $global:storageAccountName -ErrorAction SilentlyContinue 
	   

	if($storage -eq $null)
	{
		try
		{
			$newStorage = New-AzStorageAccount -ResourceGroupName $global:resourceGroupName -AccountName $global:storageAccountName -Type "Standard_LRS" -Location $location 

			if($newStorage -ne $null)
			{
				$storage = $newStorage
				Write-Host 'created.'
			}        
		}
		catch
		{
			throw
		}
	}
	else
	{
		Write-Host 'exists.'
	}

	if($storage -ne $null)
	{             
		$StorageAccountKeys = Get-AzStorageAccountKey -ResourceGroupName  $global:resourceGroupName -Name $global:storageAccountName
		$global:storageAccountKey = $StorageAccountKeys | Select-Object -First 1 -ExpandProperty Value
		$global:storageContext = New-AzStorageContext -StorageAccountName $global:storageAccountName -StorageAccountKey $global:storageAccountKey
		CreateStorageContainer
	}
}


function CreateStorageContainer{

    RefreshStorageContext
    
    if($global:storageContext -ne $null)
    {
		# Create container that will hold the lab files:
        Write-Host 'Creating Storage Container [' $global:storageContainerName  '] ....' -NoNewline 

        $storageContainer = $null

         try
        {
            $storageContainer = Get-AzStorageContainer -Context $global:storageContext -Name $global:storageContainerName -ErrorAction SilentlyContinue
        }
        catch
        {
            $storageContainer = $null
        }

        if($storageContainer -eq $null)
        {
            New-AzStorageContainer -Context $global:storageContext -Name $global:storageContainerName -Permission Container

            try
            {
                $storageContainer = Get-AzStorageContainer -Context $global:storageContext -Name $global:storageContainerName -ErrorAction SilentlyContinue
            }
            catch
            {
                $storageContainer = $null
            }

            if($storageContainer -eq $null)
            {
                Write-Host 'not created.'
                CreateStorageContainer
            }
            else
            {
                Write-Host 'created.'
            }
        }
        else
        {
            Write-Host 'already exists.'
        }        

		# Create container for the exchange of data between Azure Databricks and Azure SQL Data Warehouse:
        Write-Host 'Creating Storage Container [' $global:sqlDwTempContainer  '] ....' -NoNewline 

        $storageContainer = $null

        try
        {
            $storageContainer = Get-AzStorageContainer -Context $global:storageContext -Name $global:sqlDwTempContainer -ErrorAction SilentlyContinue
        }
        catch
        {
            $storageContainer = $null
        }

        if($storageContainer -eq $null)
        {
			New-AzStorageContainer -Context $global:storageContext -Name $global:sqlDwTempContainer -Permission Container

            try
            {
                $storageContainer = Get-AzStorageContainer -Context $global:storageContext -Name $global:sqlDwTempContainer -ErrorAction SilentlyContinue
            }
            catch
            {
                $storageContainer = $null
            }

            if($storageContainer -eq $null)
            {
                Write-Host 'not created.'
                CreateStorageContainer
            }
            else
            {
                Write-Host 'created.'
            }
        }
        else
        {
            Write-Host 'already exists.'
        }        
    }

    UploadBlobData
    UploadBlobData2
    GetSQLServer
	
	Write-Host '**COPY THESE VALUES**' -ForegroundColor "Yellow"
	Write-Host "New storage account name: $global:storageAccountName" -ForegroundColor "Cyan"
	Write-Host "New storage account key: $global:storageAccountKey" -ForegroundColor "Cyan"
}


function RefreshStorageContext{
    if($global:storageContext -eq $null)
    {
        $StorageAccountKeys = Get-AzStorageAccountKey -ResourceGroupName  $global:resourceGroupName -Name $global:storageAccountName
        $global:storageAccountKey = $StorageAccountKeys | Select-Object -First 1 -ExpandProperty Value
        $global:storageContext = New-AzStorageContext -StorageAccountName $global:storageAccountName -StorageAccountKey $global:storageAccountKey      
    }
}

function UploadBlobData{
    $sourceBlobPath = '/'
    $destBlobPath = '/retaildata/rawdata/'
    $sourceContainerName = $global:sourceContainerName
    Write-Host "Writing data to Storage Container. Please wait for some time...."

    try
    {
        $SourceStorageContext = New-AzStorageContext –StorageAccountName $global:sourceBlobAccountName -SasToken $global:sourceBlobAccountKey
        $Blobs = Get-AzStorageBlob -Context $SourceStorageContext -Container $global:sourceContainerName  -Prefix 'retaildata/rawdata'
        $BlobCpyAry = @() #Create array of objects

        foreach ($Blob in $Blobs)
        {
           # Write-Output "Moving $Blob.Name"
            $BlobCopy = Start-CopyAzureStorageBlob -Context $SourceStorageContext -SrcContainer $sourceContainerName -SrcBlob $Blob.Name `
                -DestContext $global:storageContext -DestContainer $global:storageContainerName -DestBlob $Blob.Name -Force
            $BlobCpyAry += $BlobCopy
        }

        #Check Status
        foreach ($BlobCopy in $BlobCpyAry)
        {
            #Could ignore all rest and just run $BlobCopy | Get-AzStorageBlobCopyState but I prefer output with % copied
            $CopyState = $BlobCopy | Get-AzStorageBlobCopyState
            $Message = $CopyState.Source.AbsolutePath + " " + $CopyState.Status #+ " {0:N2}%" -f (($CopyState.BytesCopied/$CopyState.TotalBytes)*100) 
           # Write-Output $Message
        }

        
    }
    catch
    {
        Write-Host "Could not write data to Storage Account."
        
        throw
    }

}


function UploadBlobData2{
   
    $sourceContainerName = 'mattsqldwlab'
    Write-Host "Writing data to Storage Container. Please wait for some time...."

    try
    {
        $SourceStorageContext = New-AzStorageContext –StorageAccountName $global:sourceBlobAccountName -SasToken $global:sourceBlobAccountKey
        $Blobs = Get-AzStorageBlob -Context $SourceStorageContext -Container $global:sourceContainerName -Prefix 'Transaction'
        $BlobCpyAry = @() #Create array of objects

        foreach ($Blob in $Blobs)
        {
           # Write-Output "Moving $Blob.Name"
            $BlobCopy = Start-CopyAzureStorageBlob -Context $SourceStorageContext -SrcContainer $global:sourceContainerName -SrcBlob $Blob.Name `
                -DestContext $global:storageContext -DestContainer $global:labContainer -DestBlob $Blob.Name -Force
            $BlobCpyAry += $BlobCopy
        }

        #Check Status
        foreach ($BlobCopy in $BlobCpyAry)
        {
            #Could ignore all rest and just run $BlobCopy | Get-AzStorageBlobCopyState but I prefer output with % copied
            $CopyState = $BlobCopy | Get-AzStorageBlobCopyState
            $Message = $CopyState.Source.AbsolutePath + " " + $CopyState.Status #+ " {0:N2}%" -f (($CopyState.BytesCopied/$CopyState.TotalBytes)*100) 
           # Write-Output $Message
        }

        
    }
    catch
    {
        Write-Host "Could not write data to Storage Account."
        
        throw
    }

}

function GetSQLServer{
    
    $sqlserver = $null
    $numberOfAttempts = 0
    
    while ($sqlserver -eq $null)
    {
        if($numberOfAttempts -gt 3)
        {
            Write-Host 'Exceeded number of attempts.'
            exit
        }
       $sqlserverName = Read-Host 'Enter SQL server name created for this class'

       try{
            $sqlserver = Get-AzSqlServer -ServerName $sqlserverName -ResourceGroupName $global:ResourceGroupName -ErrorAction SilentlyContinue
       }
       catch{
                $sqlserver = $null
       }

        $numberOfAttempts =  $numberOfAttempts  + 1
    }

    if($sqlserver -ne $null)
    {
        $sqlPassword = Read-Host 'Enter password for server admin [' $sqlserver.SqlAdministratorLogin '].'
        $global:sqlServer = $sqlserver.ServerName
        $global:sqladmin = $sqlserver.SqlAdministratorLogin
        $global:sqlpassword = $sqlPassword

        ImportSQLDB

    }

}

function ImportSQLDB{
    
    try
    {
        Write-Host "Importing SQL DB...." -NoNewline

        try
        {
            $sqlDB = Get-AzSqlDatabase -ResourceGroupName $global:resourceGroupName -ServerName $global:sqlServer -DatabaseName $global:sqlDb -ErrorAction SilentlyContinue
        }
        catch
        {
            $sqlDB = $null
        }

        if( $sqlDB -eq $null)
        {
			# Import bacpac to database
			$importRequest = New-AzSqlDatabaseImport -ResourceGroupName $global:resourceGroupName `
				-ServerName $global:sqlServer `
				-DatabaseName $global:sqlDb `
				-DatabaseMaxSizeBytes "262144000" `
				-StorageKeyType "SharedAccessKey" `
				-StorageKey $global:sourceBlobAccountKey `
				-StorageUri "https://$global:sourceBlobAccountName.blob.core.windows.net/$global:sourceContainerName/retaildb.bacpac" `
				-Edition "Standard" `
				-ServiceObjectiveName "S0" `
				-AdministratorLogin "$global:sqladmin" `
				-AdministratorLoginPassword $(ConvertTo-SecureString -String $global:sqlpassword -AsPlainText -Force)
			Write-Host $importRequest.ErrorMessage
            $importStatus = Get-AzSqlDatabaseImportExportStatus -OperationStatusLink $importRequest.OperationStatusLink

            while ($importStatus.Status -eq "InProgress")
            {
                $importStatus = Get-AzSqlDatabaseImportExportStatus -OperationStatusLink $importRequest.OperationStatusLink
                [Console]::Write(".")
                Start-Sleep -s 10
            }            
            Write-Host $importStatus.Status

            try
            {
                $sqlDB = Get-AzSqlDatabase -ResourceGroupName $global:resourceGroupName -ServerName $global:sqlServer -DatabaseName $global:sqlDb -ErrorAction SilentlyContinue
            }
            catch
            {
                $sqlDB = $null
            }

            if( $sqlDB -eq $null)
            {
                Write-Host "SqlDB not imported properly."
                ImportSQLDB
            }
        }
        else
        {
            Write-Host "already exists."
        }
    }
    catch
    {
        Write-Host "error."
         
         throw 
    }

}

function InitExecution{
    SetGlobalParameters
    if(-Not (IfSourceBlobExist) )
    {
        $global:sourceBlobAccountName = Read-Host "Enter source Azure Storage Account name"
        $global:sourceBlobAccountKey = Read-Host "Enter source SAS Token"
    }

    if(IfSourceBlobExist)
    {
        
        InitSubscription

        if($global:subscriptionID -ne $null)
        {
            GetResourceGroupName
        }

    }

}

InitExecution