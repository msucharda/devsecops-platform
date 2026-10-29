#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $ToolsPath,
    [Parameter(Mandatory)][string] $WorkPath,
    [Parameter(Mandatory)][string] $ModulesPath,
    [Parameter(Mandatory)][ValidateSet('BeforePublish', 'AfterPublish')][string] $Boundary,
    [Parameter(Mandatory)][ValidateSet('Error', 'Abrupt')][string] $Termination
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $ToolsPath 'InstanceSetup.psm1') -Force
# Instrument only this child's in-memory function; the production files and publication operations stay intact.
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $ToolsPath 'InstanceSetup.ManualSteps.ps1'), [ref] $null, [ref] $null)
$definition = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Save-SetupManualProgress'
}, $true)
$publication = $definition.Body.Find({
    param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Extent.Text.StartsWith('if ([IO.File]::Exists($Path))', [StringComparison]::Ordinal)
}, $true)
if ($null -eq $publication) { throw 'The atomic publication boundary could not be located.' }
$offset = if ($Boundary -ceq 'BeforePublish') { $publication.Extent.StartOffset } else { $publication.Extent.EndOffset }
$fault = if ($Termination -ceq 'Abrupt') { '[Environment]::Exit(77)' } else { "throw 'Injected publication interruption.'" }
$injection = @'

if ($State['steps']['application/verify-access']['status'] -ceq 'Confirmed') { __FAULT__ }

'@
$instrumented = $definition.Extent.Text.Insert(
    ($offset - $definition.Extent.StartOffset), $injection.Replace('__FAULT__', $fault))
$instrumented = $instrumented.Replace('function Save-SetupManualProgress', 'function script:Save-SetupManualProgress')
& (Get-Module InstanceSetup) {
    param($Definition)
    . ([scriptblock]::Create($Definition))
    $script:InterruptionAnswers = [Collections.Generic.Queue[string]]::new()
    $script:InterruptionAnswers.Enqueue('demo')
    $script:InterruptionAnswers.Enqueue('y')
    function script:Read-Host {
        [CmdletBinding()]
        param([string] $Prompt)
        if ($script:InterruptionAnswers.Count -eq 0) { throw "Unexpected prompt: $Prompt" }
        return $script:InterruptionAnswers.Dequeue()
    }
} $instrumented
try {
    $null = Invoke-InstanceSetup -RepoPath (Split-Path $ToolsPath -Parent) -WorkPath $WorkPath -ModulesPath $ModulesPath `
        -Phase ManualSteps -ManualStep 'application/verify-access'
}
catch {
    if ($_.Exception.Message -cne 'Injected publication interruption.') { throw }
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    exit 78
}
throw 'The requested publication interruption did not occur.'
