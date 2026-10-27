// Model / mode / effort pickers and the cost and context meters. Model names and prices come from DevOS ADE
// (/.bn/models), never from the CLI; costs come from DevOS ADE's spend logs (/.bn/spend).
import { useState } from 'preact/hooks';
import { useSel } from '../store';
import { store, setModel, setMode, setEffort, activeView, defaultModel, refreshSpend, autoOk, setPrefs, toast, switchHarness, harnessName, planOf, refreshHarnesses, goSetup, openModelBrowser } from '../app';
import { SETUP_LINKS, type SetupReason } from '../setuplinks';
import { COMPAT_INFO, GROUP_TITLE, PROVIDER_SETUP, compatWarning, findModel, hiddenCount, modelSections, providerSetups } from '../models';
import { STARRED_MAX } from '../prefs';
import { byokCount, meter } from '../spend';
import { percent } from '../budget';
import type { BnModel, Harness, HarnessInfo, PlanUsage } from '../types';
import { MODE_INFO, offeredModes, startMode } from '../modes';
import { label, money, perMtok, tokens } from '../text';
import { Dropdown, MenuItem } from './ui';
import { Icon } from './icons';
import { PRODUCT } from '../brand';

/** ~30k tokens are written to the prompt cache on a new session or a model switch (measured on Bedrock). */
const CACHE_TOKENS = 30_000;
/** At most this many rows are drawn at once (OpenRouter can bring hundreds): the search narrows the rest. */
const SHOWN_MAX = 250;

export function currentModel(models: BnModel[], current: string): BnModel | undefined {
  return findModel(models, current);
}

/** DevOS ADE's name for a model the session reports, or '' (never the reported string itself). */
export function modelLabel(models: BnModel[] | undefined, reported: string): string {
  return (models && currentModel(models, reported)?.name) || '';
}

/** A model's price as the picker shows it: "free" ($0, never spend), "$0.72 / $0.72", or nothing when unknown. */
export function priceHint(m: BnModel): string | undefined {
  if (m.free) return 'free';
  return m.input !== null && m.output !== null ? `${perMtok(m.input)} / ${perMtok(m.output)}` : undefined;
}

/** Switch to a model, and say what to expect from one that does not simply work as Claude Code's model. */
function pick(m: BnModel): void {
  void setModel(m.id).then((ok) => {   // by its full id: Claude Code runs exactly this model (an alias may let it run another)
    const w = ok ? compatWarning(m) : null;
    if (w) toast(w, m.compat === 'untested' ? 'info' : 'error');
  });
}

// Claude on your plan's models: Claude Code's own names there (what your plan offers; its default when none)
const PLAN_MODELS = [{ id: 'default', name: "Your plan's default" }, { id: 'opus', name: 'Opus' }, { id: 'sonnet', name: 'Sonnet' }, { id: 'haiku', name: 'Haiku' }];

/** a subscription in the picker: whether it can start here, in words — and when not, why (setuplinks.ts: its item goes
 *  where that is turned on, saying where) */
export function harnessState(h: HarnessInfo): { ok: boolean; says: string; reason?: SetupReason } {
  const off = (reason: SetupReason) => ({ ok: false, says: SETUP_LINKS[reason].says, reason });
  if (!h.installed) return off('tool-left-out');
  if (!h.allowed) return off('claude-plan-off');
  if (h.signed === 'no') return off('tool-signin');
  return { ok: true, says: h.signed === 'yes' ? 'signed in' : 'sign-in not known here' };
}

/** Who answers, split for the picker: Claude Code on Bedrock and the subscriptions that can start here (signed in, or
 *  whose sign-in is not known here) — and the one answering now — shown; those that cannot start (not signed in, left
 *  out of the sandbox, Claude on your plan off) folded under one row, so the models you can use come first (UX-06). */
export function answerers(list: HarnessInfo[], current: Harness): { ready: HarnessInfo[]; signIn: HarnessInfo[] } {
  const ready: HarnessInfo[] = [];
  const signIn: HarnessInfo[] = [];
  for (const h of list) (harnessState(h).ok || h.id === current ? ready : signIn).push(h);
  return { ready, signIn };
}

