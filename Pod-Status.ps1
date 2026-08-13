param(
    [Parameter(Mandatory=$true)]
    [string[]]$ServiceNames,

    [Parameter(Mandatory=$false)]
    [string]$PodPrefix = "",

    [Parameter(Mandatory=$false)]
    [string]$KubeConfig = "",

    [Parameter(Mandatory=$false)]
    [string]$Namespace = "dwp-base",

    [Parameter(Mandatory=$false)]
    [string]$OutputFile = "DWP-BASE.html",

    [Parameter(Mandatory=$false)]
    [int]$WaitBetweenDeletes = 10,

    [Parameter(Mandatory=$false)]
    [int]$ReadyTimeoutSeconds = 300,

    [Parameter(Mandatory=$false)]
    [switch]$Sequential,

    [Parameter(Mandatory=$false)]
    [ValidateSet('Cached','Fresh')]
    [string]$PullType = 'Cached'
)

if ($KubeConfig) { $env:KUBECONFIG = $KubeConfig }

# ---------------------------------------------
# Helpers
# ---------------------------------------------

function Set-DeploymentImagePullPolicy {
    param(
        [string]$PodName,
        [string]$Namespace,
        [string]$Policy   # 'Always' or 'IfNotPresent'
    )

    # Derive deployment name by stripping the last two hash segments (e.g. -7f8d9-xkzp2)
    $deploymentName = $PodName -replace '-[a-z0-9]+-[a-z0-9]+$', ''

    # Verify the deployment exists
    $check = kubectl get deployment $deploymentName -n $Namespace 2>&1 | Out-String
    if ($check -match 'not found|error') {
        Write-Host "      [PullPolicy] Deployment '$deploymentName' not found - skipping patch." -ForegroundColor DarkYellow
        return $false
    }

    # Build a JSON patch for all containers
    $deployJson = kubectl get deployment $deploymentName -n $Namespace -o json 2>$null | ConvertFrom-Json
    if (-not $deployJson) { return $false }

    $patches = @()
    for ($i = 0; $i -lt $deployJson.spec.template.spec.containers.Count; $i++) {
        $patches += [PSCustomObject]@{ op = 'replace'; path = "/spec/template/spec/containers/$i/imagePullPolicy"; value = $Policy }
    }
    $patchJson = $patches | ConvertTo-Json -Compress
    # Wrap in array if single patch
    if ($patches.Count -eq 1) { $patchJson = "[$patchJson]" }

    kubectl patch deployment $deploymentName -n $Namespace `
        --type=json `
        -p $patchJson 2>&1 | Out-Null

    Write-Host "      [PullPolicy] Set imagePullPolicy=$Policy on '$deploymentName'" -ForegroundColor DarkGray
    return $true
}

function Format-Seconds {
    param([double]$Seconds)
    if ($Seconds -le 0)   { return "0s" }
    if ($Seconds -lt 1)   { return "< 1s" }
    $h = [math]::Floor($Seconds / 3600)
    $m = [math]::Floor(($Seconds % 3600) / 60)
    $s = [math]::Round($Seconds % 60, 1)
    $r = ""
    if ($h -gt 0) { $r += "${h}h " }
    if ($m -gt 0) { $r += "${m}m " }
    if ($s -gt 0 -or $r -eq "") { $r += "${s}s" }
    return $r.Trim()
}

function Test-PodNameMatch {
    param(
        [string]$PodName,
        [string]$ServiceName,
        [string]$PodPrefix
    )

    if (-not $PodName) { return $false }

    $serviceMatch = $PodName -match [regex]::Escape($ServiceName)
    if (-not $serviceMatch) { return $false }

    if ([string]::IsNullOrWhiteSpace($PodPrefix)) {
        return $true
    }

    return ($PodName -match [regex]::Escape($PodPrefix))
}

function Get-PodLifecycleFromEvents {
    param(
        [string]$PodName,
        [string]$Namespace,
        [string]$KubeConfig
    )

    $eventsJson = kubectl get events -n $Namespace `
        --field-selector involvedObject.name=$PodName `
        -o json 2>$null | ConvertFrom-Json

    $lc = @{
        PodCreated            = $null
        Scheduled             = $null
        PullingStarted        = $null
        ImagePulled           = $null
        IstioPullingStarted   = $null
        IstioPulled           = $null
        ContainerCreated      = $null
        ContainerStarted      = $null
        PodReady              = $null
        ImageCached           = $false
        SchedulingTime        = 0
        ImagePullTime         = 0
        IstioImagePullTime    = 0
        ContainerCreationTime = 0
        ContainerStartTime    = 0
        ReadinessTime         = 0
        OtherEventsTime       = 0
        TotalTime             = 0
        RawEvents             = @()
    }

    if ($eventsJson.items) {
        $events = $eventsJson.items | Sort-Object { [DateTime]$_.firstTimestamp }

        foreach ($event in $events) {
            $ts      = [DateTime]$event.firstTimestamp
            $reason  = $event.reason
            $message = $event.message
            $count   = if ($event.count) { $event.count } else { 1 }
            $type    = if ($event.type)  { $event.type }  else { "Normal" }

            $lc.RawEvents += [PSCustomObject]@{
                Time    = $ts
                Reason  = $reason
                Message = $message
                Count   = $count
                Type    = $type
            }

            switch ($reason) {
                "Scheduled" {
                    if (-not $lc.Scheduled) { $lc.Scheduled = $ts }
                }
                "Pulling" {
                    if ($message -match "istio-proxy") {
                        if (-not $lc.IstioPullingStarted) { $lc.IstioPullingStarted = $ts }
                    } else {
                        if (-not $lc.PullingStarted) { $lc.PullingStarted = $ts }
                    }
                }
                "Pulled" {
                    if ($message -match "already present on machine") {
                        if ($message -match "istio") {
                            if (-not $lc.IstioPulled) { $lc.IstioPulled = $ts; $lc.IstioPullingStarted = $ts }
                        } else {
                            if (-not $lc.ImagePulled) { $lc.ImagePulled = $ts; $lc.PullingStarted = $ts; $lc.ImageCached = $true }
                        }
                    } else {
                        if ($message -match "istio") {
                            if (-not $lc.IstioPulled) { $lc.IstioPulled = $ts }
                        } else {
                            if (-not $lc.ImagePulled) { $lc.ImagePulled = $ts }
                        }
                    }
                }
                "Created" {
                    if (-not $lc.ContainerCreated -and $message -match "Created container" -and $message -notmatch "istio") {
                        $lc.ContainerCreated = $ts
                    }
                }
                "Started" {
                    if (-not $lc.ContainerStarted -and $message -match "Started container" -and $message -notmatch "istio") {
                        $lc.ContainerStarted = $ts
                    }
                }
            }
        }
    }

    # Pod creation and ready times from pod JSON
    $podJson = kubectl get pod $PodName -n $Namespace -o json 2>$null | ConvertFrom-Json
    if ($podJson.metadata.creationTimestamp) {
        $lc.PodCreated = [DateTime]::Parse($podJson.metadata.creationTimestamp)
    }
    if ($podJson.status.conditions) {
        $rc = $podJson.status.conditions | Where-Object { $_.type -eq "Ready" -and $_.status -eq "True" }
        if ($rc -and $rc.lastTransitionTime) {
            $lc.PodReady = [DateTime]::Parse($rc.lastTransitionTime)
        }
    }

    if ($lc.PodCreated -and $lc.Scheduled) {
        $lc.SchedulingTime = [math]::Max(0, ($lc.Scheduled - $lc.PodCreated).TotalSeconds)
    }
    if ($lc.PullingStarted -and $lc.ImagePulled) {
        $lc.ImagePullTime = [math]::Max(0, ($lc.ImagePulled - $lc.PullingStarted).TotalSeconds)
    }
    if ($lc.IstioPullingStarted -and $lc.IstioPulled) {
        $lc.IstioImagePullTime = [math]::Max(0, ($lc.IstioPulled - $lc.IstioPullingStarted).TotalSeconds)
    }
    if ($lc.ImagePulled -and $lc.ContainerCreated) {
        $lc.ContainerCreationTime = [math]::Max(0, ($lc.ContainerCreated - $lc.ImagePulled).TotalSeconds)
    }
    if ($lc.ContainerCreated -and $lc.ContainerStarted) {
        $lc.ContainerStartTime = [math]::Max(0, ($lc.ContainerStarted - $lc.ContainerCreated).TotalSeconds)
    }
    if ($lc.ContainerStarted -and $lc.PodReady) {
        $lc.ReadinessTime = [math]::Max(0, ($lc.PodReady - $lc.ContainerStarted).TotalSeconds)
    }

    # Total ready time = wall-clock PodCreated -> PodReady, taken straight from
    # the pod's own timestamps (not derived from events, which can be sparse/delayed).
    if ($lc.PodCreated -and $lc.PodReady) {
        $lc.TotalTime = [math]::Max(0, ($lc.PodReady - $lc.PodCreated).TotalSeconds)
    } else {
        $lc.TotalTime = [math]::Max(0,
            $lc.SchedulingTime + $lc.ImagePullTime + $lc.IstioImagePullTime +
            $lc.ContainerCreationTime + $lc.ContainerStartTime + $lc.ReadinessTime)
    }

    # "Other Events" = small gaps of wall-clock time that sit between the 6 named
    # stages above but aren't tied to one specific Kubernetes event (e.g. an event
    # that Kubernetes didn't emit separately, or one the API server had already
    # aged out). This time is already inside TotalTime above - it's just the
    # portion that doesn't fit neatly into one of the 6 named stages.
    $namedStages = $lc.SchedulingTime + $lc.ImagePullTime + $lc.IstioImagePullTime +
                   $lc.ContainerCreationTime + $lc.ContainerStartTime + $lc.ReadinessTime
    $lc.OtherEventsTime = [math]::Max(0, $lc.TotalTime - $namedStages)

    return $lc
}

