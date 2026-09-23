#!/usr/bin/env node
/**
 * The single entry point for everything in this plugin: the hooks call it, and
 * so do the slash commands.
 *
 * Two reasons it exists rather than the hooks invoking PowerShell directly:
 *
 * 1. It is the OS guard. The speech engine is Windows-only, and a hook whose
 *    command does not exist is *not* silent - Claude Code reports
 *    "Failed with non-blocking status code: ... No such file or directory" in
 *    the transcript. Without this file, installing the plugin on macOS or Linux
 *    would print an error after every single response, forever. Here, a
 *    non-Windows machine exits 0 and says nothing.
 *
 * 2. It is the seam. Everything agent-facing - the hooks, the commands, the
 *    cue protocol - talks to this file and not to PowerShell. Replacing the
 *    Windows engine with a cross-platform one is then a change behind this
 *    boundary, not a redesign of the plugin.
 */

'use strict';

const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');

const PLUGIN_ROOT = path.resolve(__dirname, '..');
const SPEAK = path.join(PLUGIN_ROOT, 'scripts', 'speak.ps1');
const HOTKEYS = path.join(PLUGIN_ROOT, 'scripts', 'tts-hotkeys.ps1');
const STATE_DIR = path.join(os.homedir(), '.claude', 'agent-speak');
/** Which subagent completions have already been spoken, per session. */
const ANNOUNCED_DIR = path.join(STATE_DIR, '.spoken-agents');

/** What a Claude Code session is told at the start, so cues get written at all. */
const SESSION_BRIEF = `<agent-speak>
Speech is enabled in this session, and it is a doorbell rather than a reading:
at the end of every turn the user hears one short line, not your response.

You supply that line. Before you finish a turn, write ONE sentence to:
  ${path.join(STATE_DIR, 'speak-cues', '<session_id>.txt')}

Write it for the ear: under about fifteen words, saying what is done and what
the user does next ("The tests pass and the pull request is ready for review.").
No file paths, URLs, code or markdown - they are unlistenable, and the full
response is one command away. Do not summarise your response; the cue is a
doorbell, not an abstract. A turn with no cue is announced with a generic
"Response ready.", which means the step was missed.

Once per session, also write a label naming what this session is about - an
issue number and title, or the repository and task - to:
  ${path.join(STATE_DIR, 'speak-labels', '<session_id>.txt')}
It is spoken before the cue, so the user can tell which window is talking.
Keep it short, and rewrite it if the session moves on to something else.

You may also speak DURING a turn, at a decision point the user would want to
overhear - choosing between two approaches, changing course after finding
something out, or handing work to a subagent:
  node "<plugin>/bin/agent-speak.js" say "the line" --session <session_id>

Say the decision and why it went that way, in one sentence: "Going with CSS
derivation rather than hand-tuned pixels." Not what you are about to type, not
what you just typed, and never a running commentary - a few lines in a long
turn, none in a short one. These queue and are spoken in order, so they do not
cut each other off, and the end-of-turn cue still closes the turn.

The user can say "play the full response" to hear the whole answer, and
"pause", "resume" or "stop" to control playback. Treat those bare phrases as
commands, not as conversation.
</agent-speak>`;

function isWindows() {
  return process.platform === 'win32';
}

/** Quote an argument for the command line the grandchild process will parse. */
function childArg(value) {
  const s = String(value);
  return /\s/.test(s) ? '"' + s + '"' : s;
}

/** Quote a string for a PowerShell single-quoted literal. */
function psLiteral(value) {
  return "'" + String(value).replace(/'/g, "''") + "'";
}

/**
 * Launch a player that must outlive this process.
 *
 * Node's own `detached: true` is not enough here. Agent hosts run hook commands
 * inside a job object that kills every descendant when the command returns, and
 * a Node-spawned child - detached or not - dies with it. PowerShell's
 * `Start-Process` launches through the shell instead, which escapes the job;
 * measured both ways, only this one survives.
 *
 * `Start-Process -ArgumentList` does no quoting of its own, so an argument
 * containing a space arrives as two arguments and the child fails to bind its
 * parameters - a silent death that looks exactly like "the feature is broken".
 * Hence childArg().
 */
function runDetached(script, args, done) {
  const full = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script, ...args];
  const argList = full.map((a) => psLiteral(childArg(a))).join(',');
  const child = spawn(
    'powershell',
    ['-NoProfile', '-Command', `Start-Process -FilePath 'powershell' -ArgumentList ${argList} -WindowStyle Hidden`],
    { stdio: 'ignore', windowsHide: true }
  );
  // Wait for the launcher, do not unref it. Exiting straight after spawn() lets
  // the job object tear the launcher down before it has even started - it never
  // reaches Start-Process, and nothing plays, with no error anywhere. Waiting
  // costs about half a second and is the difference between working and not.
  // The player it starts is a grandchild created through the shell, so it is
  // free of the job and outlives everything here.
  child.on('error', () => done && done());
  child.on('close', () => done && done());
}

