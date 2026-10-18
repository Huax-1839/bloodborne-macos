# Launcher "Hunter's Lantern": visual design

Status: direction chosen by the user on 2026-10-19 (`docs/LAUNCHER_PLAN.md` §9). The window and
its overview are implemented in SwiftUI (2026-10-19, layout of §3); the other pages still have
their old look inside (§9).

## 1. Direction

Victorian gothic, after printed documents of the 19th century: hunting registers, apothecary
labels, parish books, wrought iron. Dark, warm, serious, restrained. The UI reads as a typeset
print, not as a web app: few elements, much weight per element.

## 2. Tokens (binding; no values outside them)

Colours:

| Token | Value | Use |
|---|---|---|
| `bg-base` | `#0e0c0b` | window background; input fields (see §6) |
| `bg-raised` | `#161311` | settings column, disabled main button |
| `bg-sunken` | `#0a0908` | status bar, log areas |
| `line` | `#2a2420` | rules, borders |
| `line-strong` | `#4a3f36` | dotted leaders, active rules |
| `text-primary` | `#d8cfbf` | parchment/bone |
| `text-secondary` | `#8f8577` | labels, hints |
| `text-muted` | `#5c544a` | disabled, placeholders |
| `accent` / `-hover` / `-pressed` | `#7a1f1a` / `#93261f` / `#5e1713` | oxidised blood red, **only** the main action |
| `brass` | `#9c8455` | hover, ornament rules, focus, selection marks |
| `danger` | `#a83a2c` | errors |
| `ok` | `#6b7a4f` | muted moss green for "ready" |

Type (bundled, SIL Open Font License):
- Display: Cormorant Garamond 600 (title 64, main button 28), line height 1.05.
- Accent: IM Fell English SC (section headings, 14, letter spacing 0.12em; version line).
- Text: EB Garamond 400 (text 16, labels 14), line height 1.5.
- Mono: JetBrains Mono 400, 12, only for paths, versions, logs, the status bar.
- Sizes: 12 / 14 / 16 / 20 / 28 / 44 / 64.

Spacing: 4 px grid; allowed 4 / 8 / 12 / 16 / 24 / 32 / 48 / 64. Window inset 48, between
settings groups 32.

Form: radius 0 everywhere, input fields 2. Borders 1 px `line`. No shadows except inputs
(`inset 0 1px 0 rgba(0,0,0,0.4)`). Ornaments only as thin rules (1 px `brass` at 40 % opacity)
and typographic marks (❧, ✦). No pictures, no icon sets.

Motion: 180 ms hover, 600 ms window fade-in, easing `cubic-bezier(0.2, 0, 0, 1)`. No bounce or
scale. The main button flickers on hover like a gas lamp: irregular brightness, at most ±4 %;
off with Reduce Motion.

## 3. Layout (960 × 600, not resizable; revised 2026-10-19 after mock-up F)

The layout follows the library launchers (a sidebar of pages), set in this design's style, with
as little text as possible.

- Native title bar, transparent, traffic lights over the sidebar; the window drags by its
  background.
- Sidebar (192 px, `bg-raised`, 1 px `line` on its right): "Bloodborne" (the overview), a brass
  rule, then Profile, Mods, Patches, Spielstände with small counts in mono `text-muted`; at the
  bottom Spielordner, Diagnose, Einstellungen. The current page in `text-primary` with ✦ in
  `brass` before it, the others `text-secondary`, brass on hover. Every page opens in the main
  area (no sheets).
- Overview (main area, 768 px):
  - a plate of the game's own artwork, `sce_sys/pic1.png` of the user's copy, read at run time
    (never in the repository or the app), full width, 280 high, cropped to fill, a hard edge
    and a 1 px `line` under it; the artwork carries the game's name, so no title is set in type
    (without a game or artwork: the name in Cormorant 64 on `bg-sunken`);
  - under it, inset 48: the title ID and version in small caps and the profile (a text action
    with ▾ that opens the profile menu) on the left, the main action on the right (`accent`,
    240 × 72, Cormorant 28, "Jagd beginnen");
  - one line under that only when there is something to say (an error in `danger`, a hint in
    `text-secondary`);
  - at the bottom two short lists, small-caps heading over rows between 1 px rules: Jäger (slot,
    level, play time) and Letzte Jagden (day, duration, "abgestürzt" in `danger`), two rows each;
    a row links to its page.
- Status bar 32 high, `bg-sunken`, mono 12: readiness, or the last error or notice with
  "schließen" (no modal), on the left; the version (links to About) on the right.

## 4. Choices

- The profile is chosen in a menu from the overview (and on the Profiles page).
- Settings pages use register lines (`label ········ value`) when they are restyled (§9).

## 5. States

- No game folder: main button disabled (`text-muted` on `bg-raised`), the plate shows the app's
  name, a hint points to "Spielordner"; status ● `danger`.
- Game running: "Die Jagd läuft …", button and the profile menu disabled (D7).
- Error: one line under the band in `danger`, no modal; the button stays available to retry.
- Focus: 1 px `brass` outline, visible for keyboard use only.

## 6. Deviations from the original brief

- Traffic lights keep their system colours (drawn by macOS).
- Input fields use `bg-base`, not `bg-raised`: they sit in the `bg-raised` column and would
  vanish otherwise.
- The brief allowed Tauri or Electron; the plan fixes SwiftUI (D2).
- The overview shows the game's own artwork from the user's copy (the user's decision of
  2026-10-19, after the brief had forbidden pictures); nothing from the game is in the repository
  or the app.

## 7. Forbidden

Gradients, glass, blur, drop shadows, pill buttons, card grids, emoji, icon libraries, purple or
blue, Inter or system fonts for visible text, a centred hero layout, placeholder images; logos or
artwork from the game other than the user's own `sce_sys/pic1.png` on the overview.

## 8. Self-check before a design change is done

1. Is `accent` used only for the main action?
2. Is any value not among the tokens?
3. Is the main action the most dominant element at first sight?
4. Would it read as gothic/Victorian without the title?
5. Does anything look like a generic SaaS app? Remove it.

## 9. Implementation notes and what is open

- Code: tokens, type and the shared styles in `launcher/Sources/HuntersLantern/Views/Print.swift`,
  the overview in `HomeView.swift`, the window, sidebar, status bar and Go menu (⌘0–⌘7, ⌘, for
  settings) in `RootView.swift`.
- **The pages other than the overview still use the old cards and system forms inside**
  (`PageContainer` has the new title and background): to be redone in this style, page by page.
  Settings is the old Graphics page; Advanced and About are reached from the Go menu, About also
  from the status bar's version.
- The window: `Window` scene, hidden title bar, not resizable, no full screen or zoom, moved by its
  background; the content leaves out the title bar's height (measured in AppKit) so the window is
  960 × 600 in all.
- Not checked by hand yet: hover, the gas-lamp flicker, keyboard focus outlines, Reduce Motion,
  the profile menu (the snapshots cannot show them).
- First-run assistant and import progress in the same style.