function Find-RunningPodsForService {
    param(
        [string]$ServiceName,
        [string]$PodPrefix,
        [string]$Namespace,
        [string]$KubeConfig
    )

    $allPodsOutput = @(kubectl get pods -n $Namespace 2>&1 |
                       Where-Object { $_ -notmatch '^E\d{4}|^W\d{4}|^I\d{4}' })
    $pods = @()

    # Detect kubectl errors - no NAME header means genuine failure
    if (-not ($allPodsOutput | Where-Object { $_ -match '^NAME\s' })) {
        Write-Host "      [DEBUG] kubectl get pods returned no usable output. Raw response:" -ForegroundColor DarkYellow
        $allPodsOutput | Select-Object -First 5 | ForEach-Object { Write-Host "        $_" -ForegroundColor DarkYellow }
        return @()
    }

    $podNames = @($allPodsOutput |
                  Select-Object -Skip 1 |
                  Where-Object { $_.Trim() -ne '' } |
                  ForEach-Object { $_.ToString().Split()[0] })

    # 1) Match by service name only, or service + branch prefix when provided
    $pods = @($podNames | Where-Object {
        Test-PodNameMatch -PodName $_ -ServiceName $ServiceName -PodPrefix $PodPrefix
    })
    if ($pods.Count -gt 0) { return $pods }

    # 2) Deployment label fallback
    $deploys = kubectl get deployments -n $Namespace 2>$null |
               Select-String -Pattern $ServiceName -CaseSensitive:$false
    foreach ($d in $deploys) {
        $depName = ($d.Line.Split()[0])
        $labelPods = @(kubectl get pods -n $Namespace -l "app=$depName" 2>$null |
                       Select-Object -Skip 1 | ForEach-Object { ($_ -split '\s+')[0] })
        if ($labelPods.Count -gt 0) {
            $labelMatch = @($labelPods | Where-Object {
                Test-PodNameMatch -PodName $_ -ServiceName $ServiceName -PodPrefix $PodPrefix
            })
            if ($labelMatch.Count -gt 0) { return $labelMatch }
        }
    }

    # Debug: show all pod names so user can spot a naming mismatch
    $prefixInfo = if ([string]::IsNullOrWhiteSpace($PodPrefix)) { "" } else { " with prefix '$PodPrefix'" }
    Write-Host "      [DEBUG] No match for '$ServiceName'$prefixInfo. Running pods in namespace '$Namespace':" -ForegroundColor DarkYellow
    $allPodsOutput | Select-Object -Skip 1 | Select-Object -First 20 | ForEach-Object {
        Write-Host "        $($_.ToString().Split()[0])" -ForegroundColor DarkYellow
    }

    return @()
}