/** "Who answers" in the model picker, after its models: Claude Code on Bedrock, and each of your subscriptions that can
 *  start here (a switch: a new session with it here, the conversation so far carried over); the ones to sign in to
 *  first under one row that opens them */
function WhoAnswers({ current, close }: { current: Harness; close: () => void }) {
  const list = useSel(store, (s) => s.harnesses);
  const agents = useSel(store, (s) => s.server?.agents === true);
  const [more, setMore] = useState(false);
  if (!agents) return null;
  const { ready, signIn } = answerers(list ?? [], current);
  const item = (h: HarnessInfo) => {
    const st = harnessState(h);
    // (one that cannot start here: a choice that goes where that is turned on — at once, its words saying where)
    return (
      <MenuItem key={h.id} checked={current === h.id} testid={`harness-${h.id}`} setup={!st.ok && current !== h.id ? st.reason : undefined}
        onSelect={() => { close(); if (current === h.id) return; if (st.ok) void switchHarness(h.id); else if (st.reason) goSetup(st.reason, h.id); }}>
        <span class="mi-title">{h.id === 'claude' ? 'Claude · your plan' : h.name}<span class="mp-badge tone-info">your plan</span></span>
        <span class="mi-desc">{h.plan} · {st.says}</span>
      </MenuItem>
    );
  };
  return (
    <div class="mp-group" role="group" aria-label="Who answers" data-testid="who-answers">
      <div class="mp-group-head">Who answers</div>
      <MenuItem checked={current === 'bedrock'} testid="harness-bedrock" onSelect={() => { close(); if (current !== 'bedrock') void switchHarness('bedrock'); }}>
        <span class="mi-title">Claude Code on Bedrock</span>
        <span class="mi-desc">the models above, billed as {PRODUCT} bills them</span>
      </MenuItem>
      {ready.map(item)}
      {signIn.length > 0 && (
        <button type="button" class="mi mp-more" role="menuitem" aria-expanded={more} data-testid="harness-more" onClick={() => setMore(!more)}>
          <span class="mi-body">
            <span class="mi-title">Subscriptions (sign in to use)</span>
            <span class="mi-desc">{signIn.map((h) => (h.id === 'claude' ? 'Claude' : h.name)).join(', ')}</span>
          </span>
          <span class="mi-hint">{signIn.length}</span>
          <Icon name={more ? 'chevronUp' : 'chevronDown'} size={13} />
        </button>
      )}
      {more && signIn.map(item)}
      {list === null && <div class="panel-note">Your subscriptions are being listed…</div>}
      {(more || ready.length > 0 || list === null) && (
        <div class="panel-note">
          Each answers through its own app in the sandbox, signed in there with its own sign-in; usage counts against your plan (no $). Switching starts a new session in
          this project's folder with your conversation so far.{' '}
          <button type="button" class="link" role="menuitem" onClick={() => void refreshHarnesses(true)}>Check again</button>
        </div>
      )}
    </div>
  );
}

export function ModelPicker({ compact }: { compact?: boolean }) {
  const harness = useSel(store, (s) => activeView(s)?.harness ?? 'bedrock');
  if (harness !== 'bedrock') return <PlanModelPicker compact={compact} />;
  return <BedrockModelPicker compact={compact} />;
}

