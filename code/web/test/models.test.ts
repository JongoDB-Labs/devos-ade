// The Code page's model picker: every model of /.bn/models (Bedrock's and OpenRouter's), grouped by provider, searched,
// starred, with how each works as Claude Code's model; free models at $0; the status bar's tips.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { normModels } from '../src/api';
import { compatWarning, findModel, groupOf, hiddenCount, modelMatches, modelSections, nameTheModel, providerSetups, COMPAT_INFO, PROVIDER_SETUP } from '../src/models';
import { SETUP_LINKS } from '../src/setuplinks';
import { parsePrefs, STARRED_MAX } from '../src/prefs';
import { cacheNotice, CACHE_TTL_MS, caches } from '../src/budget';
import { ariaKeys } from '../src/components/ui';
import { keysFor, shortcuts } from '../src/shortcuts';
import type { BnModel } from '../src/types';

const RAW = {
  models: [
    { id: 'claude-opus-5-5', name: 'Claude Opus 5.5', provider: 'Bedrock', vendor: 'Anthropic', compat: 'works', listed: true, input_per_mtok: 4.4, output_per_mtok: 22, cache_write_per_mtok: 5.5, cache_read_per_mtok: 0.22 },
    { id: 'claude-haiku-5-5', name: 'Claude Haiku 5.5', provider: 'Bedrock', vendor: 'Anthropic', compat: 'works', listed: true, input_per_mtok: 0.11, output_per_mtok: 0.55, cache_write_per_mtok: 0.1375 },
    { id: 'llama-3-3-70b', name: 'Llama 3.3 70B', provider: 'Bedrock', vendor: 'Meta', compat: 'chat-only', listed: true, note: 'Writes tool calls as text.', input_per_mtok: 0.72, output_per_mtok: 0.72 },
    { id: 'mistral-large-3', name: 'Mistral Large 3', provider: 'Bedrock', vendor: 'Mistral', compat: 'works', listed: false, input_per_mtok: 0.5, output_per_mtok: 1.5 },
    { id: 'grok-4-7', name: 'Grok 4.7', provider: 'Bedrock', vendor: 'xAI', compat: 'fails', listed: true, input_per_mtok: 2.2, output_per_mtok: 6.6 },
    // a free model is $0 whatever else it claims (never spend), and has no cache prices
    { id: 'or/google/gemma-4-31b-it:free', name: 'Gemma 4 31B (free)', provider: 'OpenRouter', vendor: 'Google', compat: 'untested', listed: true, free: true, input_per_mtok: 9, cache_write_per_mtok: 1, context: 262144 },
    { id: 'or/google/gemma-4-31b-it', name: 'Gemma 4 31B', provider: 'OpenRouter', vendor: 'Google', compat: 'bogus', listed: true, input_per_mtok: 0.09, output_per_mtok: 0.34, context: -5 },
    { id: 'or/google/gemma-4-31b-it', name: 'duplicate', provider: 'OpenRouter' },
    { id: '../../etc/passwd', name: 'bad id' },
    { id: 'x'.repeat(200), name: 'too long' },
    { id: 'claude-sonnet-5-5', name: 'Claude Sonnet 5.5' },   // an older portal: no provider, vendor, compat
  ],
  aliases: { opus: 'claude-opus-5-5', haiku: 'claude-haiku-5-5' },
  default: 'claude-opus-5-5',
  scope: { mode: 'anthropic', listed: 99, total: 99 },
};

test('models: /.bn/models parsed with provider, vendor, compatibility, listing; free at $0; bad rows dropped', () => {
  const bn = normModels(RAW);
  assert.deepEqual(bn.models.map((m) => m.id), ['claude-opus-5-5', 'claude-haiku-5-5', 'llama-3-3-70b', 'mistral-large-3', 'grok-4-7', 'or/google/gemma-4-31b-it:free', 'or/google/gemma-4-31b-it', 'claude-sonnet-5-5']);
  const by = Object.fromEntries(bn.models.map((m) => [m.id, m]));
  const free = by['or/google/gemma-4-31b-it:free'];
  assert.deepEqual([free.free, free.input, free.output, free.cacheWrite, free.cacheRead, free.context], [true, 0, 0, null, null, 262144]);
  assert.equal(by['or/google/gemma-4-31b-it'].compat, 'untested', 'an unknown word is untested');
  assert.equal(by['or/google/gemma-4-31b-it'].context, null);
  assert.equal(by['llama-3-3-70b'].note, 'Writes tool calls as text.');
  assert.equal(by['mistral-large-3'].listed, false);
  assert.deepEqual([by['claude-sonnet-5-5'].vendor, by['claude-sonnet-5-5'].compat, by['claude-sonnet-5-5'].provider, by['claude-sonnet-5-5'].listed], ['Anthropic', 'works', 'Bedrock', true]);
  assert.equal(by['claude-opus-5-5'].alias, 'opus');
  // the scope's counts are the page's own
  assert.deepEqual(bn.scope, { mode: 'anthropic', listed: 7, total: 8 });
  assert.equal(normModels({ models: [] }).scope, null);
  assert.equal(normModels(null).models.length, 0);
});

