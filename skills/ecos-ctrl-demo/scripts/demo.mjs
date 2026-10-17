#!/usr/bin/env node
// Drive a full ECOS Studio demo over the --ctrl interface.
//
// Stages, each sent as one `ctl batch` so its caption stays on screen while
// the stage runs (captions are cleared whenever a client connection closes):
//
//   1. create  a workspace from an ecc.toml design directory
//   2. open    it from the Projects page (retried: the first click right
//              after a create can be dropped silently by the GUI)
//   3. run     click the flow Run button (retried on TARGET_OBSCURED: the
//              dashboard is still settling right after it opens)
//   4. wait    for the flow operation to reach a terminal state
//
// Node.js standard library only (Node >= 18). Exit code 0 means every
// requested stage finished and, when the flow ran, every step finished;
// anything else prints the reason and exits 1 (usage errors exit 2).

import { spawnSync } from 'node:child_process'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseArgs } from 'node:util'

const CTL = join(dirname(fileURLToPath(import.meta.url)), 'ctl')
const RETRYABLE = new Set(['TARGET_OBSCURED', 'TARGET_NOT_FOUND', 'TIMEOUT'])

const USAGE = `usage: demo.mjs --design DIR --name WS
                (--projects-dir DIR | --project ROOT)
                (--pdk-root DIR | --pdk-id ID)
                [--set KEY=VALUE]... [--pace MS] [--timeout-min N] [--no-run]`

class StageError extends Error {}

const sleep = (ms) => new Promise((done) => setTimeout(done, ms))

/**
 * Send requests over one connection; return one result per request. The
 * batch stops at the first error, so the result list may be shorter than
 * `requests`; its last item then carries `{ error: { code, message } }`.
 */
function batch(requests, timeoutS) {
  const input = requests.map((r) => JSON.stringify(r)).join('\n') + '\n'
  const proc = spawnSync(CTL, ['batch'], {
    encoding: 'utf8',
    input,
    maxBuffer: 64 * 1024 * 1024,
    timeout: timeoutS * 1000,
  })
  if (proc.error) throw new StageError(`ctl batch did not finish: ${proc.error.message}`)
  const results = []
  for (const raw of proc.stdout.split('\n')) {
    const line = raw.trim()
    if (!line.startsWith('{')) continue
    const item = JSON.parse(line)
    // create/load progress lines are not request results.
    if ('index' in item && 'total' in item && 'status' in item && !('items' in item)) continue
    results.push(item)
  }
  if (results.length === 0 && ![0, 1, 4].includes(proc.status)) {
    throw new StageError(`ctl batch failed (exit ${proc.status}): ${proc.stderr.trim()}`)
  }
  return results
}

const errorOf = (results) => results.find((item) => 'error' in item)?.error ?? null

const presentation = (paceMs, caption) => [
  { method: 'pace', params: { delayMs: paceMs, cues: true } },
  { method: 'caption', params: { text: caption, durationMs: 0 } },
]

function state() {
  const [result] = batch([{ method: 'state', params: {} }], 120)
  return result && !('error' in result) ? result : null
}

/** Run a stage, retrying retryable target errors after a short pause. */
async function stageWithRetry(name, requests, { attempts, timeoutS, done }) {
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    const results = batch(requests, timeoutS)
    const err = errorOf(results)
    if (!err) return results
    if (done()) {
      console.log(`[${name}] already done after ${err.code}; continuing`)
      return results
    }
    if (!RETRYABLE.has(err.code) || attempt === attempts) {
      throw new StageError(`[${name}] failed: ${JSON.stringify(err)}`)
    }
    console.log(`[${name}] attempt ${attempt} hit ${err.code}; retrying in 3s`)
    await sleep(3000)
  }
  throw new StageError(`[${name}] exhausted retries`)
}

function parseCli() {
  const { values } = parseArgs({
    options: {
      design: { type: 'string' },
      name: { type: 'string' },
      'projects-dir': { type: 'string' },
      project: { type: 'string' },
      'pdk-root': { type: 'string' },
      'pdk-id': { type: 'string' },
      set: { type: 'string', multiple: true, default: [] },
      pace: { type: 'string', default: '1200' },
      'timeout-min': { type: 'string', default: '30' },
      'no-run': { type: 'boolean', default: false },
      help: { type: 'boolean', short: 'h', default: false },
    },
  })
  const exactlyOne = (a, b) => Boolean(values[a]) !== Boolean(values[b])
  if (
    values.help ||
    !values.design ||
    !values.name ||
    !exactlyOne('projects-dir', 'project') ||
    !exactlyOne('pdk-root', 'pdk-id')
  ) {
    console.error(USAGE)
    process.exit(values.help ? 0 : 2)
  }
  return values
}