/** Run a PowerShell script, forwarding stdin, and exit with its code. */
function runPowerShell(script, args, { pipeStdin = false, detached = false } = {}) {
  const full = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script, ...args];

  if (detached) {
    runDetached(script, args, () => process.exit(0));
    return;
  }

  const child = spawn('powershell', full, {
    stdio: [pipeStdin ? 'pipe' : 'ignore', 'inherit', 'inherit'],
    windowsHide: true,
  });

  if (pipeStdin) {
    process.stdin.pipe(child.stdin);
    // A hook's stdin closing is the only signal the script gets that the payload
    // is complete; without this it blocks on a read that never returns.
    child.stdin.on('error', () => {});
  }

  child.on('error', () => process.exit(0));
  child.on('close', (code) => process.exit(code === null ? 0 : code));
}

/**
 * Park a line of text somewhere the detached player can still read it.
 *
 * It cannot be deleted after the spawn: the player is a grandchild that has not
 * necessarily started yet, so removing the file is a race it usually loses. They
 * are swept on the next call instead - a few hundred bytes each, and the sweep
 * costs one directory listing.
 */
function writeTempText(text) {
  const dir = path.join(STATE_DIR, 'tmp');
  fs.mkdirSync(dir, { recursive: true });
  const cutoff = Date.now() - 60 * 60 * 1000;
  try {
    for (const name of fs.readdirSync(dir)) {
      const p = path.join(dir, name);
      try {
        if (fs.statSync(p).mtimeMs < cutoff) fs.unlinkSync(p);
      } catch {
        /* another process got there first, which is the outcome we wanted */
      }
    }
  } catch {
    /* a failed sweep must not stop the line being spoken */
  }
  const file = path.join(dir, `say-${Date.now()}-${process.pid}.txt`);
  fs.writeFileSync(file, text, 'utf8');
  return file;
}

/** Pull `--session <id>` out of an argument list, returning [id, remaining]. */
function takeSession(args) {
  const i = args.indexOf('--session');
  if (i === -1 || !args[i + 1]) return ['', args];
  return [args[i + 1], args.slice(0, i).concat(args.slice(i + 2))];
}

// A command that turns its arguments into speech cannot also treat an argument
// it does not recognise as content. `say --help` used to say "dash dash help"
// out loud, because the flag was never recognised and fell through to the text.
// Anything shaped like an option is now either known, or an error — never
// something the room hears.

const USAGE = {
  say: [
    'agent-speak say "<text>" [--session <id>] [--print]',
    '  --file <path>   read the text from a file, so long text needs no quoting',
    '  --              everything after this is literal text, dashes included',
  ].join('\n'),
  speak: 'agent-speak speak <text-file> [label]',
  play: 'agent-speak play [session_id]',
  voice: [
    'agent-speak voice <list|set|preview> [name or id]',
    '  --              everything after this is a literal name',
  ].join('\n'),
  mute: 'agent-speak mute <session_id>',
  unmute: 'agent-speak unmute <session_id>',
  'mute-status': 'agent-speak mute-status <session_id>',
};

const KNOWN_OPTIONS = {
  say: new Set(['--session', '--print', '--file']),
  voice: new Set([]),
};

const TOP_LEVEL_USAGE = [
  'agent-speak <command> [options]',
  '',
  '  say "<text>"           speak a line now, queued behind anything playing',
  '  play [session_id]      read the last full response aloud',
  '  speak <file> [label]   speak the contents of a text file',
  '  voice <list|set|preview> [name or id]',
  '  mute|unmute|mute-status <session_id>',
  '  stop|pause|resume|toggle|status|forward|rewind',
  '  hotkeys|diag',
  '',
  'Help never speaks: `say --help` prints this instead of reading it aloud.',
  'To speak something that starts with a dash, put it after `--`.',
].join('\n');