test('models: a provider without its key is a greyed item that goes where the key goes in (Settings › Models & providers)', () => {
  // (the portal says which have a key; an older one says nothing: no item)
  assert.equal(normModels(RAW).providers, null);
  assert.deepEqual(providerSetups(normModels(RAW)), []);
  assert.deepEqual(normModels({ ...RAW, providers: { openrouter: true, explabs: 'yes' } }).providers, { openrouter: true, explabs: false });
  assert.deepEqual(providerSetups(normModels({ ...RAW, providers: { openrouter: false, explabs: false } })), ['openrouter-off', 'explabs-off']);
  assert.deepEqual(providerSetups(normModels({ ...RAW, providers: { openrouter: true, explabs: false } })), ['explabs-off']);
  assert.deepEqual(providerSetups(normModels({ ...RAW, providers: { openrouter: true, explabs: true } })), []);
  for (const r of Object.keys(PROVIDER_SETUP) as (keyof typeof PROVIDER_SETUP)[]) {
    assert.match(SETUP_LINKS[r].target, /^setting:(OPENROUTER|EXPLABS)_API_KEY$/);
    assert.match(SETUP_LINKS[r].says, new RegExp(`Settings › Models & providers › ${PROVIDER_SETUP[r]}`));
  }
});

test('models: the picker groups starred first, then Anthropic, Bedrock’s others, OpenRouter free, OpenRouter paid', () => {
  const ms = normModels(RAW).models;
  const sec = modelSections(ms, {});
  assert.deepEqual(sec.map((s) => s.group), ['anthropic', 'bedrock', 'or-free', 'or-paid']);
  assert.deepEqual(sec[1].models.map((m) => m.id), ['llama-3-3-70b'], 'not listed (mistral) and failing (grok) wait behind Show all');
  const all = modelSections(ms, { all: true });
  assert.deepEqual(all[1].models.map((m) => m.id), ['llama-3-3-70b', 'mistral-large-3', 'grok-4-7']);
  assert.equal(hiddenCount(ms), 2);
  // the current model is there even when it is not listed
  assert.ok(modelSections(ms, { current: 'mistral-large-3' })[1].models.some((m) => m.id === 'mistral-large-3'));
  const st = modelSections(ms, { starred: ['or/google/gemma-4-31b-it', 'claude-haiku-5-5'] });
  assert.deepEqual(st[0], { group: 'starred', models: [ms[1], ms[6]] });
  assert.ok(!st[1].models.some((m) => m.id === 'claude-haiku-5-5'), 'a starred model shows once');
  assert.equal(groupOf(ms[5]), 'or-free');
});

// Experiential Labs' models (xl/…): a group of their own, after OpenRouter's; a Claude model through the gateway is the
// gateway's, never "Anthropic (Claude)" (that group is Bedrock's)
test('models: Experiential Labs models are a group of their own, after OpenRouter', () => {
  const bn = normModels({ models: [...RAW.models,
    { id: 'xl/qwen3.8-27b', name: 'qwen3.8-27b', provider: 'Experiential Labs', vendor: 'Qwen', compat: 'untested', listed: true, input_per_mtok: 0.32, output_per_mtok: 2.4, context: 1000000 },
    { id: 'xl/claude-fable-5', name: 'claude-fable-5', provider: 'Experiential Labs', vendor: 'Anthropic', compat: 'untested', listed: true },
    { id: 'xl/odd', name: 'odd', provider: 'Somebody Else' }] });
  const by = Object.fromEntries(bn.models.map((m) => [m.id, m]));
  assert.equal(by['xl/qwen3.8-27b'].provider, 'Experiential Labs');
  assert.equal(by['xl/odd'].provider, 'Bedrock', 'an unknown provider is not passed on');
  assert.equal(groupOf(by['xl/qwen3.8-27b']), 'xl');
  assert.equal(groupOf(by['xl/claude-fable-5']), 'xl');
  assert.deepEqual(modelSections(bn.models, {}).map((s) => s.group), ['anthropic', 'bedrock', 'or-free', 'or-paid', 'xl']);
  assert.deepEqual(modelSections(bn.models, { query: 'experiential qwen' }).flatMap((s) => s.models.map((m) => m.id)), ['xl/qwen3.8-27b']);
});