function Wait-ForNewPodReady {
    param(
        [string]$ServiceName,
        [string]$PodPrefix,
        [string[]]$BeforePods,
        [string]$Namespace,
        [string]$KubeConfig,
        [int]$TimeoutSeconds
    )

    $waited  = 0
    $newPod  = $null
    $lastHeartbeat = 0

    while ($waited -lt $TimeoutSeconds) {
        $allCurrent = @(kubectl get pods -n $Namespace 2>$null |
                        Select-Object -Skip 1 | ForEach-Object { ($_ -split '\s+')[0] })

        # Find pods matching service and optional branch prefix that weren't there before.
        $candidates = @($allCurrent | Where-Object {
            (Test-PodNameMatch -PodName $_ -ServiceName $ServiceName -PodPrefix $PodPrefix) -and ($BeforePods -notcontains $_)
        })

        if ($candidates.Count -gt 0) {
            $newPod = $candidates[0]
            Write-Host "      New pod detected: $newPod" -ForegroundColor Cyan
            break
        }

        if (($waited - $lastHeartbeat) -ge 15) {
            Write-Host "      ... still waiting for a new pod to appear (${waited}s elapsed)" -ForegroundColor DarkGray
            $lastHeartbeat = $waited
        }

        Start-Sleep -Seconds 3
        $waited += 3
    }

    if (-not $newPod) {
        Write-Host "      Timeout: no new pod appeared within ${TimeoutSeconds}s" -ForegroundColor Red
        return $null
    }

    # Wait for Ready - use JSON output instead of jsonpath.
    # jsonpath filters with embedded double-quotes (e.g. @.type=="Ready") are unreliable
    # on Windows PowerShell because of how the OS reparses quoted args passed to kubectl.exe,
    # so we parse the full pod JSON instead, which is exactly what the rest of this script does.
    $waited = 0
    $lastHeartbeat = 0
    while ($waited -lt $TimeoutSeconds) {
        $podJson = kubectl get pod $newPod -n $Namespace -o json 2>$null | ConvertFrom-Json

        if ($podJson) {
            $phase = $podJson.status.phase
            $readyCondition = $podJson.status.conditions | Where-Object { $_.type -eq "Ready" }
            $isReady = $readyCondition -and ($readyCondition.status -eq "True")

            if ($phase -eq "Running" -and $isReady) {
                Write-Host "      Pod ready: $newPod" -ForegroundColor Green
                return $newPod
            }

            if ($phase -eq "Failed" -or $phase -eq "CrashLoopBackOff") {
                Write-Host "      Pod entered failed state: $newPod ($phase)" -ForegroundColor Red
                return $null
            }

            # Surface container-level waiting reasons (e.g. ImagePullBackOff, CrashLoopBackOff)
            $badContainer = $podJson.status.containerStatuses |
                Where-Object { $_.state.waiting -and $_.state.waiting.reason -match 'BackOff|Error|Invalid' } |
                Select-Object -First 1
            if ($badContainer) {
                Write-Host "      Container issue on ${newPod}: $($badContainer.state.waiting.reason)" -ForegroundColor Red
                return $null
            }
        }

        if (($waited - $lastHeartbeat) -ge 15) {
            $statusMsg = if ($podJson) { "phase=$($podJson.status.phase)" } else { "no data yet" }
            Write-Host "      ... waiting for pod to become ready (${waited}s elapsed, $statusMsg)" -ForegroundColor DarkGray
            $lastHeartbeat = $waited
        }

        Start-Sleep -Seconds 5
        $waited += 5
    }

    Write-Host "      Timeout waiting for pod to be ready: $newPod" -ForegroundColor Red
    return $null
}

# ---------------------------------------------
# Banner
# ---------------------------------------------

Write-Host ""
Write-Host "=====================================================================================================" -ForegroundColor Cyan
Write-Host "                        POD BENCHMARK  -  DWP-BASE" -ForegroundColor Cyan
Write-Host "=====================================================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Namespace  : $Namespace" -ForegroundColor White
Write-Host "  Services   : $($ServiceNames.Count)" -ForegroundColor White
Write-Host "  Pod Prefix : $(if ([string]::IsNullOrWhiteSpace($PodPrefix)) { '(service-name only)' } else { $PodPrefix })" -ForegroundColor White
Write-Host "  Pull Type  : $PullType" -ForegroundColor White
Write-Host "  Mode       : $(if ($Sequential) { 'Sequential' } else { 'Parallel groups' })" -ForegroundColor White
Write-Host "  Timeout    : ${ReadyTimeoutSeconds}s per pod" -ForegroundColor White
Write-Host ""

# ---------------------------------------------
# Preflight connectivity check
# ---------------------------------------------

Write-Host "  Preflight: checking cluster connectivity..." -ForegroundColor Gray

$preflightOut = kubectl get pods -n $Namespace 2>&1
# Filter to only stdout lines (pod table rows), ignoring kubectl background warning logs
$podTableLines = @($preflightOut | Where-Object { $_ -notmatch '^E\d{4}|^W\d{4}|^I\d{4}' })
$hasHeader = $podTableLines | Where-Object { $_ -match '^NAME\s' }

if (-not $hasHeader) {
    Write-Host ""
    Write-Host "  [ERROR] kubectl could not reach the cluster or namespace '$Namespace' not found." -ForegroundColor Red
    Write-Host "  Raw output:" -ForegroundColor Red
    $podTableLines | Select-Object -First 5 | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    Write-Host "  Available namespaces:" -ForegroundColor Yellow
    kubectl get namespaces 2>$null | Where-Object { $_ -notmatch '^E\d{4}|^W\d{4}' } | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
    Write-Host ""
    exit 1
}

$podLines = @($podTableLines | Select-Object -Skip 1 | Where-Object { $_.Trim() -ne '' })

if ($podLines.Count -eq 0) {
    Write-Host ""
    Write-Host "  [ERROR] No pods found in namespace '$Namespace'. Check the -Namespace parameter." -ForegroundColor Red
    Write-Host ""
    exit 1
}

Write-Host "  Connected. Found $($podLines.Count) pod(s) in namespace '$Namespace'." -ForegroundColor Green
Write-Host "  Context : $(kubectl config current-context 2>$null)" -ForegroundColor Gray
Write-Host ""