/** Splits argv at `--`. Everything after it is content, never an option. */
function splitLiteral(args) {
  const i = args.indexOf('--');
  return i === -1 ? [args, []] : [args.slice(0, i), args.slice(i + 1)];
}

const HELP_FLAGS = new Set(['--help', '-h', '-?', '/?', 'help']);
const wantsHelp = (args) => args.some((a) => HELP_FLAGS.has(a));

function usage(command) {
  console.log(USAGE[command] ?? TOP_LEVEL_USAGE);
  process.exit(0);
}

/**
 * Rejects an option this command does not know, rather than passing it along as
 * content. The message names the escape hatch, because sometimes the dash really
 * is part of what you meant to say.
 */
function rejectUnknownOptions(command, args) {
  const known = KNOWN_OPTIONS[command] ?? new Set();
  const bad = args.find((a) => a.length > 1 && a.startsWith('-') && !known.has(a));
  if (!bad) return;
  console.error(`agent-speak ${command}: unknown option ${bad}`);
  console.error(USAGE[command] ?? TOP_LEVEL_USAGE);
  console.error(`\nto use it as text: agent-speak ${command} -- ${bad}`);
  process.exit(2);
}

function readStdin(done) {
  let raw = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (c) => (raw += c));
  process.stdin.on('end', () => {
    try {
      done(JSON.parse(raw));
    } catch {
      done(null);
    }
  });
  process.stdin.on('error', () => done(null));
}

/** 'general-purpose' is what the tool calls it; nobody says that out loud. */
function spokenAgentName(type) {
  const t = String(type || '').trim();
  if (!t || t === 'general-purpose' || t === 'claude') return 'helper';
  return t.replace(/-/g, ' ').toLowerCase();
}

/**
 * Which subagent just finished, and what it was asked to do.
 *
 * SubagentStop says only that *a* subagent ended; it carries nothing about which
 * one. The subagent's own conversation is no help either - it is not persisted
 * anywhere on disk. What is persisted, in the parent's transcript, is the `Agent`
 * tool_use that started it, carrying the agent type and a one-line description
 * written for a human to read. That is the announcement.
 *
 * Matching the right call matters once a fan-out is running. Completions do not
 * arrive in spawn order, so the finished one is taken to be the oldest unspoken
 * call whose tool_result has already landed; if none has, the oldest unspoken
 * call is the better guess than silence.
 */
function subagentAnnouncement(payload) {
  const transcript = payload && payload.transcript_path;
  if (!transcript || !fs.existsSync(transcript)) return null;

  const sessionId =
    (payload && payload.session_id) || path.basename(transcript, '.jsonl');

  const calls = [];
  const settled = new Set();
  let lines;
  try {
    lines = fs.readFileSync(transcript, 'utf8').split(/\r?\n/);
  } catch {
    return null;
  }
  // The tail is enough: an announcement more than a few hundred entries old is
  // one this hook already made, or one nobody is still waiting to hear.
  for (const line of lines.slice(-800)) {
    if (!line) continue;
    let entry;
    try {
      entry = JSON.parse(line);
    } catch {
      continue;
    }
    const content = entry && entry.message && entry.message.content;
    if (!Array.isArray(content)) continue;
    for (const block of content) {
      if (block.type === 'tool_use' && (block.name === 'Agent' || block.name === 'Task')) {
        calls.push({
          id: block.id,
          type: (block.input && block.input.subagent_type) || '',
          description: (block.input && block.input.description) || '',
        });
      } else if (block.type === 'tool_result' && block.tool_use_id) {
        settled.add(block.tool_use_id);
      }
    }
  }
  if (!calls.length) return null;

  const stateFile = path.join(ANNOUNCED_DIR, `${sessionId}.json`);
  let announced = [];
  try {
    announced = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
    if (!Array.isArray(announced)) announced = [];
  } catch {
    /* no state yet, or unreadable - either way nothing has been announced */
  }

  const pending = calls.filter((c) => c.id && !announced.includes(c.id));
  if (!pending.length) return null;
  const done = pending.find((c) => settled.has(c.id)) || pending[0];

  announced.push(done.id);
  try {
    fs.mkdirSync(ANNOUNCED_DIR, { recursive: true });
    // Bounded, because a long session spawns a lot of agents and this is only
    // ever asked "have I said this one".
    fs.writeFileSync(stateFile, JSON.stringify(announced.slice(-50)), 'utf8');
  } catch {
    // Unwritable state means the line may be repeated later. Saying it twice is
    // a smaller failure than never saying it, so carry on.
  }

  const what = String(done.description || '').trim().replace(/[.\s]+$/, '');
  return what
    ? `The ${spokenAgentName(done.type)} agent finished: ${what}.`
    : `The ${spokenAgentName(done.type)} agent finished.`;
}

