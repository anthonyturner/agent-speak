<#
    speak.ps1 - speaks text aloud.

    Two engines, in order of preference:
      1. ElevenLabs neural voices      - needs an API key and a voice id, and the network
      2. Windows SAPI5 (System.Speech) - always there, offline, robotic

    The ElevenLabs path is tried first whenever it is configured. Anything that
    goes wrong with it - no key, no voice, no network, a bad request, a truncated
    download - falls through to SAPI5 without a word, so speech never breaks a turn.

    Five ways in:
      -Mode response   read a Stop-hook payload on stdin, speak the last reply
      -Mode notify     read a Notification-hook payload on stdin, speak the alert
      -Latest          speak the most recent assistant message, no stdin needed
      -TextFile <path> speak the contents of a file verbatim
      -Diag            print the engine configuration and exit, speaking nothing

    Choosing a voice:
      -Voice <id>      use this voice id for this run only, overriding everything below
      -RandomVoice     pick a random voice from the account for this run
    Set $RandomizeVoice below to make randomising permanent. Otherwise $ElevenVoiceId
    is used, and it is also the fallback whenever a random pick cannot be synthesised.

    Picking a voice, as a loop - see what there is, hear one, keep it:
      -Voices               list every voice on the account, marking the one in use
      -PreviewVoice <q>     speak a sample line in that voice, changing nothing
      -SetVoice <q>         make it the default, written to config.json
    <q> is a voice id or any part of a voice name; an ambiguous name lists the
    candidates rather than guessing between them.

    Add -Print to see what would be spoken instead of speaking it.
    Nothing is written to stdout otherwise, so a hook never pollutes the transcript.
#>
param(
    [ValidateSet('response', 'notify')][string]$Mode = 'response',
    [string]$TextFile = '',
    [string]$Voice = '',
    [switch]$Latest,
    [switch]$RandomVoice,
    [switch]$Print,
    [switch]$Diag,
    [switch]$Voices,
    [string]$SetVoice = '',
    [string]$PreviewVoice = '',
    [string]$Preamble = '',
    [switch]$Stop,
    [switch]$Pause,
    [switch]$Resume,
    [switch]$Toggle,
    [switch]$Status,
    [switch]$Forward,
    [switch]$Rewind,
    [int]$StepMs = 0,
    # Supplied by the Stop hook, which receives it directly. Without it the manual
    # paths have to guess the session from whichever transcript was written last,
    # and with two sessions open that guess replays the wrong one.
    [string]$SessionId = ''
)

# ---------------------------------------------------------------- tunables --
# The Stop hook speaks at the end of every turn whether or not it was asked to.
# It no longer reads any part of the response: it speaks the session's handover
# cue instead (see Get-SessionCue). An explicit /speak is a deliberate "read me
# all of it", so that path still reads the whole thing.
#
# $ScopeAuto now applies only to notifications, which have no cue of their own.
$FallbackCue    = 'Response ready.'   # spoken when a turn wrote no cue of its own
# "Play the full response" means the last real answer, not the last thing said.
# Acknowledging a transport control with "Replaying my last response." puts that
# line into the transcript as the newest assistant message, so a second replay
# would read the acknowledgement back instead of the answer - and the more the
# controls are used, the more certain that becomes. Replay therefore skips
# assistant messages shorter than this, falling back to the newest one when every
# candidate is short, so a genuinely brief answer is still replayable.
$MinReplayChars = 400
# 'summary' still applies to notifications, which have no cue of their own. The
# Stop hook does not use it: that path speaks the turn's cue.
$ScopeAuto      = 'summary'
$ScopeManual    = 'full'     # /speak and -Latest: 'summary' or 'full'
$MaxCharsAuto   = 700        # hard cap for notification speech
$MaxCharsManual = 6000       # hard cap for /speak - every character here is billed
$MinChars       = 120        # summary mode: keep adding paragraphs until this is met
$SpeakTables    = $true      # read table rows as "cell, cell, cell" instead of skipping them

$Rate      = 1           # SAPI5 only: -10 (slow) .. 10 (fast)
$Volume    = 90          # SAPI5 only: 0 .. 100
$VoiceName = ''          # SAPI5 only: 'Microsoft David Desktop' / 'Microsoft Zira Desktop'

# -- ElevenLabs ---------------------------------------------------------------
# Put the key in the environment variable named below and set $ElevenVoiceId to a
# voice id from the dashboard. Leave the voice id empty to stay on SAPI5.
# On the free tier the Voice Library is not reachable through the API, so pick one
# of the premade voices.
$UseElevenLabs    = $true
$ElevenKeyVar     = 'ELEVENLABS_API_KEY'
# A premade voice, on purpose. Voice Library voices are not reachable through the
# API on the free tier: the request returns 402 and speech drops to the robotic
# SAPI5 voice with no visible reason, which is a miserable first run for someone
# who has just installed this. Change it in config.json, not here.
$ElevenVoiceId    = '21m00Tcm4TlvDq8ikWAM'  # Rachel, premade - works on every plan
$ElevenModel      = 'eleven_flash_v2_5'  # half price, ~75ms. 'eleven_v3' = best, double cost
$ElevenFormat     = 'wav_24000'          # wav plays natively here. wav_44100 needs Pro tier
$ElevenSpeed      = 1.0                  # 0.7 (slower) .. 1.2 (faster)
$ElevenStability  = 0.5                  # lower = more expressive, higher = more consistent
$ElevenSimilarity = 0.75
$ElevenTimeoutSec = 20