# ---------------------------------------------
# Main loop
# ---------------------------------------------

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($serviceName in $ServiceNames) {
    Write-Host "-------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  Service: $serviceName" -ForegroundColor Yellow
    Write-Host ""

    # 1) Find existing running pods
    $existingPods = @(Find-RunningPodsForService -ServiceName $serviceName -PodPrefix $PodPrefix -Namespace $Namespace -KubeConfig $KubeConfig)

    if (-not $existingPods -or $existingPods.Count -eq 0) {
        Write-Host "    No pods found for service '$serviceName' - skipping." -ForegroundColor Red
        $results.Add([PSCustomObject]@{
            ServiceName           = $serviceName
            DeletedPod            = "N/A"
            NewPod                = "N/A"
            Status                = "No pods found"
            DeletedAt             = $null
            PodCreatedAt          = $null
            PodReadyAt            = $null
            SchedulingTime        = 0
            ImagePullTime         = 0
            IstioImagePullTime    = 0
            ContainerCreationTime = 0
            ContainerStartTime    = 0
            ReadinessTime         = 0
            OtherEventsTime       = 0
            TotalTimeToReady      = 0
            ImageCached           = $false
            RequestedPullType     = $PullType
            ImageName             = "N/A"
            CPURequest            = "N/A"
            MemoryRequest         = "N/A"
            NodeName              = "N/A"
            Events                = @()
        })
        continue
    }

    $podToDelete = $existingPods[0]
    Write-Host "    Found pod : $podToDelete" -ForegroundColor Gray

    # 2) Get pod metadata before delete (for the report)
    $beforeJson = kubectl get pod $podToDelete -n $Namespace -o json 2>$null | ConvertFrom-Json

    $imageName    = "N/A"
    $cpuRequest   = "N/A"
    $memRequest   = "N/A"
    $nodeName     = "N/A"

    if ($beforeJson) {
        $mainContainer = $beforeJson.spec.containers | Where-Object { $_.name -notmatch 'istio' } | Select-Object -First 1
        if ($mainContainer) {
            $imageName  = if ($mainContainer.image)                        { $mainContainer.image }                        else { "N/A" }
            $cpuRequest = if ($mainContainer.resources.requests.cpu)       { $mainContainer.resources.requests.cpu }       else { "N/A" }
            $memRequest = if ($mainContainer.resources.requests.memory)    { $mainContainer.resources.requests.memory }    else { "N/A" }
        }
        $nodeName = if ($beforeJson.spec.nodeName) { $beforeJson.spec.nodeName } else { "N/A" }
    }

    # 3) Patch imagePullPolicy on the deployment to control cached vs fresh pull
    $kubePullPolicy = if ($PullType -eq 'Fresh') { 'Always' } else { 'IfNotPresent' }
    Write-Host "    Setting imagePullPolicy to '$kubePullPolicy' ($PullType pull)..." -ForegroundColor Gray
    $patched = Set-DeploymentImagePullPolicy -PodName $podToDelete -Namespace $Namespace -Policy $kubePullPolicy
    if ($patched) { Start-Sleep -Seconds 3 }   # brief settle time after patch

    # 4) Snapshot all current pods for this service (to detect the brand-new one later)
    $allPodsSnapshot = kubectl get pods -n $Namespace 2>$null |
                       Select-Object -Skip 1 | ForEach-Object { ($_ -split '\s+')[0] }
    $beforePodsForService = @($allPodsSnapshot | Where-Object {
        Test-PodNameMatch -PodName $_ -ServiceName $serviceName -PodPrefix $PodPrefix
    })

    # 5) Delete the pod
    Write-Host "    Deleting pod..." -ForegroundColor Yellow
    $deleteTime = Get-Date
    kubectl delete pod $podToDelete -n $Namespace --wait=false 2>&1 | Out-Null
    Write-Host "    Deleted at: $($deleteTime.ToString('HH:mm:ss'))" -ForegroundColor Gray

    if ($WaitBetweenDeletes -gt 0 -and -not $Sequential) {
        Start-Sleep -Seconds $WaitBetweenDeletes
    }

    # 6) Wait for replacement pod to appear and become ready
    Write-Host "    Waiting for replacement pod..." -ForegroundColor Gray
    $newPodName = Wait-ForNewPodReady `
        -ServiceName $serviceName `
        -PodPrefix $PodPrefix `
        -BeforePods  $beforePodsForService `
        -Namespace   $Namespace `
        -KubeConfig  $KubeConfig `
        -TimeoutSeconds $ReadyTimeoutSeconds

    if (-not $newPodName) {
        Write-Host "    Could not find/wait for replacement pod - recording failure." -ForegroundColor Red
        $results.Add([PSCustomObject]@{
            ServiceName           = $serviceName
            DeletedPod            = $podToDelete
            NewPod                = "N/A"
            Status                = "Replacement pod not found / timed out"
            DeletedAt             = $deleteTime
            PodCreatedAt          = $null
            PodReadyAt            = $null
            SchedulingTime        = 0
            ImagePullTime         = 0
            IstioImagePullTime    = 0
            ContainerCreationTime = 0
            ContainerStartTime    = 0
            ReadinessTime         = 0
            OtherEventsTime       = 0
            TotalTimeToReady      = 0
            ImageCached           = $false
            RequestedPullType     = $PullType
            ImageName             = $imageName
            CPURequest            = $cpuRequest
            MemoryRequest         = $memRequest
            NodeName              = $nodeName
            Events                = @()
        })
        continue
    }

    # 7) Collect lifecycle timing
    Write-Host "    Collecting lifecycle metrics..." -ForegroundColor Gray
    $lc = Get-PodLifecycleFromEvents -PodName $newPodName -Namespace $Namespace -KubeConfig $KubeConfig

    Write-Host "      Scheduling      : $(Format-Seconds $lc.SchedulingTime)"        -ForegroundColor DarkCyan
    Write-Host "      Image Pull      : $(Format-Seconds $lc.ImagePullTime) $(if ($lc.ImageCached) { '(cached)' } else { '(not cached)' })" -ForegroundColor DarkCyan
    Write-Host "      Istio Pull      : $(Format-Seconds $lc.IstioImagePullTime)"    -ForegroundColor DarkCyan
    Write-Host "      Container Create: $(Format-Seconds $lc.ContainerCreationTime)" -ForegroundColor DarkCyan
    Write-Host "      Container Start : $(Format-Seconds $lc.ContainerStartTime)"    -ForegroundColor DarkCyan
    Write-Host "      Readiness       : $(Format-Seconds $lc.ReadinessTime)"         -ForegroundColor DarkCyan
    Write-Host "      Other Events    : $(Format-Seconds $lc.OtherEventsTime)"       -ForegroundColor DarkGray
    Write-Host "      -----------------------------" -ForegroundColor DarkGray
    Write-Host "      Total Ready Time: $(Format-Seconds $lc.TotalTime)"             -ForegroundColor Green

    $results.Add([PSCustomObject]@{
        ServiceName           = $serviceName
        DeletedPod            = $podToDelete
        NewPod                = $newPodName
        Status                = "Success"
        DeletedAt             = $deleteTime
        PodCreatedAt          = $lc.PodCreated
        PodReadyAt            = $lc.PodReady
        SchedulingTime        = $lc.SchedulingTime
        ImagePullTime         = $lc.ImagePullTime
        IstioImagePullTime    = $lc.IstioImagePullTime
        ContainerCreationTime = $lc.ContainerCreationTime
        ContainerStartTime    = $lc.ContainerStartTime
        ReadinessTime         = $lc.ReadinessTime
        OtherEventsTime       = $lc.OtherEventsTime
        TotalTimeToReady      = $lc.TotalTime
        ImageCached           = $lc.ImageCached
        RequestedPullType     = $PullType
        ImageName             = $imageName
        CPURequest            = $cpuRequest
        MemoryRequest         = $memRequest
        NodeName              = $nodeName
        Events                = $lc.RawEvents
    })

    if ($Sequential -and $WaitBetweenDeletes -gt 0) {
        Write-Host "    Waiting ${WaitBetweenDeletes}s before next service..." -ForegroundColor DarkGray
        Start-Sleep -Seconds $WaitBetweenDeletes
    }
}

# ---------------------------------------------
# Summary to console
# ---------------------------------------------

Write-Host ""
Write-Host "=====================================================================================================" -ForegroundColor Cyan
Write-Host "  SUMMARY" -ForegroundColor Cyan
Write-Host "=====================================================================================================" -ForegroundColor Cyan

$successResults = $results | Where-Object { $_.Status -eq "Success" }
$failedResults  = $results | Where-Object { $_.Status -ne "Success" }

foreach ($r in $results) {
    $statusColor = if ($r.Status -eq "Success") { "Green" } else { "Red" }
    $timeStr     = if ($r.TotalTimeToReady -gt 0) { "  $(Format-Seconds $r.TotalTimeToReady)" } else { "" }
    Write-Host ("  {0,-40} {1,-35}{2}" -f $r.ServiceName, $r.Status, $timeStr) -ForegroundColor $statusColor
}

