#!/usr/bin/env node
// Builds recipes/boat-sandbox.json from src/. Orca gives a recipe command neither this folder nor any
// settings, so each phase becomes one self-contained `exec bash -c '...'` command: the library
// functions that phase calls, then the phase script. `exec` keeps stdin, which carries Orca's
// lifecycle JSON. No dependencies: Orca installs this folder as is, node_modules included.
//
//   node build.mjs          write recipes/boat-sandbox.json
//   node build.mjs --check  fail if it is out of date or any phase is unsound

import { spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = dirname(fileURLToPath(import.meta.url))
const RECIPE_PATH = 'recipes/boat-sandbox.json'
const PHASES = ['create', 'suspend', 'resume', 'destroy']
const MAX_COMMAND_BYTES = 32 * 1024
const MAX_RECIPE_BYTES = 256 * 1024
const GH_WRAPPER_PLACEHOLDER = '@@gh-wrapper.sh@@'
// macOS ships bash 3.2, and Orca runs these commands on the desktop.
const BASH4_ONLY = [
  [/\bdeclare\s+-[a-zA-Z]*A/, 'declare -A'],
  [/\b(mapfile|readarray|coproc)\b/, 'mapfile/readarray/coproc'],
  [/\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^)/, '${var,,} / ${var^^}'],
  [/&>>/, '&>>'],
  [/\|&/, '|&'],
  [/\blocal\s+-n\b/, 'local -n'],
  [/\[\[\s+-v\s/, '[[ -v ]]'],
  [/;;&|;&/, ';;& / ;&']
]

const read = (path) => readFileSync(join(ROOT, path), 'utf8')
const bytes = (text) => Buffer.byteLength(text, 'utf8')
const isComment = (line) => line.trimStart().startsWith('#')

function fail(message) {
  console.error(`build: ${message}`)
  process.exit(1)
}

// Splits lib.sh into top-level assignments and named functions. Doc comments stay in lib.sh, except
// shellcheck directives: commands are capped at MAX_COMMAND_BYTES and the prose does not run.
function parseLibrary(text) {
  const lines = text.split('\n')
  const fnStart = /^([a-z_][a-z0-9_]*)\(\) \{/
  const topLevel = /^(set -|export |[A-Za-z_][A-Za-z0-9_]*=)/
  const preamble = []
  const functions = new Map()
  let pending = []
  let i = 0
  while (i < lines.length && (lines[i].trim() === '' || isComment(lines[i]))) i++

  const docComment = () => {
    const doc = []
    for (let k = pending.length - 1; k >= 0 && isComment(pending[k]); k--) doc.unshift(pending[k])
    pending = []
    return doc.filter((line) => /^\s*# shellcheck /.test(line))
  }

  for (; i < lines.length; i++) {
    const line = lines[i]
    const start = fnStart.exec(line)
    if (start) {
      const body = [...docComment(), line]
      if (!line.trimEnd().endsWith('}')) {
        for (i++; i < lines.length && lines[i] !== '}'; i++) body.push(lines[i])
        if (i >= lines.length) fail(`lib.sh: function ${start[1]} is never closed with a "}" line`)
        body.push('}')
      }
      functions.set(start[1], body.join('\n'))
    } else if (line.trim() === '' || isComment(line)) {
      pending.push(line)
    } else if (topLevel.test(line)) {
      preamble.push(...docComment(), line)
    } else {
      fail(`lib.sh line ${i + 1}: only set, export and variable assignments may sit outside a function`)
    }
  }
  return { preamble: preamble.join('\n'), functions }
}

const identifiers = (text) =>
  new Set(
    text
      .split('\n')
      .filter((line) => !isComment(line))
      .join('\n')
      .match(/[A-Za-z_][A-Za-z0-9_]*/g) ?? []
  )

function neededFunctions(library, phaseBody) {
  const needed = new Set()
  const queue = [...identifiers(phaseBody)]
  while (queue.length > 0) {
    const name = queue.pop()
    if (!library.functions.has(name) || needed.has(name)) continue
    needed.add(name)
    queue.push(...identifiers(library.functions.get(name)))
  }
  return [...library.functions.keys()].filter((name) => needed.has(name))
}

function assemble(phase, library, repository) {
  const phaseBody = read(`src/${phase}.sh`).replace(/^# shellcheck .*\n/, '').trim()
  const parts = [
    `# Boat.dev sandbox plugin, ${phase} phase. Generated from src/ at ${repository}`,
    library.preamble,
    ...neededFunctions(library, phaseBody).map((name) => library.functions.get(name)),
    phaseBody
  ]
  let script = `${parts.join('\n\n')}\n`
  if (script.includes(GH_WRAPPER_PLACEHOLDER)) {
    const wrapper = read('src/gh-wrapper.sh').trimEnd()
    if (/^(ORCA_GH_WRAPPER|REMOTE)$/m.test(wrapper)) fail('gh-wrapper.sh contains a heredoc terminator line')
    script = script.replace(GH_WRAPPER_PLACEHOLDER, () => wrapper)
  }
  if (script.includes('@@')) fail(`${phase}: an @@placeholder@@ was left in the script`)
  return script
}

function toCommand(phase, script) {
  const command = `exec bash -c '${script.replaceAll("'", "'\\''")}' boat-sandbox-${phase}`
  if (command.includes('\0')) fail(`${phase}: the command contains a NUL byte`)
  if (bytes(command) > MAX_COMMAND_BYTES) {
    fail(`${phase}: ${bytes(command)} bytes, over the ${MAX_COMMAND_BYTES} byte limit Orca allows per command`)
  }
  return command
}

function buildRecipe() {
  const manifest = JSON.parse(read('orca-plugin.json'))
  const library = parseLibrary(read('src/lib.sh'))
  const scripts = {}
  const commands = {}
  for (const phase of PHASES) {
    scripts[phase] = assemble(phase, library, manifest.repository)
    commands[phase] = toCommand(phase, scripts[phase])
  }
  const recipe = {
    schemaVersion: 1,
    id: 'boat-sandbox',
    name: 'Boat.dev sandbox',
    description:
      'Runs the workspace in a fresh boat.dev sandbox and checks out the repo there. Needs the boat CLI and jq on macOS or Linux.',
    checkoutMode: 'provisioned-root',
    ...commands
  }
  const json = `${JSON.stringify(recipe, null, 2)}\n`
  if (bytes(json) > MAX_RECIPE_BYTES) fail(`recipe file is ${bytes(json)} bytes, over ${MAX_RECIPE_BYTES}`)
  return { json, scripts, commands }
}

function checkScripts(scripts) {
  const dir = mkdtempSync(join(tmpdir(), 'boat-sandbox-build-'))
  const problems = []
  const haveShellcheck = spawnSync('shellcheck', ['--version'], { stdio: 'ignore' }).status === 0
  if (!haveShellcheck) {
    if (process.env.CI) problems.push('shellcheck is not installed')
    else console.warn('build: shellcheck is not installed; skipping it (CI requires it)')
  }
  try {
    for (const [phase, script] of Object.entries(scripts)) {
      const file = join(dir, `${phase}.sh`)
      writeFileSync(file, script)
      const syntax = spawnSync('bash', ['-n', file], { encoding: 'utf8' })
      if (syntax.status !== 0) problems.push(`${phase}: bash -n failed\n${syntax.stderr}`)
      for (const [pattern, label] of BASH4_ONLY) {
        if (pattern.test(script)) problems.push(`${phase}: uses ${label}, which bash 3.2 lacks`)
      }
      if (haveShellcheck) {
        // SC2034: a phase uses only some of the variables the library declares.
        const lint = spawnSync('shellcheck', ['-s', 'bash', '-e', 'SC2034', file], { encoding: 'utf8' })
        if (lint.status !== 0) problems.push(`${phase}: shellcheck\n${lint.stdout}${lint.stderr}`)
      }
    }
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
  return problems
}

function checkManifest() {
  const problems = []
  const manifest = JSON.parse(read('orca-plugin.json'))
  if (manifest.contributes?.vmRecipes?.[0]?.path !== RECIPE_PATH) {
    problems.push(`orca-plugin.json must contribute ${RECIPE_PATH}`)
  }
  if (!/^>=\d+\.\d+\.\d+$/.test(manifest.engines?.orca ?? '')) {
    problems.push('orca-plugin.json engines.orca must look like ">=1.4.199"')
  }
  if (manifest.main !== undefined || (manifest.capabilities ?? []).length > 0) {
    problems.push('orca-plugin.json must not declare a worker or capabilities')
  }
  const changelogVersion = /^## \[?(\d+\.\d+\.\d+)\]?/m.exec(read('CHANGELOG.md'))?.[1]
  if (changelogVersion !== manifest.version) {
    problems.push(`CHANGELOG.md latest version (${changelogVersion}) differs from orca-plugin.json (${manifest.version})`)
  }
  return problems
}

const { json, scripts, commands } = buildRecipe()
for (const phase of PHASES) console.log(`build: ${phase.padEnd(8)} ${bytes(commands[phase])} / ${MAX_COMMAND_BYTES} bytes`)

if (process.argv.includes('--check')) {
  const problems = [...checkManifest(), ...checkScripts(scripts)]
  let current = ''
  try {
    current = read(RECIPE_PATH)
  } catch {
    // reported below
  }
  if (current !== json) problems.push(`${RECIPE_PATH} is out of date; run: node build.mjs`)
  if (problems.length > 0) fail(`check failed:\n${problems.map((p) => `- ${p}`).join('\n')}`)
  console.log('build: check passed')
} else {
  writeFileSync(join(ROOT, RECIPE_PATH), json)
  console.log(`build: wrote ${RECIPE_PATH}`)
}
