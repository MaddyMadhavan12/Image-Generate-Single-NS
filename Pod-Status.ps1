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
    [string]$PullType = 'Cached',

    # NEW: Detailed Image Pull Analysis
    # Opt-in switch. When OFF (default) the script behaves exactly as before -
    # same performance, same output - nothing below is executed.
    # When ON, the script additionally:
    #   1) MODIFIED: Uses the Kubernetes NODE's own containerd runtime as the
    #      PRIMARY and authoritative source for image manifest + layer data.
    #      Flow: Pod -> Node -> Image/Digest -> `kubectl debug node/<name>`
    #      (chroot into the host) -> `ctr -n k8s.io images ls` to resolve the
    #      image's manifest digest -> `ctr -n k8s.io content get <digest>` to
    #      read the actual manifest/layer list straight off that node ->
    #      `ctr -n k8s.io content ls` to read that node's containerd content
    #      store, taken BOTH before the old pod is deleted and again after the
    #      replacement pod is Ready, so cached-vs-freshly-downloaded layers can
    #      be measured by diffing the two snapshots (not guessed). This never
    #      depends on registry credentials and works even when anonymous
    #      manifest access against the private registry fails.
    #   2) The image registry (HTTPS v2 API call from this workstation) is used
    #      ONLY as a SECONDARY fallback for manifest metadata (digest/total
    #      layer count) - and only when the node-side containerd lookup itself
    #      could not resolve the image. A registry auth failure never fails the
    #      analysis; it is simply marked Unavailable and the script continues
    #      using node/event data.
    #      Per-node/per-image results are cached in-memory for the run (see
    #      $script:NodeManifestCache / $script:ImageManifestCache) since this is
    #      an opt-in, elevated-RBAC operation (`kubectl debug node`) and must
    #      stay safe to run across large (300+ node) fleets.
    #      If node access fails for any reason (RBAC, timeout, missing ctr
    #      binary, image GC'd, etc.), the script degrades gracefully and marks
    #      that data as "Unavailable" with a plain-English reason - it never
    #      fabricates numbers.
    [Parameter(Mandatory=$false)]
    [switch]$DetailedImagePullAnalysis,

    # NEW: Detailed Image Pull Analysis
    # How long to wait on node-debug / registry-manifest calls before giving up
    # and marking that image's detailed data as Unavailable, so one slow/unreachable
    # node or registry can't stall the whole run.
    [Parameter(Mandatory=$false)]
    [int]$RegistryTimeoutSeconds = 10,

    # MODIFIED: OPTIONAL OVERRIDE ONLY - the namespace `kubectl debug node/<n>`
    # creates its ephemeral debug pod in. Leave this blank (the default) and
    # the script will auto-detect the debug pod's actual namespace itself
    # (it is NOT necessarily "default", and it is NOT the app namespace passed
    # via -Namespace - those are two different things: e.g. -Namespace could
    # be "dwp-base" while the debug pod lands in "default", "kube-system", or
    # wherever your kubeconfig context/cluster policy places it). Only set
    # this if you already know exactly which namespace `kubectl debug` uses
    # in your cluster and want to skip the auto-detect lookup.
    [Parameter(Mandatory=$false)]
    [string]$DebugPodNamespace = ""
)

if ($KubeConfig) { $env:KUBECONFIG = $KubeConfig }
$ClusterLabel = $Namespace.ToUpper()

# NEW: Detailed Image Pull Analysis
# In-memory caches so a given image manifest (or node layer check) is only ever
# queried ONCE per run, no matter how many services/pods reference it. This is
# what keeps this feature safe to run against ~335 nodes: the registry fallback
# is cached per-IMAGE (independent of node count), and the node-side containerd
# lookups are cached per NODE+IMAGE combination - never once-per-pod-per-node
# in a loop.
$script:ImageManifestCache = @{}
# MODIFIED: replaces the old $script:NodeLayerCacheCache. Caches the node-side
# manifest resolution (digest + layer list read out of that node's containerd)
# per Node+Image. Content-store SNAPSHOTS (before/after) are intentionally NOT
# cached here - they must be fresh every time or the before/after diff used to
# tell "already cached" apart from "downloaded this run" would be meaningless.
$script:NodeManifestCache = @{}

# NEW (digest-correlation fix): guard so the one-time deep-dive diagnostic
# dump (manifest digests vs raw content-store output vs `ctr images check`)
# only fires ONCE per run, for the first service that reaches node-side layer
# analysis - never for every service, and never controlled by the main loop
# or the param block. Scoped entirely inside the layer-analysis functions.
$script:DigestCorrelationDiagnosticsShown = $false

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

function Get-DurationFromPulledMessage {
    param([string]$Message)
    # kubelet's "Pulled" event message embeds the real pull duration, e.g.:
    #   Successfully pulled image "..." in 352ms (352ms including waiting). Image size: ...
    #   Successfully pulled image "..." in 5.943326931s
    # This has full sub-second precision, unlike the event's firstTimestamp
    # (which is only accurate to the whole second). Prefer this when present.
    if ($Message -match 'in\s+([\d.]+)(ms|s)\b') {
        $value = [double]$Matches[1]
        $unit  = $Matches[2]
        if ($unit -eq 'ms') { return $value / 1000.0 }
        return $value
    }
    return $null
}

# =========================================================================
# NEW: Detailed Image Pull Analysis
# =========================================================================
#
# WHERE EACH PIECE OF DATA ACTUALLY COMES FROM (see also the write-up sent
# alongside this script):
#
#   Kubernetes Events (kubectl get events)
#     -> Pulling / Pulled timestamps and, when present, the sub-second
#        duration kubelet embeds in the "Pulled" message ("...in 5.94s").
#        This is the ONLY pull-timing data Kubernetes Events expose. There is
#        no per-layer or per-stage timing in an Event, ever. This remains the
#        ONE source for Total Image Pull Time (unchanged).
#
#   MODIFIED: Node containerd runtime (PRIMARY source, -DetailedImagePullAnalysis)
#     -> Flow: Pod -> Node -> Image/Digest -> `kubectl debug node/<name>`
#        (chroot into host) -> `ctr -n k8s.io images ls` (resolve the image's
#        manifest digest as actually pulled on THAT node) -> `ctr -n k8s.io
#        content get <digest>` (the real manifest/layer list, read from the
#        node, not the registry) -> `ctr -n k8s.io content ls` (that node's
#        containerd content store), captured BEFORE the old pod is deleted and
#        again AFTER the replacement pod is Ready. Diffing those two snapshots
#        gives a measured Cached vs Downloaded split - not an estimate. This
#        needs per-node access (`kubectl debug node/<name>`), which requires
#        elevated RBAC and is not guaranteed to succeed. Best-effort only;
#        failures degrade to "Unavailable" and are never faked. This is now
#        the authoritative source for Total/Cached/Missing/Downloaded Layers
#        and Cache Status whenever it succeeds.
#
#   MODIFIED: Image registry (SECONDARY / fallback only)
#     -> HTTPS calls to the registry's own v2 API, from wherever this script
#        runs (NOT from the node). Used ONLY when the node-side containerd
#        lookup above could not resolve the image (e.g. -DetailedImagePullAnalysis
#        was not requested, or the node lookup itself failed). Provides, at
#        best, image digest + total layer count - never a cached/downloaded
#        split, since that requires the node's own state. The registry being
#        private and rejecting anonymous manifest access is an EXPECTED,
#        handled outcome here, not a script failure: it is marked Unavailable
#        with a plain-English reason and the run continues normally.
#
#   NOT obtainable at all from this workstation or from containerd, for any
#   cluster, without custom node-side tracing tooling we don't have:
#     -> Sub-second breakdown of the pull itself into
#        Registry/DNS/Connection, Authentication, Manifest Resolution,
#        Manifest Fetch, Layer Cache Check, Layer Download, Layer
#        Verification, Layer Unpack, Finalization. Containerd does not
#        expose these as Kubernetes Events, through the Kubernetes API, or via
#        `ctr`. They only exist (if at all) in node-local containerd
#        traces/metrics/logs, which this script does not have access to. This
#        script does NOT fabricate a split of the total pull time across these
#        stages - see Get-ImagePullAnalysis below, which explicitly reports
#        this as "Detailed Pull Stage Timing: Unavailable" with the reason.
# =========================================================================

