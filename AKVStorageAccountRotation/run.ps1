param($eventGridEvent, $TriggerMetadata)

$global:constants = [pscustomobject]@{
                       StorageAccountNameTagKey = 'StorageAccountName'
                       ResourceGroupTagKey = 'ResourceGroupName'
                       alternateCredentialId= "key1"
                       EventType="Microsoft.KeyVault.SecretNearExpiry"
                       SuccessMessage="Function {fnname} executed successfully"
                       ErrorMessage="Something went wrong while processing the request"
                       VersionConflictError="The current version has been updated manually or by another app , not proceeding further"
                       NotificationUrl ="https://prod-24.eastus2.logic.azure.com:443/workflows/76967f1fc2d34640ac458f946f126812/triggers/manual/paths/invoke?api-version=2016-10-01&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=9QdFQEFdxQ7HpL60iL_Jy5MzYhKw5h-EP7pD9q5zbwY"
  }

# Fetch secret value as text
function GetSecretValueAsText($keyVaultName,$secretName) 
{
  $secret = Get-AzKeyVaultSecret -VaultName $keyvaultName -Name $secretName
  $ssPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret.SecretValue)
  $secretValueText = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ssPtr)
  Write-Host $constants.SuccessMessage.Replace('{fnname}',$MyInvocation.MyCommand)
  return $secretValueText
}

# Notify users
function NotifyUsers($keyVaultName,$secretName,$oldExpiryDate,$oldVersion,$storageAccount,$resourceGroup,$success,$error) 
{
  If($success -eq $true ){  
    $subscription = ((Get-AzResourceGroup -Name $resourceGroup).ResourceId -split '/')[2]
    $newSecret = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $secretName
     }

  $body = @{
   "KeyVaultName" =$keyVaultName
   "SecretName" = $secretName
   "OldExpiryDate"=$oldExpiryDate
   "UpdatedExpiryDate"=$newSecret.Expires
   "OldVersion"= $oldVersion
   "NewVersion"=$newSecret.Version
   "StorageAccount"=$storageAccount
   "ResourceGroup"=$resourceGroup
   "Success"=$success
   "Subsciption"= $subscription
   "Error"= $error
      } | ConvertTo-Json

   $headers = @{
    "Content-Type" ="application/json"
      } 
  Invoke-RestMethod -Method Post -Headers $headers -Body $body -Uri $constants.NotificationUrl
}

function GetStorageAccountMetadata($secretValueText,$secret) 
{
  $storageAccount = @{}
  if($secret.Tags -ne $null -And [bool]($secret.Tags.PSobject.Properties.name -match $constants.StorageAccountNameTagKey) -And [bool]($secret.Tags.PSobject.Properties.name -match $constants.ResourceGroupTagKey ) ) {
  $storageAccount.Name = $secret.Tags[$constants.StorageAccountNameTagKey]
  $storageAccount.ResourceGroup = $secret.Tags[$constants.ResourceGroupTagKey]
  }
  elseif ($secretValueText -Match "AccountName") {
  $secretValueObject = $secretValueText -split ';'
  $storageAccountArray = $secretValueObject[1] -split '='
  $storageAccount.Name = $storageAccountArray[1]
  $storageAccounts= Get-AzStorageAccount
  Foreach ($sa in $StorageAccounts)
    {   
      if($sa.StorageAccountName -ceq $storageAccount.Name)
        {
          $storageAccount.ResourceGroup = $sa.ResourceGroupName
          $storageAccount.accountExists =$true
          break
        }
      }
    Write-Host $constants.SuccessMessage.Replace('{fnname}',$MyInvocation.MyCommand)
    return $storageAccount
        }
}

# Create storage connection string value
function SetConnectionString( $primaryKey,$secretValue)
{
  $secretValueObject = $secretValue -split ';'
  $secretValueObject[2] = "AccountKey=$primaryKey"
  $storageConnectionString = $secretValueObject -join ';'
  Write-Host $constants.SuccessMessage.Replace('{fnname}',$MyInvocation.MyCommand)
  return $storageConnectionString   
}