test('models: search by name, id, vendor, provider, badge and "free" — every word', () => {
  const ms = normModels(RAW).models;
  const ids = (q: string) => modelSections(ms, { query: q, all: true }).flatMap((s) => s.models.map((m) => m.id));
  assert.deepEqual(ids('free'), ['or/google/gemma-4-31b-it:free']);
  assert.deepEqual(ids('GOOGLE openrouter'), ['or/google/gemma-4-31b-it:free', 'or/google/gemma-4-31b-it']);
  assert.deepEqual(ids('meta chat only'), ['llama-3-3-70b']);
  assert.deepEqual(ids('haiku'), ['claude-haiku-5-5']);
  assert.deepEqual(ids('nothing-like-this'), []);
  assert.ok(modelMatches(ms[0], '   '));
});

test('models: the session’s model found exactly — never a shorter id that only prefixes it', () => {
  const ms = normModels(RAW).models;
  assert.equal(findModel(ms, 'or/google/gemma-4-31b-it:free')?.id, 'or/google/gemma-4-31b-it:free');
  assert.equal(findModel(ms, 'or/google/gemma-4-31b-it')?.id, 'or/google/gemma-4-31b-it');
  assert.equal(findModel(ms, 'claude-haiku-5-5-20261001')?.id, 'claude-haiku-5-5', 'a longer form a provider reports');
  assert.equal(findModel(ms, 'opus')?.id, 'claude-opus-5-5');
  assert.equal(findModel(ms, 'or/google/gemma-4-31b-it:nitro'), undefined);
  assert.equal(findModel(ms, ''), undefined);
});

test('models: a switch to a model that does not simply work says what to expect', () => {
  const by = Object.fromEntries(normModels(RAW).models.map((m) => [m.id, m]));
  assert.equal(compatWarning(by['claude-opus-5-5']), null);
  assert.equal(compatWarning(by['mistral-large-3']), null);
  assert.match(compatWarning(by['llama-3-3-70b']) ?? '', /^Llama 3\.3 70B: It answers, but cannot use tools.*Writes tool calls as text\.$/);
  assert.match(compatWarning(by['grok-4-7']) ?? '', /fails/);
  assert.match(compatWarning(by['or/google/gemma-4-31b-it:free']) ?? '', /Not checked with Claude Code/);
  for (const c of ['works', 'chat-only', 'fails', 'untested'] as const) assert.ok(COMPAT_INFO[c].badge);
});

test('models: stars and "show all" are kept per browser, checked and capped', () => {
  const p = parsePrefs({ starred: ['claude-opus-5-5', 'claude-opus-5-5', '../x', 7, ...Array.from({ length: 80 }, (_, i) => `m-${i}`)], allModels: true });
  assert.equal(p.starred[0], 'claude-opus-5-5');
  assert.equal(p.starred.length, STARRED_MAX);
  assert.ok(!p.starred.includes('../x'));
  assert.equal(p.allModels, true);
  assert.deepEqual([parsePrefs({ starred: 'x' }).starred, parsePrefs({}).allModels], [[], false]);
});

test('models: the cold-cache line only for models that write the prompt cache at a price', () => {
  const by = Object.fromEntries(normModels(RAW).models.map((m) => [m.id, m]));
  const idle = Date.now() - CACHE_TTL_MS - 60_000;
  assert.ok(cacheNotice(idle, 40_000, by['claude-haiku-5-5']));
  assert.equal(cacheNotice(idle, 40_000, by['llama-3-3-70b']), null, 'no cache price, another provider: nothing to warn about');
  assert.equal(cacheNotice(idle, 40_000, by['or/google/gemma-4-31b-it:free']), null, 'free: $0');
  const claudeNoPrice: BnModel = { ...by['claude-haiku-5-5'], cacheWrite: null };
  assert.ok(caches(claudeNoPrice) && caches(null));
});