function Get-ImageManifestInfo {
    <#
        MODIFIED: This is now a SECONDARY / fallback source only.

        Queries the image's OWN registry (Docker Hub / ECR / GCR / ACR / Harbor,
        etc. - anything speaking the standard Docker/OCI Registry v2 protocol)
        directly over HTTPS to obtain:
          - Image digest
          - Total layer count
          - Individual layer digests

        The PRIMARY source for this data is now the Kubernetes node's own
        containerd runtime (see Get-NodeImageManifestInfo below), which does
        not need registry credentials at all. This function is only called
        when the node-side lookup could not resolve the image (node debug
        access unavailable, or -DetailedImagePullAnalysis not requested), and
        even then it only ever supplies manifest metadata (digest/total layer
        count) - never a cached/downloaded layer split, since that requires
        the node's own state.

        This is a per-IMAGE lookup (not per-node, not per-pod), so it scales
        fine to hundreds of nodes: identical images across many pods/nodes are
        resolved once and cached in $script:ImageManifestCache for the rest of
        the run.

        Returns a PSCustomObject with .Available = $true/$false. When $false
        (e.g. a private registry rejecting anonymous manifest access, network
        egress blocked from the workstation, or a manifest list without a
        resolvable linux/amd64 entry), .Reason explains why - this is treated
        as an EXPECTED, handled outcome (never a fatal error) and is NEVER
        fabricated.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Image,
        [int]$TimeoutSeconds = 10
    )

    if ($script:ImageManifestCache.ContainsKey($Image)) {
        return $script:ImageManifestCache[$Image]
    }

    $result = [PSCustomObject]@{
        Image        = $Image
        Registry     = $null
        Repository   = $null
        Reference    = $null
        Digest       = $null
        TotalLayers  = 0
        LayerDigests = @()
        Available    = $false
        Source       = "Measured (Registry Manifest, Secondary)"   # MODIFIED: now explicitly secondary
        Reason       = ""
    }

    try {
        # --- Parse "[registry/]repo[:tag][@digest]" -------------------------
        $imgRef  = $Image
        $registry = "registry-1.docker.io"     # Docker Hub default
        $repoTag  = $imgRef

        $firstSlashSeg = $imgRef.Split('/')[0]
        if ($imgRef -match '/' -and ($firstSlashSeg -match '\.' -or $firstSlashSeg -match ':' -or $firstSlashSeg -eq 'localhost')) {
            $registry = $firstSlashSeg
            $repoTag  = $imgRef.Substring($firstSlashSeg.Length + 1)
        } else {
            if ($repoTag -notmatch '/') { $repoTag = "library/$repoTag" }   # Docker Hub official image shorthand
        }

        $reference = "latest"
        if ($repoTag -match '^(.+)@(sha256:[a-f0-9]+)$') {
            $repoTag = $Matches[1]; $reference = $Matches[2]
        } elseif ($repoTag -match '^(.+):([^:/]+)$') {
            $repoTag = $Matches[1]; $reference = $Matches[2]
        }

        $result.Registry   = $registry
        $result.Repository = $repoTag
        $result.Reference  = $reference

        $acceptHeader = "application/vnd.docker.distribution.manifest.v2+json, " +
                        "application/vnd.docker.distribution.manifest.list.v2+json, " +
                        "application/vnd.oci.image.manifest.v1+json, " +
                        "application/vnd.oci.image.index.v1+json"
        $headers = @{ "Accept" = $acceptHeader }

        # --- Authentication ---------------------------------------------------
        if ($registry -match '\.dkr\.ecr\.([a-z0-9-]+)\.amazonaws\.com') {
            # AWS ECR: token comes from the AWS CLI (already-configured AWS creds),
            # not from an anonymous Docker Registry token exchange.
            $region = $Matches[1]
            $awsCli = Get-Command aws -ErrorAction SilentlyContinue
            if ($awsCli) {
                $ecrPassword = & aws ecr get-login-password --region $region 2>$null
                if ($ecrPassword) {
                    $basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("AWS:$ecrPassword"))
                    $headers["Authorization"] = "Basic $basic"
                }
            }
            if (-not $headers.ContainsKey("Authorization")) {
                $result.Reason = "ECR registry detected but no usable AWS credentials were found (aws CLI missing or 'aws ecr get-login-password' failed). Configure AWS credentials for this workstation to enable manifest lookups against ECR."
                $script:ImageManifestCache[$Image] = $result
                return $result
            }
        } else {
            # Standard Docker Registry v2 anonymous/bearer token flow (works for
            # Docker Hub and most public/anonymous-pull registries).
            try {
                Invoke-WebRequest -Uri "https://$registry/v2/" -Method Get -UseBasicParsing -TimeoutSec $TimeoutSeconds -ErrorAction Stop | Out-Null
            } catch {
                $wwwAuth = $null
                try { $wwwAuth = $_.Exception.Response.Headers["WWW-Authenticate"] } catch {}
                if ($wwwAuth -and ($wwwAuth -match 'realm="([^"]+)"') -and ($wwwAuth -match 'service="([^"]+)"')) {
                    $realm   = $Matches[1]
                    $svcMatch = [regex]::Match($wwwAuth, 'service="([^"]+)"')
                    $service = $svcMatch.Groups[1].Value
                    $scope   = "repository:${repoTag}:pull"
                    try {
                        $tokenResp = Invoke-RestMethod -Uri "$realm`?service=$service&scope=$scope" -Method Get -TimeoutSec $TimeoutSeconds -ErrorAction Stop
                        $token = if ($tokenResp.token) { $tokenResp.token } else { $tokenResp.access_token }
                        if ($token) { $headers["Authorization"] = "Bearer $token" }
                    } catch {
                        $result.Reason = "Registry requires authentication and the anonymous token exchange failed (private image/registry). Supply credentials to enable manifest lookups."
                        $script:ImageManifestCache[$Image] = $result
                        return $result
                    }
                }
                # If no WWW-Authenticate challenge was returned, registry may allow
                # fully anonymous manifest GETs - continue without a token.
            }
        }

        # --- Fetch the manifest -------------------------------------------
        $manifestUrl = "https://$registry/v2/$repoTag/manifests/$reference"
        $manifest = Invoke-RestMethod -Uri $manifestUrl -Headers $headers -Method Get -TimeoutSec $TimeoutSeconds -ErrorAction Stop

        # Manifest list / OCI index (multi-arch) - resolve to linux/amd64 (or the
        # first entry if that specific platform isn't listed).
        if ($manifest.manifests) {
            $chosen = $manifest.manifests | Where-Object { $_.platform.os -eq 'linux' -and $_.platform.architecture -eq 'amd64' } | Select-Object -First 1
            if (-not $chosen) { $chosen = $manifest.manifests | Select-Object -First 1 }
            if ($chosen) {
                $result.Digest = $chosen.digest
                $manifestUrl2 = "https://$registry/v2/$repoTag/manifests/$($chosen.digest)"
                $manifest = Invoke-RestMethod -Uri $manifestUrl2 -Headers $headers -Method Get -TimeoutSec $TimeoutSeconds -ErrorAction Stop
            }
        }

        if ($manifest.layers) {
            $result.TotalLayers  = $manifest.layers.Count
            $result.LayerDigests = @($manifest.layers | ForEach-Object { $_.digest })
            $result.Available    = $true
            if (-not $result.Digest -and $manifest.config -and $manifest.config.digest) {
                # Fallback identifier when we resolved a single-arch manifest directly
                # (no manifest-list digest available) - this is the config digest, not
                # the image digest, and is only used for display when nothing better exists.
                $result.Digest = $manifest.config.digest
            }
        } else {
            $result.Reason = "Registry responded but manifest contained no 'layers' field (unexpected manifest schema)."
        }
    } catch {
        $result.Available = $false
        if (-not $result.Reason) {
            $result.Reason = "Could not query the registry manifest for this image (private registry needing credentials, network egress blocked from this workstation, or the image/tag no longer exists). Detail: $($_.Exception.Message)"
        }
    }

    $script:ImageManifestCache[$Image] = $result
    return $result
}

function Invoke-NodeDebugCapture {
    <#
        NEW: Runs a command on a node's host filesystem via `kubectl debug
        node/<n>` and reliably captures its REAL output.

        MODIFIED FLOW (per confirmed EKS behavior): `kubectl debug node/<n>`
        does NOT stream the remote command's stdout back to this workstation.
        It only prints one line - "Creating debugging pod <name> with
        container debugger on node <node>." - and returns as soon as the
        debug pod exists. The actual command output only becomes available
        once the debug pod finishes, via:
            kubectl logs <debug-pod-name> -c debugger

        MODIFIED: the debug pod's namespace is NOT assumed to be "default"
        (or any other fixed value) and is NOT the same thing as the app's
        -Namespace (e.g. "dwp-base"). If -DebugPodNamespace was left blank
        (the default), this function auto-detects the debug pod's real
        namespace by looking it up across all namespaces right after it's
        created. If -DebugPodNamespace was explicitly supplied, that value is
        trusted as-is and the auto-detect lookup is skipped.

        This function implements the full, confirmed-working lifecycle:
          1) LAUNCH   : `kubectl debug node/<n> --image=busybox:1.36
                         --attach=false -- chroot /host sh -c "<command>"`
                         and parse the generated debug pod's name out of
                         kubectl's own "Creating debugging pod <name> ..." line.
          2) RESOLVE  : if no explicit -DebugPodNamespace was given, find the
                         debug pod's actual namespace via
                         `kubectl get pods --all-namespaces --field-selector
                         metadata.name=<name> -o json`.
          3) POLL     : `kubectl get pod <name> -n <resolved namespace> -o json`
                         repeatedly until the pod (or its "debugger" container)
                         reaches a terminal state, or TimeoutSeconds elapses.
          4) LOGS     : `kubectl logs <name> -n <resolved namespace> -c debugger`
                         for the actual command output.
          5) CLEANUP  : `kubectl delete pod <name> -n <resolved namespace>
                         --wait=false` in a `finally` block, so debug pods
                         never pile up across repeated runs on a large fleet.

        Returns Available=$false with a plain-English Reason on ANY failure
        (pod name unparsable, namespace unresolvable, pod never completes,
        logs empty, etc.) - never fabricates command output.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$NodeName,
        [Parameter(Mandatory=$true)][string]$RemoteCommand,
        [string]$DebugPodNamespace = "",   # MODIFIED: blank = auto-detect, not "default"
        [int]$TimeoutSeconds = 30
    )

    $result = [PSCustomObject]@{
        Available          = $false
        Output             = ""
        Reason             = ""
        ResolvedNamespace  = ""   # NEW: the namespace actually used, for logging/troubleshooting
    }

    if (-not $NodeName -or $NodeName -eq "N/A") {
        $result.Reason = "No node name available to inspect."
        return $result
    }

    $podName = $null
    $resolvedNamespace = $null
    try {
        # 1) LAUNCH - --attach=false makes this return as soon as the debug pod
        # is created, instead of trying to attach/stream (matches the
        # confirmed observed behavior of returning only the "Creating
        # debugging pod ..." line). Wrapped in a job with its own short
        # timeout in case launch itself ever hangs.
        $launchJob = Start-Job -ScriptBlock {
            param($node, $cmd)
            kubectl debug "node/$node" --image=busybox:1.36 --attach=false -- chroot /host sh -c $cmd 2>&1
        } -ArgumentList $NodeName, $RemoteCommand

        $launchTimeout = [math]::Min(20, $TimeoutSeconds)
        $launchCompleted = Wait-Job -Job $launchJob -Timeout $launchTimeout
        if (-not $launchCompleted) {
            Stop-Job -Job $launchJob -ErrorAction SilentlyContinue
            Remove-Job -Job $launchJob -Force -ErrorAction SilentlyContinue
            $result.Reason = "Timed out after ${launchTimeout}s waiting for 'kubectl debug node/$NodeName' to create the debug pod (node under load or no debug access)."
            return $result
        }

        $launchOut = (Receive-Job -Job $launchJob -ErrorAction SilentlyContinue) -join "`n"
        Remove-Job -Job $launchJob -Force -ErrorAction SilentlyContinue

        if ($launchOut -match 'Creating debugging pod\s+(\S+)\s') {
            $podName = $Matches[1]
        }

        if (-not $podName) {
            $result.Reason = "Could not parse the generated debug pod name out of 'kubectl debug node/$NodeName' output. Raw output: $($launchOut.Trim())"
            return $result
        }

        # 2) RESOLVE NAMESPACE - MODIFIED / NEW: do NOT assume "default" (or any
        # other fixed namespace). If the caller explicitly passed
        # -DebugPodNamespace, trust it and skip this lookup. Otherwise, find
        # the pod cluster-wide by name to learn where kubectl actually put it -
        # this is deliberately separate from (and never confused with) the
        # app's -Namespace (e.g. "dwp-base").
        if ($DebugPodNamespace) {
            $resolvedNamespace = $DebugPodNamespace
        } else {
            $lookupTimeout = [math]::Min(15, [math]::Max(5, $TimeoutSeconds - $launchTimeout))
            $findJob = Start-Job -ScriptBlock {
                param($name)
                kubectl get pods --all-namespaces --field-selector "metadata.name=$name" -o json 2>$null
            } -ArgumentList $podName

            $findCompleted = Wait-Job -Job $findJob -Timeout $lookupTimeout
            if (-not $findCompleted) {
                Stop-Job -Job $findJob -ErrorAction SilentlyContinue
                Remove-Job -Job $findJob -Force -ErrorAction SilentlyContinue
                $result.Reason = "Timed out after ${lookupTimeout}s trying to auto-detect the namespace of debug pod '$podName' (kubectl get pods --all-namespaces). Pass -DebugPodNamespace explicitly to skip auto-detection, or check RBAC for listing pods cluster-wide."
                return $result
            }

            $findOut = (Receive-Job -Job $findJob -ErrorAction SilentlyContinue) -join "`n"
            Remove-Job -Job $findJob -Force -ErrorAction SilentlyContinue

            $findJson = $null
            try { $findJson = $findOut | ConvertFrom-Json -ErrorAction Stop } catch { $findJson = $null }

            if ($findJson -and $findJson.items -and $findJson.items.Count -gt 0) {
                $resolvedNamespace = $findJson.items[0].metadata.namespace
            } else {
                $result.Reason = "Could not auto-detect the namespace of debug pod '$podName' (cluster-wide lookup returned no match). It may have already been cleaned up, or RBAC doesn't allow listing pods across namespaces. Pass -DebugPodNamespace explicitly if you know which namespace 'kubectl debug node' uses in this cluster."
                return $result
            }
        }

        $result.ResolvedNamespace = $resolvedNamespace

        # 3) POLL - wait for the debug pod to reach a terminal state.
        $remaining = [math]::Max(5, $TimeoutSeconds - $launchTimeout)
        $waited = 0
        $pollInterval = 2
        $lastPhase = $null
        $done = $false
        while ($waited -lt $remaining) {
            $podJson = kubectl get pod $podName -n $resolvedNamespace -o json 2>$null | ConvertFrom-Json
            if ($podJson) {
                $lastPhase = $podJson.status.phase
                if ($lastPhase -eq 'Succeeded' -or $lastPhase -eq 'Failed') { $done = $true; break }
                $debuggerStatus = $podJson.status.containerStatuses | Where-Object { $_.name -eq 'debugger' } | Select-Object -First 1
                if ($debuggerStatus -and $debuggerStatus.state.terminated) { $done = $true; break }
            }
            Start-Sleep -Seconds $pollInterval
            $waited += $pollInterval
        }

        if (-not $done) {
            $result.Reason = "Timed out after $($launchTimeout + $waited)s waiting for debug pod '$podName' (namespace '$resolvedNamespace') on node '$NodeName' to finish (last phase seen: $lastPhase)."
            return $result
        }

        # 4) LOGS - the debug pod's own output IS the real command output.
        $logs = (kubectl logs $podName -n $resolvedNamespace -c debugger 2>$null | Out-String)

        if (-not $logs -or $logs.Trim() -eq "") {
            $result.Reason = "Debug pod '$podName' (namespace '$resolvedNamespace') on node '$NodeName' finished (phase: $lastPhase) but 'kubectl logs' returned no output. Likely causes: insufficient RBAC for 'kubectl logs' in that namespace, or the remote command produced no stdout."
            return $result
        }

        $result.Output    = $logs
        $result.Available = $true
    } catch {
        $result.Reason = "Node debug capture failed: $($_.Exception.Message)."
    } finally {
        # 5) CLEANUP - always attempt to remove the temporary debug pod, success
        # or failure, so these don't accumulate across repeated runs. Uses the
        # resolved namespace, not a hardcoded/assumed one.
        if ($podName -and $resolvedNamespace) {
            kubectl delete pod $podName -n $resolvedNamespace --wait=false --ignore-not-found=true 2>$null | Out-Null
        }
    }

    return $result
}