# -- voice randomisation ------------------------------------------------------
# Off by default, so $ElevenVoiceId above is what you normally hear. Flip this to
# $true to get a different voice from the account on every utterance, or pass
# -RandomVoice for a single run. A pick the plan cannot synthesise falls back to
# $ElevenVoiceId rather than to the robotic SAPI5 voice.
$RandomizeVoice   = $false
$AvoidRepeatVoice = $true   # never pick the same voice twice running
$VoiceCacheHours  = 24      # how long the account's voice list is reused before refetching
# -----------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'
# The single most expensive line in this file, by its absence.
#
# Windows PowerShell 5.1 redraws a console progress bar for every chunk that
# Invoke-WebRequest -OutFile writes, and the redraw costs far more than the
# transfer. Measured on one 1500-character request: 44.6 s with the bar,
# 3.1 s without it - the same bytes, fourteen times faster. Nothing is
# rendering that bar anyway, because speech runs in a hidden window.
#
# It was also silently capping how much could ever be spoken: at that rate a
# request longer than roughly 700 characters exceeded $ElevenTimeoutSec, so a
# long reply did not merely lag - it timed out and fell back to the robotic
# SAPI5 voice, with the failure looking like an ElevenLabs problem.
$ProgressPreference = 'SilentlyContinue'
# Everything this tool owns lives in one folder, rather than scattering dotfiles
# through ~/.claude. It sits outside the plugin directory on purpose: a plugin
# update replaces the plugin, and a user's voice choice must survive that.
$StateRoot      = Join-Path $env:USERPROFILE '.claude\agent-speak'
if (-not (Test-Path -LiteralPath $StateRoot)) {
    New-Item -ItemType Directory -Force -Path $StateRoot -ErrorAction SilentlyContinue | Out-Null
}
$configFile     = Join-Path $StateRoot 'config.json'
$errorLog       = Join-Path $StateRoot 'errors.log'

$pidFile        = Join-Path $StateRoot '.tts.pid'
# Playback happens inside a short-lived process the hook launched, so a later
# -Pause has no handle on it. This file is the channel between them: the player
# polls it a few times a second and matches whatever state it names, 'play' or
# 'pause'. Stopping does not need it - killing the process is instant and needs
# no cooperation from the player - but pausing does, because the audio has to
# stay alive to be resumable. The poll interval is the trade: 120ms is
# imperceptible to a listener and costs one small file read.
$ctlFile = Join-Path $StateRoot '.tts.ctl'
# .tts.ctl is a sustained state ('play' or 'pause') that the player keeps matching.
# A seek is not a state, it is an event: it happens once and is then over. Mixing
# the two in one file would mean the player re-seeking on every poll, so seeks get
# their own file, holding a millisecond delta that the player consumes and deletes.
$seekFile = Join-Path $StateRoot '.tts.seek'
$SeekStepMs     = 10000
$PollMs         = 120
$voiceCacheFile = Join-Path $StateRoot '.tts-voices.json'
$lastVoiceFile = Join-Path $StateRoot '.tts-lastvoice'

function Read-Payload {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    try { return $raw | ConvertFrom-Json } catch { return $null }
}

# ---------------------------------------------------------------- config -----
# config.json overrides any tunable above by name, so a user never edits this
# file and never loses their settings to an update. Unknown keys are ignored;
# a malformed file is ignored too, because failing to speak is better than
# failing the turn.
if (Test-Path -LiteralPath $configFile) {
    try {
        $cfg = Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($prop in $cfg.PSObject.Properties) {
            if (Get-Variable -Name $prop.Name -Scope Script -ErrorAction SilentlyContinue) {
                Set-Variable -Name $prop.Name -Value $prop.Value -Scope Script
            }
        }
    } catch { }
}

# ----------------------------------------------------------- session label --
# The Stop hook speaks at the end of every turn, and several Claude sessions are
# usually open at once, so a response arrives spoken with no clue which tab
# produced it. A session writes one line - "Issue 466, unified notification
# toast" - to speak-labels\<session-id>.txt, and every spoken message is
# introduced with it.
#
# The session id is the transcript's file name. Keying off that is what lets a
# label survive across turns without this script holding any state of its own,
# and it means a label written once at the start of a session keeps working for
# the rest of it. No label file just means no preamble, exactly as before.
$LabelRoot = Join-Path $StateRoot 'speak-labels'

function Get-SessionLabel([string]$transcript) {
    # an explicit -Preamble always wins, so /speak can label a one-off
    if ($Preamble) { return $Preamble.Trim() }
    $id = $SessionId
    if (-not $id) {
        if (-not $transcript) { return '' }
        $id = [System.IO.Path]::GetFileNameWithoutExtension($transcript)
    }
    if (-not $id) { return '' }
    $file = Join-Path $LabelRoot "$id.txt"
    if (-not (Test-Path -LiteralPath $file)) { return '' }
    try {
        $line = @(Get-Content -LiteralPath $file -TotalCount 1 -Encoding UTF8)[0]
        if ($line) { return ([string]$line).Trim() }
    } catch { }
    return ''
}

function Add-SessionLabel([string]$label, [string]$text) {
    if (-not $text -or -not $label) { return $text }
    # the full stop and the blank line are what give the synthesizer a real pause,
    # so the label is heard as its own sentence instead of running into the first
    # word of the response
    return ($label.TrimEnd('.', ' ', "`t") + ".`n`n" + $text)
}

# ------------------------------------------------------------- session cue --
# What the Stop hook says at the end of a turn.
#
# It used to read the opening paragraphs of the response itself, which is the
# wrong thing out loud: the response is written to be read, and hearing the first
# 700 characters of it is neither the whole answer nor a useful summary. What is
# actually wanted is a handover - "the draft pull request is up and ready for
# review" - after which the full response can be played on request with
# -Latest.
#
# So the session writes that one line to speak-cues\<session-id>.txt as it
# finishes, and this reads it. The file is deleted once spoken, which is the
# whole staleness guard: a cue can never be replayed on a later turn, and a turn
# that wrote no cue falls back to a generic line rather than announcing the
# previous turn's news a second time.
$CueRoot = Join-Path $StateRoot 'speak-cues'

