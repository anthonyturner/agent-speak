# What the speech text clean-up does to issue and pull request references. Loads
# only the two functions under test, so nothing is spoken and no state is touched.
$ErrorActionPreference = 'Stop'
$speak = Join-Path $PSScriptRoot 'speak.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($speak, [ref]$null, [ref]$null)
$wanted = 'Remove-WorkItemNumbers', 'Convert-ToSpeech'
$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $wanted -contains $n.Name }, $false) |
    ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }

$failed = 0
function Assert-Heard([string]$given, [string]$expected, [switch]$Light) {
    $actual = if ($Light) { Convert-ToSpeech (Remove-WorkItemNumbers $given) -Light } else { Convert-ToSpeech $given }
    if ($actual -cne $expected) {
        Write-Output "FAIL: '$given'`n  expected '$expected'`n  got      '$actual'"
        $script:failed++
    }
}

# the two forms the rule was written against
Assert-Heard 'Issue 454, hero page three columns' 'hero page three columns' -Light
Assert-Heard '#465, Load YouTube players' 'Load YouTube players'
# at the end of a label, in a list, in brackets, or as a link
Assert-Heard 'Rivals Pulse, hotkey cut, issue 1258' 'Rivals Pulse, hotkey cut' -Light
Assert-Heard 'RivalsPulse real build signals, issues 1283 and 1161' 'RivalsPulse real build signals' -Light
Assert-Heard 'Fixes the mixer (#32).' 'Fixes the mixer.'
Assert-Heard '[#123](https://example.test/1) done' 'done'
Assert-Heard '- #12, #13 and #14: saved filters' 'saved filters'
Assert-Heard 'Pull request 1184: roster band merged.' 'roster band merged.' -Light
Assert-Heard 'PR #7 is merged.' 'is merged.' -Light
# nothing left to say
Assert-Heard 'Issue 5.' '' -Light
# numbers that are not references, and real headings
Assert-Heard 'All 2 tests pass on version 3, and 12 issues remain.' 'All 2 tests pass on version 3, and 12 issues remain.' -Light
Assert-Heard 'C#12 and &#123; stay' 'C#12 and &#123; stay' -Light
Assert-Heard "## Summary`n`nIt works" "Summary`n`nIt works"

if ($failed) { Write-Output "$failed failed"; exit 1 }
Write-Output 'speech text: all passed'