# =========================================================================
# MODIFIED (digest-correlation fix): Get-NodeContentDigests
# =========================================================================
#
# ROOT-CAUSE CONTEXT: `ctr -n k8s.io content ls` only lists blobs still
# sitting in containerd's raw content store. Many EKS/Bottlerocket containerd
# configs set `discard_unpacked_layers = true`, which deletes a layer's
# compressed blob from the content store once it has been unpacked into the
# overlayfs snapshotter - the layer is still fully present and usable (that's
# how the pod became Ready), but its digest no longer exists in `content ls`
# output. Manifest/config JSON blobs are small and are NOT normally discarded
# this way, which is consistent with content count staying non-zero (e.g. 76)
# while every LAYER digest reads Missing.
#
# CHANGE: this function now also supports an opt-in -IncludeRawOutput switch
# that captures the FULLY UNFILTERED, un-grepped `ctr -n k8s.io content ls`
# output (raw lines, header included) alongside the previously-parsed digest
# set, so the diagnostic path in Get-NodeLayerCacheAnalysis can show the exact
# raw evidence rather than a pre-filtered view that could itself be hiding a
# parsing bug. The default (non-diagnostic) BEFORE/AFTER snapshot path used by
# Wait-ForNewPodReady and Get-NodeImageManifestInfo is UNCHANGED.
# =========================================================================
function Get-NodeContentDigests {
    param(
        [Parameter(Mandatory=$true)][string]$NodeName,
        [string]$DebugPodNamespace = "",   # MODIFIED: blank = auto-detect (not "default")
        [int]$TimeoutSeconds = 30,
        [switch]$IncludeRawOutput   # NEW: when set, also returns the fully unfiltered `ctr content ls` output, for diagnostics only
    )

    $result = [PSCustomObject]@{
        Available          = $false
        Digests            = [System.Collections.Generic.HashSet[string]]::new()
        Reason             = ""
        ResolvedNamespace  = ""   # NEW: surfaced for logging/troubleshooting
        RawOutput          = ""   # NEW: unfiltered `ctr -n k8s.io content ls` output (only populated when -IncludeRawOutput)
    }

    if (-not $NodeName -or $NodeName -eq "N/A") {
        $result.Reason = "No node name available to inspect."
        return $result
    }

    if ($IncludeRawOutput) {
        # NEW: diagnostic path - capture BOTH the raw, completely unfiltered
        # `ctr content ls` output AND the same column-1-only filtered digest
        # list the normal path uses, in one debug-pod run, split by a marker.
        # This proves/disproves whether the filtering itself is the problem,
        # independent of whether the digests are actually present.
        $remoteCmd = "echo '###RAW###'; ctr -n k8s.io content ls 2>&1; echo '###FILTERED###'; ctr -n k8s.io content ls 2>/dev/null | awk 'NR>1 && NF{print `$1}' | grep -E '^sha256:[a-f0-9]{64}`$'"
        $capture = Invoke-NodeDebugCapture -NodeName $NodeName -RemoteCommand $remoteCmd -DebugPodNamespace $DebugPodNamespace -TimeoutSeconds $TimeoutSeconds
        $result.ResolvedNamespace = $capture.ResolvedNamespace

        if (-not $capture.Available) {
            $result.Reason = $capture.Reason
            return $result
        }

        $rawPart = ""
        $filteredPart = ""
        if ($capture.Output -match '(?s)###RAW###\r?\n(.*?)###FILTERED###\r?\n(.*)$') {
            $rawPart      = $Matches[1]
            $filteredPart = $Matches[2]
        } else {
            $rawPart = $capture.Output
        }

        $result.RawOutput = $rawPart.Trim()
        foreach ($line in ($filteredPart -split "`r?`n")) {
            $trimmed = $line.Trim()
            if ($trimmed -match '^sha256:[a-f0-9]{64}$') {
                [void]$result.Digests.Add($trimmed)
            }
        }
        $result.Available = $true
        return $result
    }

    # UNCHANGED: normal (non-diagnostic) path - filtered, column-1-only digest
    # list, same as before this update. Same reasoning as documented previously:
    # column selection/validation is done remotely in the shell so the LABELS
    # column's unrelated sha256 references can never be picked up as if they
    # were this row's own digest.
    $remoteContentListCmd = "ctr -n k8s.io content ls 2>/dev/null | awk 'NR>1 && NF{print `$1}' | grep -E '^sha256:[a-f0-9]{64}`$'"
    $capture = Invoke-NodeDebugCapture -NodeName $NodeName -RemoteCommand $remoteContentListCmd -DebugPodNamespace $DebugPodNamespace -TimeoutSeconds $TimeoutSeconds
    $result.ResolvedNamespace = $capture.ResolvedNamespace

    if (-not $capture.Available) {
        $result.Reason = $capture.Reason
        return $result
    }

    foreach ($line in ($capture.Output -split "`r?`n")) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^sha256:[a-f0-9]{64}$') {
            [void]$result.Digests.Add($trimmed)
        }
    }
    $result.Available = $true

    return $result
}