/** A session on your plan or with an agent: who answers, and the models its own tool offers */
function PlanModelPicker({ compact }: { compact?: boolean }) {
  const v = useSel(store, (s) => activeView(s));
  const names = useSel(store, (s) => (v ? harnessName(v.harness, s) : ''));
  if (!v) return null;
  const models = v.harness === 'claude' ? PLAN_MODELS : v.init?.models ?? [];
  const cur = models.find((m) => m.id === v.model)?.name ?? (v.model || 'its default');
  return (
    <Dropdown title={`Who answers: ${names} · ${cur}`} class="picker" panelClass="model-panel" testid="model-picker"
      trigger={
        <>
          <Icon name="model" size={15} />
          <span class="picker-value">{compact ? names.replace(/ · your plan$/, '') : `${names} · ${cur}`}</span>
          <span class="mp-badge tone-info">your plan</span>
          <Icon name="chevronDown" size={13} class="picker-chev" />
        </>
      }>
      {(close) => (
        <>
          <div class="mp-group" role="group" aria-label={`${names}'s models`} data-testid="plan-models">
            <div class="mp-group-head">{names}'s models</div>
            {models.map((m) => (
              <MenuItem key={m.id} checked={m.id === v.model} testid={`plan-model-${m.id}`} onSelect={() => { close(); void setModel(m.id); }}>
                <span class="mi-title">{m.name}</span>
                <span class="mi-desc">{m.id}</span>
              </MenuItem>
            ))}
            {!models.length && <div class="panel-note">Its models are listed once it has started (send a prompt).</div>}
          </div>
          <WhoAnswers current={v.harness} close={close} />
        </>
      )}
    </Dropdown>
  );
}

