$functionAppName= "armemplatepoc-StorageAccount-rotation-fnapp"
$subscriptionName= "Microsoft Internal Consumption"
$roleDefinitionName ="Storage Account Contributor"
$objectid = (Get-AzADServicePrincipal -DisplayName $functionAppName).id
$subscriptionId = (Get-AzSubscription -SubscriptionName $subscriptionName).Id
New-AzRoleAssignment -ObjectId $objectid -RoleDefinitionName $roleDefinitionName -Scope /subscriptions/$subscriptionId