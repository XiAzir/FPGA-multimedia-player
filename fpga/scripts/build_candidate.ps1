param([ValidateSet('synthesis','physical','hold','bitstream')] [string]$Stage='synthesis')
. (Join-Path $PSScriptRoot '../../tools/anlu_tools.ps1')
# Use this wrapper as the delivery entry point; invoking TD Tcl scripts directly bypasses stage evidence gates.
$ErrorActionPreference='Stop'
$taskRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$taskTool = Resolve-AnluTool -Name 'td_commands_prompt'
$taskOutput=Join-Path $taskRoot 'build\manual'
New-Item -ItemType Directory -Force -Path $taskOutput | Out-Null
. (Join-Path $PSScriptRoot 'build_evidence.ps1')
$taskSourceRoot=Join-Path $taskRoot 'src'
# Configure the TD project root for this checkout before taking source evidence.
$taskLocalProject=Join-Path $taskSourceRoot 'td_project/AC201_tf_hdmi.al'
Restore-AnluProjectLocation $taskLocalProject ((Split-Path -Parent $taskLocalProject).Replace('\','/'))
$taskFiles=@(Get-ChildItem -LiteralPath (Join-Path $taskSourceRoot 'user_source') -Recurse -Force -File)
$taskFiles+=Get-Item -LiteralPath (Join-Path $taskSourceRoot 'td_project/AC201_tf_hdmi.al')
$taskFiles+=Get-ChildItem -LiteralPath (Join-Path $taskSourceRoot 'td_project/al_ip') -Recurse -File
$taskScope=@($taskFiles | Sort-Object FullName | ForEach-Object {
    [ordered]@{path=[IO.Path]::GetRelativePath($taskSourceRoot,$_.FullName);sha256=(Get-FileHash -LiteralPath $_.FullName).Hash}
})
$taskScopePath=Join-Path $taskOutput 'build_source_scope.json'
if($Stage -ne 'synthesis') {
    if(!(Test-Path -LiteralPath $taskScopePath)) { throw 'No successful synthesis source snapshot' }
    $taskPrevious=@(Get-Content -Raw -LiteralPath $taskScopePath | ConvertFrom-Json)
    if(($taskPrevious | ConvertTo-Json -Compress) -ne ($taskScope | ConvertTo-Json -Compress)) {
        throw 'Sources changed since synthesis; rebuild before proceeding'
    }
}
if($Stage -eq 'bitstream') {
    $taskTiming=Get-Content -Raw -LiteralPath (Join-Path $taskOutput 'AC201_tf_hdmi_phy.ts')
    $taskMatch=[regex]::Match($taskTiming,'SWNS:\s*([-\d.]+)ns, STNS:\s*([-\d.]+)ns\.\s*HWNS:\s*([-\d.]+)ns, HTNS:\s*([-\d.]+)ns\.')
    if(!$taskMatch.Success) { throw 'Missing recognizable final timing status; do not generate bitstream' }
    foreach($taskGroup in 1..4) {
        if([double]$taskMatch.Groups[$taskGroup].Value -lt 0) { throw 'Timing violation remains; do not generate bitstream' }
    }
}
$taskScript=@{synthesis='build_manual_syn.tcl';physical='build_manual_phy.tcl';hold='fix_hold.tcl';bitstream='generate_bit.tcl'}[$Stage]
$taskMarker=@{synthesis='SYNTHESIS_COMPLETE_WITH_GATE_DATABASE';physical='PLACE_ROUTE_COMPLETE_WITH_REPORTS';hold='POST_ROUTE_HOLD_FIX_COMPLETE';bitstream='BITSTREAM_GENERATED'}[$Stage]
Start-StageEvidence $Stage $taskSourceRoot $PSScriptRoot $taskOutput | Out-Null
if($Stage -eq 'bitstream') {
    $taskOldBit=Join-Path $taskOutput 'AC201_player_c41_museum_osd.bit'
    if(Test-Path -LiteralPath $taskOldBit -PathType Leaf) {
        $taskBitAttempt=Read-StageEvidence $taskOutput 'bitstream'
        $taskSavedBits=Join-Path $taskRoot ('build/stale_bit/'+$taskBitAttempt.runId)
        $taskAbsoluteSaved=[IO.Path]::GetFullPath($taskSavedBits)
        if(!$taskAbsoluteSaved.StartsWith($taskRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {
            throw 'Bit archive escaped candidate workspace'
        }
        New-Item -ItemType Directory -Path $taskSavedBits -Force | Out-Null
        Move-Item -LiteralPath $taskOldBit -Destination $taskSavedBits
    }
}
$taskProjectFile=Join-Path $taskSourceRoot 'td_project/AC201_tf_hdmi.al'
$taskProjectPath=Get-AnluProjectLocation $taskProjectFile
$taskLog=Join-Path $taskOutput ($Stage+'_console.log')
if($Stage -eq 'hold') {
    $preHold=Join-Path $taskOutput 'pre_hold'
    if(Test-Path -LiteralPath $preHold) { throw 'pre_hold evidence already exists; retain this run and use a separate candidate for retries' }
    New-Item -ItemType Directory -Path $preHold | Out-Null
    foreach($name in (Get-RouteArtifacts $taskOutput).Keys) {
        Copy-Item -LiteralPath (Join-Path $taskOutput $name) -Destination $preHold
    }
}
try {
    & $taskTool ((Join-Path $PSScriptRoot $taskScript).Replace('\','/')) *> $taskLog
    $taskExit=$LASTEXITCODE
} finally {
    Restore-AnluProjectLocation $taskProjectFile $taskProjectPath
}
Get-Content -LiteralPath $taskLog -Tail 12
if($Stage -eq 'synthesis' -and (Select-String -LiteralPath $taskLog -Pattern 'HDL-5105' -Quiet)) {
    throw 'Spectrum ROM initialization failed; reject this synthesis even when TD returns success'
}
if($taskExit -ne 0 -or (Select-String -LiteralPath $taskLog -Pattern '^[A-Z]+-\d+\s*(?::\s*)?ERROR:|^ERROR:|Assertion failed|Oops! coredump' -Quiet) -or !(Select-String -LiteralPath $taskLog -SimpleMatch $taskMarker -Quiet)) {
    throw "TD $Stage failed; see $taskLog"
}
Complete-StageEvidence $Stage $taskSourceRoot $PSScriptRoot $taskOutput
if($Stage -eq 'synthesis') {
    $taskScope | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $taskScopePath -Encoding utf8
}