/** Queue one line, and hand the queue to a drainer if none is running. */
function queueLine(text, sessionId, print) {
  const file = writeTempText(text);
  const args = ['-Queue', '-TextFile', file];
  if (sessionId) args.push('-SessionId', sessionId);
  if (print) {
    runPowerShell(SPEAK, [...args, '-Print']);
    return;
  }
  runPowerShell(SPEAK, args, { detached: true });
}

function main() {
  const [command, ...rest] = process.argv.slice(2);

  // Help is answered before anything else, and on every platform, so asking a
  // command what it does can never be mistaken for telling it what to do.
  if (command === undefined || HELP_FLAGS.has(command)) {
    console.log(TOP_LEVEL_USAGE);
    process.exit(0);
  }

  // Everything below this line needs Windows. Say nothing and succeed.
  if (!isWindows()) {
    if (command === 'doctor') {
      console.log(`agent-speak: not supported on ${process.platform} yet (Windows only).`);
    }
    process.exit(0);
  }

  switch (command) {
    // -- hooks ---------------------------------------------------------------
    case 'session-start':
      // The agent is about to be told to write files into these, so they had
      // better exist. Doing it here rather than in the engine means the very
      // first cue of a fresh install lands somewhere.
      for (const dir of ['speak-cues', 'speak-labels']) {
        try {
          fs.mkdirSync(path.join(STATE_DIR, dir), { recursive: true });
        } catch {
          /* a session must start whether or not this works */
        }
      }
      // stdout from SessionStart is added to the model's context, which is the
      // only way the instruction to write cues can travel with the plugin.
      console.log(SESSION_BRIEF);
      break;

    // `--print` shows what would be spoken and speaks nothing. It is the only
    // way to debug a hook without filling the room with test audio, and it
    // leaves the turn's cue in place so the real hook can still consume it.
    case 'response':
      runPowerShell(SPEAK, ['-Mode', 'response', ...(rest.includes('--print') ? ['-Print'] : [])], {
        pipeStdin: true,
      });
      return;

    case 'notify':
      runPowerShell(SPEAK, ['-Mode', 'notify', ...(rest.includes('--print') ? ['-Print'] : [])], {
        pipeStdin: true,
      });
      return;

    case 'subagent-stop':
      readStdin((payload) => {
        const line = subagentAnnouncement(payload);
        // Nothing to say is the normal case for a subagent whose start was never
        // recorded. Say nothing, succeed, and do not guess.
        if (!line) process.exit(0);
        queueLine(line, (payload && payload.session_id) || '', rest.includes('--print'));
      });
      return;

    // -- narration -----------------------------------------------------------
    // Spoken during a turn, not at the end of one. Queued rather than spoken
    // outright: the agent may narrate twice in a row, and the second line must
    // not cut off the first.
    case 'say': {
      const [flagged, literal] = splitLiteral(rest);
      if (wantsHelp(flagged)) usage('say');

      const print = flagged.includes('--print');
      const [sessionId, afterSession] = takeSession(flagged.filter((a) => a !== '--print'));

      // `--file` exists so a long line never has to survive shell quoting,
      // which is the other half of how the wrong thing gets spoken.
      let text = null;
      let words = afterSession;
      const fi = words.indexOf('--file');
      if (fi !== -1) {
        const file = words[fi + 1];
        if (!file) {
          console.error('agent-speak say --file <path>');
          process.exit(2);
        }
        words = words.slice(0, fi).concat(words.slice(fi + 2));
        try {
          text = fs.readFileSync(file, 'utf8').trim();
        } catch (e) {
          console.error(`agent-speak say: cannot read ${file}: ${e.message}`);
          process.exit(2);
        }
      }

      rejectUnknownOptions('say', words);
      if (text === null) text = [...words, ...literal].join(' ').trim();

      if (!text) {
        console.error(USAGE.say);
        process.exit(2);
      }
      queueLine(text, sessionId, print);
      if (!print) console.log('queued');
      break;
    }

    // -- playback ------------------------------------------------------------
    case 'play': {
      // Detached on purpose: the whole point is that the turn ends and the user
      // can still pause, skip or stop what is playing.
      const args = ['-Latest'];
      if (rest[0]) args.push('-SessionId', rest[0]);
      runPowerShell(SPEAK, args, { detached: true });
      console.log('playing');
      break;
    }

    case 'speak': {
      const file = rest[0];
      if (!file) {
        console.error('agent-speak speak <text-file> [label]');
        process.exit(2);
      }
      const args = ['-TextFile', file];
      if (rest[1]) args.push('-Preamble', rest[1]);
      runPowerShell(SPEAK, args, { detached: true });
      console.log('speaking');
      break;
    }

    // -- per-session quiet ---------------------------------------------------
    // Keyed by session, because "be quiet" almost always means this window and
    // not the four others that are working fine.
    case 'mute':
    case 'unmute':
    case 'mute-status': {
      const id = rest[0];
      if (!id) {
        console.error(`agent-speak ${command} <session_id>`);
        process.exit(2);
      }
      const flag =
        command === 'mute' ? '-Mute' : command === 'unmute' ? '-Unmute' : '-MuteStatus';
      runPowerShell(SPEAK, [flag, '-SessionId', id]);
      return;
    }

    // -- transport -----------------------------------------------------------
    case 'stop':
    case 'pause':
    case 'resume':
    case 'toggle':
    case 'status':
    case 'forward':
    case 'rewind': {
      const switchName = '-' + command[0].toUpperCase() + command.slice(1);
      runPowerShell(SPEAK, [switchName]);
      return;
    }

    // -- hotkeys -------------------------------------------------------------
    case 'hotkeys':
      if (rest[0] === 'stop' || rest[0] === 'status') {
        runPowerShell(HOTKEYS, ['-' + rest[0][0].toUpperCase() + rest[0].slice(1)]);
        return;
      }
      runPowerShell(HOTKEYS, rest[0] === 'trace' ? ['-Trace'] : [], { detached: true });
      console.log('listening');
      break;

    // -- voice ---------------------------------------------------------------
    // The query is joined back from the remaining argv rather than taken as
    // rest[1], so an unquoted two-word name still resolves.
    case 'voice': {
      const [flagged, literal] = splitLiteral(rest);
      if (wantsHelp(flagged)) usage('voice');
      const action = flagged[0] || 'list';
      const nameArgs = flagged.slice(1);
      rejectUnknownOptions('voice', nameArgs);
      const query = [...nameArgs, ...literal].join(' ').trim();

      if (action === 'list') {
        runPowerShell(SPEAK, ['-Voices']);
        return;
      }

      if (action === 'set' || action === 'preview') {
        if (!query) {
          console.error(`agent-speak voice ${action} <name or id>`);
          process.exit(2);
        }
        if (action === 'set') {
          runPowerShell(SPEAK, ['-SetVoice', query]);
          return;
        }
        // Detached for the same reason speak is: the sample keeps playing after
        // the turn ends, and stays pausable while it does.
        runPowerShell(SPEAK, ['-PreviewVoice', query], { detached: true });
        console.log('previewing');
        break;
      }

      console.error('agent-speak voice <list|set|preview> [name or id]');
      process.exit(2);
    }

    case 'diag':
    case 'doctor':
      runPowerShell(SPEAK, ['-Diag']);
      return;

    // An unrecognised command is a mistake, and exits non-zero so a script
    // that mistypes one finds out rather than carrying on in silence.
    default:
      console.error(`agent-speak: unknown command ${command}`);
      console.error(TOP_LEVEL_USAGE);
      process.exit(2);
  }
}

main();