if ($successResults) {
    $avgTime = ($successResults | Measure-Object -Property TotalTimeToReady -Average).Average
    $maxTime = ($successResults | Measure-Object -Property TotalTimeToReady -Maximum).Maximum
    $minTime = ($successResults | Measure-Object -Property TotalTimeToReady -Minimum).Minimum
    Write-Host ""
    Write-Host ("  Average time-to-ready : {0}" -f (Format-Seconds $avgTime)) -ForegroundColor White
    Write-Host ("  Fastest               : {0}" -f (Format-Seconds $minTime)) -ForegroundColor White
    Write-Host ("  Slowest               : {0}" -f (Format-Seconds $maxTime)) -ForegroundColor White
}

# ---------------------------------------------
# HTML Report
# ---------------------------------------------

$runTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$runId = Get-Date -Format "yyyyMMddHHmmss"

$successCount = $successResults.Count
$failedCount  = $failedResults.Count

$avgStr = if ($successResults) { Format-Seconds (($successResults | Measure-Object -Property TotalTimeToReady -Average).Average) } else { "N/A" }
$maxStr = if ($successResults) { Format-Seconds (($successResults | Measure-Object -Property TotalTimeToReady -Maximum).Maximum) } else { "N/A" }
$minStr = if ($successResults) { Format-Seconds (($successResults | Measure-Object -Property TotalTimeToReady -Minimum).Minimum) } else { "N/A" }

function HtmlEscape {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return "" }
    return [System.Web.HttpUtility]::HtmlEncode($Text)
}
Add-Type -AssemblyName System.Web

# -- Summary table rows ------------------------------------------
$tableRows = ""
foreach ($r in $results) {
    $statusClass = if ($r.Status -eq "Success") { "status-success" } else { "status-failed" }

    # Image Pull display is based on ACTUAL detected cache state for this run
    # (from the "already present on machine" Kubernetes event), not the requested
    # -PullType. Cached -> just the "Cached" badge. Not cached -> the measured
    # pull duration plus a "Not Cached" badge.
    $imgPullDisplay = if ($r.ImageCached) {
        '<span class="badge cached">Cached</span>'
    } elseif ($r.ImagePullTime -gt 0) {
        "$(Format-Seconds $r.ImagePullTime) " + '<span class="badge fresh">Not Cached</span>'
    } else {
        '<span class="badge fresh">Not Cached</span>'
    }

    $deletedAtStr    = if ($r.DeletedAt)     { $r.DeletedAt.ToString("HH:mm:ss")     } else { "-" }
    $podCreatedAtStr = if ($r.PodCreatedAt)  { $r.PodCreatedAt.ToString("HH:mm:ss")  } else { "-" }
    $podReadyAtStr   = if ($r.PodReadyAt)    { $r.PodReadyAt.ToString("HH:mm:ss")    } else { "-" }

    $totalClass = ""
    if ($r.TotalTimeToReady -gt 0) {
        if    ($r.TotalTimeToReady -lt 30)  { $totalClass = "time-fast"   }
        elseif($r.TotalTimeToReady -lt 90)  { $totalClass = "time-medium" }
        else                                 { $totalClass = "time-slow"   }
    }

    $tableRows += @"
        <tr>
            <td class="svc-name">$($r.ServiceName)</td>
            <td class="$statusClass">$($r.Status)</td>
            <td class="mono small">$($r.DeletedPod)</td>
            <td class="mono small">$($r.NewPod)</td>
            <td>$deletedAtStr</td>
            <td>$podCreatedAtStr</td>
            <td>$podReadyAtStr</td>
            <td>$(Format-Seconds $r.SchedulingTime)</td>
            <td>$imgPullDisplay</td>
            <td>$(Format-Seconds $r.IstioImagePullTime)</td>
            <td>$(Format-Seconds $r.ContainerCreationTime)</td>
            <td>$(Format-Seconds $r.ContainerStartTime)</td>
            <td>$(Format-Seconds $r.ReadinessTime)</td>
            <td class="$totalClass total-cell">$(Format-Seconds $r.TotalTimeToReady)</td>
            <td class="mono small">$($r.CPURequest)</td>
            <td class="mono small">$($r.MemoryRequest)</td>
            <td class="mono small">$($r.NodeName)</td>
        </tr>
"@
}

# -- Lifecycle stage table rows -----------------------------------
function Get-StageClass {
    param([double]$Seconds, [double]$Avg)
    if ($Seconds -eq 0)              { return "stage-zero" }
    if ($Avg -gt 0 -and $Seconds -gt $Avg * 1.25) { return "stage-slow" }
    if ($Avg -gt 0 -and $Seconds -lt $Avg * 0.75) { return "stage-fast" }
    return "stage-ok"
}

# Per-stage averages (success only)
$successOnly = @($results | Where-Object { $_.Status -eq "Success" })
$avgSched  = if ($successOnly.Count) { ($successOnly | Measure-Object SchedulingTime        -Average).Average } else { 0 }
$avgImgPull= if ($successOnly.Count) { ($successOnly | Measure-Object ImagePullTime         -Average).Average } else { 0 }
$avgIstio  = if ($successOnly.Count) { ($successOnly | Measure-Object IstioImagePullTime    -Average).Average } else { 0 }
$avgCCr    = if ($successOnly.Count) { ($successOnly | Measure-Object ContainerCreationTime -Average).Average } else { 0 }
$avgCSt    = if ($successOnly.Count) { ($successOnly | Measure-Object ContainerStartTime    -Average).Average } else { 0 }
$avgReady  = if ($successOnly.Count) { ($successOnly | Measure-Object ReadinessTime         -Average).Average } else { 0 }
$avgOther  = if ($successOnly.Count) { ($successOnly | Measure-Object OtherEventsTime       -Average).Average } else { 0 }
$avgTotal  = if ($successOnly.Count) { ($successOnly | Measure-Object TotalTimeToReady      -Average).Average } else { 0 }