function Get-SessionCue([string]$transcript) {
    $id = $SessionId
    if (-not $id) {
        if (-not $transcript) { return '' }
        $id = [System.IO.Path]::GetFileNameWithoutExtension($transcript)
    }
    if (-not $id) { return '' }
    $file = Join-Path $CueRoot "$id.txt"
    if (-not (Test-Path -LiteralPath $file)) { return '' }
    $cue = ''
    try {
        foreach ($line in @(Get-Content -LiteralPath $file -Encoding UTF8)) {
            if ($line -and $line.Trim()) { $cue = ([string]$line).Trim(); break }
        }
    } catch { }
    # -Print is a dry run, so it must leave the cue in place for the real turn
    if (-not $Print) {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
    return $cue
}

function Get-LatestTranscript {
    # An explicit session id wins: 'the newest file on disk' is a guess, and it is
    # wrong exactly when it matters, which is when several sessions are open.
    if ($SessionId) {
        $root = Join-Path $env:USERPROFILE '.claude\projects'
        if (Test-Path -LiteralPath $root) {
            $match = Get-ChildItem -LiteralPath $root -Filter "$SessionId.jsonl" -Recurse -File -ErrorAction SilentlyContinue |
                     Select-Object -First 1
            if ($match) { return $match.FullName }
        }
    }
    $root = Join-Path $env:USERPROFILE '.claude\projects'
    if (-not (Test-Path -LiteralPath $root)) { return '' }
    $f = Get-ChildItem -LiteralPath $root -Filter *.jsonl -Recurse -File -ErrorAction SilentlyContinue |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($f) { return $f.FullName }
    return ''
}

function Get-LastAssistantText([string]$transcript, [int]$minChars = 0) {
    if (-not $transcript -or -not (Test-Path -LiteralPath $transcript)) { return '' }
    # @() matters: a one-line file comes back as a bare string, and indexing that gives one character
    $lines = @(Get-Content -LiteralPath $transcript -Tail 400 -Encoding UTF8)
    $newest = ''
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $o = $line | ConvertFrom-Json } catch { continue }
        if ($o.type -ne 'assistant') { continue }
        $parts = @($o.message.content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text })
        if ($parts.Count -eq 0) { continue }
        $joined = ($parts -join "`n").Trim()
        if (-not $joined) { continue }
        # remember the newest either way, so a transcript of nothing but short
        # messages still replays something rather than falling silent
        if (-not $newest) { $newest = $joined }
        if ($joined.Length -ge $minChars) { return $joined }
    }
    return $newest
}

function Convert-ToSpeech([string]$s, [switch]$Light) {
    if (-not $s) { return '' }
    if (-not $Light) {
        # fenced code blocks say nothing useful out loud
        $s = [regex]::Replace($s, '(?s)```.*?```', "`n`n")
        # markdown links and images: keep the label, drop the target
        $s = [regex]::Replace($s, '!?\[([^\]]*)\]\([^)]*\)', '$1')
        # inline code: keep the words, drop the backticks
        $s = $s -replace '`', ''
        # horizontal rules say nothing; table rows become sentences so a
        # table-heavy response is not silently gutted
        $kept = @()
        foreach ($line in ($s -split "`r?`n")) {
            if ($line -match '^\s*[-=_*]{3,}\s*$') { continue }
            if ($line -match '^\s*\|') {
                if (-not $SpeakTables) { continue }
                # a separator row (| --- | :--- |) carries no words at all
                if ($line -notmatch '[A-Za-z0-9]') { continue }
                $cells = @(($line.Trim() -replace '^\||\|$', '') -split '\|' |
                           ForEach-Object { $_.Trim() } | Where-Object { $_ })
                if ($cells.Count) { $kept += (($cells -join ', ') + '.') }
                continue
            }
            $kept += $line
        }
        $s = $kept -join "`n"
        # heading, list, quote and emphasis markers
        $s = [regex]::Replace($s, '(?m)^\s{0,3}#{1,6}\s*', '')
        $s = [regex]::Replace($s, '(?m)^\s*[-*+]\s+', '')
        $s = [regex]::Replace($s, '(?m)^\s*>\s?', '')
        $s = $s -replace '\*\*', '' -replace '__', ''
        # bare file paths and URLs are unlistenable character-by-character
        $s = [regex]::Replace($s, '\S*[\\/]\S*', ' ')
    }
    # emoji, box drawing and other non-speech glyphs (always, even in light mode)
    $s = [regex]::Replace($s, '[^\p{L}\p{N}\p{P}\p{Zs}\n]', ' ')
    # tidy whitespace, preserving paragraph breaks
    $s = [regex]::Replace($s, '[^\S\n]+', ' ')
    $s = [regex]::Replace($s, '(?m)^ +| +$', '')
    $s = [regex]::Replace($s, '\n{3,}', "`n`n")
    return $s.Trim()
}

function Select-Portion([string]$s, [string]$scope, [int]$max) {
    if ($scope -eq 'full') {
        if ($s.Length -gt $max) { return $s.Substring(0, $max) }
        return $s
    }
    $paras = @([regex]::Split($s, '\n\s*\n') | Where-Object { $_.Trim() })
    $out = ''
    foreach ($p in $paras) {
        if ($out) { $out = "$out`n$($p.Trim())" } else { $out = $p.Trim() }
        if ($out.Length -ge $MinChars) { break }
    }
    if ($out.Length -gt $max) { $out = $out.Substring(0, $max) }
    return $out
}

