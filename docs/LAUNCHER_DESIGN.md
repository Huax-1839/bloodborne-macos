# Launcher "Hunter's Lantern": visual design

Status: direction chosen by the user on 2026-10-19 (`docs/LAUNCHER_PLAN.md` §9). The window and
its home page are implemented in SwiftUI (2026-10-19): tokens, type and the components in
`launcher/Sources/HuntersLantern/Views/Print.swift`, the page in `HomeView.swift`, the fixed window
and the page sheets in `RootView.swift`. The pages behind the sheets still have their old look
(§9).

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

## 3. Layout (960 × 600, not resizable)

- Native title bar, transparent, traffic lights over the content; the window drags by its
  background.
- Left area (576 px): game title 64, version line in small caps, a brass rule with ❧, a register
  with dotted leaders (last hunt, hunter level and play time, backups), then at the bottom the
  main button "Jagd beginnen": a `accent` rectangle, full column width, 72 high, text 28.
- Right column (384 px, `bg-raised`, 1 px `line` on its left): settings groups with a small-caps
  heading: Profil, Darstellung (renderer, frame rate), Spiel (game folder, mods).
- Status bar 32 high, `bg-sunken`, mono 12: readiness on the left (● in `ok` or `danger` + text),
  version on the right.

## 4. Choices as register entries

No pop-up menus or boxed fields for choices. Every setting is a register line:
`label ········ value`.
- Lists (profiles): one line per option, the chosen one marked with ✦ in `brass` and set in
  `text-primary`, the others in `text-secondary`; a note at the line's end (e.g. "empfohlen").
- Short alternatives (renderer, frame rate): the options as words after the leader, the chosen one
  in `text-primary` with a 1 px `brass` underline.
- Paths: the label line ends in a text action ("ändern"/"wählen"), the path follows on its own
  line in mono.
- They are radio groups (keyboard: arrows inside the group, Tab between groups), focus as a 1 px
  `brass` outline.

## 5. States

- No game folder: main button disabled (`text-muted` on `bg-raised`), the register hidden, a hint
  under the button in `text-secondary`; status ● `danger`.
- Game running: button text "Die Jagd läuft…", button and all settings disabled (D7).
- Error: one line above the button in `danger`, no modal; the button stays available to retry.
- Focus: 1 px `brass` outline, visible for keyboard use only.

## 6. Deviations from the original brief

- Traffic lights keep their system colours (drawn by macOS).
- Input fields use `bg-base`, not `bg-raised`: they sit in the `bg-raised` column and would
  vanish otherwise.
- The brief allowed Tauri or Electron; the plan fixes SwiftUI (D2).
- No game artwork on the home page (the brief forbids pictures); D17 changed accordingly.

## 7. Forbidden

Gradients, glass, blur, drop shadows, pill buttons, card grids, emoji, icon libraries, purple or
blue, Inter or system fonts for visible text, a centred hero layout, placeholder images, logos
or artwork from the game.

## 8. Self-check before a design change is done

1. Is `accent` used only for the main action?
2. Is any value not among the tokens?
3. Is the main action the most dominant element at first sight?
4. Would it read as gothic/Victorian without the title?
5. Does anything look like a generic SaaS app? Remove it.

## 9. Implementation notes and what is open

- The other pages (game, profiles, graphics, mods, patches, saves, advanced, diagnostics, about)
  are sheets of 880 × 520 over the window, reached from the text actions ("verwalten", "ändern",
  "mehr"), the register lines (last hunt → diagnostics, hunter and backups → saves), the version
  in the status bar (about) and the Go menu (⌘1–⌘7, ⌘, for graphics). Their frame
  (`PageContainer`) has the new title, background and a "schließen" action (Esc); **their content
  still uses the old cards and system forms**: to be redone in the print style, page by page.
- Errors: the home page shows them inline (§5); a sheet covers it, so the sheets keep an alert.
- Built-in profiles are read-only (as on the Graphics page): their renderer and frame-rate words
  are muted, with "zum Ändern kopieren" next to them.
- The title is "Bloodborne" for every accepted title ID (all are Bloodborne with update 1.09); the
  version line names the title ID.
- The window: `Window` scene, hidden title bar, not resizable, no full screen or zoom, moved by its
  background; the content leaves out the title bar's height so the window is 960 × 600 in all.
- Not checked by hand yet: hover, the gas-lamp flicker, keyboard focus outlines, Reduce Motion
  (the snapshots cannot show them).
- First-run assistant and import progress in the same style.
