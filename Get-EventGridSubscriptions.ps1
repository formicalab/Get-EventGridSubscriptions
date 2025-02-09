#requires -version 7
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# verify that Az module is installed
if (-not (Get-Module -Name Az -ListAvailable)) {
    throw "Please install the Az module before running this script"
}

# verify that we have an active context
if (-not (Get-AzContext)) {
    throw "Please log in to Azure before running this script (use: Connect-AzAccount)"
}

# using Graph, obtain a list of all Event Grid system topics in all subscriptions
$kqlQuery = @'
resources
| where type =~ 'microsoft.eventgrid/systemTopics'
| extend source = properties.source
| extend topicType = toupper(properties.topicType)
| join kind=inner (    resourcecontainers    
| where type == 'microsoft.resources/subscriptions'    
| project subscriptionName=name, subscriptionId = subscriptionId) on $left.subscriptionId == $right.subscriptionId
| order by subscriptionName, resourceGroup
| project id, subscriptionName,resourceGroup,location, name, topicType, source
'@

Write-Host -NoNewline "Querying Azure Graph for Event Grid system topics: "

$batchSize = 100
$skipResult = 0
$kqlResult = @()

while ($true) {

    write-host -NoNewline "."

    if ($skipResult -gt 0) {
      $graphResult = Search-AzGraph -Query $kqlQuery -First $batchSize -SkipToken $graphResult.SkipToken
    }
    else {
      $graphResult = Search-AzGraph -Query $kqlQuery -First $batchSize
    }
  
    $kqlResult += $graphResult.data
  
    if ($graphResult.data.Count -lt $batchSize) {
      break;
    }
    $skipResult += $skipResult + $batchSize
  }

Write-Host
Write-Host "Found $($kqlResult.Count) Event Grid system topics in all subscriptions"

# sort the results by subscription name
$kqlResult = $kqlResult | Sort-Object subscriptionName

# get current subscription
$currentSubscription = (Get-AzContext).Subscription.Name

# iterate over all event grid system topics
foreach ($topic in $kqlResult) {

    $subscriptionName = $topic.subscriptionName
    $resourceGroup = $topic.resourceGroup
    $topicName = $topic.name
    $topicType = $topic.topicType
    $topicSource = $topic.source -replace '.*/', ''     # take just the last part of the source

    # switch to the subscription if needed
    if ($subscriptionName -ne $currentSubscription) {
        Set-AzContext -SubscriptionName $subscriptionName | Out-Null
        $currentSubscription = $subscriptionName
    }

    Write-Host -ForegroundColor Green "$subscriptionName, $resourceGroup, $topicName, $topicType, Source: $topicSource"

    # get all event grid system topic subscriptions for the current topic
    $subscriptions = Get-AzEventGridSystemTopicEventSubscription -SystemTopicName $topicName -ResourceGroupName $resourceGroup

    # iterate over all subscriptions
    foreach ($subscription in $subscriptions) {

        $endpointType = $subscription.Destination?.EndpointType ?? "N/A"
        if ($endpointType -eq "WebHook") {
            $endpointBaseUrl = $subscription.Destination.EndpointBaseUrl ?? "N/A"

            # destinations like *.datafactory.azure.com or *.storageav.azure.com are OK, we don't need to show them
            if ($endpointBaseUrl -match '\.datafactory\.azure\.com' -or $endpointBaseUrl -match '\.storageav\.azure\.com') {
                continue
            }

            write-host "$($subscription.Destination.EndpointType): $($subscription.Destination.EndpointBaseUrl)"
        }
    }
}