test('status bar: Run and Ports have shortcuts in the sheet, and tips name them for assistive tech', () => {
  assert.equal(keysFor('run'), 'Alt+R');
  assert.equal(keysFor('ports'), 'Alt+P');
  assert.ok(shortcuts().some((s) => s.keys === 'Alt+R' && s.group === 'Panels'));
  assert.equal(ariaKeys('Shift+Tab · Alt+M'), 'Shift+Tab Alt+M');
  assert.equal(ariaKeys('Ctrl+`'), 'Control+`');
  assert.equal(ariaKeys('⌘+K · Ctrl+Shift+P'), 'Meta+K Control+Shift+P');
});

test('models: a new session starts on your last pick — an Experiential Labs or OpenRouter model too, listed or not — never silently on another', async () => {
  const { startModel } = await import('../src/models');
  const bn = normModels({ ...RAW, models: [...RAW.models, { id: 'xl/glm-5.3-uncensored:free', name: 'GLM 5.3 Uncensored (free)', provider: 'Experiential Labs', vendor: 'Zhipu', compat: 'untested', listed: false, free: true }] });
  assert.deepEqual(startModel('xl/glm-5.3-uncensored:free', bn), { model: 'xl/glm-5.3-uncensored:free', missed: null }, 'not listed in Settings › Claude Code › Models: still your pick');
  assert.deepEqual(startModel('or/google/gemma-4-31b-it:free', bn), { model: 'or/google/gemma-4-31b-it:free', missed: null });
  assert.deepEqual(startModel('mistral-large-3', bn), { model: 'mistral-large-3', missed: null });
  assert.deepEqual(startModel('haiku', bn), { model: 'claude-haiku-5-5', missed: null }, 'an alias from before: its id');
  // the list not there yet: your pick (the backend never runs another in its place)
  assert.deepEqual(startModel('xl/glm-5.3-uncensored:free', null), { model: 'xl/glm-5.3-uncensored:free', missed: null });
  // no pick: DevOS ADE's default; a pick no longer served (Experiential Labs' key removed): the default, and said
  assert.deepEqual(startModel('', bn), { model: 'claude-opus-5-5', missed: null });
  assert.deepEqual(startModel('xl/gone:free', bn), { model: 'claude-opus-5-5', missed: 'xl/gone:free' });
});

test('a provider error whose way on is another model names the session\'s model by DevOS ADE\'s name (JON-521)', () => {
  const promo = 'Experiential Labs: the free promotion for this model has ended. From now on its requests are charged to your Experiential Labs credits. Send your message again to continue, or pick another model.';
  assert.equal(nameTheModel(promo, 'glm-5.3-uncensored'), 'Experiential Labs: the free promotion for glm-5.3-uncensored has ended. From now on its requests are charged to your Experiential Labs credits. Send your message again to continue, or pick another model.');
  assert.equal(nameTheModel("Your Experiential Labs key isn't allowed to use this model", 'deepseek-v4.1-flash:free'), "Your Experiential Labs key isn't allowed to use deepseek-v4.1-flash:free");
  assert.equal(nameTheModel(promo, ''), promo);   // (not known: "this model")
});

test('JON-816: a local model (downloaded from Hugging Face, run on this computer) is its own group, free at $0, never spend', () => {
  const bn = normModels({ models: [
    { id: 'claude-haiku-5-5', name: 'Claude Haiku 5.5', provider: 'Bedrock', vendor: 'Anthropic', compat: 'works', listed: true, input_per_mtok: 0.11, output_per_mtok: 0.55 },
    { id: 'lm/bartowski/smollm2-135m-instruct-gguf:q4_k_m', name: 'smollm2-135m-instruct-gguf Q4_K_M', provider: 'Local', vendor: 'bartowski', compat: 'chat-only', listed: true, input_per_mtok: 7, context: 8192, note: 'Chat only.' },
  ] });
  const m = bn.models[1];
  assert.deepEqual([m.provider, m.free, m.input, m.output, m.cacheWrite, m.compat], ['Local', true, 0, 0, null, 'chat-only']);
  assert.equal(groupOf(m), 'local');
  assert.deepEqual(modelSections(bn.models, { all: true }).map((s) => s.group), ['anthropic', 'local']);
  assert.ok(modelMatches(m, 'local free'));
});