function BedrockModelPicker({ compact }: { compact?: boolean }) {
  const bn = useSel(store, (s) => s.models);
  const err = useSel(store, (s) => s.modelsError);
  const viewModel = useSel(store, (s) => activeView(s)?.model ?? '');
  const prefModel = useSel(store, (s) => defaultModel(s));
  const hasSession = useSel(store, (s) => !!activeView(s));
  const starred = useSel(store, (s) => s.prefs.starred);
  const all = useSel(store, (s) => s.prefs.allModels);
  const signal = useSel(store, (s) => s.modelMenu);
  const [query, setQuery] = useState('');
  const models = bn?.models ?? [];
  // the sandbox reports the session's model (init); only DevOS ADE's own names are shown in the page's chrome
  const cur = currentModel(models, viewModel) ?? currentModel(models, prefModel);
  const current = cur?.id ?? '';
  const name = cur?.name ?? (models.length ? 'Choose a model' : 'Model');
  const sections = modelSections(models, { query, starred, all, current });
  const hidden = hiddenCount(models);
  const sub = cur ? priceHint(cur) : undefined;
  let drawn = 0;
  return (
    <Dropdown
      title={`Model: ${name}`}
      class="picker"
      panelClass="model-panel"
      panelRole="dialog"
      panelLabel="Model"
      testid="model-picker"
      openSignal={signal}
      focus=".mp-search"
      trigger={
        <>
          <Icon name="model" size={15} />
          <span class="picker-value">{compact ? name.replace(/^Claude /, '') : name}</span>
          {!compact && sub && <span class={`picker-sub${cur?.free ? ' free' : ''}`}>{sub.replace(' / ', '/')}</span>}
          {cur && cur.compat !== 'works' && <span class={`mp-badge tone-${COMPAT_INFO[cur.compat].tone}`}>{COMPAT_INFO[cur.compat].badge}</span>}
          <Icon name="chevronDown" size={13} class="picker-chev" />
        </>
      }
    >
      {(close) => (
        <>
          <div class="panel-head mp-head">
            <span>Model</span>
            {bn?.scope && bn.scope.mode !== 'all' && (
              <button type="button" class="linkish mp-scope setup-link" data-testid="model-scope" data-setup="models-scope" title={SETUP_LINKS['models-scope'].says}
                onClick={() => { close(); goSetup('models-scope'); }}>
                {bn.scope.mode === 'anthropic' ? 'Anthropic only' : 'your list'} · Settings › Claude Code
              </button>
            )}
          </div>
          <div class="mp-searchbox">
            <Icon name="search" size={14} />
            <input
              class="mp-search"
              type="search"
              value={query}
              placeholder={`Search ${all ? models.length : models.length - hidden} models: name, provider, free…`}
              aria-label="Search the models"
              autocomplete="off"
              spellcheck={false}
              data-testid="model-search"
              onInput={(e) => setQuery((e.target as HTMLInputElement).value)}
              onKeyDown={(e) => {
                if (e.key !== 'Enter') return;
                e.preventDefault();
                const first = sections[0]?.models[0];
                if (first) {
                  pick(first);
                  setQuery('');
                  close();
                }
              }}
            />
          </div>
          {err && <div class="panel-note err">Models could not be loaded: {err}</div>}
          {/* (the picker is a dialog — it holds a search and buttons —; its models are menu items, in a menu) */}
          <div role="menu" aria-label="Models">
          {sections.map(({ group, models: list }) => (
            <div class="mp-group" key={group} role="group" aria-label={GROUP_TITLE[group]} data-testid={`model-group-${group}`}>
              <div class="mp-group-head">{GROUP_TITLE[group]}</div>
              {list.map((m) => {
                if (drawn >= SHOWN_MAX) return null;
                drawn++;
                const info = COMPAT_INFO[m.compat];
                const star = starred.includes(m.id);
                return (
                  <div class={`mp-row${m.compat === 'fails' ? ' mp-fails' : ''}`} key={m.id}>
                    <MenuItem
                      checked={m.id === current}
                      testid={`model-${m.alias ?? m.id}`}
                      onSelect={() => {
                        pick(m);
                        setQuery('');
                        close();
                      }}
                      hint={priceHint(m)}
                    >
                      <span class="mi-title">
                        {m.name}
                        {m.free && <span class="mp-free" data-testid="free-tag">free</span>}
                        {(m.compat !== 'works' || !isClaude(m)) && (
                          <span class={`mp-badge tone-${info.tone}`} title={info.says} data-testid={`compat-${m.compat}`}>
                            {info.badge}
                          </span>
                        )}
                      </span>
                      {(() => {
                        // (its full text in a tooltip too: a narrow menu cuts the end of it)
                        const desc = [m.vendor && m.vendor !== 'Anthropic' ? m.vendor : '', m.provider !== 'Bedrock' ? m.provider : '', m.alias ? m.alias : '', m.id].filter(Boolean).join(' · ')
                          + (m.context ? ` · ${tokens(m.context)} context` : '')
                          + (hasSession && m.id !== current && m.cacheWrite !== null ? ` · switching ≈ ${money((CACHE_TOKENS * m.cacheWrite) / 1e6)}` : '');
                        return <span class="mi-desc" title={desc}>{desc}</span>;
                      })()}
                      {m.compat !== 'works' && m.note && <span class="mi-desc mp-note">{m.note}</span>}
                    </MenuItem>
                    <button
                      type="button"
                      class={`mp-star${star ? ' on' : ''}`}
                      role="menuitemcheckbox"
                      aria-checked={star}
                      aria-label={star ? `Unstar ${m.name}` : `Star ${m.name}: listed first`}
                      title={star ? 'Starred: listed first (in this browser)' : 'Star: list it first (in this browser)'}
                      data-testid={`star-${m.id}`}
                      onClick={(e) => {
                        e.stopPropagation();
                        toggleStar(m.id);
                      }}
                    >
                      <Icon name="star" size={14} />
                    </button>
                  </div>
                );
              })}
            </div>
          ))}
          </div>
          {/* a provider without its key: a greyed item that goes where the key goes in (Settings › Models & providers) */}
          {!query && providerSetups(bn).length > 0 && (
            <div class="mp-group" role="group" aria-label="More providers" data-testid="model-group-setup">
              <div class="mp-group-head">More providers</div>
              {providerSetups(bn).map((r) => (
                <MenuItem key={r} testid={`model-${r}`} setup={r} onSelect={() => { close(); goSetup(r); }}>
                  <span class="mi-title">{PROVIDER_SETUP[r]} models</span>
                  <span class="mi-desc">{SETUP_LINKS[r].says}</span>
                </MenuItem>
              ))}
            </div>
          )}
          {drawn >= SHOWN_MAX && <div class="panel-note">More models match: search to narrow the list.</div>}
          {!sections.length && models.length > 0 && <div class="panel-note" data-testid="model-none">No model matches “{label(query, 40)}”.</div>}
          {!models.length && !err && <div class="panel-note">Loading models…</div>}
          {hidden > 0 && (
            <label class="mp-all">
              <input type="checkbox" checked={all} onChange={() => setPrefs((p) => ({ ...p, allModels: !p.allModels }))} data-testid="model-show-all" />
              Show all models ({hidden} more: outside Settings › Claude Code › Models{models.some((m) => m.compat === 'fails') ? ', or failing' : ''})
            </label>
          )}
          {/* More models…: the portal's browser — search Bedrock, OpenRouter and Experiential Labs and add one (JON-520) */}
          <button type="button" class="linkish mp-more" data-testid="model-more" onClick={() => { close(); openModelBrowser(); }}>
            More models… <span class="mp-more-note">search Bedrock, OpenRouter and Experiential Labs, add or remove</span>
          </button>
          {/* who answers, after the models you can use (your subscriptions to sign in to: folded under one row) */}
          <div role="menu" aria-label="Who answers">
            <WhoAnswers current="bedrock" close={close} />
          </div>
          <div class="panel-note">
            Prices per million input / output tokens, as {PRODUCT} bills them; free models cost $0. Claude Code speaks Anthropic's API with tools: other
            providers' models answer through LiteLLM's translation, and tool use, thinking, prompt caching and long contexts vary —{' '}
            <strong>works</strong> means a tool-using turn was checked, <strong>chat only</strong> that it cannot use tools.
            {hasSession
              ? ' Switching mid-session writes the prompt cache again (~30k tokens at the new model’s cache price, where it has one); so does every new session.'
              : ' Every new session first writes ~30k tokens of prompt cache on models that cache.'}
          </div>
        </>
      )}
    </Dropdown>
  );
}

