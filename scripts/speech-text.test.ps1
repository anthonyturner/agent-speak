# What the speech text clean-up does to issue and pull request references. Loads
# only the functions under test, so nothing is spoken and no state is touched.
$ErrorActionPreference = 'Stop'
$speak = Join-Path $PSScriptRoot 'speak.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($speak, [ref]$null, [ref]$null)
$wanted = 'Remove-WorkItemNumbers', 'Convert-SpokenLine', 'Convert-ToSpeech', 'Get-SessionLabel'
$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $wanted -contains $n.Name }, $false) |
    ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }

$failed = 0
function Assert-Same([string]$given, [string]$expected, [string]$actual) {
    if ($actual -cne $expected) {
        Write-Output "FAIL: '$given'`n  expected '$expected'`n  got      '$actual'"
        $script:failed++
    }
}
function Assert-Spoken([string]$given, [string]$expected) { Assert-Same $given $expected (Convert-SpokenLine $given) }
function Assert-Read([string]$given, [string]$expected) { Assert-Same $given $expected (Convert-ToSpeech $given) }

# the two forms the rule was written against
Assert-Spoken 'Issue 454, hero page three columns' 'hero page three columns'
Assert-Read '#465, Load YouTube players' 'Load YouTube players'

# at the end of a label, in brackets, or as a link
Assert-Spoken 'Rivals Pulse, hotkey cut, issue 1258' 'Rivals Pulse, hotkey cut'
Assert-Read 'Fixes the mixer (#32).' 'Fixes the mixer.'
Assert-Read '[#123](https://example.test/1) done' 'done'
Assert-Spoken 'Pull request 1184: roster band merged.' 'roster band merged.'
Assert-Spoken 'PR #7 is merged.' 'is merged.'

# lists
Assert-Spoken 'RivalsPulse real build signals, issues 1283 and 1161' 'RivalsPulse real build signals'
Assert-Spoken 'Issues 12, 13 and 14 are done' 'are done'
Assert-Spoken 'issues #12, 13 and #14 done' 'done'
Assert-Spoken 'Issues 12-14 are done' 'are done'
Assert-Read '- #12, #13 and #14: saved filters' 'saved filters'
Assert-Spoken 'PR #38 and issue #37 are ready' 'are ready'
Assert-Spoken 'issue 12 / PR 13 ready' 'ready'
Assert-Read 'Fix the mixer (issue 12, PR 13).' 'Fix the mixer.'

# attached forms
Assert-Spoken 'PR#38 is merged' 'is merged'
Assert-Spoken 'Issue#38 is fixed' 'is fixed'
Assert-Spoken 'PR-38 is merged' 'is merged'
Assert-Spoken 'web#127 is merged' 'is merged'

# what surrounds a reference goes with it
Assert-Read '**#465**, Load' 'Load'
Assert-Spoken 'Issue #454''s title is clear' 'title is clear'
Assert-Read "It works.`n`nCloses #37" 'It works.'

# nothing left to say
Assert-Spoken 'Issue 5.' ''

# counts stay, even right after a reference
Assert-Spoken 'All 2 tests pass on version 3, and 12 issues remain.' 'All 2 tests pass on version 3, and 12 issues remain.'
Assert-Spoken '12 issues, 3 PRs' '12 issues, 3 PRs'
Assert-Spoken 'PR 12 and 3 tests pass' 'and 3 tests pass'
Assert-Spoken 'Merged #12 and 3 more are waiting' 'Merged and 3 more are waiting'
Assert-Spoken 'Fixed issue 7 or 8 files changed' 'Fixed or 8 files changed'
Assert-Spoken 'Merged the PR 2 days ago' 'Merged the PR 2 days ago'
Assert-Spoken 'I saw the issue 3 times' 'I saw the issue 3 times'

# other uses of the hash stay, and so do real headings
Assert-Spoken 'C#12 and &#123; stay' 'C#12 and &#123; stay'
Assert-Spoken 'You are ranked #1 today' 'You are ranked #1 today'
Assert-Spoken 'This is the #1 priority' 'This is the #1 priority'
Assert-Spoken 'Now do step #3' 'Now do step #3'
Assert-Read "## Summary`n`nIt works" "Summary`n`nIt works"

# linked hashes, every list separator, and a number right after a reference
$enDash = [string][char]0x2013
Assert-Spoken '#12/#13 are done' 'are done'
Assert-Spoken '#12-#14 are done' 'are done'
Assert-Spoken 'issue 12 and 13 are done' 'are done'
Assert-Spoken '#12 and 13 are merged' 'are merged'
Assert-Spoken "Issues 12$($enDash)14 are done" 'are done'
Assert-Spoken 'issues 12/13 done' 'done'
Assert-Spoken 'issue 12/13 done' 'done'
Assert-Spoken 'issues 12, 13, or 14 are next' 'are next'
Assert-Spoken 'Issues 12 through 14 are done' 'are done'
Assert-Spoken 'PR 38 tests pass' 'tests pass'
Assert-Spoken 'Issue 1258 tests pass' 'tests pass'
Assert-Spoken 'PR 38 of agent-speak is merged' 'of agent-speak is merged'
Assert-Spoken 'PR-38 tests pass' 'tests pass'

# a word before the number that shows it is a count
Assert-Spoken 'Fixed the issue 3 users reported' 'Fixed the issue 3 users reported'
Assert-Spoken 'Merged the PR 2 reviewers approved' 'Merged the PR 2 reviewers approved'
Assert-Spoken 'the PR 10 comments' 'the PR 10 comments'
Assert-Spoken '12 issues 3 PRs' '12 issues 3 PRs'
Assert-Spoken 'Closed 5 issues and 3 PRs' 'Closed 5 issues and 3 PRs'

# names and ranks stay
Assert-Spoken 'Tony#1234 joined' 'Tony#1234 joined'
Assert-Spoken 'the #1 hero' 'the #1 hero'
Assert-Spoken 'Option #2 is better' 'Option #2 is better'

# text passed to the speak command is left as written
Assert-Same 'explicit text' 'Issue 5 is done' (Convert-ToSpeech 'Issue 5 is done' -Light)

# session labels, from the speak command and from the stored file
$Preamble = 'Issue 1258, hotkey cut'
Assert-Same 'preamble label' 'hotkey cut' (Get-SessionLabel '')
$Preamble = ''
$LabelRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('speech-text-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $LabelRoot | Out-Null
try {
    function Get-SessionIdFor([string]$transcript) { 'session' }
    Set-Content -LiteralPath (Join-Path $LabelRoot 'session.txt') -Value 'Issue 454, hero page' -Encoding UTF8
    Assert-Same 'stored label' 'hero page' (Get-SessionLabel '')
} finally {
    Remove-Item -LiteralPath $LabelRoot -Recurse -Force
}

if ($failed) { Write-Output "$failed failed"; exit 1 }
Write-Output 'speech text: all passed'
