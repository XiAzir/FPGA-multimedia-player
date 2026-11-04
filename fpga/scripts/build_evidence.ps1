function Get-FileSha256($Path) {
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing build evidence input: $Path" }
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Get-ValueSha256($Value) {
    $json=ConvertTo-Json -InputObject $Value -Depth 20 -Compress
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($json))).ToLowerInvariant()
}
function Get-CurrentEvidenceContext($SourceRoot,$ScriptsRoot) {
    $files=@(Get-ChildItem -LiteralPath (Join-Path $SourceRoot 'user_source') -Recurse -Force -File)
    $files+=Get-Item -LiteralPath (Join-Path $SourceRoot 'td_project/AC201_tf_hdmi.al')
    $files+=Get-ChildItem -LiteralPath (Join-Path $SourceRoot 'td_project/al_ip') -Recurse -Force -File
    $scope=@($files | Sort-Object FullName | ForEach-Object {[ordered]@{path=[IO.Path]::GetRelativePath($SourceRoot,$_.FullName).Replace('\','/');sha256=(Get-FileSha256 $_.FullName)}})
    $tcls=@(Get-ChildItem -LiteralPath $ScriptsRoot -Recurse -Force -File | Where-Object { $_.Extension -in '.tcl','.ps1' } | Sort-Object FullName | ForEach-Object {[ordered]@{path=[IO.Path]::GetRelativePath($ScriptsRoot,$_.FullName).Replace('\','/');sha256=(Get-FileSha256 $_.FullName)}})
    if(!$tcls.Count){throw 'No Tcl build scripts found for evidence'}
    [ordered]@{scopeHash=(Get-ValueSha256 $scope);scriptHash=(Get-ValueSha256 $tcls);scripts=$tcls}
}
function Get-EvidencePath($OutputDir,$Stage) { Join-Path (Join-Path $OutputDir 'stage_evidence') ('latest_'+$Stage+'.json') }
function Read-StageEvidence($OutputDir,$Stage) {
    $p=Get-EvidencePath $OutputDir $Stage
    if(!(Test-Path -LiteralPath $p -PathType Leaf)){throw "Missing $Stage evidence; run its stage through build_candidate.ps1"}
    $latest=Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
    $record=Join-Path (Split-Path -Parent $p) $latest.record
    if(!(Test-Path -LiteralPath $record -PathType Leaf)){throw "Missing $Stage attempt evidence; rerun the stage through build_candidate.ps1"}
    $e=Get-Content -LiteralPath $record -Raw | ConvertFrom-Json -AsHashtable
    if($e.runId -ne $latest.runId -or $e.status -ne $latest.status){throw "Inconsistent $Stage evidence pointer; refusing stale build artifacts"}
    $e
}
function Write-StageEvidence($OutputDir,$Stage,$Evidence) {
    $d=Join-Path $OutputDir 'stage_evidence'; New-Item -ItemType Directory -Force -Path $d | Out-Null
    $recordName=$Stage+'_'+$Evidence.runId+'.json'
    $Evidence | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $d $recordName) -Encoding utf8
    [ordered]@{stage=$Stage;status=$Evidence.status;runId=$Evidence.runId;record=$recordName} | ConvertTo-Json | Set-Content -LiteralPath (Get-EvidencePath $OutputDir $Stage) -Encoding utf8
}
function Assert-Context($Evidence,$Context) {
    if($Evidence.status -ne 'success' -or $Evidence.scopeHash -ne $Context.scopeHash -or $Evidence.scriptHash -ne $Context.scriptHash){throw 'Stage evidence is stale or incomplete; rerun synthesis and physical through build_candidate.ps1'}
    if((Get-ValueSha256 $Evidence.scripts) -ne $Context.scriptHash){throw 'Recorded Tcl script hashes do not match the current build scripts'}
}
function Get-RouteArtifacts($OutputDir) {
    $names=@('AC201_tf_hdmi_pr.db','AC201_tf_hdmi_phy.ts','AC201_tf_hdmi_pr.timing','AC201_tf_hdmi_chk.timing','AC201_tf_hdmi_exception.timing','AC201_tf_hdmi_phy.area','AC201_tf_hdmi_routed.v','strategy_actual.place.log','strategy_actual.route.log')
    $items=[ordered]@{}; foreach($n in $names){$items[$n]=Get-FileSha256 (Join-Path $OutputDir $n)}; $items
}
function Assert-RouteArtifacts($Evidence,$OutputDir,[bool]$RequireCleanTiming=$true) {
    if((Get-ValueSha256 (Get-RouteArtifacts $OutputDir)) -ne (Get-ValueSha256 $Evidence.artifacts)){throw 'Routed database or final report changed since stage evidence was recorded'}
    if(!$RequireCleanTiming){return}
    $timing=Get-Content -LiteralPath (Join-Path $OutputDir 'AC201_tf_hdmi_phy.ts') -Raw
    $m=[regex]::Match($timing,'SWNS:\s*([-\d.]+)ns, STNS:\s*([-\d.]+)ns\.\s*HWNS:\s*([-\d.]+)ns, HTNS:\s*([-\d.]+)ns\.')
    if(!$m.Success){throw 'Missing recognizable final timing status; do not generate bitstream'}
    foreach($i in 1..4){if([double]$m.Groups[$i].Value -lt 0){throw 'Timing violation remains; do not generate bitstream'}}
}
function Start-StageEvidence($Stage,$SourceRoot,$ScriptsRoot,$OutputDir) {
    $ctx=Get-CurrentEvidenceContext $SourceRoot $ScriptsRoot; $syn=$null
    if($Stage -ne 'synthesis') {
        $syn=Read-StageEvidence $OutputDir 'synthesis'; Assert-Context $syn $ctx
        if((Get-FileSha256 (Join-Path $OutputDir 'AC201_tf_hdmi_gate.db')) -ne $syn.gateDbHash){throw 'Gate database does not match the successful synthesis evidence'}
    }
    if($Stage -eq 'hold' -or $Stage -eq 'bitstream') {
        $route=Read-StageEvidence $OutputDir 'physical'; Assert-Context $route $ctx
        if($route.synthesisRunId -ne $syn.runId -or $route.gateDbHash -ne $syn.gateDbHash){throw 'Physical evidence belongs to a different synthesis run'}
        if($Stage -eq 'hold'){Assert-RouteArtifacts $route $OutputDir $false}
    }
    if($Stage -eq 'bitstream') {
        $holdPath=Get-EvidencePath $OutputDir 'hold'; $route=Read-StageEvidence $OutputDir 'physical'
        if(Test-Path -LiteralPath $holdPath -PathType Leaf) {
            $hold=Read-StageEvidence $OutputDir 'hold'
            if($hold.synthesisRunId -eq $syn.runId) {
                Assert-Context $hold $ctx
                if($hold.gateDbHash -ne $syn.gateDbHash){throw 'Hold evidence belongs to a different gate database'}
                Assert-RouteArtifacts $hold $OutputDir; $route=$hold
            }
        }
        if($route.stage -eq 'physical'){Assert-RouteArtifacts $route $OutputDir}
        $receipt=[ordered]@{stage=$Stage;status='running';runId=[guid]::NewGuid().ToString();synthesisRunId=$syn.runId;routeStage=$route.stage;scopeHash=$ctx.scopeHash;scriptHash=$ctx.scriptHash;scripts=$ctx.scripts;gateDbHash=$syn.gateDbHash;startedUtc=[DateTime]::UtcNow.ToString('o')}
    } else {
        $synRunId=$null; $gateDbHash=$null
        if($syn){$synRunId=$syn.runId; $gateDbHash=$syn.gateDbHash}
        $receipt=[ordered]@{stage=$Stage;status='running';runId=[guid]::NewGuid().ToString();synthesisRunId=$synRunId;scopeHash=$ctx.scopeHash;scriptHash=$ctx.scriptHash;scripts=$ctx.scripts;gateDbHash=$gateDbHash;startedUtc=[DateTime]::UtcNow.ToString('o')}
    }
    Write-StageEvidence $OutputDir $Stage $receipt
}
function Complete-StageEvidence($Stage,$SourceRoot,$ScriptsRoot,$OutputDir) {
    $r=Read-StageEvidence $OutputDir $Stage; $ctx=Get-CurrentEvidenceContext $SourceRoot $ScriptsRoot
    if($r.status -ne 'running' -or $r.scopeHash -ne $ctx.scopeHash -or $r.scriptHash -ne $ctx.scriptHash -or (Get-ValueSha256 $r.scripts) -ne $ctx.scriptHash){throw 'Inputs or Tcl scripts changed during the build; stage evidence was not certified'}
    if($Stage -eq 'synthesis') {$r.gateDbHash=Get-FileSha256 (Join-Path $OutputDir 'AC201_tf_hdmi_gate.db')}
    elseif($Stage -eq 'physical' -or $Stage -eq 'hold') {
        $syn=Read-StageEvidence $OutputDir 'synthesis'
        if($syn.status -ne 'success' -or $r.synthesisRunId -ne $syn.runId -or $r.gateDbHash -ne $syn.gateDbHash -or (Get-FileSha256 (Join-Path $OutputDir 'AC201_tf_hdmi_gate.db')) -ne $syn.gateDbHash){throw 'Synthesis evidence changed during the build'}
        $r.artifacts=Get-RouteArtifacts $OutputDir
    } elseif($Stage -eq 'bitstream') {
        $route=Read-StageEvidence $OutputDir $r.routeStage
        Assert-Context $route $ctx
        if($route.synthesisRunId -ne $r.synthesisRunId -or $route.gateDbHash -ne $r.gateDbHash){throw 'Route evidence changed during bitstream generation'}
        Assert-RouteArtifacts $route $OutputDir
        $r.bitHash=Get-FileSha256 (Join-Path $OutputDir 'AC201_player_c41_museum_osd.bit')
    }
    $r.status='success'; $r.completedUtc=[DateTime]::UtcNow.ToString('o'); Write-StageEvidence $OutputDir $Stage $r
}