function RegenerateCredential($credentialId, $storageAccount ,$secretValueText)
{
  $operationResult = New-AzStorageAccountKey -ResourceGroupName $storageAccount.ResourceGroup -Name $storageAccount.Name -KeyName $credentialId
  $newCredentialValue = (Get-AzStorageAccountKey -ResourceGroupName $storageAccount.ResourceGroup -AccountName $storageAccount.Name|where KeyName -eq $credentialId).value 
  Write-Host $constants.SuccessMessage.Replace('{fnname}',$MyInvocation.MyCommand)
  return SetConnectionString $newCredentialValue $secretValueText
}

function CreateSecretTags($credentialId, $storageAccount)
{
  $validityPeriodDays=90
  $Tags = @{}
  $Tags.ValidityPeriodDays = $validityPeriodDays
  $Tags.CredentialId=$credentialId
  $Tags.StorageAccountName = $storageAccount.Name
  $Tags.ResourceGroupName = $storageAccount.ResourceGroup
  return $Tags
} 

function AddSecretToKeyVault($keyVaultName,$secretName,$secretvalue,$exprityDate,$tags)
{
  $nbf = (Get-Date).ToUniversalTime() 
  $contentType= 'text'
  Set-AzKeyVaultSecret -VaultName $keyVaultName -Name $secretName -SecretValue $secretvalue -Tag $tags -Expires $expiryDate -NotBefore $nbf -ContentType $contentType
  Write-Host $constants.SuccessMessage.Replace('{fnname}',$MyInvocation.MyCommand)
}

function RotateSecret($keyVaultName,$secret,$secretValueText,$secretVersion,$storageAccount )
{
  If($secret.Version -ne $secretVersion ) {return}      
    
  $newCredentialValue = (RegenerateCredential $constants.alternateCredentialId $storageAccount $secretValueText)
  $newSecretVersionTags = (CreateSecretTags $constants.alternateCredentialId $storageAccount)  
  $expiryDate = (Get-Date).AddDays([int]$newSecretVersionTags.ValidityPeriodDays).ToUniversalTime()
  $secretvalue = ConvertTo-SecureString "$newCredentialValue" -AsPlainText -Force
  AddSecretToKeyVault $keyVAultName $secretName $secretvalue $expiryDate $newSecretVersionTags
  Write-Host $constants.SuccessMessage.Replace('{fnname}',$MyInvocation.MyCommand)
}

function RotateStorageAccountKeys ($eventGridEvent,$secretValueText,$secret) 
{
  if($eventGridEvent.eventType -ceq $constants.EventType ) {
  RotateSecret $keyVaultName $secret $secretValueText $eventGridEvent.data.Version $storageAccount
  Write-Host $constants.SuccessMessage.Replace('{fnname}',$MyInvocation.MyCommand)
    }
}

$ErrorActionPreference = "Stop"
[String]$secretName = $eventGridEvent.subject
[String]$keyVaultName = $eventGridEvent.data.VaultName

try {
 $secretValueText = GetSecretValueAsText $keyVaultName $secretName
 $secret = (Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $secretName) 
 $storageAccount = GetStorageAccountMetadata $secretValueText $secret
 RotateStorageAccountKeys $eventGridEvent $secretValueText $secret
 NotifyUsers $keyVaultName $secretName $eventGridEvent.data.EXP $eventGridEvent.data.Version $storageAccount.Name $storageAccount.ResourceGroup $true $null
    }

catch {
  Write-Host $constants.ErrorMessage 
  Write-Host "Error stack : $_"
  NotifyUsers $keyVaultName $secretName $eventGridEvent.data.EXP $eventGridEvent.data.Version $null $null $false $_  
  throw $_
      }