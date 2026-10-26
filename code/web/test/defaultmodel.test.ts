// A new session's model (UX-01): DevOS ADE's default is Claude Sonnet unless Settings name one (the portal decides:
// /.bn/models default and settings_default); your last pick is kept for your sign-in by the backend, so a new browser or
// a phone starts there too; a default set or changed in Settings since your pick wins over it.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { normModels, normUserPrefs } from '../src/api';
import { startModel } from '../src/models';
import { parsePrefs } from '../src/prefs';

const claude = (id: string, name: string, alias: string) => ({ id, name, alias, vendor: 'Anthropic', provider: 'Bedrock', compat: 'works', listed: true });
const RAW = {
  models: [claude('claude-opus-5-5', 'Claude Opus 5.5', 'opus'), claude('claude-sonnet-5-5', 'Claude Sonnet 5.5', 'sonnet'), claude('claude-haiku-5-5', 'Claude Haiku 5.5', 'haiku'),
    { id: 'mistral-large-3', name: 'Mistral Large 3', vendor: 'Mistral', provider: 'Bedrock', compat: 'works', listed: true }],
  aliases: { opus: 'claude-opus-5-5', sonnet: 'claude-sonnet-5-5', haiku: 'claude-haiku-5-5' },
};

test('default model: a browser with no pick of its own, on a stack whose Settings name none, starts on Sonnet', () => {
  const bn = normModels({ ...RAW, default: 'claude-sonnet-5-5', settings_default: null });
  assert.equal(bn.settingsDefault, null);
  assert.deepEqual(startModel('', bn), { model: 'claude-sonnet-5-5', missed: null });
  assert.deepEqual(startModel('', bn, null), { model: 'claude-sonnet-5-5', missed: null });
  // (Settings' default must be a model of the list; anything else is none)
  assert.equal(normModels({ ...RAW, default: 'claude-sonnet-5-5', settings_default: 'claude-gone' }).settingsDefault, null);
  assert.equal(normModels({ ...RAW, default: 'claude-sonnet-5-5', settings_default: '<img src=x>' }).settingsDefault, null);
  assert.equal(normModels({ ...RAW, default: 'claude-sonnet-5-5' }).settingsDefault, null, 'an older portal: none');
});

test('default model: your pick wins — unless Settings\' default was set or changed since you picked', () => {
  const none = normModels({ ...RAW, default: 'claude-sonnet-5-5', settings_default: null });
  const mistral = normModels({ ...RAW, default: 'mistral-large-3', settings_default: 'mistral-large-3' });
  // picked with no Settings default: kept while there is none
  assert.equal(startModel('claude-haiku-5-5', none, null).model, 'claude-haiku-5-5');
  // Settings name one after the pick: the newer choice wins (the pick is not lost: picking again keeps it)
  assert.equal(startModel('claude-haiku-5-5', mistral, null).model, 'mistral-large-3');
  // picked while Settings already named it: the pick wins
  assert.equal(startModel('claude-haiku-5-5', mistral, 'mistral-large-3').model, 'claude-haiku-5-5');
  // Settings changed to another one since: that one
  assert.equal(startModel('claude-haiku-5-5', mistral, 'claude-opus-5-5').model, 'mistral-large-3');
  // Settings' default taken away since: the pick (never Sonnet over a choice of yours)
  assert.equal(startModel('claude-haiku-5-5', none, 'mistral-large-3').model, 'claude-haiku-5-5');
  // a pick from before this was kept (not known under which default): it wins, as it did
  assert.equal(startModel('claude-haiku-5-5', mistral).model, 'claude-haiku-5-5');
  assert.equal(startModel('claude-haiku-5-5', mistral, undefined).model, 'claude-haiku-5-5');
  // no pick: Settings' default
  assert.equal(startModel('', mistral, null).model, 'mistral-large-3');
});

test('prefs kept for your sign-in: model ids only — an alias, markup or anything else is none', () => {
  assert.deepEqual(normUserPrefs({ model: 'claude-haiku-5-5', settingsDefault: null, at: 5 }), { model: 'claude-haiku-5-5', settingsDefault: null });
  assert.deepEqual(normUserPrefs({ model: 'or/google/gemma-4-31b-it:free', settingsDefault: 'mistral-large-3' }), { model: 'or/google/gemma-4-31b-it:free', settingsDefault: 'mistral-large-3' });
  for (const bad of [{ model: 'opus' }, { model: 'sonnet[1m]' }, { model: '<b>' }, { model: 5 }, null, 'x', []]) {
    assert.deepEqual(normUserPrefs(bad), { model: null, settingsDefault: null }, JSON.stringify(bad));
  }
  // this browser's copy: what Settings' default was at the pick (null: none; absent: not known — a pick from before)
  assert.equal(parsePrefs({ model: 'claude-haiku-5-5', modelSetting: null }).modelSetting, null);
  assert.equal(parsePrefs({ model: 'claude-haiku-5-5', modelSetting: 'mistral-large-3' }).modelSetting, 'mistral-large-3');
  assert.equal('modelSetting' in parsePrefs({ model: 'claude-haiku-5-5' }), false);
  assert.equal('modelSetting' in parsePrefs({ model: 'claude-haiku-5-5', modelSetting: '<img>' }), false);
});