function buildCreate(values) {
  const item = {
    kind: 'design',
    designDir: resolve(values.design),
    workspaceName: values.name,
    pdk: values['pdk-root']
      ? { root: resolve(values['pdk-root']) }
      : { installationId: values['pdk-id'] },
  }
  if (values.project) item.projectRoot = resolve(values.project)
  if (values.set.length > 0) {
    item.set = {}
    for (const pair of values.set) {
      const at = pair.indexOf('=')
      if (at <= 0) throw new StageError(`--set needs KEY=VALUE, got ${JSON.stringify(pair)}`)
      const raw = pair.slice(at + 1)
      let value = raw
      try {
        value = JSON.parse(raw) // numbers and booleans keep their type
      } catch {
        // plain strings stay strings
      }
      item.set[pair.slice(0, at)] = value
    }
  }
  // No `focus`: when the item fails, a focus turns the item error into a
  // generic BAD_REQUEST that hides the real cause (e.g. target_exists).
  const create = { items: [item] }
  if (values['projects-dir']) create.projectsDir = resolve(values['projects-dir'])
  return create
}

async function main() {
  const values = parseCli()
  const pace = Number(values.pace)
  const create = buildCreate(values)

  // 1. create
  let results = batch(
    [
      ...presentation(pace, `Create workspace ${values.name}`),
      { method: 'create', params: create },
    ],
    15 * 60,
  )
  let err = errorOf(results)
  if (err) throw new StageError(`[create] failed: ${JSON.stringify(err)}`)
  const created = results.at(-1).items[0]
  if (created.status !== 'created') {
    const code = created.error?.code ?? created.status
    throw new StageError(
      `[create] item not created (${code}); see reference/ctl-reference.md: ${JSON.stringify(created)}`,
    )
  }
  const workspacePath = created.targetDirectory
  console.log(`[create] ${workspacePath}`)

  // 2. open
  const openButton = { role: 'button', name: `Open workspace ${values.name}` }
  const opened = () => {
    const s = state()
    return s?.route === '/workspace/home' && s?.workspace?.path === workspacePath
  }
  await stageWithRetry(
    'open',
    [
      ...presentation(pace, `Open ${values.name}`),
      { method: 'waitFor', params: { target: openButton, state: 'enabled', timeoutMs: 30000 } },
      { method: 'click', params: { target: openButton } },
      { method: 'waitFor', params: { route: '/workspace/home', timeoutMs: 20000 } },
    ],
    { attempts: 3, timeoutS: 180, done: opened },
  )
  if (!opened()) throw new StageError('[open] the control window did not open the new workspace')
  console.log('[open] /workspace/home')
  if (values['no-run']) return 0

  // 3. run
  const runButton = { testId: 'flow-run' }
  const running = () => Boolean(state()?.flow?.running)
  await stageWithRetry(
    'run',
    [
      ...presentation(pace, 'Run the full RTL-to-GDS flow'),
      { method: 'waitFor', params: { target: runButton, state: 'enabled', timeoutMs: 30000 } },
      { method: 'click', params: { target: runButton } },
    ],
    { attempts: 4, timeoutS: 180, done: running },
  )
  console.log('[run] flow started')

  // 4. wait (one connection, so the caption stays up for the whole run)
  const timeoutMs = Math.min(Number(values['timeout-min']), 30) * 60 * 1000
  results = batch(
    [
      ...presentation(pace, 'Flow running...'),
      { method: 'waitFor', params: { operation: true, timeoutMs } },
    ],
    timeoutMs / 1000 + 300,
  )
  err = errorOf(results)
  if (err) {
    console.log(`[wait] ${err.code}: ${err.message}`)
    console.log('[wait] the flow keeps running in the GUI; check it with `ctl state`')
    return 1
  }
  const status = results.at(-1).status
  console.log(`[wait] operation status: ${status}`)
  const steps = state()?.flow?.steps ?? []
  for (const step of steps) console.log(`  ${step.name.padEnd(24)} ${step.status}`)
  // The GUI can report "succeeded" when ECC failed before any step ran, so
  // success also requires every step to have actually finished.
  const unfinished = steps
    .filter((step) => !['succeeded', 'skipped'].includes(step.status))
    .map((step) => step.name)
  if (status === 'succeeded' && unfinished.length > 0) {
    console.log(`[wait] reported succeeded, but these steps did not finish: ${unfinished.join(', ')}`)
    console.log('[wait] read the ECC run log: <workspace>/log/<operationId>.log')
    return 1
  }
  return status === 'succeeded' ? 0 : 1
}

main().then(
  (code) => process.exit(code),
  (error) => {
    console.error(error instanceof StageError ? error.message : error)
    process.exit(1)
  },
)