$lifecycleRows = ""
$eventPanels   = ""
$rowIndex = 0
foreach ($r in $results) {
    $rowIndex++
    $rowId = "evt-$runId-$rowIndex"

    # Badge next to the service name reflects the ACTUAL detected cache state
    # for this run (not the requested -PullType).
    $cachedBadge = if ($r.ImageCached) { '<span class="badge cached">Cached</span>' } else { '<span class="badge fresh">Not Cached</span>' }
    $failedRow   = if ($r.Status -ne "Success") { ' class="failed-row"' } else { "" }

    $scSched  = Get-StageClass $r.SchedulingTime        $avgSched
    $scImg    = Get-StageClass $r.ImagePullTime         $avgImgPull
    $scIstio  = Get-StageClass $r.IstioImagePullTime    $avgIstio
    $scCCr    = Get-StageClass $r.ContainerCreationTime $avgCCr
    $scCSt    = Get-StageClass $r.ContainerStartTime    $avgCSt
    $scReady  = Get-StageClass $r.ReadinessTime         $avgReady
    $totalClass = ""
    if ($r.TotalTimeToReady -gt 0) {
        if    ($r.TotalTimeToReady -lt 30)  { $totalClass = "time-fast"   }
        elseif($r.TotalTimeToReady -lt 90)  { $totalClass = "time-medium" }
        else                                 { $totalClass = "time-slow"   }
    }

    # Bar widths (% of total, capped for display)
    $total = [math]::Max($r.TotalTimeToReady, 1)
    function PctBar { param([double]$v, [double]$t, [string]$cls)
        $w = [math]::Min([math]::Round($v / $t * 100), 100)
        if ($w -eq 0) { return '<span class="bar-zero">-</span>' }
        return "<div class=`"bar-wrap`"><div class=`"bar $cls`" style=`"width:${w}%`"></div><span class=`"bar-label`">$(Format-Seconds $v)</span></div>"
    }

    $hasEvents = ($r.Events -and $r.Events.Count -gt 0)
    $eventBtn = if ($hasEvents) {
        "<button class=`"evt-toggle`" onclick=`"toggleEvents('$rowId')`">&#128269; $($r.Events.Count) events</button>"
    } else {
        '<span class="evt-none">no events</span>'
    }

    $lifecycleRows += @"
        <tr$failedRow>
            <td class="svc-name">$($r.ServiceName) $cachedBadge<br/>$eventBtn</td>
            <td class="$scSched stage-cell">$(Format-Seconds $r.SchedulingTime)</td>
            <td class="$scImg   stage-cell">$(Format-Seconds $r.ImagePullTime)</td>
            <td class="$scIstio stage-cell">$(Format-Seconds $r.IstioImagePullTime)</td>
            <td class="$scCCr   stage-cell">$(Format-Seconds $r.ContainerCreationTime)</td>
            <td class="$scCSt   stage-cell">$(Format-Seconds $r.ContainerStartTime)</td>
            <td class="$scReady stage-cell">$(Format-Seconds $r.ReadinessTime)</td>
            <td class="stage-cell stage-other" title="Small bits of time between the 6 tracked steps that don't belong to any one step specifically. Already included in Total Ready Time.">$(Format-Seconds $r.OtherEventsTime)</td>
            <td class="$totalClass total-cell">$(Format-Seconds $r.TotalTimeToReady)</td>
            <td>$(PctBar $r.SchedulingTime        $total 'c-sched')</td>
            <td>$(PctBar $r.ImagePullTime         $total 'c-img')</td>
            <td>$(PctBar $r.IstioImagePullTime    $total 'c-istio')</td>
            <td>$(PctBar $r.ContainerCreationTime $total 'c-ccr')</td>
            <td>$(PctBar $r.ContainerStartTime    $total 'c-cst')</td>
            <td>$(PctBar $r.ReadinessTime         $total 'c-ready')</td>
            <td>$(PctBar $r.OtherEventsTime       $total 'c-other')</td>
        </tr>
"@

    if ($hasEvents) {
        $evtRows = ""
        foreach ($ev in $r.Events) {
            $typeClass = if ($ev.Type -eq "Warning") { "evt-warning" } else { "evt-normal" }
            $countBadge = if ($ev.Count -gt 1) { "<span class=`"evt-count`">&times;$($ev.Count)</span>" } else { "" }
            $safeMessage = HtmlEscape $ev.Message
            $safeReason  = HtmlEscape $ev.Reason
            $evtRows += @"
                <tr class="$typeClass">
                    <td class="mono small">$($ev.Time.ToString("HH:mm:ss.fff"))</td>
                    <td class="evt-reason">$safeReason $countBadge</td>
                    <td class="evt-message">$safeMessage</td>
                </tr>
"@
        }

        $eventPanels += @"
    <div class="event-panel" id="$rowId" style="display:none">
        <div class="event-panel-header">
            <span>&#128203; Raw Kubernetes events &mdash; <strong>$($r.ServiceName)</strong> ($($r.NewPod))</span>
            <button class="evt-close" onclick="toggleEvents('$rowId')">&times; Close</button>
        </div>
        <table class="event-table">
            <thead>
                <tr><th style="width:110px">Time</th><th style="width:160px">Reason</th><th>Message</th></tr>
            </thead>
            <tbody>
$evtRows
            </tbody>
        </table>
    </div>
"@
    }
}

# Average footer row
$lifecycleRows += @"
        <tr class="avg-row">
            <td class="svc-name">Avg Average</td>
            <td class="stage-cell">$(Format-Seconds $avgSched)</td>
            <td class="stage-cell">$(Format-Seconds $avgImgPull)</td>
            <td class="stage-cell">$(Format-Seconds $avgIstio)</td>
            <td class="stage-cell">$(Format-Seconds $avgCCr)</td>
            <td class="stage-cell">$(Format-Seconds $avgCSt)</td>
            <td class="stage-cell">$(Format-Seconds $avgReady)</td>
            <td class="stage-cell">$(Format-Seconds $avgOther)</td>
            <td class="total-cell">$(Format-Seconds $avgTotal)</td>
            <td colspan="7"></td>
        </tr>
"@

$htmlContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>[DWP-BASE] Pod Readiness Benchmark</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: 'Segoe UI', Arial, sans-serif; background: #f4f6fb; color: #1a1a2e; font-size: 13px; }

        /* -- Header ------------------------------------------- */
        header {
            background: linear-gradient(135deg, #4a6cf7 0%, #7c3aed 100%);
            padding: 36px 40px 32px;
            text-align: center;
            color: #fff;
        }
        header .icon { font-size: 36px; margin-bottom: 8px; }
        header h1   { font-size: 28px; font-weight: 700; margin-bottom: 8px; letter-spacing: -0.3px; }
        header .sub { font-size: 13px; opacity: 0.85; margin-bottom: 14px; }
        header .meta {
            display: inline-flex; flex-wrap: wrap; gap: 0;
            background: rgba(255,255,255,0.15); border-radius: 6px;
            padding: 6px 16px; font-size: 12px;
        }
        header .meta span { padding: 0 10px; border-right: 1px solid rgba(255,255,255,0.3); }
        header .meta span:last-child { border-right: none; }
        header .meta strong { font-weight: 600; }

        /* -- Notice banner --------------------------------------- */
        .notice {
            margin: 20px 40px 0; padding: 12px 18px; border-radius: 8px;
            background: #eff6ff; border: 1px solid #bfdbfe; color: #1e3a8a;
            font-size: 12px; line-height: 1.6;
        }
        .notice strong { color: #1d4ed8; }

        /* -- Summary cards ------------------------------------- */
        .summary-grid {
            display: flex; flex-wrap: wrap; gap: 20px;
            padding: 28px 40px;
            background: #fff;
            border-bottom: 1px solid #e2e8f0;
        }
        .card {
            background: #fff;
            border: 1px solid #e2e8f0;
            border-left: 4px solid #4a6cf7;
            border-radius: 8px;
            padding: 18px 24px;
            min-width: 150px;
            box-shadow: 0 1px 4px rgba(0,0,0,0.06);
        }
        .card.green  { border-left-color: #10b981; }
        .card.red    { border-left-color: #ef4444; }
        .card.yellow { border-left-color: #f59e0b; }
        .card .label { font-size: 10px; font-weight: 700; color: #6b7280; text-transform: uppercase; letter-spacing: 0.07em; margin-bottom: 8px; }
        .card .value { font-size: 26px; font-weight: 800; color: #4a6cf7; }
        .card.green  .value { color: #10b981; }
        .card.red    .value { color: #ef4444; }
        .card.yellow .value { color: #f59e0b; }

        /* -- Section titles ------------------------------------ */
        .section-wrap { padding: 28px 40px 0; }
        .section-title {
            font-size: 16px; font-weight: 700; color: #1a1a2e;
            margin-bottom: 4px; display: flex; align-items: center; gap: 8px;
        }
        .section-title::after {
            content: ''; flex: 1; height: 2px;
            background: linear-gradient(90deg, #4a6cf7 0%, transparent 100%);
            margin-left: 12px; border-radius: 2px;
        }
        .section-sub { font-size: 12px; color: #6b7280; margin-bottom: 16px; }

        /* -- Tables -------------------------------------------- */
        .table-wrap { padding: 0 40px 36px; overflow-x: auto; }
        table { width: 100%; border-collapse: collapse; font-size: 12px; background: #fff; border-radius: 8px; overflow: hidden; box-shadow: 0 1px 4px rgba(0,0,0,0.07); }
        thead th {
            background: #f8fafc; color: #4b5563;
            font-weight: 700; font-size: 11px; text-transform: uppercase; letter-spacing: 0.05em;
            text-align: left; padding: 11px 14px;
            border-bottom: 2px solid #e2e8f0;
            white-space: nowrap; position: sticky; top: 0;
        }
        tbody tr { border-bottom: 1px solid #f1f5f9; transition: background 0.1s; }
        tbody tr:hover { background: #f0f4ff; }
        tbody td { padding: 10px 14px; vertical-align: middle; }

        .svc-name  { font-weight: 700; color: #1e293b; white-space: nowrap; }
        .mono      { font-family: 'Consolas', monospace; }
        .small     { font-size: 11px; color: #94a3b8; }

        .status-success { color: #10b981; font-weight: 700; }
        .status-failed  { color: #ef4444; font-weight: 700; }

        .time-fast   { color: #10b981; font-weight: 700; }
        .time-medium { color: #f59e0b; font-weight: 700; }
        .time-slow   { color: #ef4444; font-weight: 700; }
        .total-cell  { font-size: 13px; font-weight: 800; white-space: nowrap; }

        .badge {
            display: inline-block; padding: 2px 8px; border-radius: 12px;
            font-size: 10px; font-weight: 700; margin-left: 6px; vertical-align: middle;
        }
        .badge.cached { background: #dbeafe; color: #1d4ed8; }
        .badge.fresh  { background: #fef3c7; color: #92400e; }

        /* -- Lifecycle stage table ----------------------------- */
        .lifecycle-table thead th { background: #f8fafc; }
        .lifecycle-table thead th.hdr-stage {
            background: linear-gradient(135deg, #4a6cf7 0%, #7c3aed 100%);
            color: #fff; text-align: center;
            border-right: 1px solid rgba(255,255,255,0.2);
        }
        .lifecycle-table thead th.hdr-bar {
            background: #f1f5f9; color: #94a3b8;
            text-align: center; font-size: 10px;
        }
        .lifecycle-table thead .sub-hdr th {
            background: #f8fafc; color: #6b7280;
            font-size: 10px; font-weight: 600; padding: 5px 14px 9px;
            border-bottom: 2px solid #e2e8f0;
        }
        .lifecycle-table thead .sub-hdr th.hdr-stage {
            background: rgba(74,108,247,0.08); color: #4a6cf7;
        }

        .stage-cell { text-align: right; white-space: nowrap; font-family: 'Consolas', monospace; font-size: 12px; }
        .stage-zero { color: #cbd5e1; }
        .stage-fast { color: #10b981; font-weight: 700; }
        .stage-ok   { color: #374151; }
        .stage-slow { color: #ef4444; font-weight: 700; }
        .stage-other { color: #94a3b8; font-style: italic; }

        .failed-row td { opacity: 0.4; }
        .avg-row td { background: #f0f4ff; font-weight: 700; color: #4a6cf7; border-top: 2px solid #e2e8f0; }

        /* bars */
        .bar-wrap  { display: flex; align-items: center; gap: 6px; min-width: 80px; }
        .bar       { height: 8px; border-radius: 3px; min-width: 2px; flex-shrink: 0; }
        .bar-label { font-size: 10px; color: #94a3b8; white-space: nowrap; }
        .bar-zero  { font-size: 10px; color: #cbd5e1; }
        .c-sched { background: #4a6cf7; }
        .c-img   { background: #f59e0b; }
        .c-istio { background: #8b5cf6; }
        .c-ccr   { background: #10b981; }
        .c-cst   { background: #059669; }
        .c-ready { background: #f87171; }
        .c-other { background: #cbd5e1; }

        /* legend */
        .legend { display: flex; flex-wrap: wrap; gap: 14px; padding: 0 40px 18px; }
        .legend-item { display: flex; align-items: center; gap: 6px; font-size: 11px; color: #6b7280; }
        .legend-dot  { width: 10px; height: 10px; border-radius: 2px; flex-shrink: 0; }

        /* -- Event toggle / panel ------------------------------ */
        .evt-toggle {
            margin-top: 4px; font-size: 10px; font-weight: 600;
            background: #eef2ff; color: #4a6cf7; border: 1px solid #c7d2fe;
            border-radius: 5px; padding: 3px 8px; cursor: pointer;
        }
        .evt-toggle:hover { background: #e0e7ff; }
        .evt-none { font-size: 10px; color: #cbd5e1; }

        .event-panel {
            margin: 0 40px 18px; background: #0f172a; border-radius: 10px;
            overflow: hidden; box-shadow: 0 4px 16px rgba(0,0,0,0.12);
        }
        .event-panel-header {
            display: flex; justify-content: space-between; align-items: center;
            padding: 12px 18px; background: #1e293b; color: #e2e8f0; font-size: 12px;
        }
        .evt-close {
            background: transparent; border: 1px solid #475569; color: #cbd5e1;
            border-radius: 5px; padding: 3px 10px; font-size: 11px; cursor: pointer;
        }
        .evt-close:hover { background: #334155; }
        .event-table { width: 100%; border-collapse: collapse; box-shadow: none; border-radius: 0; }
        .event-table thead th {
            background: #1e293b; color: #94a3b8; position: static;
            border-bottom: 1px solid #334155; font-size: 10px;
        }
        .event-table tbody tr { border-bottom: 1px solid #1e293b; }
        .event-table tbody tr:hover { background: #1e293b; }
        .event-table td { padding: 7px 14px; color: #cbd5e1; font-size: 11px; vertical-align: top; }
        .event-table .evt-reason { font-weight: 700; white-space: nowrap; color: #93c5fd; }
        .event-table .evt-message { color: #e2e8f0; }
        .event-table tr.evt-warning .evt-reason { color: #fca5a5; }
        .event-table tr.evt-warning .evt-message { color: #fecaca; }
        .evt-count {
            display: inline-block; margin-left: 4px; font-size: 9px;
            background: #334155; color: #cbd5e1; border-radius: 8px; padding: 1px 6px;
        }
    </style>
    <script>
        function toggleEvents(id) {
            var el = document.getElementById(id);
            if (!el) { return; }
            el.style.display = (el.style.display === 'none') ? 'block' : 'none';
            if (el.style.display === 'block') {
                el.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
            }
        }
    </script>
</head>
<body>

<header>
    <div class="icon">&#x26A1;</div>
    <h1>Pod Readiness Benchmark</h1>
    <div class="sub">Measuring pod startup performance after delete &amp; recreate</div>
    <div class="meta">
        <span><strong>Cluster:</strong> DWP-BASE</span>
        <span><strong>Namespace:</strong> $Namespace</span>
        <span><strong>Pull Type:</strong> $PullType</span>
        <span><strong>Run:</strong> $runTimestamp</span>
        <span><strong>Services:</strong> $($results.Count)</span>
    </div>
</header>

<div class="notice">
    <strong>Note on run-to-run variance:</strong> readiness times for the same service can legitimately differ between runs.
    Common causes include node-level image cache state, scheduler/node placement (a pod landing on a busy or newly-scaled
    node takes longer), API server / etcd load when many events fire close together, and cluster autoscaler activity.
</div>

<div class="notice">
    <strong>Cached vs Not Cached:</strong> this is determined from the pod's actual Kubernetes events for this run, not from
    the requested Pull Type. If the node already had the image, kubelet emits "already present on machine" and the row shows
    <strong>Cached</strong> with no pull time. If a real pull happened, the row shows the measured pull duration (e.g. 16s)
    plus a <strong>Not Cached</strong> label.
</div>

<div class="notice">
    <strong>What is "Other Events"?</strong> Small bits of time between the 6 tracked steps (Scheduling, Image Pull, Istio Pull,
    Container Create, Container Start, Readiness) that don't belong to any one step specifically. It's already counted in the
    Total Ready Time shown &mdash; not extra time, not missing time, just leftover time that doesn't fit neatly into one of the
    6 named steps.
</div>

<div class="summary-grid">
    <div class="card green">
        <div class="label">Succeeded</div>
        <div class="value">$successCount</div>
    </div>
    <div class="card red">
        <div class="label">Failed</div>
        <div class="value">$failedCount</div>
    </div>
    <div class="card">
        <div class="label">Avg Total Ready Time</div>
        <div class="value">$avgStr</div>
    </div>
    <div class="card yellow">
        <div class="label">Slowest</div>
        <div class="value">$maxStr</div>
    </div>
    <div class="card green">
        <div class="label">Fastest</div>
        <div class="value">$minStr</div>
    </div>
</div>

<!-- SECTION 1 - Lifecycle Stage Breakdown -->
<div class="section-wrap">
    <div class="section-title">&#x23F1; Pod Lifecycle Stage Breakdown</div>
    <div class="section-sub">Time spent in each stage from pod creation to ready. <span style="color:#ef4444;font-weight:700">Red</span> = &gt;25% above average &nbsp;|&nbsp; <span style="color:#10b981;font-weight:700">Green</span> = &gt;25% below average. Click &#128269; on a service to inspect its raw Kubernetes events.</div>
</div>

<div class="legend">
    <div class="legend-item"><div class="legend-dot c-sched"></div>Scheduling</div>
    <div class="legend-item"><div class="legend-dot c-img"></div>Image Pull</div>
    <div class="legend-item"><div class="legend-dot c-istio"></div>Istio Pull</div>
    <div class="legend-item"><div class="legend-dot c-ccr"></div>Container Create</div>
    <div class="legend-item"><div class="legend-dot c-cst"></div>Container Start</div>
    <div class="legend-item"><div class="legend-dot c-ready"></div>Readiness</div>
    <div class="legend-item"><div class="legend-dot c-other"></div>Other Events</div>
</div>

<div class="table-wrap">
    <table class="lifecycle-table">
        <thead>
            <tr>
                <th rowspan="2" style="vertical-align:bottom">Service</th>
                <th class="hdr-stage" colspan="8">Stage Durations</th>
                <th class="hdr-bar"   colspan="7">Proportion of Total Ready Time</th>
            </tr>
            <tr class="sub-hdr">
                <th class="hdr-stage" style="text-align:right">1. Scheduling</th>
                <th class="hdr-stage" style="text-align:right">2. Image Pull</th>
                <th class="hdr-stage" style="text-align:right">3. Istio Pull</th>
                <th class="hdr-stage" style="text-align:right">4. Ctr Create</th>
                <th class="hdr-stage" style="text-align:right">5. Ctr Start</th>
                <th class="hdr-stage" style="text-align:right">6. Readiness</th>
                <th class="hdr-stage" style="text-align:right">Other Events</th>
                <th class="hdr-stage" style="text-align:right;border-right:none">Total Ready Time</th>
                <th class="hdr-bar">Scheduling</th>
                <th class="hdr-bar">Image Pull</th>
                <th class="hdr-bar">Istio Pull</th>
                <th class="hdr-bar">Ctr Create</th>
                <th class="hdr-bar">Ctr Start</th>
                <th class="hdr-bar">Readiness</th>
                <th class="hdr-bar">Other Events</th>
            </tr>
        </thead>
        <tbody>
$lifecycleRows
        </tbody>
    </table>
</div>

$eventPanels

<!-- SECTION 2 - Full Results -->
<div class="section-wrap">
    <div class="section-title">&#x1F4CB; Full Results</div>
    <div class="section-sub">Complete per-service result including pod names, timestamps, and resource requests.</div>
</div>

<div class="table-wrap">
    <table>
        <thead>
            <tr>
                <th>Service</th>
                <th>Status</th>
                <th>Deleted Pod</th>
                <th>New Pod</th>
                <th>Deleted At</th>
                <th>Pod Created</th>
                <th>Pod Ready</th>
                <th>Scheduling</th>
                <th>Image Pull</th>
                <th>Istio Pull</th>
                <th>Container Create</th>
                <th>Container Start</th>
                <th>Readiness</th>
                <th>Total Ready Time</th>
                <th>CPU Req</th>
                <th>Mem Req</th>
                <th>Node</th>
            </tr>
        </thead>
        <tbody>
$tableRows
        </tbody>
    </table>
</div>

</body>
</html>
"@


$htmlContent | Set-Content -Path $OutputFile -Encoding UTF8
Write-Host ""
Write-Host "  Report saved: $OutputFile" -ForegroundColor Cyan
Write-Host ""