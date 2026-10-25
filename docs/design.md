# Design

Back to the [README](../README.md).

DevOS ADE uses the DevOS design system: the DevOS website's tokens, type scale, fonts, radii, shadow, easing and card,
button and nav patterns. Two things are ADE's own. The accent is ADE's teal, taken from the icon's ribbon, where the
website uses violet. Dark mode uses the DevOS apps' warm "Ink" palette, not the website's cool dark.

The tokens live in one file with two identical copies, because the portal and the Code page are built from separate
Docker contexts:

- `portal/portal/static/tokens.css` and `code/web/src/styles/tokens.css`: custom properties only.
- `portal/portal/static/fonts.css` and `code/web/src/styles/fonts.css`: the `@font-face` rules, with the fonts beside
  them in `fonts/`.

`tests/test_design_tokens.sh` fails when the copies differ.

## Tokens

| ADE token | Light | Dark | From |
|---|---|---|---|
| `--bg` | `#f5f3ee` | `#14110e` | site `--bg` / apps `Ink.bg` |
| `--bg-2` | `#ebe8e0` | `#1a1511` | site `--bg-2` / apps `Ink.well` |
| `--surface` | `#ffffff` | `#221c17` | site `--surface` / apps `Ink.card` |
| `--ink` | `#14151a` | `#f4ecdf` | site `--ink` / apps `Ink.ink` |
| `--muted` | `#4b4e5a` | `#b3a394` | site `--muted` / apps `Ink.dim` |
| `--line` | `#d6d2c7` | `#3a3128` | site `--line` / apps `Ink.line` |
| `--line-strong` | `#858073` | `#806f5f` | ADE: form fields' borders, 3:1 or more |
| `--accent` | `#1b6a5f` | `#84c8bf` | ADE teal, in place of the site's violet |
| `--accent-ink` | `#ffffff` | `#14110e` | site `--accent-ink` |
| `--accent-soft` | `#dcece8` | `#1f2d29` | site `--accent-soft`, in teal |
| `--steel` | `#3d6591` | `#8fb0d6` | site `--steel` (also the icon's blue ribbon) |
| `--ok` | `#2c7340` | `#b7c7a1` | ADE / apps `Ink.good` |
| `--warn` | `#94590b` | `#e6a15a` | ADE / apps `Ink.lamp` (attention) |
| `--bad` | `#b02f30` | `#f08c7c` | ADE |
| `--track` | `#e4e0d6` | `#2e2620` | ADE: meters, switches |
| `--sidebar` | `#ece9e1` | `#1a1511` | ADE |
| `--shadow` | site | site (dark) | site `--shadow`: a card that lifts |
| `--shadow-pop` | | | ADE: menus, dialogs, sheets |
| `--card-edge` | none | a 1 px warm highlight on a card's top edge | apps: their cards catch a little light |
| `--ease` | `cubic-bezier(0.22, 0.8, 0.24, 1)` | | site `--ease` |
| `--r-s` … `--r-pill` | 6, 10, 14, 18, 999 px | | the site's radii: tags, fields, small cards, cards, pills |

Light and dark follow `prefers-color-scheme`. `[data-theme="light"]` and `[data-theme="dark"]` on `<html>` force
either, as on the website. ADE has no theme switch, so this only matters for a future one.

The old names `--sans`, `--mono` and `--figures` remain as aliases of `--font-sans`, `--font-mono` and
`--font-display`.

## The teal

Sampled from `portal/brand/AppIcon.icon/Assets/torus-teal.png`: the teal ribbon has a hue of 172°. Its median colour
is `#7ea8a2`, with about 18 % saturation, and its lit face is `#a0c5c0`. Both accents keep that hue. They are more
saturated, so they read as teal rather than grey, and their lightness is set for contrast (WCAG 2.2 ratios):

| | on `--bg` | on `--surface` | on `--bg-2` | text on the accent |
|---|---|---|---|---|
| Light `#1b6a5f` (HSL 172° 60 % 26 %) | 5.79 | 6.42 | 5.24 | white: 6.42 |
| Dark `#84c8bf` (HSL 172° 38 % 65 %) | 9.85 | 8.82 | 9.48 | `#14110e`: 9.85 |

The accent on `--accent-soft` is 5.26 in light and 7.50 in dark.

The other text colours, on `--bg` and `--surface`:

| | Light | Dark |
|---|---|---|
| `--ink` | 16.4 / 18.2 | 16.0 / 14.4 |
| `--muted` | 7.47 / 8.28 | 7.69 / 6.89 |
| `--ok` | 5.21 / 5.78 | 10.5 / 9.38 |
| `--warn` | 5.13 / 5.69 | 8.61 / 7.71 |
| `--bad` | 5.75 / 6.37 | 7.84 / 7.02 |
| `--line-strong` (non-text) | 3.55 / 3.94 | 3.90 / 3.50 |

## Type

| Token | Size | Used for |
|---|---|---|
| `--t-4` | `clamp(2.1rem, …, 3.4rem)` | not used yet: the site's section heads |
| `--t-3` | `clamp(1.6rem, …, 2.1rem)` | page titles: Home, Settings, Sign in |
| `--t-2` | 1.4375rem | a Settings section, the update card, dialogs, sheets |
| `--t-1` | 1.1875rem | card titles on Home, Activity, the walkthrough |
| `--t-0` | 1rem | the walkthrough's step title |
| `--t-s` | 0.875rem | labels |
| `--t-xs` | 0.8rem | ADE's step below `--t-s` (16 / 1.25), dense chrome |

The portal's running text stays at 15 px and the Code page's chrome at 13 px: both are dense tools.

- **Display:** "DevOS Serif" (Source Serif 4), weight 600, for page and section titles: `h1` to `h4`, the brand name
  and the spend figure.
- **UI:** "DevOS Sans" (Inter).
- **Code, commands, keys, versions, tags and the terminal:** "DevOS Mono" (JetBrains Mono).

The three fonts are the website's own files: latin subsets with a variable weight axis, 140 KB in all. Each is under
the SIL Open Font License 1.1, with its licence beside it in `fonts/LICENSE-*.txt`. They load from the page's own
origin, never from a CDN.

The sign-in and unlock pages that the Admin, Files, terminal and Code hosts serve read the portal's style sheets from
the portal's host. Their CSP allows no fonts from there, so they use the system fonts in the same colours.

## Components

- **Buttons:** pills. The main action (`.action.primary`: Sign in, Install app, Open in Code, Save, Confirm) is teal,
  with `--accent-ink` text. It lifts 1 px with `--shadow` on hover. Other buttons are outlined in `--line`, with ink
  text, and their outline turns ink on hover. A disabled button is dashed and muted, never faded, so its label keeps
  its contrast. Text on a coloured badge or button uses `--accent-ink`: white in light, Ink in dark.
- **Chips and filters:** pills on `--surface`. The chosen one is ink, as on the website's filters.
- **Cards:** `--surface`, a `--line` hairline and an 18 px corner, plus `--card-edge` in dark. Home's cards do not
  lift: they are not links.
- **Lit card:** a card that needs you, such as the update card, has a 4 px teal rail on its left (the apps'
  `LampCard`).
- **Navigation:** the sidebar marks the page shown with a teal pill: the website's header marks its page with a pill,
  and ADE's is its teal. Settings marks its section with a teal wash and a 3 px teal rail, like the website's active
  step. The phone's tab bar marks it with a teal icon, label and underline.
- **Page head:** an eyebrow above each page title, as the website labels its sections: mono, uppercase, teal, for
  example "DevOS ADE · Home". It is `aria-hidden`, so the heading's name stays the title. Behind the head, a soft
  `--accent-soft` wash fades into the paper over about 340 px.
- **Fields:** a 10 px corner and a `--line-strong` border (3:1). Search fields are pills.
- **Tags and badges:** mono, 11 px, with a 6 px corner (the website's `.tag`).
- **Focus:** a 2 px `--accent` outline, offset 2 px, everywhere.
- **Overlays:** dialogs, Activity, search, the walkthrough card and the phone sheets use an 18 px corner and
  `--shadow-pop`.
- **Motion:** `--ease`, 0.2 to 0.25 s. `prefers-reduced-motion` turns transitions and lifts off.

## The Code page and the terminal

The Code page imports the same `tokens.css` and `fonts.css`. Its own extra tokens, in `code/web/src/styles/app.css`,
are derived from the palette: chrome, panels, the editor, syntax and diffs. Syntax colours keep 4.5:1 on the editor
in both themes. The page's chrome follows the portal:

- pills for its buttons, pickers and status-bar actions;
- mono eyebrows for its group heads;
- the display serif for dialog titles, the welcome, a permission card's question and the headings in Claude's
  answers.

A permission card is the apps' lit card: a 4 px amber edge, because it needs you. The prompt box has an 18 px corner
and a teal ring while you type in it.

The terminal (ttyd, `terminal/bin/bn-terminal`; tmux, `terminal/tmux.conf`) is Ink in both themes:

- background `#14110e`, text `#f4ecdf`;
- a teal cursor, and a teal tab for the current window.

It keeps the system's monospace font. ttyd's page allows fonts only as `data:` URLs, and xterm.js measures its
character cells once, when it opens. A web font that arrived later would draw text out of step with the cells.

## Do and don't

- **Do** use the tokens. A new colour first becomes a token in both `tokens.css` copies, with its contrast in this
  file.
- **Do** keep the accent for the main button, links, focus, the current place, progress, budgets within their limit
  and switches that are on. Amber and red are for near the limit and over it.
- **Do** put titles in the display serif, and keep body text, controls and numbers in tables in Inter.
- **Don't** add gradients beyond the head wash and the sign-in glow, or new imagery.
- **Don't** load anything from another origin: fonts, styles and images stay same-origin, so the CSP stays as it is.
- **Don't** use `text-transform` on text that tests or screen readers read as words. Use it only on short eyebrow
  labels, as the search groups do.
- **Don't** change the icon. It is the DevOS torus, sized to match the apps.
- **Don't** fade a disabled control below 4.5:1. Use the dashed style.

## Chat (Open WebUI)

Chat is Open WebUI, a third-party app. It is restyled only through its own supported settings, never forked.