# =========================================================================
# MODIFIED (digest-correlation fix): Get-NodeImageManifestInfo
# =========================================================================
# PRIMARY SOURCE: resolves an image's manifest and layer list directly from
# a Kubernetes node's own containerd runtime. All prior behavior (single
# debug-pod run, CRLF->LF normalization + base64 transport, exact-then-
# substring image matching, digest extraction by regex not column position)
# is UNCHANGED.
#
# CHANGE: the remote script now ALSO captures, in the SAME debug-pod run
# (no extra pods spun up):
#   - ###IMAGESCHECK###   : `ctr -n k8s.io images check <matched-ref>` -
#     containerd's OWN authoritative content-completeness check for an
#     image, computed internally by containerd rather than by us grepping
#     digests. If containerd itself reports the image "complete", that is
#     strong independent evidence the layers exist somewhere containerd can
#     see them, even if a content-store digest grep says otherwise.
#   - ###DISCARDCONFIG### : a best-effort grep of the node's containerd
#     config for `discard_unpacked_layers`, since that setting - if true -
#     is the most likely explanation for layer blobs disappearing from
#     `content ls` after a successful unpack.
# Both are captured ALWAYS (cheap) but only ever DISPLAYED for the one
# diagnostic service - see Get-NodeLayerCacheAnalysis - and never feed into
# the Cached/Downloaded/Missing computation itself.
# =========================================================================
function Get-NodeImageManifestInfo {
    param(
        [Parameter(Mandatory=$true)][string]$NodeName,
        [Parameter(Mandatory=$true)][string]$Image,
        [string]$DebugPodNamespace = "",   # blank = auto-detect (not "default")
        [int]$TimeoutSeconds = 30
    )

    $cacheKey = "$NodeName|$Image"
    if ($script:NodeManifestCache.ContainsKey($cacheKey)) {
        return $script:NodeManifestCache[$cacheKey]
    }

    $result = [PSCustomObject]@{
        Available           = $false
        Digest               = $null
        TotalLayers          = 0
        LayerDigests         = @()
        AfterContentDigests  = [System.Collections.Generic.HashSet[string]]::new()
        Reason               = ""
        Source               = "Measured (Node containerd, primary)"
        ImagesCheckOutput    = ""   # NEW: raw `ctr images check` output for this image, for diagnostics
        DiscardConfigOutput  = ""   # NEW: raw grep of containerd config for discard_unpacked_layers, for diagnostics
    }

    if (-not $NodeName -or $NodeName -eq "N/A") {
        $result.Reason = "No node name available for this pod - cannot inspect node-side containerd."
        $script:NodeManifestCache[$cacheKey] = $result
        return $result
    }

    $imgEscaped = $Image -replace "'", "'\\''"
    $remoteScript = @"
IMG='$imgEscaped'

ALL_REFS=`$(ctr -n k8s.io images ls 2>/dev/null)

MATCH_LINE=`$(printf '%s\n' "`$ALL_REFS" | awk -v img="`$IMG" '`$1 == img {print; exit}')

if [ -z "`$MATCH_LINE" ]; then
  MATCH_LINE=`$(printf '%s\n' "`$ALL_REFS" | grep -F -- "`$IMG" | head -n1)
fi

MATCHED_REF=`$(printf '%s' "`$MATCH_LINE" | awk '{print `$1}')

DIGEST=`$(printf '%s' "`$MATCH_LINE" | grep -oE 'sha256:[a-f0-9]+' | head -n1)

echo "REQUESTED_IMAGE: `$IMG"
echo "MATCHED_REF: `$MATCHED_REF"
echo "MATCHED_DIGEST: `$DIGEST"

echo '###DIGEST###'
echo "`$DIGEST"
echo '###MANIFEST###'
if [ -n "`$DIGEST" ]; then ctr -n k8s.io content get "`$DIGEST" 2>/dev/null; fi
echo '###CONTENTLIST###'
ctr -n k8s.io content ls 2>/dev/null | awk 'NR>1 && NF{print `$1}' | grep -E '^sha256:[a-f0-9]{64}`$'
echo '###IMAGESCHECK###'
if [ -n "`$MATCHED_REF" ]; then ctr -n k8s.io images check "`$MATCHED_REF" 2>&1; else echo '(no matched ref - could not run images check)'; fi
echo '###DISCARDCONFIG###'
grep -R 'discard_unpacked_layers' /etc/containerd/config.toml /etc/eks/containerd/*.toml 2>/dev/null || echo '(discard_unpacked_layers not found in the usual EKS containerd config paths - not conclusive, config may live elsewhere)'
"@

    # NEW: CRLF -> LF normalization, then base64 transport. Unchanged reasoning
    # from before this update - a single flat, whitespace-free token cannot be
    # split, re-quoted, or mangled by any layer between this workstation and
    # the remote shell.
    $remoteScript = $remoteScript -replace "`r`n", "`n"
    $remoteScriptBytes = [System.Text.Encoding]::UTF8.GetBytes($remoteScript)
    $remoteScriptB64   = [Convert]::ToBase64String($remoteScriptBytes)
    $launcherCommand   = "echo $remoteScriptB64 | base64 -d | sh"

    $capture = Invoke-NodeDebugCapture -NodeName $NodeName -RemoteCommand $launcherCommand -DebugPodNamespace $DebugPodNamespace -TimeoutSeconds $TimeoutSeconds

    if (-not $capture.Available) {
        $result.Reason = $capture.Reason
        $script:NodeManifestCache[$cacheKey] = $result
        return $result
    }

    $rawText = $capture.Output
    $digestPart   = ""
    $manifestPart = ""
    $contentPart  = ""
    $imagesCheckPart = ""      # NEW
    $discardConfigPart = ""    # NEW

    if ($rawText -match 'REQUESTED_IMAGE:\s*(.*)') { Write-Host "      [Node match] REQUESTED_IMAGE: $($Matches[1].Trim())" -ForegroundColor DarkGray }
    if ($rawText -match 'MATCHED_REF:\s*(.*)')     { Write-Host "      [Node match] MATCHED_REF:     $($Matches[1].Trim())" -ForegroundColor DarkGray }
    if ($rawText -match 'MATCHED_DIGEST:\s*(.*)')  { Write-Host "      [Node match] MATCHED_DIGEST:  $($Matches[1].Trim())" -ForegroundColor DarkGray }

    # MODIFIED: marker regex extended to also capture ###IMAGESCHECK### and
    # ###DISCARDCONFIG### sections appended after ###CONTENTLIST###.
    if ($rawText -match '(?s)###DIGEST###\r?\n(.*?)###MANIFEST###\r?\n(.*?)###CONTENTLIST###\r?\n(.*?)###IMAGESCHECK###\r?\n(.*?)###DISCARDCONFIG###\r?\n(.*)$') {
        $digestPart        = $Matches[1].Trim()
        $manifestPart      = $Matches[2].Trim()
        $contentPart       = $Matches[3]
        $imagesCheckPart   = $Matches[4].Trim()
        $discardConfigPart = $Matches[5].Trim()
    }

    foreach ($line in ($contentPart -split "`r?`n")) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^sha256:[a-f0-9]{64}$') {
            [void]$result.AfterContentDigests.Add($trimmed)
        }
    }

    $result.ImagesCheckOutput   = $imagesCheckPart
    $result.DiscardConfigOutput = $discardConfigPart

    if (-not $digestPart) {
        $result.Reason = "Image '$Image' was not found in node '$NodeName''s containerd image store via 'ctr -n k8s.io images ls'. The pod's image reference may not match containerd's stored ref string, or the image was garbage-collected since the pod started."
        $script:NodeManifestCache[$cacheKey] = $result
        return $result
    }

    $result.Digest = $digestPart

    if (-not $manifestPart) {
        $result.Reason = "Resolved digest '$digestPart' on node '$NodeName' but 'ctr -n k8s.io content get' returned no manifest body (content may have been GC'd between resolving the digest and reading it)."
        $script:NodeManifestCache[$cacheKey] = $result
        return $result
    }

    try {
        $manifestObj = $manifestPart | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $result.Reason = "Manifest read from node '$NodeName' was not valid JSON (unexpected containerd/manifest schema). Detail: $($_.Exception.Message)"
        $script:NodeManifestCache[$cacheKey] = $result
        return $result
    }

    if ($manifestObj.layers) {
        $result.TotalLayers  = $manifestObj.layers.Count
        $result.LayerDigests = @($manifestObj.layers | ForEach-Object { $_.digest })
        $result.Available    = $true
    } else {
        $result.Reason = "Manifest read from node '$NodeName' contained no 'layers' field (may be a manifest-list/index digest rather than a resolved single-platform manifest)."
    }

    $script:NodeManifestCache[$cacheKey] = $result
    return $result
}

# =========================================================================
# MODIFIED (digest-correlation fix): Get-NodeLayerCacheAnalysis
# =========================================================================
# WHAT CHANGED AND WHY:
#
# Previously, once BeforeNodeName == AfterNodeName and a BEFORE snapshot
# existed, this function trusted a straight HashSet.Contains() check of each
# manifest layer digest against the content-store digest lists as a
# CONFIRMED Cached/Downloaded/Missing split. A real run showed that trust is
# unsafe: BEFORE and AFTER content counts were both non-zero (e.g. 76, real
# data, not a capture failure), yet all 6 manifest layer digests were absent
# from BOTH - while the pod was demonstrably Ready and running that exact
# image. A confirmed-Ready pod cannot have 0 of its layers anywhere on its
# own node, so a 0/6 "Missing" result here is evidence the CORRELATION
# METHOD is wrong for this node's containerd configuration, not evidence the
# layers are absent (most likely cause: discard_unpacked_layers=true purging
# blobs from the content store after they're unpacked into the snapshotter -
# see the doc comment on Get-NodeContentDigests above).
#
# NEW SAFEGUARD: before trusting a same-node Contains()-based split, this
# function now requires at least one manifest layer digest to actually be
# found in the combined BEFORE+AFTER content-store digest sets. If NONE of
# the manifest's layer digests appear in either snapshot, the correlation is
# treated as UNPROVEN - the split is reported Unavailable with an explicit
# reason, rather than as a confirmed 0/N Missing. This is a floor check only
# (any single found digest clears it); it never fabricates a partial split
# when correlation is broken - per-layer Missing is only ever used once the
# overall correlation has passed this sanity check.
#
# NEW DIAGNOSTICS: for exactly ONE service per run (the first one to reach
# this function with -DetailedImagePullAnalysis on, guarded by the
# module-scope $script:DigestCorrelationDiagnosticsShown flag declared near
# the top of this script), this prints:
#   - all manifest layer digests, with BEFORE/AFTER presence
#   - a fresh, raw, unfiltered `ctr -n k8s.io content ls` dump from the node
#   - the filtered digest list actually used for comparison
#   - `ctr -n k8s.io images check` output for the same image (containerd's
#     own completeness check, computed independently of our grep-based
#     matching)
#   - any discard_unpacked_layers setting found in the node's containerd
#     config
# so the correlation method itself can be verified or falsified from real
# node output. This diagnostic block is purely informational - it runs AFTER
# the correlation decision above and never influences it.
#
# Everything else in this function (SameNode detection, the zero-content
# capture-failure guard, the not-same-node / capture-failed Reason messages,
# the per-layer debug Write-Host output) is UNCHANGED.
# =========================================================================
function Get-NodeLayerCacheAnalysis {
    param(
        [Parameter(Mandatory=$true)][string]$Image,
        [string]$BeforeNodeName,
        [PSCustomObject]$BeforeContentInfo,   # result of Get-NodeContentDigests, or $null
        [Parameter(Mandatory=$true)][string]$AfterNodeName,
        [string]$DebugPodNamespace = "",   # MODIFIED: blank = auto-detect (not "default")
        [int]$TimeoutSeconds = 30
    )

    $result = [PSCustomObject]@{
        Available           = $false
        Digest               = $null
        TotalLayers          = 0
        LayerDigests         = @()
        CachedDigests        = @()
        DownloadedDigests     = @()
        MissingDigests       = @()
        SameNode             = $false
        Reason               = ""
        Source               = "Measured (Node containerd, primary)"
        CorrelationVerified  = $false   # NEW: whether at least one manifest digest was actually located in the node's content store
    }

    $nodeManifest = Get-NodeImageManifestInfo -NodeName $AfterNodeName -Image $Image -DebugPodNamespace $DebugPodNamespace -TimeoutSeconds $TimeoutSeconds
    if (-not $nodeManifest.Available) {
        $result.Reason = $nodeManifest.Reason
        return $result
    }

    $result.Available    = $true
    $result.Digest       = $nodeManifest.Digest
    $result.TotalLayers  = $nodeManifest.TotalLayers
    $result.LayerDigests = $nodeManifest.LayerDigests

    $result.SameNode = [bool]($BeforeNodeName -and $AfterNodeName -and ($BeforeNodeName -eq $AfterNodeName) -and $BeforeContentInfo -and $BeforeContentInfo.Available)

    # TEMPORARY debug output (unchanged - requirement: always show what was
    # actually matched, per layer, before trusting any split).
    $beforeCountForDebug = if ($BeforeContentInfo -and $BeforeContentInfo.Available) { $BeforeContentInfo.Digests.Count } else { 0 }
    Write-Host "      [Layer debug] Manifest layers: $($nodeManifest.TotalLayers)" -ForegroundColor DarkGray
    Write-Host "      [Layer debug] BEFORE NODE: $BeforeNodeName" -ForegroundColor DarkGray
    Write-Host "      [Layer debug] AFTER NODE : $AfterNodeName" -ForegroundColor DarkGray
    Write-Host "      [Layer debug] BEFORE matched layers: $beforeCountForDebug (total BEFORE content-store items parsed)" -ForegroundColor DarkGray
    Write-Host "      [Layer debug] AFTER matched layers: $($nodeManifest.AfterContentDigests.Count) (total AFTER content-store items parsed)" -ForegroundColor DarkGray

    # Anti-fabrication guard (unchanged): a node running any pods always has
    # more than zero items in its containerd content store, so a BEFORE or
    # AFTER set of exactly 0 digests means the capture/parsing itself failed,
    # not that the cache is genuinely empty.
    if ($result.SameNode -and $beforeCountForDebug -eq 0) {
        $result.SameNode = $false
        $result.Reason = "The BEFORE content-store snapshot on node '$BeforeNodeName' parsed to 0 digests from 'ctr -n k8s.io content ls'. A node that is running workloads never has a genuinely empty content store, so this reflects a capture/parsing failure (RBAC, timeout, or unexpected 'ctr' output) rather than an actually-empty cache. Cached/Downloaded split: Unavailable - Total Layers/Digest above are still measured directly from node '$AfterNodeName''s containerd."
    } elseif ($result.SameNode -and $nodeManifest.AfterContentDigests.Count -eq 0) {
        $result.SameNode = $false
        $result.Reason = "The AFTER content-store snapshot on node '$AfterNodeName' parsed to 0 digests from 'ctr -n k8s.io content ls'. A node that just ran this pod to Ready never has a genuinely empty content store, so this reflects a capture/parsing failure (RBAC, timeout, or unexpected 'ctr' output) rather than an actually-empty cache. Cached/Downloaded split: Unavailable - Total Layers/Digest above are still measured directly from node '$AfterNodeName''s containerd."
    }

    # NEW: correlation sanity check. Only meaningful once we have a same-node
    # BEFORE+AFTER pair to check against (i.e. neither capture-failure guard
    # above fired).
    if ($result.SameNode) {
        $combinedContentDigests = [System.Collections.Generic.HashSet[string]]::new($BeforeContentInfo.Digests)
        foreach ($d in $nodeManifest.AfterContentDigests) { [void]$combinedContentDigests.Add($d) }

        $anyManifestDigestFound = $false
        foreach ($ld in $nodeManifest.LayerDigests) {
            if ($combinedContentDigests.Contains($ld)) { $anyManifestDigestFound = $true; break }
        }
        $result.CorrelationVerified = $anyManifestDigestFound

        if (-not $anyManifestDigestFound) {
            # This is the exact failure mode reported: real BEFORE/AFTER
            # snapshots (non-zero, same node), but ZERO overlap with any
            # manifest layer digest. Given the pod reached Ready, that is far
            # more consistent with the content-store no longer holding
            # discrete layer blobs (e.g. discard_unpacked_layers=true) than
            # with the image genuinely having 0 of N layers on its own node.
            # Do NOT report a confirmed Missing split here - report
            # Unavailable and say exactly why.
            $result.SameNode = $false
            $result.Reason = "None of this image's $($nodeManifest.TotalLayers) manifest layer digests were found in EITHER the BEFORE or AFTER 'ctr -n k8s.io content ls' snapshot on node '$AfterNodeName' (which otherwise contained $beforeCountForDebug / $($nodeManifest.AfterContentDigests.Count) items respectively) - even though this pod reached Ready using this exact image on this exact node. A Ready pod cannot genuinely have 0 of its layers present on its own node, so this indicates the digest-correlation method itself is unreliable on this node (most likely cause: containerd's 'discard_unpacked_layers' setting removing layer blobs from the content store once they're unpacked into the snapshotter, which the raw content-store digest list can no longer see even though the layer is fully present and in use). Cached/Downloaded layer split: Unavailable - digest correlation could not be verified. Total Layers/Digest above are still measured directly from node '$AfterNodeName''s containerd manifest read, which is independent of this content-store check."
        }
    }

    # NEW: one-time, single-service diagnostic deep-dive. Only fires once per
    # run (guarded by $script:DigestCorrelationDiagnosticsShown, declared once
    # near the top of this script), for whichever service is the first to
    # reach this function. Prints the raw evidence needed to prove or
    # disprove the correlation method. Purely informational - it runs AFTER
    # the correlation decision above and never influences it.
    if (-not $script:DigestCorrelationDiagnosticsShown) {
        $script:DigestCorrelationDiagnosticsShown = $true

        Write-Host ""
        Write-Host "      ================= DIGEST CORRELATION DIAGNOSTICS (one-time, this service only) =================" -ForegroundColor Magenta
        Write-Host "      Image  : $Image" -ForegroundColor Magenta
        Write-Host "      Node   : $AfterNodeName" -ForegroundColor Magenta
        Write-Host ""
        Write-Host "      -- Manifest layer digests ($($nodeManifest.LayerDigests.Count)) --" -ForegroundColor Magenta
        $li = 0
        foreach ($ld in $nodeManifest.LayerDigests) {
            $li++
            $inBefore = ($BeforeContentInfo -and $BeforeContentInfo.Available -and $BeforeContentInfo.Digests.Contains($ld))
            $inAfter  = $nodeManifest.AfterContentDigests.Contains($ld)
            Write-Host ("        Layer {0}: {1}  [BEFORE: {2}]  [AFTER: {3}]" -f $li, $ld, $(if ($inBefore) {'YES'} else {'NO'}), $(if ($inAfter) {'YES'} else {'NO'})) -ForegroundColor Magenta
        }

        # Pull a fresh, raw, unfiltered content-store dump directly
        # (independent capture from the manifest-resolution debug pod above)
        # so the exact text containerd returns can be inspected, not just our
        # already-parsed set.
        Write-Host ""
        Write-Host "      -- Fetching a fresh, fully unfiltered 'ctr -n k8s.io content ls' from node '$AfterNodeName' for comparison --" -ForegroundColor Magenta
        $rawContentCheck = Get-NodeContentDigests -NodeName $AfterNodeName -DebugPodNamespace $DebugPodNamespace -TimeoutSeconds $TimeoutSeconds -IncludeRawOutput
        if ($rawContentCheck.Available) {
            Write-Host "      Raw 'ctr content ls' output (first 40 lines):" -ForegroundColor Magenta
            $rawContentCheck.RawOutput -split "`r?`n" | Select-Object -First 40 | ForEach-Object { Write-Host "        $_" -ForegroundColor DarkGray }
            Write-Host "      Filtered digest count from this fresh capture: $($rawContentCheck.Digests.Count)" -ForegroundColor Magenta
        } else {
            Write-Host "      Fresh raw content-store capture failed: $($rawContentCheck.Reason)" -ForegroundColor Magenta
        }

        Write-Host ""
        Write-Host "      -- 'ctr -n k8s.io images check' output (containerd's own completeness check) --" -ForegroundColor Magenta
        if ($nodeManifest.ImagesCheckOutput) {
            $nodeManifest.ImagesCheckOutput -split "`r?`n" | ForEach-Object { Write-Host "        $_" -ForegroundColor DarkGray }
        } else {
            Write-Host "        (no output captured)" -ForegroundColor DarkGray
        }

        Write-Host ""
        Write-Host "      -- discard_unpacked_layers check (node containerd config) --" -ForegroundColor Magenta
        if ($nodeManifest.DiscardConfigOutput) {
            $nodeManifest.DiscardConfigOutput -split "`r?`n" | ForEach-Object { Write-Host "        $_" -ForegroundColor DarkGray }
        } else {
            Write-Host "        (no output captured)" -ForegroundColor DarkGray
        }

        Write-Host "      ====================================================================================================" -ForegroundColor Magenta
        Write-Host ""
    }

    if ($result.SameNode) {
        $cached     = @()
        $downloaded = @()
        $missing    = @()
        $layerIdx   = 0
        foreach ($digest in $nodeManifest.LayerDigests) {
            $layerIdx++
            $isBefore = $BeforeContentInfo.Digests.Contains($digest)
            $isAfter  = $nodeManifest.AfterContentDigests.Contains($digest)
            if ($isBefore) {
                $cached += $digest
                $layerStatus = "Cached"
            } elseif ($isAfter) {
                $downloaded += $digest
                $layerStatus = "Downloaded"
            } else {
                $missing += $digest
                $layerStatus = "Missing"
            }
            Write-Host "      [Layer debug] Layer ${layerIdx}: $digest" -ForegroundColor DarkGray
            Write-Host "          BEFORE: $(if ($isBefore) { 'YES' } else { 'NO' })" -ForegroundColor DarkGray
            Write-Host "          AFTER : $(if ($isAfter) { 'YES' } else { 'NO' })" -ForegroundColor DarkGray
            Write-Host "          STATUS: $layerStatus" -ForegroundColor DarkGray
        }
        $result.CachedDigests     = $cached
        $result.DownloadedDigests = $downloaded
        $result.MissingDigests    = $missing
    } elseif (-not $result.Reason) {
        if ($BeforeNodeName -and $AfterNodeName -and ($BeforeNodeName -ne $AfterNodeName)) {
            $result.Reason = "The replacement pod landed on a different node ('$AfterNodeName') than the one the deleted pod was on ('$BeforeNodeName'), so there is no valid same-node 'before' cache snapshot to diff against. Total Layers/Digest above are still measured directly from node '$AfterNodeName''s containerd; the cached/downloaded split is left unavailable rather than guessed."
        } elseif ($BeforeContentInfo -and -not $BeforeContentInfo.Available) {
            $result.Reason = "A 'before' content-store snapshot was attempted on node '$BeforeNodeName' but failed: $($BeforeContentInfo.Reason) The cached/downloaded split is left unavailable rather than guessed."
        } else {
            $result.Reason = "No 'before' content-store snapshot was captured for this pod's node, so there is nothing to diff the current (post-ready) snapshot against. The cached/downloaded split is left unavailable rather than guessed."
        }
    }

    return $result
}

function Get-ImagePullAnalysis {
    <#
        UNCHANGED by this update. Combines everything above into ONE honest,
        non-fabricated picture of an image pull for a single pod, tagged
        clearly as Measured / Derived / Unavailable per data point.

        - TotalImagePullTime  : Measured (from the kubelet "Pulled" event).
        - Digest/TotalLayers/CachedLayers/MissingLayers/DownloadedLayers/
          CacheStatus         : PRIMARY source is the node's own containerd
                                runtime (Get-NodeLayerCacheAnalysis, now with
                                the digest-correlation safeguard above). If
                                node data isn't available, or the correlation
                                could not be verified, this falls back to the
                                registry manifest (Measured, Secondary) for
                                Digest/TotalLayers ONLY - never for the
                                cached/downloaded split - and finally to the
                                coarse Kubernetes Event signal when nothing
                                else is available.
        - Stage breakdown     : ALWAYS Unavailable - see doc comment above
                                Get-ImageManifestInfo.
    #>
    param(
        [string]$Image,
        [string]$BeforeNodeName,          # node the NEW/replacement pod landed on (before-snapshot is taken here, never the old deleted pod's node)
        [PSCustomObject]$BeforeContentInfo, # result of Get-NodeContentDigests taken before delete, or $null
        [string]$AfterNodeName,           # the node the NEW (measured) pod actually landed on
        [bool]$ImageCachedFromEvents,
        [double]$MeasuredPullTimeSeconds,
        [bool]$RunDetailedAnalysis,
        [string]$DebugPodNamespace = "",  # blank = auto-detect, passed through to node-debug calls
        [int]$TimeoutSeconds = 10
    )

    $analysis = [PSCustomObject]@{
        Image                 = $Image
        NodeName               = $AfterNodeName
        Digest                 = $null
        TotalLayers            = 0
        CachedLayers           = 0
        MissingLayers          = 0
        DownloadedLayers       = 0
        CacheStatus            = "Unknown"
        LayerDataSource        = "Unavailable"
        LayerUnavailableReason = ""
        LayerDetails           = @()
        MeasuredPullTimeSeconds = $MeasuredPullTimeSeconds
        StageBreakdownAvailable = $false
        StageBreakdownReason   = "Kubernetes Events only expose 'Pulling' and 'Pulled' timestamps (plus, sometimes, the kubelet-reported total duration). There is no Kubernetes-exposed sub-stage timing for Registry/DNS/Connection, Authentication, Manifest Resolution/Fetch, Layer Cache Check, Layer Download, Layer Verification, Layer Unpack, or Finalization. Obtaining real per-stage timing would require node-local containerd traces/metrics, which are not queried by this script to avoid inventing numbers."
    }

    $nodeAnalysis = $null
    if ($RunDetailedAnalysis -and $AfterNodeName -and $AfterNodeName -ne "N/A") {
        $nodeAnalysis = Get-NodeLayerCacheAnalysis `
            -Image $Image `
            -BeforeNodeName $BeforeNodeName `
            -BeforeContentInfo $BeforeContentInfo `
            -AfterNodeName $AfterNodeName `
            -DebugPodNamespace $DebugPodNamespace `
            -TimeoutSeconds ($TimeoutSeconds + 20)
    }

    if ($nodeAnalysis -and $nodeAnalysis.Available) {
        $analysis.Digest      = $nodeAnalysis.Digest
        $analysis.TotalLayers = $nodeAnalysis.TotalLayers

        if ($nodeAnalysis.SameNode) {
            $analysis.CachedLayers     = $nodeAnalysis.CachedDigests.Count
            $analysis.DownloadedLayers = $nodeAnalysis.DownloadedDigests.Count
            $analysis.MissingLayers    = $nodeAnalysis.MissingDigests.Count
            $analysis.LayerDataSource  = "Measured (Node containerd, before/after diff)"
            $idx = 0
            $analysis.LayerDetails = @($nodeAnalysis.LayerDigests | ForEach-Object {
                $idx++
                $status = if ($nodeAnalysis.CachedDigests -contains $_) { "Cached" }
                          elseif ($nodeAnalysis.DownloadedDigests -contains $_) { "Downloaded" }
                          else { "Missing" }
                [PSCustomObject]@{ Index = $idx; Digest = $_; Status = $status }
            })
        } else {
            # NEW (digest-correlation fix): this branch is now also reached
            # when SameNode was set back to $false by the correlation
            # safeguard in Get-NodeLayerCacheAnalysis (zero manifest digests
            # found in either snapshot). $nodeAnalysis.Reason already contains
            # the exact "Cached/Downloaded layer split: Unavailable - digest
            # correlation could not be verified" explanation in that case.
            $analysis.LayerDataSource = "Measured (Node containerd, split unavailable)"
            $analysis.LayerUnavailableReason = $nodeAnalysis.Reason
            $analysis.CachedLayers     = $null
            $analysis.MissingLayers    = $null
            $analysis.DownloadedLayers = $null
        }
    } else {
        $registryReason = if ($nodeAnalysis) { $nodeAnalysis.Reason } elseif (-not $RunDetailedAnalysis) { "Per-layer node/containerd analysis requires -DetailedImagePullAnalysis (opt-in, needs 'kubectl debug node' access). No private registry access is required to enable it." } else { "Node name unavailable for this pod." }

        $manifestInfo = Get-ImageManifestInfo -Image $Image -TimeoutSeconds $TimeoutSeconds

        if ($manifestInfo.Available) {
            $analysis.Digest      = $manifestInfo.Digest
            $analysis.TotalLayers = $manifestInfo.TotalLayers
            $analysis.LayerDataSource = "Measured (Registry Manifest, Secondary - node data unavailable)"
            $analysis.LayerUnavailableReason = "$registryReason Falling back to the registry manifest for total layer count only; the registry cannot provide a cached/downloaded split (that requires the node's own containerd state)."
        } else {
            $analysis.LayerDataSource = "Unavailable"
            $analysis.LayerUnavailableReason = "$registryReason Registry fallback also unavailable: $($manifestInfo.Reason)"
        }

        if ($ImageCachedFromEvents) {
            $analysis.CachedLayers     = $analysis.TotalLayers
            $analysis.MissingLayers    = 0
            $analysis.DownloadedLayers = 0
        } else {
            $analysis.CachedLayers     = $null
            $analysis.MissingLayers    = $null
            $analysis.DownloadedLayers = $null
        }
    }

    if ($null -eq $analysis.CachedLayers) {
        $analysis.CacheStatus = if ($ImageCachedFromEvents) { "Fully Cached" } else { "Not Cached (layer-level split unavailable)" }
    } elseif ($analysis.TotalLayers -eq 0) {
        $analysis.CacheStatus = "Unknown"
    } elseif ($analysis.CachedLayers -eq $analysis.TotalLayers) {
        $analysis.CacheStatus = "Fully Cached"
    } elseif ($analysis.CachedLayers -eq 0) {
        $analysis.CacheStatus = "Not Cached"
    } else {
        $analysis.CacheStatus = "Partially Cached"
    }

    return $analysis
}
function Test-PodNameMatch {
    param(
        [string]$PodName,
        [string]$ServiceName,
        [string]$PodPrefix,
        [string[]]$AllServiceNames = @()
    )

    if (-not $PodName) { return $false }

    $serviceMatch = $PodName -match [regex]::Escape($ServiceName)
    if (-not $serviceMatch) { return $false }

    if (-not [string]::IsNullOrWhiteSpace($PodPrefix)) {
        if ($PodName -notmatch [regex]::Escape($PodPrefix)) { return $false }
    }

    # Disambiguate service names where one is a literal substring of another
    # in the SAME benchmark run, e.g. "microservice-attachment" vs
    # "microservice-attachment-upload", or "microservice-holesection" vs
    # "microservice-holesection-summary". A plain substring match would let
    # "microservice-attachment" wrongly claim the pod that actually belongs
    # to "microservice-attachment-upload".
    #
    # We don't try to guess at Kubernetes hash-suffix patterns (that breaks
    # on real pod names, e.g. a trailing "-client-<hash>" segment). Instead we
    # use the one piece of information we actually have: if another service
    # name in THIS run is a longer extension of this one (ServiceName +
    # "-something") and it ALSO matches this pod, the pod belongs to that
    # longer, more specific service instead.
    foreach ($other in $AllServiceNames) {
        if ($other -eq $ServiceName) { continue }
        if ($other.Length -le $ServiceName.Length) { continue }
        if ($other -notmatch ("^" + [regex]::Escape($ServiceName) + "-")) { continue }
        if ($PodName -match [regex]::Escape($other)) { return $false }
    }

    return $true
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
        ImagePullTimeFromMsg  = $null
        IstioImagePullTimeFromMsg = $null
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
                            if (-not $lc.IstioPulled) {
                                $lc.IstioPulled = $ts
                                if (-not $lc.IstioImagePullTimeFromMsg) { $lc.IstioImagePullTimeFromMsg = Get-DurationFromPulledMessage $message }
                            }
                        } else {
                            if (-not $lc.ImagePulled) {
                                $lc.ImagePulled = $ts
                                if (-not $lc.ImagePullTimeFromMsg) { $lc.ImagePullTimeFromMsg = Get-DurationFromPulledMessage $message }
                            }
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

    # Image pull time: prefer the sub-second duration kubelet embeds in the
    # "Pulled" event message (e.g. "in 352ms") over the difference between
    # Pulling/Pulled *event* timestamps. Event firstTimestamp is only accurate
    # to the whole second, so any pull under ~1s (very common) rounds down to
    # exactly 0s via subtraction and becomes visually indistinguishable from a
    # truly cached ("already present on machine") pull. The message text does
    # not suffer from that rounding, so it's a strictly better source when present.
    if ($null -ne $lc.ImagePullTimeFromMsg) {
        $lc.ImagePullTime = $lc.ImagePullTimeFromMsg
    } elseif ($lc.PullingStarted -and $lc.ImagePulled) {
        $lc.ImagePullTime = [math]::Max(0, ($lc.ImagePulled - $lc.PullingStarted).TotalSeconds)
    }

    if ($null -ne $lc.IstioImagePullTimeFromMsg) {
        $lc.IstioImagePullTime = $lc.IstioImagePullTimeFromMsg
    } elseif ($lc.IstioPullingStarted -and $lc.IstioPulled) {
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
        [string]$KubeConfig,
        [string[]]$AllServiceNames = @()
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
        Test-PodNameMatch -PodName $_ -ServiceName $ServiceName -PodPrefix $PodPrefix -AllServiceNames $AllServiceNames
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
                Test-PodNameMatch -PodName $_ -ServiceName $ServiceName -PodPrefix $PodPrefix -AllServiceNames $AllServiceNames
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
    <#
        MODIFIED (this update): the layer-cache BEFORE snapshot must be taken
        on the NEW replacement pod's actual node - which is only known once
        the scheduler places it - and it must be taken BEFORE that node
        finishes pulling the image (otherwise the layers are already there
        and everything would incorrectly show as "Cached"). The OLD pod's
        node is not a valid stand-in, since the replacement pod can land
        anywhere in the cluster.

        This function is the only place that naturally sits between "the
        new pod exists and has a node" and "the new pod is Ready", so the
        BEFORE snapshot is now captured here, immediately after the
        replacement pod's nodeName becomes visible (short bounded poll,
        since scheduling can lag pod-creation by a couple of seconds) and
        before the Ready-wait loop below runs. This does not change how
        Ready is detected or how long that can take - it only adds a small,
        early, one-time snapshot in between.

        Return value CHANGED: previously returned a plain string ($newPod)
        or $null. Now returns a PSCustomObject so the new node name and its
        BEFORE snapshot can be handed back to the caller alongside the pod
        name:
            NewPodName        - the replacement pod's name, or $null on failure
            NewNodeName       - the node the replacement pod actually landed
                                 on, or $null if it couldn't be determined
            BeforeContentInfo - result of Get-NodeContentDigests taken on
                                 NewNodeName before the image pull completed,
                                 or $null when -CaptureBeforeSnapshot was not
                                 requested or the node couldn't be resolved
                                 in time
    #>
    param(
        [string]$ServiceName,
        [string]$PodPrefix,
        [string[]]$BeforePods,
        [string]$Namespace,
        [string]$KubeConfig,
        [int]$TimeoutSeconds,
        [string[]]$AllServiceNames = @(),
        [bool]$CaptureBeforeSnapshot = $false,     # NEW: opt-in, mirrors -DetailedImagePullAnalysis
        [string]$DebugPodNamespace = "",           # NEW: passed through to Get-NodeContentDigests
        [int]$NodeSnapshotTimeoutSeconds = 30,      # NEW: passed through to Get-NodeContentDigests
        [int]$NodeSchedulePollTimeoutSeconds = 30   # NEW: how long to wait for spec.nodeName to appear
    )

    $waited  = 0
    $newPod  = $null
    $lastHeartbeat = 0

    while ($waited -lt $TimeoutSeconds) {
        $allCurrent = @(kubectl get pods -n $Namespace 2>$null |
                        Select-Object -Skip 1 | ForEach-Object { ($_ -split '\s+')[0] })

        # Find pods matching service and optional branch prefix that weren't there before.
        $candidates = @($allCurrent | Where-Object {
            (Test-PodNameMatch -PodName $_ -ServiceName $ServiceName -PodPrefix $PodPrefix -AllServiceNames $AllServiceNames) -and ($BeforePods -notcontains $_)
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
        return [PSCustomObject]@{ NewPodName = $null; NewNodeName = $null; BeforeContentInfo = $null }
    }

    # NEW (this update): resolve the replacement pod's actual node as early
    # as possible, and - if requested - capture the BEFORE containerd
    # snapshot on THAT node right now, before the Ready-wait loop below lets
    # the image pull run to completion. Bounded poll because scheduling
    # typically follows pod-creation within a couple of seconds but is not
    # guaranteed to be instantaneous.
    $newNodeName = $null
    $beforeContentInfo = $null
    if ($CaptureBeforeSnapshot) {
        $nodePollWaited = 0
        while ($nodePollWaited -lt $NodeSchedulePollTimeoutSeconds) {
            $schedJson = kubectl get pod $newPod -n $Namespace -o json 2>$null | ConvertFrom-Json
            if ($schedJson -and $schedJson.spec.nodeName) {
                $newNodeName = $schedJson.spec.nodeName
                break
            }
            Start-Sleep -Seconds 2
            $nodePollWaited += 2
        }

        Write-Host "      [Layer debug] AFTER NODE: $(if ($newNodeName) { $newNodeName } else { 'unresolved - pod not yet scheduled' })" -ForegroundColor DarkGray

        if ($newNodeName) {
            Write-Host "      Snapshotting node '$newNodeName' containerd cache (before pull, on the replacement pod's own node)..." -ForegroundColor Gray
            $beforeContentInfo = Get-NodeContentDigests -NodeName $newNodeName -DebugPodNamespace $DebugPodNamespace -TimeoutSeconds $NodeSnapshotTimeoutSeconds
            if ($beforeContentInfo.Available) {
                Write-Host "      Debug pod namespace: $($beforeContentInfo.ResolvedNamespace)" -ForegroundColor DarkGray
                Write-Host "      [Layer debug] BEFORE snapshot count: $($beforeContentInfo.Digests.Count)" -ForegroundColor DarkGray
            } else {
                Write-Host "      [Before-snapshot unavailable] $($beforeContentInfo.Reason)" -ForegroundColor DarkYellow
            }
        } else {
            Write-Host "      [Layer debug] Replacement pod was not scheduled to a node within ${NodeSchedulePollTimeoutSeconds}s - BEFORE snapshot skipped; cache split will be reported Unavailable." -ForegroundColor DarkYellow
        }
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
                # NEW: if the node wasn't resolved during the early poll
                # above (e.g. CaptureBeforeSnapshot was off, or scheduling
                # was unusually slow), pick it up now for reporting/AFTER
                # purposes - just no BEFORE snapshot will exist for it.
                if (-not $newNodeName -and $podJson.spec.nodeName) {
                    $newNodeName = $podJson.spec.nodeName
                }
                return [PSCustomObject]@{ NewPodName = $newPod; NewNodeName = $newNodeName; BeforeContentInfo = $beforeContentInfo }
            }

            if ($phase -eq "Failed" -or $phase -eq "CrashLoopBackOff") {
                Write-Host "      Pod entered failed state: $newPod ($phase)" -ForegroundColor Red
                return [PSCustomObject]@{ NewPodName = $null; NewNodeName = $newNodeName; BeforeContentInfo = $beforeContentInfo }
            }

            # Surface container-level waiting reasons (e.g. ImagePullBackOff, CrashLoopBackOff)
            $badContainer = $podJson.status.containerStatuses |
                Where-Object { $_.state.waiting -and $_.state.waiting.reason -match 'BackOff|Error|Invalid' } |
                Select-Object -First 1
            if ($badContainer) {
                Write-Host "      Container issue on ${newPod}: $($badContainer.state.waiting.reason)" -ForegroundColor Red
                return [PSCustomObject]@{ NewPodName = $null; NewNodeName = $newNodeName; BeforeContentInfo = $beforeContentInfo }
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
    return [PSCustomObject]@{ NewPodName = $null; NewNodeName = $newNodeName; BeforeContentInfo = $beforeContentInfo }
}

# ---------------------------------------------
# Banner
# ---------------------------------------------

Write-Host ""
Write-Host "=====================================================================================================" -ForegroundColor Cyan
Write-Host "                        POD BENCHMARK  -  $ClusterLabel" -ForegroundColor Cyan
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
    $existingPods = @(Find-RunningPodsForService -ServiceName $serviceName -PodPrefix $PodPrefix -Namespace $Namespace -KubeConfig $KubeConfig -AllServiceNames $ServiceNames)

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
            # NEW: Detailed Image Pull Analysis fields (defaults - nothing to analyze, no pod exists)
            ImageDigest           = "N/A"
            TotalLayers           = 0
            CachedLayers          = $null
            MissingLayers         = $null
            DownloadedLayers      = $null
            CacheStatus           = "N/A"
            LayerDataSource       = "Unavailable"
            LayerUnavailableReason = "No pod found for this service - nothing to analyze."
            LayerDetails          = @()
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

    # NEW (this update): the layer-cache BEFORE snapshot is now taken on the
    # REPLACEMENT pod's own node, inside Wait-ForNewPodReady below - not
    # here, and not on this (soon to be deleted) pod's node. The old pod can
    # be replaced by the scheduler onto any node in the cluster, so a
    # same-node BEFORE/AFTER diff is only valid if both snapshots come from
    # the node the NEW pod actually runs on. $nodeName above is kept purely
    # for informational reporting (e.g. the "landed on a different node"
    # message below) - it is never used for the cache comparison.

    # 3) Patch imagePullPolicy on the deployment to control cached vs fresh pull
    $kubePullPolicy = if ($PullType -eq 'Fresh') { 'Always' } else { 'IfNotPresent' }
    Write-Host "    Setting imagePullPolicy to '$kubePullPolicy' ($PullType pull)..." -ForegroundColor Gray
    $patched = Set-DeploymentImagePullPolicy -PodName $podToDelete -Namespace $Namespace -Policy $kubePullPolicy
    if ($patched) { Start-Sleep -Seconds 3 }   # brief settle time after patch

    # 4) Snapshot all current pods for this service (to detect the brand-new one later)
    $allPodsSnapshot = kubectl get pods -n $Namespace 2>$null |
                       Select-Object -Skip 1 | ForEach-Object { ($_ -split '\s+')[0] }
    $beforePodsForService = @($allPodsSnapshot | Where-Object {
        Test-PodNameMatch -PodName $_ -ServiceName $serviceName -PodPrefix $PodPrefix -AllServiceNames $ServiceNames
    })

    # 5) Delete the pod
    Write-Host "    Deleting pod..." -ForegroundColor Yellow
    $deleteTime = Get-Date
    kubectl delete pod $podToDelete -n $Namespace --wait=false 2>&1 | Out-Null
    Write-Host "    Deleted at: $($deleteTime.ToString('HH:mm:ss'))" -ForegroundColor Gray

    if ($WaitBetweenDeletes -gt 0 -and -not $Sequential) {
        Start-Sleep -Seconds $WaitBetweenDeletes
    }

    # 6) Wait for replacement pod to appear and become ready.
    # MODIFIED: also resolves the replacement pod's real node and - when
    # -DetailedImagePullAnalysis is on - captures the BEFORE containerd
    # snapshot on THAT node as soon as it's known, before the image pull
    # completes. See Wait-ForNewPodReady's doc comment for why this moved
    # here instead of snapshotting the old pod's node before delete.
    Write-Host "    Waiting for replacement pod..." -ForegroundColor Gray
    $waitResult = Wait-ForNewPodReady `
        -ServiceName $serviceName `
        -PodPrefix $PodPrefix `
        -BeforePods  $beforePodsForService `
        -Namespace   $Namespace `
        -KubeConfig  $KubeConfig `
        -TimeoutSeconds $ReadyTimeoutSeconds `
        -AllServiceNames $ServiceNames `
        -CaptureBeforeSnapshot:$DetailedImagePullAnalysis `
        -DebugPodNamespace $DebugPodNamespace `
        -NodeSnapshotTimeoutSeconds ($RegistryTimeoutSeconds + 20)

    $newPodName        = $waitResult.NewPodName
    $newNodeName       = $waitResult.NewNodeName
    $beforeNodeContent = $waitResult.BeforeContentInfo

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
            # NEW: Detailed Image Pull Analysis fields (defaults - pod never became ready)
            ImageDigest           = "N/A"
            TotalLayers           = 0
            CachedLayers          = $null
            MissingLayers         = $null
            DownloadedLayers      = $null
            CacheStatus           = "N/A"
            LayerDataSource       = "Unavailable"
            LayerUnavailableReason = "Replacement pod never became ready - nothing to analyze."
            LayerDetails          = @()
        })
        continue
    }

    # NEW: fallback node lookup, only needed if Wait-ForNewPodReady couldn't
    # resolve the node itself (e.g. -DetailedImagePullAnalysis was off, so it
    # never bothered polling for one). This is purely for the report's Node
    # column when detailed analysis wasn't requested - it plays no part in
    # the cache comparison either way.
    if (-not $newNodeName) {
        $afterJson = kubectl get pod $newPodName -n $Namespace -o json 2>$null | ConvertFrom-Json
        $newNodeName = if ($afterJson -and $afterJson.spec.nodeName) { $afterJson.spec.nodeName } else { "N/A" }
    }
    if ($newNodeName -ne $nodeName) {
        Write-Host "    Replacement pod landed on a different node: '$nodeName' -> '$newNodeName' (expected/valid - the cache comparison below uses '$newNodeName''s own before/after snapshots, not the old node)" -ForegroundColor DarkYellow
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

    # MODIFIED: Detailed Image Pull Analysis
    # Node containerd (the pod's actual node, $newNodeName) is now the PRIMARY
    # source, run only when the user opts in with -DetailedImagePullAnalysis
    # (needs elevated 'kubectl debug node' access and costs real time across a
    # 335-node fleet). The registry manifest is used only as a secondary
    # fallback when the node-side lookup itself is unavailable or wasn't
    # requested - it is never required and its failure (private registry,
    # anonymous access rejected) never fails this analysis.
    Write-Host "    Analyzing image pull ($(if ($DetailedImagePullAnalysis) { 'node containerd (primary)' } else { 'event-based only' }))..." -ForegroundColor Gray
    $imgAnalysis = Get-ImagePullAnalysis `
        -Image $imageName `
        -BeforeNodeName $newNodeName `
        -BeforeContentInfo $beforeNodeContent `
        -AfterNodeName $newNodeName `
        -ImageCachedFromEvents $lc.ImageCached `
        -MeasuredPullTimeSeconds $lc.ImagePullTime `
        -RunDetailedAnalysis:$DetailedImagePullAnalysis `
        -DebugPodNamespace $DebugPodNamespace `
        -TimeoutSeconds $RegistryTimeoutSeconds

    if ($imgAnalysis.TotalLayers -gt 0) {
        Write-Host "      Image Layers    : $($imgAnalysis.CachedLayers)/$($imgAnalysis.TotalLayers) cached ($($imgAnalysis.CacheStatus)) [$($imgAnalysis.LayerDataSource)]" -ForegroundColor DarkCyan
    } else {
        Write-Host "      Image Layers    : unavailable ($($imgAnalysis.LayerUnavailableReason))" -ForegroundColor DarkGray
    }

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
        NodeName              = $newNodeName
        Events                = $lc.RawEvents
        # NEW: Detailed Image Pull Analysis fields
        ImagePullStartedAt     = $lc.PullingStarted
        ImagePulledAt          = $lc.ImagePulled
        ImageDigest            = $imgAnalysis.Digest
        TotalLayers            = $imgAnalysis.TotalLayers
        CachedLayers           = $imgAnalysis.CachedLayers
        MissingLayers          = $imgAnalysis.MissingLayers
        DownloadedLayers       = $imgAnalysis.DownloadedLayers
        CacheStatus            = $imgAnalysis.CacheStatus
        LayerDataSource        = $imgAnalysis.LayerDataSource
        LayerUnavailableReason = $imgAnalysis.LayerUnavailableReason
        LayerDetails           = $imgAnalysis.LayerDetails
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

$successResults = @($results | Where-Object { $_.Status -eq "Success" })
$failedResults  = @($results | Where-Object { $_.Status -ne "Success" })

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
            <td class="col-bold">$(Format-Seconds $r.ContainerStartTime)</td>
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
    $cacheId = "cache-$runId-$rowIndex"

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

    # NEW: Container Start -> Ready = Container Start duration + Readiness duration.
    # These are stage DURATIONS (not timestamps), so the combined elapsed time from
    # the beginning of Container Start until the container becomes Ready is a simple
    # sum of the two existing measured durations - never re-derived from timestamps,
    # and never just the Readiness duration alone.
    $csrTime = $r.ContainerStartTime + $r.ReadinessTime

    $hasEvents = ($r.Events -and $r.Events.Count -gt 0)
    $eventBtn = if ($hasEvents) {
        "<button class=`"evt-toggle`" onclick=`"toggleEvents('$rowId')`">&#128269; $($r.Events.Count) events</button>"
    } else {
        '<span class="evt-none">no events</span>'
    }

    # NEW: Cache toggle button - only rendered when this row actually has
    # image-pull/cache analysis data to show (Status Success and a resolved
    # image name). This mirrors the event button's "only show when there's
    # something to show" pattern and never fabricates a panel for rows with
    # nothing to display. The id ($cacheId) is generated using the SAME
    # per-row index as the event button/panel above, and the matching panel
    # is built later in the $imagePullPanels loop using this identical
    # "cache-$runId-$rowIndex" scheme so the two stay correctly paired.
    $hasCacheData = ($r.Status -eq "Success" -and $r.ImageName -and $r.ImageName -ne "N/A")
    $cacheBtn = if ($hasCacheData) {
        "<button class=`"cache-toggle`" onclick=`"toggleCache('$cacheId')`">&#128451; Cache</button>"
    } else {
        ""
    }

    $lifecycleRows += @"
        <tr$failedRow>
            <td class="svc-name">$($r.ServiceName) $cachedBadge<br/>$eventBtn$cacheBtn</td>
            <td class="$scSched stage-cell">$(Format-Seconds $r.SchedulingTime)</td>
            <td class="$scImg   stage-cell">$(Format-Seconds $r.ImagePullTime)</td>
            <td class="$scIstio stage-cell">$(Format-Seconds $r.IstioImagePullTime)</td>
            <td class="$scCCr   stage-cell">$(Format-Seconds $r.ContainerCreationTime)</td>
            <td class="$scCSt   stage-cell col-bold">$(Format-Seconds $r.ContainerStartTime)</td>
            <td class="$scReady stage-cell">$(Format-Seconds $r.ReadinessTime)</td>
            <td class="stage-cell stage-other" title="Small bits of time between the 6 tracked steps that don't belong to any one step specifically. Already included in Total Ready Time.">$(Format-Seconds $r.OtherEventsTime)</td>
            <td class="$totalClass total-cell">$(Format-Seconds $r.TotalTimeToReady)</td>
            <td class="csr-cell"><strong>$(Format-Seconds $csrTime)</strong></td>
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
            <td class="stage-cell col-bold">$(Format-Seconds $avgCSt)</td>
            <td class="stage-cell">$(Format-Seconds $avgReady)</td>
            <td class="stage-cell">$(Format-Seconds $avgOther)</td>
            <td class="total-cell">$(Format-Seconds $avgTotal)</td>
            <td class="csr-cell"><strong>$(Format-Seconds ($avgCSt + $avgReady))</strong></td>
            <td colspan="7"></td>
        </tr>
"@

# -- NEW: Image Pull Detailed Analysis panels ---------------------
function Get-CacheStatusBadgeClass {
    param([string]$Status)
    if ($Status -match '^Fully Cached')     { return 'full' }
    if ($Status -match '^Partially Cached') { return 'partial' }
    if ($Status -match '^Not Cached')       { return 'none' }
    return 'unknown'
}

function Get-DataSourceTagHtml {
    param([string]$Source)
    if ($Source -match '^Measured') { return '<span class="data-source-tag measured">Measured</span>' }
    if ($Source -match '^Derived')  { return '<span class="data-source-tag derived">Derived</span>' }
    return '<span class="data-source-tag unavailable">Unavailable</span>'
}

# MODIFIED: this loop now increments $imgRowIndex on EVERY iteration over
# $results (success or not), in lock-step with the $rowIndex counter used in
# the lifecycle-rows loop above, so "cache-$runId-$imgRowIndex" always
# resolves to the SAME id the cache-toggle button in that row was given -
# even though rows without cache data are skipped here and never get a panel.
# Each qualifying card is now wrapped in a hidden (display:none) .cache-panel
# with its own header + close button, exactly mirroring the existing
# .event-panel pattern, instead of being rendered permanently visible.
$imagePullPanels = ""
$imgRowIndex = 0
foreach ($r in $results) {
    $imgRowIndex++
    if ($r.Status -ne "Success" -or -not $r.ImageName -or $r.ImageName -eq "N/A") { continue }

    $cacheId = "cache-$runId-$imgRowIndex"

    $badgeClass  = Get-CacheStatusBadgeClass $r.CacheStatus
    $sourceTag   = Get-DataSourceTagHtml $r.LayerDataSource
    $digestDisp  = if ($r.ImageDigest) { $r.ImageDigest } else { "Unavailable" }
    $pullingStr  = if ($r.ImagePullStartedAt) { $r.ImagePullStartedAt.ToString("HH:mm:ss") } else { "-" }
    $pulledStr   = if ($r.ImagePulledAt)      { $r.ImagePulledAt.ToString("HH:mm:ss") }      else { "-" }

    # Layer summary block - only rendered with real numbers when we have them;
    # otherwise an honest "not available" explanation, never a fabricated split.
    if ($r.TotalLayers -gt 0 -and $null -ne $r.CachedLayers) {
        $missingDisp = if ($null -ne $r.MissingLayers) { $r.MissingLayers } else { "?" }
        $downloadDisp = if ($null -ne $r.DownloadedLayers) { $r.DownloadedLayers } else { "?" }
        $layerSummaryHtml = @"
                <table class="layer-summary-table">
                    <tr><td>Total Layers</td><td class="lv">$($r.TotalLayers)</td></tr>
                    <tr><td>Cached Layers</td><td class="lv">$($r.CachedLayers)</td></tr>
                    <tr><td>Missing Layers</td><td class="lv">$missingDisp</td></tr>
                    <tr><td>Downloaded Layers</td><td class="lv">$downloadDisp</td></tr>
                    <tr><td>Cache Status</td><td class="lv"><span class="cache-status-badge $badgeClass">$($r.CacheStatus)</span></td></tr>
                </table>
"@
    } elseif ($r.TotalLayers -gt 0) {
        # We know total layers (registry manifest resolved, or node manifest
        # resolved but correlation unverified) but not the cached/downloaded split
        $layerSummaryHtml = @"
                <table class="layer-summary-table">
                    <tr><td>Total Layers</td><td class="lv">$($r.TotalLayers)</td></tr>
                    <tr><td>Cached / Downloaded split</td><td class="lv">Unavailable</td></tr>
                    <tr><td>Cache Status</td><td class="lv"><span class="cache-status-badge $badgeClass">$($r.CacheStatus)</span></td></tr>
                </table>
                <div class="unavailable-box" style="margin-top:8px">
                    <strong>Why no cached/downloaded split:</strong> $($r.LayerUnavailableReason)
                </div>
"@
    } else {
        $layerSummaryHtml = @"
                <div class="unavailable-box">
                    <strong>Detailed Runtime Breakdown: Not Available</strong><br/><br/>
                    Reason: $($r.LayerUnavailableReason)<br/><br/>
                    Still available: Total Image Pull Time = Pulled - Pulling, measured directly from Kubernetes Events
                    (shown above as <strong>$(Format-Seconds $r.ImagePullTime)</strong>).
                </div>
"@
    }

    # Layer-by-layer table - only when we actually have per-layer node data
    # (requires -DetailedImagePullAnalysis, a working node debug check, AND a
    # verified digest correlation - see Get-NodeLayerCacheAnalysis). No
    # timings are invented per layer - only Cached/Downloaded status, which is
    # the one thing the containerd content-store check can actually tell us
    # once correlation is proven.
    $layerTableHtml = ""
    if ($r.LayerDetails -and $r.LayerDetails.Count -gt 0) {
        $layerRowsHtml = ""
        foreach ($ld in $r.LayerDetails) {
            $statusClass = if ($ld.Status -eq "Cached") { "layer-status-cached" } else { "layer-status-downloaded" }
            $layerRowsHtml += "<tr><td>Layer $($ld.Index)</td><td>$($ld.Digest)</td><td class=`"$statusClass`">$($ld.Status)</td></tr>`n"
        }
        $layerTableHtml = @"
                <table class="layer-table">
                    <thead><tr><th>Layer</th><th>Digest</th><th>Status</th></tr></thead>
                    <tbody>
$layerRowsHtml
                    </tbody>
                </table>
"@
    }

    # Stage breakdown - ALWAYS unavailable in this script; shown once per card
    # rather than fabricated.
    $stageBreakdownHtml = @"
                <div class="unavailable-box">
                    <strong>Detailed Pull Stage Timing: Unavailable</strong><br/><br/>
                    Stages that would make up this breakdown (Registry/Connection, Auth, Manifest Resolution/Fetch,
                    Layer Cache Check, Layer Download, Layer Verification, Layer Unpack, Finalization) are not exposed
                    by Kubernetes Events, the Kubernetes API, or containerd's `ctr` tool. Kubernetes Events only expose
                    Pulling/Pulled timestamps (and, when present, kubelet's total pull duration). That level of
                    sub-stage detail only exists (if at all) in node-local containerd traces/metrics, which this
                    script does not have access to - so it is not queried, and no split is fabricated.<br/><br/>
                    What IS measured: <strong>Total Image Pull Time = $(Format-Seconds $r.ImagePullTime)</strong>
                    (Pulled timestamp minus Pulling timestamp / kubelet-reported duration).
                </div>
"@

    # MODIFIED: the .img-card is now wrapped in a hidden .cache-panel, with
    # its own header (service name + close button), toggled open/closed by
    # the .cache-toggle button rendered next to the events button above -
    # exactly mirroring how .event-panel wraps the Raw Kubernetes Events
    # table. The .img-card's own internal markup/content is unchanged.
    $imagePullPanels += @"
    <div class="cache-panel" id="$cacheId" style="display:none">
        <div class="cache-panel-header">
            <span>&#128451; Image Pull / Cache Details &mdash; <strong>$($r.ServiceName)</strong> ($($r.NewPod))</span>
            <button class="cache-close" onclick="toggleCache('$cacheId')">&times; Close</button>
        </div>
    <div class="img-card">
        <div class="img-card-header">
            <div class="svc">$($r.ServiceName) <span class="cache-status-badge $badgeClass">$($r.CacheStatus)</span> $sourceTag</div>
            <div class="small mono">Pod: $($r.NewPod)</div>
        </div>
        <div class="img-card-body">
            <div class="img-meta">
                <div><strong>Image:</strong> <span class="mono">$($r.ImageName)</span></div>
                <div><strong>Digest:</strong> <span class="mono">$digestDisp</span></div>
                <div><strong>Node:</strong> $($r.NodeName)</div>
                <div><strong>Pulling:</strong> $pullingStr &nbsp;&nbsp; <strong>Pulled:</strong> $pulledStr</div>
                <div><strong>Total Image Pull Time:</strong> $(Format-Seconds $r.ImagePullTime)</div>
            </div>
            <div>
                <div class="small" style="margin-bottom:6px;font-weight:700;color:#6b7280">LAYER SUMMARY</div>
$layerSummaryHtml
$layerTableHtml
            </div>
            <div style="flex:1;min-width:280px">
                <div class="small" style="margin-bottom:6px;font-weight:700;color:#6b7280">STAGE BREAKDOWN</div>
$stageBreakdownHtml
            </div>
        </div>
    </div>
    </div>
"@
}

if (-not $imagePullPanels) {
    $imagePullPanels = '<div class="table-wrap"><div class="section-sub">No successful pod replacements this run - nothing to analyze.</div></div>'
}

$htmlContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>[$ClusterLabel] Pod Readiness Benchmark</title>
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
        .csr-cell    { font-family: 'Consolas', monospace; font-size: 13px; font-weight: 800; white-space: nowrap; color: #7c3aed; text-align: right; }

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

        /* Requirement #1: Container Start column (header + all values) bold */
        .col-bold, .col-bold * { font-weight: 800 !important; }

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

        /* -- NEW: Cache toggle / panel (mirrors Event toggle / panel) -- */
        .cache-toggle {
            margin-top: 4px; margin-left: 4px; font-size: 10px; font-weight: 600;
            background: #ecfdf5; color: #059669; border: 1px solid #a7f3d0;
            border-radius: 5px; padding: 3px 8px; cursor: pointer;
        }
        .cache-toggle:hover { background: #d1fae5; }

        .cache-panel {
            margin: 0 40px 18px; background: #fff; border: 1px solid #e2e8f0;
            border-radius: 10px; overflow: hidden; box-shadow: 0 4px 16px rgba(0,0,0,0.10);
        }
        .cache-panel-header {
            display: flex; justify-content: space-between; align-items: center;
            padding: 12px 18px; background: #f0fdf9; color: #065f46; font-size: 12px;
            border-bottom: 1px solid #a7f3d0;
        }
        .cache-close {
            background: transparent; border: 1px solid #6ee7b7; color: #059669;
            border-radius: 5px; padding: 3px 10px; font-size: 11px; cursor: pointer;
        }
        .cache-close:hover { background: #d1fae5; }

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

        /* -- NEW: Image Pull Detailed Analysis ------------------ */
        .img-card {
            background: #fff; border: 1px solid #e2e8f0; border-radius: 10px;
            margin: 0 40px 20px; box-shadow: 0 1px 4px rgba(0,0,0,0.06); overflow: hidden;
        }
        .img-card-header {
            display: flex; flex-wrap: wrap; justify-content: space-between; align-items: center;
            gap: 8px; padding: 14px 20px; background: #f8fafc; border-bottom: 1px solid #e2e8f0;
        }
        .img-card-header .svc { font-size: 14px; font-weight: 800; color: #1e293b; }
        .img-card-body { padding: 16px 20px; display: flex; flex-wrap: wrap; gap: 24px; }
        .img-meta { font-size: 11px; color: #6b7280; line-height: 1.9; min-width: 260px; }
        .img-meta strong { color: #1e293b; }
        .img-meta .mono { font-family: 'Consolas', monospace; word-break: break-all; }

        .cache-status-badge {
            display: inline-block; padding: 3px 10px; border-radius: 12px;
            font-size: 10px; font-weight: 800; text-transform: uppercase; letter-spacing: 0.03em;
        }
        .cache-status-badge.full    { background: #d1fae5; color: #065f46; }
        .cache-status-badge.partial { background: #fef3c7; color: #92400e; }
        .cache-status-badge.none    { background: #fee2e2; color: #991b1b; }
        .cache-status-badge.unknown { background: #e2e8f0; color: #475569; }

        .data-source-tag {
            display: inline-block; padding: 1px 7px; border-radius: 4px;
            font-size: 9px; font-weight: 700; text-transform: uppercase; margin-left: 6px;
        }
        .data-source-tag.measured   { background: #dbeafe; color: #1d4ed8; }
        .data-source-tag.derived   { background: #ede9fe; color: #6d28d9; }
        .data-source-tag.unavailable { background: #f1f5f9; color: #94a3b8; }

        .layer-summary-table { border-collapse: collapse; font-size: 11px; }
        .layer-summary-table td { padding: 3px 14px 3px 0; }
        .layer-summary-table td.lv { font-weight: 700; color: #1e293b; text-align: right; }

        .unavailable-box {
            background: #f8fafc; border: 1px dashed #cbd5e1; border-radius: 8px;
            padding: 12px 16px; font-size: 11px; color: #64748b; line-height: 1.6; max-width: 520px;
        }
        .unavailable-box strong { color: #475569; }

        .layer-table { width: 100%; max-width: 520px; border-collapse: collapse; font-size: 11px; }
        .layer-table th { text-align: left; padding: 5px 10px; background: #f8fafc; color: #6b7280; font-size: 9px; text-transform: uppercase; }
        .layer-table td { padding: 4px 10px; border-bottom: 1px solid #f1f5f9; font-family: 'Consolas', monospace; }
        .layer-table td.layer-status-cached     { color: #10b981; font-weight: 700; font-family: inherit; }
        .layer-table td.layer-status-downloaded { color: #f59e0b; font-weight: 700; font-family: inherit; }
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

        // NEW: separate toggle function for the Cache panel, mirroring
        // toggleEvents exactly. Kept as its own function (rather than reused)
        // so the existing event-toggle behavior above is never touched.
        function toggleCache(id) {
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
        <span><strong>Cluster:</strong> $ClusterLabel</span>
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
    <div class="section-sub">Time spent in each stage from pod creation to ready. <span style="color:#ef4444;font-weight:700">Red</span> = &gt;25% above average &nbsp;|&nbsp; <span style="color:#10b981;font-weight:700">Green</span> = &gt;25% below average. Click &#128269; on a service to inspect its raw Kubernetes events, or &#128451; to inspect its image cache details.</div>
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
                <th class="hdr-stage" colspan="9">Stage Durations</th>
                <th class="hdr-bar"   colspan="7">Proportion of Total Ready Time</th>
            </tr>
            <tr class="sub-hdr">
                <th class="hdr-stage" style="text-align:right">1. Scheduling</th>
                <th class="hdr-stage" style="text-align:right">2. Image Pull</th>
                <th class="hdr-stage" style="text-align:right">3. Istio Pull</th>
                <th class="hdr-stage" style="text-align:right">4. Ctr Create</th>
                <th class="hdr-stage col-bold" style="text-align:right">5. Ctr Start</th>
                <th class="hdr-stage" style="text-align:right">6. Readiness</th>
                <th class="hdr-stage" style="text-align:right">Other Events</th>
                <th class="hdr-stage" style="text-align:right">Total Ready Time</th>
                <th class="hdr-stage" style="text-align:right;border-right:none">Container Start &rarr; Ready</th>
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

$imagePullPanels

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
                <th class="col-bold">Container Start</th>
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