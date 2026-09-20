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

The user can say "play the full response" to hear the whole answer, and
"pause", "resume" or "stop" to control playback. Treat those bare phrases as
commands, not as conversation.
</agent-speak>`;

function isWindows() {
  return process.platform === 'win32';
}

/** Run a PowerShell script, forwarding stdin, and exit with its code. */
function runPowerShell(script, args, { pipeStdin = false, detached = false } = {}) {
  const full = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script, ...args];

  if (detached) {
    // Playback blocks for the length of the audio. A hook that waited for it
    // would hold the turn open for minutes, so the player is let go of instead.
    const child = spawn('powershell', full, {
      detached: true,
      stdio: 'ignore',
      windowsHide: true,
    });
    child.unref();
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

function main() {
  const [command, ...rest] = process.argv.slice(2);

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

    case 'diag':
    case 'doctor':
      runPowerShell(SPEAK, ['-Diag']);
      return;

    default:
      console.log(
        'agent-speak <play|speak|stop|pause|resume|toggle|status|forward|rewind|hotkeys|diag>'
      );
      break;
  }
}

main();
