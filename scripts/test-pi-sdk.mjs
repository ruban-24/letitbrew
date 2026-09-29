// Optional installed-Pi integration. The caller owns the disposable fixture root.
import assert from 'node:assert/strict'
import fs from 'node:fs/promises'
import path from 'node:path'
import { pathToFileURL } from 'node:url'

export async function testInstalledPi(packageDir, extension, emissions) {
  assert(path.isAbsolute(packageDir))
  const root = path.dirname(extension)
  const agentDir = path.join(root, 'pi')
  await fs.mkdir(path.join(agentDir, 'extensions'), { recursive: true })
  await fs.copyFile(extension, path.join(agentDir, 'extensions', 'letitbrew.ts'))
  const previousAgentDir = process.env.PI_CODING_AGENT_DIR
  process.env.PI_CODING_AGENT_DIR = agentDir
  const originalFetch = globalThis.fetch
  globalThis.fetch = () => { throw new Error('Network forbidden in Pi fixture') }
  let session
  try {
    const sdk = await import(pathToFileURL(path.join(packageDir, 'dist/index.js')))
    const { AssistantMessageEventStream } = await import(pathToFileURL(path.join(packageDir, '../pi-ai/dist/utils/event-stream.js')))
    const cwd = path.join(root, 'project')
    await fs.mkdir(cwd)
    let loaded = await sdk.discoverAndLoadExtensions([], cwd, agentDir)
    assert.deepEqual(loaded.errors, [])
    assert.equal(loaded.extensions.length, 1, 'Pi discovers the global .ts extension')
    const { loadExtensionFromFactory } = await import(pathToFileURL(path.join(packageDir, 'dist/core/extensions/loader.js')))
    let compactMode = 'success'
    loaded.extensions.push(await loadExtensionFromFactory(pi => {
      pi.on('session_before_compact', event => compactMode === 'cancel' ? { cancel: true } : {
        compaction: { summary: 'Local fixture summary', firstKeptEntryId: event.preparation.firstKeptEntryId,
          tokensBefore: event.preparation.tokensBefore },
      })
    }, cwd, sdk.createEventBus(), loaded.runtime, '<local-compaction-fixture>'))
    const resourceLoader = {
      getExtensions: () => loaded,
      getSkills: () => ({ skills: [], diagnostics: [] }),
      getPrompts: () => ({ prompts: [], diagnostics: [] }),
      getThemes: () => ({ themes: [], diagnostics: [] }),
      getAgentsFiles: () => ({ agentsFiles: [] }),
      getSystemPrompt: () => 'Local integration fixture.',
      getSystemPromptSource: () => undefined,
      getAppendSystemPrompt: () => [],
      getAppendSystemPromptSources: () => [],
      extendResources: () => {},
      reload: async () => { loaded = await sdk.discoverAndLoadExtensions([], cwd, agentDir) },
    }
    const modelRuntime = await sdk.ModelRuntime.create({
      authPath: path.join(agentDir, 'auth.json'),
      modelsPath: path.join(agentDir, 'models.json'),
      modelsStorePath: path.join(agentDir, 'models-store.json'),
      allowModelNetwork: false, refreshOnCreate: false,
    })
    modelRuntime.registerProvider('letitbrew-fixture', {
      api: 'openai-completions', apiKey: 'local-fixture-only', baseUrl: 'http://127.0.0.1:1',
      models: [{ id: 'fixture', name: 'Fixture', reasoning: false, input: ['text'],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 32000, maxTokens: 32 }],
    })
    const model = modelRuntime.getModel('letitbrew-fixture', 'fixture')
    assert(model)
    ;({ session } = await sdk.createAgentSession({
      cwd, agentDir, modelRuntime, model, resourceLoader, tools: [], thinkingLevel: 'off',
      sessionManager: sdk.SessionManager.inMemory(cwd),
      settingsManager: sdk.SettingsManager.inMemory({ compaction: { enabled: false, keepRecentTokens: 1, reserveTokens: 32 }, retry: { enabled: false, baseDelayMs: 1, maxDelayMs: 1, maxRetries: 2 } }),
    }))
    const errors = []
    let answerPrompt
    await session.bindExtensions({ mode: 'interactive', onError: e => errors.push(e),
      uiContext: { confirm: () => new Promise(resolve => { answerPrompt = resolve }) } })
    const start = (await emissions()).at(-1)
    assert.equal(start.args[2], 'SessionStart')
    const id = start.payload.session_id
    let finishRequest
    session.agent.streamFunction = () => {
      const stream = new AssistantMessageEventStream()
      finishRequest = () => {
        const message = { role: 'assistant', content: [{ type: 'text', text: 'Fixture answer' }],
          api: model.api, provider: model.provider, model: model.id, stopReason: 'stop', timestamp: Date.now(),
          usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2,
            cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } }
        stream.push({ type: 'done', reason: 'stop', message })
      }
      return stream
    }
    const until = async predicate => {
      for (let i = 0; i < 150; i++) {
        if (await predicate()) return
        await new Promise(resolve => setTimeout(resolve, 20))
      }
      throw new Error('Pi fixture timed out')
    }
    const lastEvent = async () => (await emissions()).at(-1)?.args[2]
    const request = session.prompt('Private fixture prompt, never forward its contents.')
    await until(() => finishRequest)
    assert.equal(await lastEvent(), 'UserPromptSubmit')
    const prompt = session.extensionRunner.getUIContext().confirm('Private title', 'Private question')
    await until(async () => await lastEvent() === 'UserInputRequested')
    answerPrompt(true)
    await prompt
    await until(async () => await lastEvent() === 'UserInputResolved')
    finishRequest()
    await request
    assert.equal(await lastEvent(), 'Stop', 'real Pi settlement releases the run')
    // Failure and abort must settle through the real agent loop, not manually
    // dispatched lifecycle events. This stream replaces only the provider.
    const message = (stopReason, errorMessage) => ({
      role: 'assistant', content: stopReason === 'stop' ? [{ type: 'text', text: 'Fixture answer' }] : [],
      api: model.api, provider: model.provider, model: model.id, stopReason, errorMessage, timestamp: Date.now(),
      usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
    })
    const finish = (stream, reason, errorMessage) => {
      if (reason === 'stop') stream.push({ type: 'done', reason, message: message(reason) })
      else stream.push({ type: 'error', reason, error: message(reason, errorMessage) })
    }
    session.agent.streamFunction = () => {
      const stream = new AssistantMessageEventStream()
      finish(stream, 'error', 'Fixture terminal failure')
      return stream
    }
    await session.prompt('Fixture failure')
    assert.equal(await lastEvent(), 'Stop', 'failed request releases work')
    let enteredAbortRequest = false
    session.agent.streamFunction = (_model, _context, options) => {
      const stream = new AssistantMessageEventStream()
      enteredAbortRequest = true
      options.signal.addEventListener('abort', () => finish(stream, 'aborted', 'Fixture cancelled'), { once: true })
      return stream
    }
    const abortedRequest = session.prompt('Fixture cancellation')
    await until(() => enteredAbortRequest)
    assert.equal(await lastEvent(), 'UserPromptSubmit')
    await session.abort()
    await abortedRequest
    assert.equal(await lastEvent(), 'Stop', 'cancelled request releases work')
    let attempts = 0
    const retryStart = (await emissions()).length
    session.setAutoRetryEnabled(true)
    session.agent.streamFunction = () => {
      const stream = new AssistantMessageEventStream()
      attempts++
      finish(stream, attempts === 1 ? 'error' : 'stop', attempts === 1 ? '429 rate limit exceeded' : undefined)
      return stream
    }
    await session.prompt('Fixture retry')
    assert.equal(attempts, 2, 'the real retry loop runs the next provider attempt')
    const retryEvents = (await emissions()).slice(retryStart).map(x => x.args[2])
    assert.equal(retryEvents.at(-1), 'Stop')
    assert.equal(retryEvents.filter(x => x === 'Stop').length, 1, 'retry never releases early')
    session.setAutoRetryEnabled(false)
    // A real compaction command uses local extension-provided summary content.
    compactMode = 'cancel'
    const compactStart = (await emissions()).length
    await assert.rejects(session.compact(), /cancelled/)
    assert.deepEqual((await emissions()).slice(compactStart).map(x => x.args[2]), ['UserPromptSubmit', 'Stop'])
    compactMode = 'success'
    await session.compact()
    assert.equal(await lastEvent(), 'Stop', 'completed manual compaction releases work')
    await session.reload()
    const afterReload = await emissions()
    assert.equal(afterReload.at(-2).args[2], 'SessionEnd')
    assert.equal(afterReload.at(-2).payload.session_id, id)
    assert.equal(afterReload.at(-1).args[2], 'SessionStart')
    assert.notEqual(afterReload.at(-1).payload.session_id, id)
    const runtime = new sdk.AgentSessionRuntime(session, { cwd, agentDir }, async options => {
      await resourceLoader.reload()
      const result = await sdk.createAgentSession({ ...options, modelRuntime, model, resourceLoader,
        tools: [], thinkingLevel: 'off', settingsManager: sdk.SettingsManager.inMemory({ compaction: { enabled: false } }) })
      return { ...result, services: { cwd, agentDir }, diagnostics: [] }
    })
    runtime.setRebindSession(async next => {
      session = next
      await next.bindExtensions({ mode: 'print', onError: e => errors.push(e) })
    })
    const assertReplacement = async operation => {
      const previousID = (await emissions()).at(-1).payload.session_id
      const start = (await emissions()).length
      const result = await operation()
      assert.equal(result.cancelled, false)
      const events = (await emissions()).slice(start)
      assert.deepEqual(events.map(x => x.args[2]), ['SessionEnd', 'SessionStart'])
      assert.equal(events[0].payload.session_id, previousID)
      assert.notEqual(events[1].payload.session_id, previousID)
    }
    const forkEntry = session.sessionManager.getEntries().find(e => e.type === 'message' && e.message.role === 'user')
    assert(forkEntry)
    await assertReplacement(() => runtime.fork(forkEntry.id, { position: 'at' }))
    await assertReplacement(() => runtime.newSession())
    await runtime.dispose()
    assert.equal(await lastEvent(), 'SessionEnd')
    assert.deepEqual(errors, [])
    assert(!(await fs.readFile(path.join(root, 'events.jsonl'), 'utf8')).includes('Private'))
    console.error('PASS: installed Pi SDK discovery, run, UI wait, failure, cancellation, retry, compaction, reload, fork, new session, shutdown')
  } finally {
    session?.dispose()
    globalThis.fetch = originalFetch
    if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR
    else process.env.PI_CODING_AGENT_DIR = previousAgentDir
  }
}
