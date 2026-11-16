# Undertow — design

> A field instrument: a well-made tool you carry into a tense place. Calm,
> dark, exact, with one warm signal light. Nothing glows, nothing shouts.

The vault is the product; the cover (Video Trimmer) is a disguise and keeps
the look of a plain Android utility. This document is about the vault.

## Why it changed

The first design was assembled from defaults: Tailwind's violet on GitHub's
dark grey, a geometric "startup" typeface, a glowing purple ring, every row
in its own rounded card with a coloured icon tile, ALL-CAPS section labels,
a two-line description under everything, and a status line ("AES-256 GCM ·
Active") that performed security instead of serving the person holding the
phone. It looked like every generated app.

The references that shaped the new one: Mercury and teenage engineering
(via Refero Styles) for restraint and a single rationed colour; React Bits'
own interface and 21st.dev's app shell for quiet rows with monospaced
detail; Bencho's context meter and slide-to-confirm; Magic UI's staggered
entrances and number ticking, used sparingly; Uiverse's tactile controls;
Designeer's hold-to-confirm.

## Principles

1. **One signal colour.** Amber means "this is the action" or "this is
   live" (armed, recording, selected). Red means only "destroys something".
   Everything else is warm grey.
2. **Hierarchy from type and space, not boxes.** Group related rows on one
   surface, separated by hairlines. No icon tiles, no card per row, no
   gradients, no glows.
3. **Say it once.** Short labels in sentence case. A description only when
   the row would be misread without it.
4. **Numbers are data.** Sizes, dates, counts, codes and timers are set in
   the monospaced face, muted, aligned.
5. **Native first.** The system typeface (Roboto on Android) for text, so
   the app reads as a real Android app, not a template.
6. **Motion confirms, never decorates.** Rows settle in once, a step apart;
   presses give way slightly; destructive actions take a deliberate gesture.
   No sounds (a covert app must stay silent); haptics only on deliberate
   actions.

## Tokens

### Colour (dark only)

| Token | Value | Use |
|---|---|---|
| `canvas` | `#0F0F0E` | Screen background |
| `surface` | `#191917` | Grouped rows, sheets, dialogs |
| `raised` | `#23231F` | Inputs, pressed rows, secondary buttons |
| `hairline` | `#2D2C28` | Dividers between rows, field borders |
| `ink` | `#EDEAE3` | Primary text and icons |
| `ink2` | `#A39F95` | Secondary text, row icons |
| `ink3` | `#6F6B63` | Hints, disabled, tertiary detail |
| `signal` | `#E8A33D` | The primary action; armed / live / selected |
| `onSignal` | `#14110B` | Text on signal |
| `alert` | `#E5574F` | Destructive actions, failures, the recording dot |

### Type

| Role | Face | Size / weight |
|---|---|---|
| Screen title | System sans | 28 / 500, -0.4 tracking |
| Section label | System sans | 13 / 500, `ink2`, sentence case |
| Row title | System sans | 16 / 400 |
| Row detail | System sans | 13 / 400, `ink2` |
| Data (sizes, dates, codes) | Fira Code | 12 / 400, `ink2` |
| Button | System sans | 15 / 500 |

### Shape and space

- Base unit 4. Screen gutters 20. Rows 56 tall minimum (one line) or 68
  (two lines); 16 inside a group.
- Groups: radius 16, `surface`, rows divided by a hairline inset 16 from
  the left (52 when the row has an icon).
- Buttons and inputs: radius 12, 52 tall. Primary = `signal` fill,
  `onSignal` text. Secondary = `raised`. No shadows anywhere.

## Components

- **Group** — an optional sentence-case label, then rows on one surface.
- **Row** — leading line icon in `ink2` (no tile), title, optional detail,
  optional trailing value (mono) or chevron. Destructive rows in `alert`.
- **Meter** — the vault's size in large mono numerals, then a thin bar split
  by kind of file in shades of `ink`, then a one-line legend.
- **Filter** — text tabs with a 2-pt `signal` underline on the selected one
  and a mono count; no chips.
- **Primary button** — full width at the bottom of a flow, or the single
  floating "Add" in the vault.
- **Confirm by holding** — destructive actions fill in `alert` while held;
  letting go early cancels.
- **Toasts** — `raised` surface, `ink` text, an icon for kind; never a
  coloured background.