const isClaude = (m: BnModel): boolean => m.vendor === 'Anthropic' && m.provider === 'Bedrock';

/** Star or unstar a model (kept in this browser; starred models come first in the picker). */
export function toggleStar(id: string): void {
  setPrefs((p) => ({ ...p, starred: p.starred.includes(id) ? p.starred.filter((x) => x !== id) : [id, ...p.starred].slice(0, STARRED_MAX) }));
}

/** The permission mode, next to Send as in Claude Code's desktop app: Read only · Plan · Manual · Accept edits · Auto ·
 *  Bypass permissions (Auto and Bypass when Settings allow them). Shift+Tab in the prompt box cycles, Alt+M opens it. */
export function ModePicker({ compact }: { compact?: boolean }) {
  // (no session: the mode the next one starts in — a remembered Auto shows as Manual while Settings do not allow it)
  const mode = useSel(store, (s) => activeView(s)?.mode ?? startMode(s.startWith ?? s.prefs.mode, 'default', autoOk(s)));
  // (a subscription's agent: Read only, Plan, Manual, Accept edits — its own "approve everything" modes are never used)
  const agent = useSel(store, (s) => { const h = activeView(s)?.harness; return h !== undefined && h !== 'bedrock' && h !== 'claude'; });
  const allowBypass = useSel(store, (s) => s.server?.allowBypass === true) && !agent;
  const allowAuto = useSel(store, (s) => s.server?.allowAuto === true) && !agent;
  const signal = useSel(store, (s) => s.modeMenu);
  const info = MODE_INFO[mode] ?? MODE_INFO.default;
  const name = compact && mode === 'bypassPermissions' ? 'Bypass' : info.label;
  return (
    <Dropdown
      title={`Permission mode: ${info.label} (Shift+Tab cycles, Alt+M opens)`}
      class={`picker mode-picker tone-${info.tone}`}
      panelClass="mode-panel"
      testid="mode-picker"
      openSignal={signal}
      trigger={
        <>
          <Icon name={info.icon} size={14} />
          <span class="picker-value">{name}</span>
          {mode === 'bypassPermissions' && <Icon name="alert" size={13} class="mode-warn" />}
          <Icon name="chevronDown" size={13} class="picker-chev" />
        </>
      }
    >
      {(close) => (
        <>
          <div class="panel-head">Permission mode</div>
          {offeredModes(allowBypass, allowAuto).map((m) => {
            const mi = MODE_INFO[m];
            return (
              <MenuItem
                key={m}
                checked={m === mode}
                testid={`mode-${m}`}
                onSelect={() => {
                  close();
                  setMode(m);
                }}
              >
                <span class={`mi-title mode-title tone-${mi.tone}`}>
                  <Icon name={mi.icon} size={13} /> {mi.label}
                </span>
                <span class="mi-desc">{mi.desc}</span>
                <span class="mi-desc mi-runs">{mi.runs}</span>
              </MenuItem>
            );
          })}
          {agent && <div class="panel-note" data-testid="mode-agent">This tool's own sessions take Read only, Plan, Manual and Accept edits: what it asks goes to you; Read only and Plan refuse its changes.</div>}
          {!agent && (!allowAuto || !allowBypass) && (
            <div class="panel-note" data-testid={allowBypass ? 'mode-auto-off' : 'mode-bypass-off'}>
              {/* (each a link to its setting: setuplinks.ts) */}
              {(['auto-off', 'bypass-off'] as const).filter((r) => (r === 'auto-off' ? !allowAuto : !allowBypass)).map((r) => (
                <button type="button" class="linkish setup-link" data-setup={r} key={r} onClick={() => { close(); goSetup(r); }}>{SETUP_LINKS[r].says}</button>
              ))}
            </div>
          )}
          <div class="panel-note">
            Shift+Tab in the prompt box cycles Manual → Accept edits → Plan{allowBypass ? ' → Bypass' : ''}
            {allowAuto ? ' → Auto' : ''}; Alt+M opens this menu. Read only, Manual, Accept edits{allowAuto ? ' and Auto' : ''} are remembered for new
            sessions; Plan and Bypass permissions are for this session only.
          </div>
        </>
      )}
    </Dropdown>
  );
}

export function EffortPicker() {
  const v = useSel(store, (s) => activeView(s));
  const prefEffort = useSel(store, (s) => s.prefs.effort);
  const model = v?.model ?? '';
  const cli = v?.cliModels ?? [];
  const entry = cli.find((m) => m.value === model || m.resolved === model || (model && (m.resolved.startsWith(model) || model.startsWith(m.value)))) ?? (v?.init ? cli.find((m) => m.resolved === v.init?.model) : undefined);
  const levels = entry?.efforts ?? [];
  const effort = v?.effort ?? prefEffort;
  if (!levels.length) return null;
  return (
    <Dropdown
      title="Reasoning effort"
      class="picker"
      testid="effort-picker"
      trigger={
        <>
          <Icon name="gauge" size={15} />
          <span class="picker-value">{effort ?? 'auto'}</span>
          <Icon name="chevronDown" size={13} class="picker-chev" />
        </>
      }
    >
      {(close) => (
        <>
          <div class="panel-head">Effort</div>
          <MenuItem
            checked={!effort}
            onSelect={() => {
              setEffort(null);
              close();
            }}
          >
            <span class="mi-title">Auto</span>
            <span class="mi-desc">The model's default</span>
          </MenuItem>
          {levels.map((l) => (
            <MenuItem
              key={l}
              checked={effort === l}
              onSelect={() => {
                setEffort(l);
                close();
              }}
            >
              <span class="mi-title">{l}</span>
            </MenuItem>
          ))}
          <div class="panel-note">More effort: more thinking tokens, slower and dearer turns.</div>
        </>
      )}
    </Dropdown>
  );
}

/** a session on your plan: its tokens and turns, and the plan's own limits as its tool reported them — never dollars */
export function planText(p: PlanUsage | null, plan: string): { short: string; long: string } {
  const u = p ?? { input: 0, output: 0, cached: 0, turns: 0, limits: [] };
  const lim = u.limits.map((l) => `${l.label}: ${l.usedPercent === null ? '?' : `${l.usedPercent}%`} used${l.resetsAt ? ` (resets ${new Date(l.resetsAt).toLocaleString()})` : ''}`);
  return { short: `${tokens(u.input + u.cached)} in · ${tokens(u.output)} out`,
    long: `On ${plan}: ${tokens(u.input + u.cached)} tokens in (${tokens(u.cached)} cached), ${tokens(u.output)} out, ${u.turns} turn${u.turns === 1 ? '' : 's'} in this session. No dollars: it counts against your plan's own limits.${lim.length ? `\n${lim.join('\n')}` : ''}` };
}

export function CostMeter() {
  const v = useSel(store, (s) => activeView(s));
  const budget = useSel(store, (s) => s.budget);
  const plan = useSel(store, (s) => (v ? planOf(v.harness, s) : null));
  if (!v) return null;
  if (v.harness !== 'bedrock') {
    const t = planText(v.plan, plan ?? 'your plan');
    const near = v.plan?.limits.some((l) => (l.usedPercent ?? 0) >= 80);
    return (
      <span class={`meter-btn plan${near ? ' warn' : ''}`} title={t.long} data-testid="cost-plan">
        <span class="meter-label">on {plan ?? 'your plan'} · </span>
        <span class="meter-fig">{t.short}</span>
      </span>
    );
  }
  const { turn, session } = meter(v.turns, v.spend);
  const byok = byokCount(v.spend);
  const pct = v.budget ? percent(session, v.budget) : 0;
  const level = !v.budget ? '' : pct >= 100 ? ' over' : pct >= 80 ? ' warn' : '';
  const key =
    budget && budget.max !== null
      ? `\nThe key claude-code-terminal: ${money(budget.spend)} of its ${money(budget.max)} budget${budget.resetAt ? ` (resets ${new Date(budget.resetAt).toLocaleDateString()})` : ''}.`
      : '';
  return (
    <button
      type="button"
      class={`meter-btn${level}`}
      title={`Cost from ${PRODUCT}'s spend logs (what Bedrock, OpenRouter or Experiential Labs billed; a free model costs $0). Turns appear a few seconds after they end. Click to refresh.${byok ? `\n${byok} of this session's requests ran on your own provider key through Experiential Labs: that provider bills them, $0 here.` : ''}${v.budget ? `\nThis session's budget: ${money(v.budget.usd, 2)}${v.budget.hard ? ', stop on' : ' (warnings only)'} — ⋯ › Budget.` : ''}${key}`}
      onClick={() => void refreshSpend(v.id)}
      data-testid="cost"
    >
      {turn !== undefined && (
        <span class="meter-turn">
          <span class="meter-fig">{money(turn)}</span>
          <span class="meter-label"> turn</span>
          <span class="meter-sep"> · </span>
        </span>
      )}
      <span class="meter-fig">{money(session)}</span>
      <span class="meter-label">session</span>
      {v.budget && (
        <span class="meter-budget" data-testid="cost-budget" aria-label={`${Math.round(pct)} % of its ${money(v.budget.usd, 2)} budget`}>
          {' '}
          · {Math.round(pct)}%
        </span>
      )}
    </button>
  );
}

export function ContextMeter() {
  const c = useSel(store, (s) => activeView(s)?.context ?? null);
  if (!c) return null;
  const pct = Math.min(100, Math.round((c.used / c.max) * 100));
  const level = pct >= 85 ? 'over' : pct >= 65 ? 'warn' : '';
  return (
    <span class={`ctx ${level}`} title={`Context: ${tokens(c.used)} of ${tokens(c.max)} tokens${c.categories.length ? '\n' + c.categories.map((x) => `${x.name}: ${tokens(x.tokens)}`).join('\n') : ''}\n/compact frees it.`} data-testid="context">
      <span class="ctx-gauge">
        <i
          ref={(el) => {
            if (el) el.style.width = `${pct}%`;
          }}
        />
      </span>
      <span class="ctx-label">{pct}%</span>
    </span>
  );
}