function Get-ActiveSpeech {
    if (-not (Test-Path -LiteralPath $pidFile)) { return $null }
    $stamp = (Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($stamp -notmatch '^(\d+)\|(\d+)\|(\w+)$') { return $null }
    $oldPid = [int]$Matches[1]; $oldTicks = [long]$Matches[2]; $kind = $Matches[3]
    try {
        $p = Get-Process -Id $oldPid -ErrorAction Stop
        # the ticks check makes sure this is our process, not a recycled PID
        if ($p.StartTime.Ticks -eq $oldTicks) {
            # ...and the command line makes sure it is a speech process at all.
            # A lock left behind by a killed run can end up naming a long-lived
            # PowerShell session, and a 'manual' lock silences the Stop hook by
            # design - so a bogus one switches automatic speech off permanently,
            # with no error and nothing to see. Observed on 2026-09-20: the lock
            # named the editor's own shell process and every turn went quiet.
            # Get-CimInstance costs ~313ms, and this runs on every pause, resume
            # and status check. It is only needed to catch a lock naming a process
            # that is not ours, and our own player is always powershell - so a
            # different process name settles it for free, and the expensive check
            # is reserved for the case that actually looks like us.
            $cmd = ''
            if ($p.ProcessName -notlike 'powershell*' -and $p.ProcessName -notlike 'pwsh*') {
                $cmd = 'not-a-shell'
            } else {
                try {
                    $cmd = [string](Get-CimInstance Win32_Process -Filter "ProcessId = $oldPid" -ErrorAction Stop).CommandLine
                } catch { }
            }
            # an unreadable command line is not evidence of a stale lock, so only
            # a command line we can read and that is clearly not ours is rejected
            if ($cmd -and $cmd -notmatch 'speak\.ps1') {
                Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
                return $null
            }
            return @{ Id = $oldPid; Kind = $kind }
        }
    } catch { }
    return $null
}

function Get-ControlState {
    if (-not (Test-Path -LiteralPath $ctlFile)) { return 'play' }
    try {
        $v = (Get-Content -LiteralPath $ctlFile -TotalCount 1 -ErrorAction Stop)
        if ($v) { $v = ([string]$v).Trim().ToLowerInvariant() }
        if ($v -eq 'pause') { return 'pause' }
    } catch { }
    return 'play'
}

function Set-ControlState([string]$state) {
    try { Set-Content -LiteralPath $ctlFile -Value $state -Encoding ascii -ErrorAction Stop } catch { }
}

function Clear-ControlState {
    Remove-Item -LiteralPath $ctlFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $seekFile -Force -ErrorAction SilentlyContinue
}

function Add-SeekRequest([int]$deltaMs) {
    # deltas accumulate, so holding fast-forward skips further rather than the
    # second press cancelling the first
    $pending = 0
    if (Test-Path -LiteralPath $seekFile) {
        try { $pending = [int](Get-Content -LiteralPath $seekFile -TotalCount 1 -ErrorAction Stop) } catch { $pending = 0 }
    }
    try { Set-Content -LiteralPath $seekFile -Value ([string]($pending + $deltaMs)) -Encoding ascii -ErrorAction Stop } catch { }
}

function Read-SeekRequest {
    if (-not (Test-Path -LiteralPath $seekFile)) { return 0 }
    $delta = 0
    try { $delta = [int](Get-Content -LiteralPath $seekFile -TotalCount 1 -ErrorAction Stop) } catch { $delta = 0 }
    # consumed, not just read: a seek must never repeat on the next poll
    Remove-Item -LiteralPath $seekFile -Force -ErrorAction SilentlyContinue
    return $delta
}

# -- MCI ----------------------------------------------------------------------
# SoundPlayer can only start and stop, so it cannot support pause at all. MCI can
# - play / pause / resume / status against one open alias - and it plays
# asynchronously, which is what leaves this process free to watch the control
# file while the audio runs.
$script:MciReady = $false
function Initialize-Mci {
    if ($script:MciReady) { return }
    $sig = @'
[System.Runtime.InteropServices.DllImport("winmm.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto)]
public static extern int mciSendString(string command, System.Text.StringBuilder buffer, int bufferSize, System.IntPtr callback);
'@
    Add-Type -Namespace Tts -Name Native -MemberDefinition $sig
    $script:MciReady = $true
}

function Invoke-Mci([string]$command) {
    Initialize-Mci
    $sb = New-Object System.Text.StringBuilder 512
    [void][Tts.Native]::mciSendString($command, $sb, $sb.Capacity, [System.IntPtr]::Zero)
    return $sb.ToString().Trim()
}

function Stop-PreviousSpeech {
    $active = Get-ActiveSpeech
    if ($active) { Stop-Process -Id $active.Id -Force -ErrorAction SilentlyContinue }
}

function Get-ElevenKey {
    # a key set with setx lands in the User scope, and a shell started before that
    # will not have inherited it - so check every scope rather than just this process
    foreach ($scope in 'Process', 'User', 'Machine') {
        $v = [Environment]::GetEnvironmentVariable($ElevenKeyVar, $scope)
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
    }
    return ''
}

function Get-AccountVoices {
    # the voice ids on the account, cached to disk. The picker runs on every utterance
    # and the account's roster changes maybe monthly, so paying for a round trip each
    # time would add latency to speech for nothing.
    if (Test-Path -LiteralPath $voiceCacheFile) {
        try {
            $age = (Get-Date) - (Get-Item -LiteralPath $voiceCacheFile).LastWriteTime
            if ($age.TotalHours -lt $VoiceCacheHours) {
                # ConvertFrom-Json hands back a JSON array as ONE object on 5.1, so @( ) around
                # the pipeline wraps it instead of flattening it -- the result is a single
                # element that is itself an array. That made $ids.Count 1, which silently
                # skipped the no-repeat filter below. Cast to [string[]] to flatten for real.
                $parsed = Get-Content -LiteralPath $voiceCacheFile -Raw | ConvertFrom-Json
                $cached = [string[]]$parsed
                if ($cached.Count) { return $cached }
            }
        } catch { }
    }
    $key = Get-ElevenKey
    if (-not $key) { return @() }
    $vr = Invoke-ElevenApi $key 'voices'
    if ($vr.Code -ne 200) { return @() }
    try {
        $ids = [string[]](($vr.Body | ConvertFrom-Json).voices | ForEach-Object { $_.voice_id })
        if ($ids.Count) { ($ids | ConvertTo-Json -Compress) | Set-Content -LiteralPath $voiceCacheFile -Encoding ascii }
        return $ids
    } catch { return @() }
}

function Resolve-VoiceId {
    # -Voice wins outright; then randomisation; then the configured default.
    if ($Voice) { return $Voice }
    if (-not ($RandomVoice -or $RandomizeVoice)) { return $ElevenVoiceId }

    # [string[]] rather than @( ), so a nested array can never reach the filter below
    $ids = [string[]](Get-AccountVoices)
    # no network, or a key without Voices read: speak in the known-good default rather
    # than failing over to SAPI5, which is the one outcome worse than a repeated voice
    if ($ids.Count -eq 0) { return $ElevenVoiceId }

    if ($AvoidRepeatVoice -and $ids.Count -gt 1 -and (Test-Path -LiteralPath $lastVoiceFile)) {
        try {
            $last = (Get-Content -LiteralPath $lastVoiceFile -Raw).Trim()
            $trimmed = @($ids | Where-Object { $_ -ne $last })
            if ($trimmed.Count) { $ids = $trimmed }
        } catch { }
    }

    $pick = $ids | Get-Random
    try { Set-Content -LiteralPath $lastVoiceFile -Value $pick -Encoding ascii } catch { }
    return $pick
}

function Get-ElevenAudio([string]$text) {
    # returns the path to a playable wav, or '' to mean "fall back to SAPI5"
    if (-not $UseElevenLabs) { return '' }
    if (-not (Get-ElevenKey)) { return '' }

    $voiceId = Resolve-VoiceId
    if ([string]::IsNullOrWhiteSpace($voiceId)) { return '' }

    $wav = Request-ElevenWav $text $voiceId
    if ($wav) { return $wav }

    # A randomly picked voice can be one this plan cannot synthesise, or one that has
    # since been removed from the account. The configured default is known good, so it
    # is worth one more request before dropping to the robotic SAPI5 voice.
    if ($ElevenVoiceId -and $voiceId -ne $ElevenVoiceId) {
        return Request-ElevenWav $text $ElevenVoiceId
    }
    return ''
}

function Request-ElevenWav([string]$text, [string]$voiceId) {
    $key = Get-ElevenKey
    if (-not $key) { return '' }

    $out = Join-Path ([IO.Path]::GetTempPath()) ("speak-{0}.wav" -f [guid]::NewGuid().ToString('N'))
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $uri = "https://api.elevenlabs.io/v1/text-to-speech/$voiceId`?output_format=$ElevenFormat"
        $payload = @{
            text     = $text
            model_id = $ElevenModel
            voice_settings = @{
                stability         = $ElevenStability
                similarity_boost  = $ElevenSimilarity
                speed             = $ElevenSpeed
                use_speaker_boost = $true
            }
        } | ConvertTo-Json -Depth 4 -Compress
        # send raw UTF-8 bytes: a curly quote or dash in the text must survive the wire
        $body = [Text.Encoding]::UTF8.GetBytes($payload)

        Invoke-WebRequest -Uri $uri -Method Post -UseBasicParsing `
            -Headers @{ 'xi-api-key' = $key } `
            -ContentType 'application/json' `
            -Body $body -OutFile $out -TimeoutSec $ElevenTimeoutSec | Out-Null

        if (-not (Test-Path -LiteralPath $out)) { return '' }
        if ((Get-Item -LiteralPath $out).Length -lt 1024) {
            # an error body is JSON and tiny; real speech never is
            Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
            return ''
        }
        $magic = -join [char[]]([IO.File]::ReadAllBytes($out)[0..3])
        if ($magic -ne 'RIFF') {
            Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
            return ''
        }
        return $out
    } catch {
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
        return ''
    }
}

function Invoke-Wav([string]$wav) {
    # the alias carries the PID so two overlapping runs cannot fight over one name
    $alias = "tts$PID"
    $open = Invoke-Mci ('open "' + $wav + '" type waveaudio alias ' + $alias)
    if ($open -like '*rror*') {
        # MCI refused the file: a playback with no pause beats no playback at all
        $player = New-Object System.Media.SoundPlayer $wav
        try { $player.PlaySync() } finally { $player.Dispose() }
        return
    }
    try {
        # waveaudio can report position in bytes; ask for milliseconds so the seek
        # arithmetic below means what it says
        [void](Invoke-Mci "set $alias time format milliseconds")
        $length = 0
        try { $length = [int](Invoke-Mci "status $alias length") } catch { $length = 0 }
        [void](Invoke-Mci "play $alias")
        while ($true) {
            $mode = Invoke-Mci "status $alias mode"
            if ($mode -ne 'playing' -and $mode -ne 'paused') { break }

            $delta = Read-SeekRequest
            if ($delta -ne 0 -and $length -gt 0) {
                $pos = 0
                try { $pos = [int](Invoke-Mci "status $alias position") } catch { $pos = 0 }
                $target = $pos + $delta
                if ($target -lt 0) { $target = 0 }
                # seeking past the end means "I am done with this", so stop rather
                # than restarting or clamping to a last sliver of audio
                if ($target -ge $length) { break }
                [void](Invoke-Mci "play $alias from $target")
                # 'play from' always resumes, so a seek made while paused would
                # silently un-pause; put it back
                if ((Get-ControlState) -eq 'pause') { [void](Invoke-Mci "pause $alias") }
                Start-Sleep -Milliseconds $PollMs
                continue
            }

            $want = Get-ControlState
            if ($want -eq 'pause' -and $mode -eq 'playing') { [void](Invoke-Mci "pause $alias") }
            elseif ($want -eq 'play' -and $mode -eq 'paused') { [void](Invoke-Mci "resume $alias") }
            Start-Sleep -Milliseconds $PollMs
        }
    } finally {
        [void](Invoke-Mci "close $alias")
    }
}

function Invoke-Sapi([string]$text) {
    Add-Type -AssemblyName System.Speech
    $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
    try {
        $synth.Rate = $Rate
        $synth.Volume = $Volume
        if ($VoiceName) { try { $synth.SelectVoice($VoiceName) } catch { } }
        # SpeakAsync rather than Speak, for the same reason the wav path uses MCI:
        # a blocking call cannot watch the control file while it runs
        [void]$synth.SpeakAsync($text)
        while ($synth.State -ne [System.Speech.Synthesis.SynthesizerState]::Ready) {
            $want = Get-ControlState
            if ($want -eq 'pause' -and $synth.State -eq [System.Speech.Synthesis.SynthesizerState]::Speaking) {
                $synth.Pause()
            } elseif ($want -eq 'play' -and $synth.State -eq [System.Speech.Synthesis.SynthesizerState]::Paused) {
                $synth.Resume()
            }
            Start-Sleep -Milliseconds $PollMs
        }
    } finally {
        # a synth disposed while still paused never returns to Ready, so let it go
        try { if ($synth.State -eq [System.Speech.Synthesis.SynthesizerState]::Paused) { $synth.Resume() } } catch { }
        $synth.Dispose()
    }
}

function Invoke-Speech([string]$text, [string]$Kind = 'auto') {
    if (-not $text) { return }
    if ($Print) { Write-Output $text; return }
    Stop-PreviousSpeech
    # a pause left over from the previous playback would start this one muted
    Clear-ControlState
    $me = Get-Process -Id $PID
    Set-Content -LiteralPath $pidFile -Value "$PID|$($me.StartTime.Ticks)|$Kind" -Encoding ascii
    $wav = ''
    try {
        $wav = Get-ElevenAudio $text
        if ($wav) {
            Invoke-Wav $wav
        } else {
            Invoke-Sapi $text
        }
    } finally {
        if ($wav) { Remove-Item -LiteralPath $wav -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        Clear-ControlState
    }
}

function Invoke-ElevenApi([string]$key, [string]$path) {
    # returns the status code and raw body, so a diagnostic can tell a bad key
    # apart from a key that simply lacks one permission
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $r = Invoke-WebRequest -Uri "https://api.elevenlabs.io/v1/$path" -UseBasicParsing `
             -Headers @{ 'xi-api-key' = $key } -TimeoutSec 15
        return @{ Code = [int]$r.StatusCode; Body = $r.Content }
    } catch {
        $resp = $_.Exception.Response
        return @{ Code = $(if ($resp) { [int]$resp.StatusCode } else { 0 }); Body = '' }
    }
}

# ------------------------------------------------------------- voice picker --
# Picking a voice is a loop: see what the account has, hear one, keep it. Each
# step is its own switch so the agent can drive them separately, and none of
# them keeps a list of its own - the account is the only source of truth for
# what exists, so a voice added or removed in the dashboard needs no change here.

function Get-VoiceCatalog {
    # Every voice on the account, or @() if it cannot be read. Deliberately does
    # not throw and does not consult $voiceCacheFile: that cache holds ids only,
    # for the random picker, and a person choosing a voice needs the names.
    $key = Get-ElevenKey
    if (-not $key) { return @() }
    $r = Invoke-ElevenApi $key 'voices'
    if ($r.Code -ne 200) { return @() }
    try { return @(($r.Body | ConvertFrom-Json).voices) } catch { return @() }
}

function Resolve-VoiceQuery([string]$query) {
    # A query is an exact voice id or any part of a name. Returns one of Voice,
    # Matches or Error so the caller can word its own report - set and preview
    # resolve identically but say different things about the result.
    #
    # Never guesses between candidates. Voice ids are opaque and the names are
    # short, so 'Sarah' matching two voices is far more likely to be an
    # ambiguity than a preference, and picking one silently would be heard
    # rather than read - the worst place to hide a wrong guess.
    $query = "$query".Trim()
    if (-not $query) { return @{ Error = 'no voice given' } }

    $all = Get-VoiceCatalog
    if ($all.Count -eq 0) {
        return @{ Error = 'could not read the account voice list - check the key, its Voices read permission, and the network' }
    }

    $exact = @($all | Where-Object { $_.voice_id -eq $query })
    if ($exact.Count -eq 1) { return @{ Voice = $exact[0] } }

    # name match, tightest first: whole name, then prefix, then anywhere
    foreach ($test in @(
        { $_.name -ieq $query },
        { $_.name -ilike "$query*" },
        { $_.name -ilike "*$query*" }
    )) {
        $hits = @($all | Where-Object $test)
        if ($hits.Count -eq 1) { return @{ Voice = $hits[0] } }
        if ($hits.Count -gt 1) { return @{ Matches = $hits } }
    }
    return @{ Error = "no voice on the account matches '$query'" }
}

function Write-VoiceRows($rows) {
    foreach ($v in $rows) {
        $mark = if ($v.voice_id -eq $ElevenVoiceId) { '*' } else { ' ' }
        # 44 fits the longest premade name ElevenLabs currently ships; a longer one
        # pushes its own row out rather than padding all 26 for one outlier.
        Write-Output ('{0} {1,-44} {2,-13} {3}' -f $mark, $v.name, $v.category, $v.voice_id)
    }
}

function Show-Voices {
    $all = Get-VoiceCatalog
    if ($all.Count -eq 0) {
        Write-Output 'No voices could be read - the key is missing, lacks Voices read, or the network is down.'
        Write-Output 'Run -Diag for the full engine configuration.'
        return
    }
    Write-VoiceRows ($all | Sort-Object category, name)
    Write-Output ''
    $byCat = ($all | Group-Object category | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', '
    Write-Output ("{0} voices ({1}). * is the one in use." -f $all.Count, $byCat)
    # A list with no way to act on it is a wall of ids. Said in this script's own
    # switches; the slash command restates it in its own vocabulary for the agent.
    Write-Output 'Hear one:  -PreviewVoice <name or id>     Keep one:  -SetVoice <name or id>'

    # Removing a voice in the dashboard does not reach config.json, so the saved
    # default can name a voice the account no longer has. Synthesis then fails and
    # drops to the robotic SAPI5 voice with nothing said about why - the one
    # failure in this script a listener cannot diagnose by ear. Say it plainly
    # here, where the evidence is already in hand.
    if ($ElevenVoiceId -and -not ($all | Where-Object { $_.voice_id -eq $ElevenVoiceId })) {
        Write-Output ''
        Write-Output ("WARNING: the saved voice {0} is no longer on this account." -f $ElevenVoiceId)
        Write-Output '         Speech will fall back to the Windows voice until you set one from the list above.'
    }
}

# $candidates, not $matches: $Matches is an automatic variable PowerShell rewrites
# on every -match, so a parameter of that name is a trap for whoever edits next.
function Show-VoiceAmbiguity([string]$query, $candidates) {
    Write-Output "'$query' matches more than one voice - name it more precisely, or use the id:"
    Write-VoiceRows $candidates
}

function Set-DefaultVoice([string]$query) {
    $resolved = Resolve-VoiceQuery $query
    if ($resolved.Matches) { Show-VoiceAmbiguity $query $resolved.Matches; return }
    if ($resolved.Error)   { Write-Output $resolved.Error; return }
    # $picked for the same reason Invoke-VoicePreview uses it - see the note there.
    $picked = $resolved.Voice

    # Read-modify-write, never a fresh file: config.json belongs to the user and
    # carries keys this function knows nothing about. Rewriting it wholesale
    # would silently discard their model, speed and volume settings.
    $cfg = $null
    if (Test-Path -LiteralPath $configFile) {
        try { $cfg = Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    if (-not $cfg) { $cfg = [pscustomobject]@{} }

    if ($cfg.PSObject.Properties.Name -contains 'ElevenVoiceId') {
        $cfg.ElevenVoiceId = $picked.voice_id
    } else {
        $cfg | Add-Member -NotePropertyName 'ElevenVoiceId' -NotePropertyValue $picked.voice_id
    }

    try {
        # Not Set-Content -Encoding UTF8: on 5.1 that prepends a byte-order mark,
        # and a BOM in front of a '{' is rejected by strict JSON parsers. This
        # file is read by anything the user points at it, not only by this script.
        [System.IO.File]::WriteAllText(
            $configFile,
            ($cfg | ConvertTo-Json -Depth 6),
            (New-Object System.Text.UTF8Encoding $false)
        )
    } catch {
        Write-Output "could not write $configFile - $($_.Exception.Message)"
        return
    }

    # A deliberate choice should be heard on the very next utterance, so drop the
    # randomiser's memory of what it last played rather than letting it skip this one.
    Remove-Item -LiteralPath $lastVoiceFile -ErrorAction SilentlyContinue
    Write-Output ('voice set to {0} [{1}]  {2}' -f $picked.name, $picked.category, $picked.voice_id)
}

function Invoke-VoicePreview([string]$query) {
    $resolved = Resolve-VoiceQuery $query
    if ($resolved.Matches) { Show-VoiceAmbiguity $query $resolved.Matches; return }
    if ($resolved.Error)   { Write-Output $resolved.Error; return }

    # $picked, never $voice. PowerShell looks variables up dynamically, through the
    # call stack rather than the file, so a local named $voice here would be what
    # Resolve-VoiceId sees when Invoke-Speech calls down into it - shadowing the
    # $Voice parameter set on the line below with this whole object. Names are
    # case-insensitive, so $voice and $Voice are one name and the clash is silent:
    # every preview then played the default voice while printing the right one.
    $picked = $resolved.Voice

    # Said before speaking, not after: a preview is launched detached so the
    # sample can be paused and stopped, and nothing written after this line is read.
    Write-Output ('previewing {0} [{1}]  {2}' -f $picked.name, $picked.category, $picked.voice_id)

    # -Voice is already the per-run override the speech path honours, so a
    # preview is an ordinary utterance with it set. No second synthesis path.
    $script:Voice = $picked.voice_id
    Invoke-Speech ('This is {0}. Your agent will sound like this.' -f $picked.name) 'manual'
}

function Show-Diag {
    $key = Get-ElevenKey
    $voices = @()
    try {
        Add-Type -AssemblyName System.Speech
        $voices = (New-Object System.Speech.Synthesis.SpeechSynthesizer).GetInstalledVoices() |
                  ForEach-Object { $_.VoiceInfo.Name }
    } catch { }
    $keyState = if ($key) { "found ({0} chars)" -f $key.Length } else { 'NOT SET' }
    $voiceState = if ($ElevenVoiceId) { $ElevenVoiceId } else { 'NOT SET' }
    $ready = $UseElevenLabs -and $key -and $ElevenVoiceId
    $picking = if ($Voice) { "-Voice override: $Voice" }
               elseif ($RandomVoice) { 'random this run (-RandomVoice)' }
               elseif ($RandomizeVoice) { 'random every run ($RandomizeVoice)' }
               else { 'fixed - the default voice id below' }
    Write-Output "ElevenLabs enabled : $UseElevenLabs"
    Write-Output "API key            : $ElevenKeyVar - $keyState"
    Write-Output "Voice selection    : $picking"
    Write-Output "Default voice id   : $voiceState"
    Write-Output "Model / format     : $ElevenModel / $ElevenFormat"
    Write-Output "Engine in use      : $(if ($ready) { 'ElevenLabs, with SAPI5 on any failure' } else { 'SAPI5 - ElevenLabs not configured' })"
    Write-Output "SAPI5 voices       : $($voices -join ', ')"
    if (-not $ready) { return }

    # /v1/voices needs only the Voices read permission, so it is the honest test
    # of whether the key works. The subscription endpoint needs a separate
    # permission that a properly restricted key often lacks - a 401 there says
    # nothing about the key being bad.
    $vr = Invoke-ElevenApi $key 'voices'
    if ($vr.Code -ne 200) {
        Write-Output "Key check          : FAILED - HTTP $($vr.Code) - wrong key, or it lacks Voices read"
        return
    }
    Write-Output "Key check          : OK - the key is valid"

    $cat = ''
    try {
        $all = ($vr.Body | ConvertFrom-Json).voices
        $match = $all | Where-Object { $_.voice_id -eq $ElevenVoiceId }
        if ($match) {
            $cat = $match.category
            Write-Output "Default voice      : $($match.name) [$cat]"
        } else {
            Write-Output "Default voice      : NOT in your account - add it in the dashboard first"
        }
        $byCat = ($all | Group-Object category | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', '
        Write-Output "Voices available   : $($all.Count) ($byCat)"
        $cacheState = if (Test-Path -LiteralPath $voiceCacheFile) {
            $h = [math]::Round(((Get-Date) - (Get-Item -LiteralPath $voiceCacheFile).LastWriteTime).TotalHours, 1)
            "cached ${h}h ago, refetched after $VoiceCacheHours h"
        } else { 'not cached yet - first random pick will fetch it' }
        Write-Output "Voice list cache   : $cacheState"
    } catch { }

    $tier = ''
    $sr = Invoke-ElevenApi $key 'user/subscription'
    if ($sr.Code -eq 200) {
        $sub = $sr.Body | ConvertFrom-Json
        $tier = $sub.tier
        $left = $sub.character_limit - $sub.character_count
        Write-Output "Account            : $tier - $left of $($sub.character_limit) characters left"
    } elseif ($sr.Code -eq 401) {
        Write-Output "Account            : key has no User read permission, so quota is unknown (harmless)"
    } else {
        Write-Output "Account            : unavailable - HTTP $($sr.Code)"
    }

    # Only warn on a tier the API actually reported as free. An unknown tier is the
    # normal case for a key without User read permission, and warning on it told a
    # paid account its voice would not work when it already did.
    if ($cat -and $cat -ne 'premade' -and $tier -eq 'free') {
        Write-Output ''
        Write-Output "WARNING: '$cat' voices come from the Voice Library, and a free plan cannot use"
        Write-Output "them through the API - the request returns 402 and speech drops back to SAPI5."
        Write-Output "Pick a 'premade' voice, or upgrade to Starter to use this one."
    }
}

function Get-SpeechStatus {
    $active = Get-ActiveSpeech
    if (-not $active) { return 'idle' }
    if ((Get-ControlState) -eq 'pause') { return 'paused' }
    return 'playing'
}

try {
    if ($Diag) { Show-Diag; exit 0 }

    # -- voice picker ---------------------------------------------------------
    # Ahead of the transport controls because none of these act on a playback in
    # flight: listing and setting speak nothing at all, and a preview starts a
    # new utterance the same way -TextFile does.
    if ($Voices)       { Show-Voices;                       exit 0 }
    if ($SetVoice)     { Set-DefaultVoice $SetVoice;        exit 0 }
    if ($PreviewVoice) { Invoke-VoicePreview $PreviewVoice; exit 0 }

    # -- transport controls ---------------------------------------------------
    # These act on a playback already in flight, so they run before anything that
    # reads stdin or a transcript and they never speak anything themselves.
    if ($Status) { Write-Output (Get-SpeechStatus); exit 0 }

    if ($Stop) {
        $was = Get-SpeechStatus
        # killing the player is instant and needs no cooperation from it, which is
        # why stop works even if the poll loop is wedged
        Stop-PreviousSpeech
        Clear-ControlState
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        if ($was -eq 'idle') { Write-Output 'nothing was playing' } else { Write-Output 'stopped' }
        exit 0
    }

    if ($Forward -or $Rewind) {
        if ((Get-SpeechStatus) -eq 'idle') { Write-Output 'nothing is playing'; exit 0 }
        $step = $SeekStepMs
        if ($StepMs -gt 0) { $step = $StepMs }
        if ($Rewind) { $step = -$step }
        Add-SeekRequest $step
        if ($step -lt 0) { Write-Output 'rewound' } else { Write-Output 'skipped' }
        exit 0
    }

    if ($Pause -or $Resume -or $Toggle) {
        $now = Get-SpeechStatus
        if ($now -eq 'idle') { Write-Output 'nothing is playing'; exit 0 }
        $want = ''
        if ($Toggle) {
            if ($now -eq 'playing') { $want = 'pause' } else { $want = 'play' }
        } elseif ($Pause) {
            $want = 'pause'
        } else {
            $want = 'play'
        }
        Set-ControlState $want
        if ($want -eq 'pause') { Write-Output 'paused' } else { Write-Output 'resumed' }
        exit 0
    }

    if ($TextFile) {
        # explicit text: only strip glyphs the synthesizer cannot say, keep everything else
        $raw = Get-Content -LiteralPath $TextFile -Raw -Encoding UTF8
        $text = Convert-ToSpeech $raw -Light
        # truncate first, then label, so a long text can never crowd the label out
        if ($text.Length -gt $MaxCharsManual) { $text = $text.Substring(0, $MaxCharsManual) }
        # no transcript scan here: /speak passes -Preamble, and scanning every
        # project folder to label a one-off line is not worth the seconds it costs
        Invoke-Speech (Add-SessionLabel (Get-SessionLabel '') $text) 'manual'
    }
    elseif ($Latest) {
        $transcript = Get-LatestTranscript
        $text = Select-Portion (Convert-ToSpeech (Get-LastAssistantText $transcript $MinReplayChars)) $ScopeManual $MaxCharsManual
        Invoke-Speech (Add-SessionLabel (Get-SessionLabel $transcript) $text) 'manual'
    }
    elseif ($Mode -eq 'notify') {
        $payload = Read-Payload
        $msg = if ($payload -and $payload.message) { [string]$payload.message } else { 'Claude needs you.' }
        # a notification is the case that needs the label most: it is asking the
        # user to come back to a window, so it had better say which one
        $transcript = ''
        if ($payload) { $transcript = [string]$payload.transcript_path }
        Invoke-Speech (Add-SessionLabel (Get-SessionLabel $transcript) (Convert-ToSpeech $msg)) 'auto'
    }
    else {
        # the Stop hook fires at the end of the same turn a /speak ran in - do not
        # talk over a playback the user asked for, and do not kill it either
        $active = Get-ActiveSpeech
        if ($active -and $active.Kind -eq 'manual') { exit 0 }
        $payload = Read-Payload
        if (-not $payload) { exit 0 }
        $transcript = [string]$payload.transcript_path
        # a handover line, not the response - the response is played on request
        # with -Latest, which is what /speak with no arguments runs
        $cue = Get-SessionCue $transcript
        if (-not $cue) { $cue = $FallbackCue }
        Invoke-Speech (Add-SessionLabel (Get-SessionLabel $transcript) (Convert-ToSpeech $cue -Light)) 'auto'
    }
} catch {
    # A speech failure must never break the turn, so this still swallows the
    # error - but silently swallowing it left anyone debugging on their own
    # machine with nothing whatsoever to look at. Now it leaves a trail.
    try {
        $line = '{0}  {1}  {2}:{3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $_.Exception.Message,
                                       $_.InvocationInfo.ScriptName, $_.InvocationInfo.ScriptLineNumber
        Add-Content -LiteralPath $errorLog -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
        # keep the log from growing without limit
        $existing = @(Get-Content -LiteralPath $errorLog -ErrorAction SilentlyContinue)
        if ($existing.Count -gt 200) {
            Set-Content -LiteralPath $errorLog -Value ($existing | Select-Object -Last 100) -Encoding UTF8 -ErrorAction SilentlyContinue
        }
    } catch { }
}
exit 0
