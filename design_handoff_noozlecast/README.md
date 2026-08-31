# Handoff: NoozleCast — iOS Companion App for Bambuddy

## Overview
NoozleCast is an iOS app design that acts as a mobile frontend for **Bambuddy**, a self-hosted command center for Bambu Lab 3D printers. It talks to the Bambuddy REST API (the same API the existing bambuddy/frontend React app uses) to display live printer status/video and to manage filament inventory + AMS slot assignments. It also includes a camera scan-to-add-filament flow modeled after the `filament_to_bambuddy` companion tool (barcode scan + label-photo OCR → lookup → review → add to inventory).

## About the Design Files
The bundled file (`Nozzlecast.dc.html`) is a **design reference built in HTML** — a high-fidelity, interactive prototype of the intended look, layout, and interaction flow. It is NOT production code to embed in the app. The task is to **recreate this design natively in Swift/SwiftUI** (this is a fresh iOS app with no existing Swift codebase to match), using SwiftUI's native components (NavigationStack, TabView, List with `.listStyle(.insetGrouped)`, `.sheet`, Segmented `Picker`, `Toggle`, AVFoundation/VisionKit for the scanner) styled to match the glass/blur look documented below — not by embedding a WebView.

## Fidelity
**High-fidelity.** Colors, spacing, type sizes, radii, and copy below are final — implement pixel-close using SwiftUI equivalents (e.g. `.background(.ultraThinMaterial)` / `.regularMaterial` for the glass surfaces, SF Symbols standing in for the inline SVG icons used in the prototype).

## Data source
Everything shown is currently mock data standing in for live Bambuddy API responses. The app should be wired to Bambuddy's existing REST API (see `bambuddy/backend/app/api/routes/` in the Bambuddy repo) — printer status/telemetry, AMS trays, and inventory spools/assignments all already exist server-side. No backend changes are required for the Monitor, Inventory, or AMS-assignment screens. The **Scan** flow's barcode/OFD lookup logic should reuse the approach in `filament_to_bambuddy/app.py` (`/api/lookup`, `/api/parse`) — either by calling that service directly or porting its lookup logic — and spools are created via Bambuddy's `POST /api/v1/inventory/spools`.

---

## Design Tokens

### Colors
- Canvas background: `#1a1a1a`
- Glass card fill: `rgba(45,45,45,0.55)` with `backdrop-filter: blur(20px) saturate(180%)` → SwiftUI: dark `.ultraThinMaterial`/`.regularMaterial` over a dark base, or a custom `Material`-backed view
- Card border: `1px solid rgba(255,255,255,0.08)` (hairline, iOS 26 style borders use `rgba(255,255,255,0.06–0.15)`)
- Insets/wells (thumbnails, empty AMS slots): `#111` / `#141414`
- Primary text: `#ffffff`
- Secondary text: `rgba(235,235,245,0.6)`
- Tertiary/muted text: `rgba(235,235,245,0.4–0.45)`
- **Accent — "Neptune Blue"**: base `#2A5FCC`, light/hover `#4F7FE0`, dark/pressed `#1E48A8`. Used for progress fills, primary buttons, active tab icon/label, active filter chip, active AMS slot border, "Light" control highlight, FAB.
- **Status colors (fixed — never re-themed by accent)**: printing/ok `#22C55E`, warning/paused `#F59E0B`, error `#EF4444`, offline/idle `#6B6B6B`/`#4A4A4A`.
- Destructive action (Remove spool): `#EF4444`
- Settings grouped-list background: `#1C1C1E` (native iOS grouped list dark background), separators `rgba(84,84,88,0.55)` hairline (0.5px)
- Segmented control (Scan mode): track `rgba(120,120,128,0.24)`, selected thumb `#6B6B70` (neutral — NOT accent-colored, matching native `UISegmentedControl` dark mode)

### Typography
Font: `-apple-system` / SF Pro (system font stack) throughout — no custom typeface.
- Page large title: 34px / 700
- Screen/section title (detail, scan): 24px / 700
- Card title / printer name: 15–16px / 600
- Body / list row: 15px / 400–600
- Secondary/meta: 12–13px / 400–500
- Micro labels (AMS slot text, temps unit labels): 9–11px / 700, uppercase where noted
- Section eyebrow headers ("TEMPERATURES", "AMS FILAMENT", "BAMBUDDY SERVER"): 13px, uppercase, `letter-spacing: 0.6px`, `rgba(235,235,245,0.6)`

### Radii
- Cards: 18–20px
- Chips/temp stat boxes/AMS slots: 12–14px
- Inputs: 12px
- Pills/buttons/tab bar knobs/progress bars: 999px (fully round)
- Bottom sheets: 24px top corners only
- Settings grouped list container: 10px

### Spacing
4px-based scale, primary gutters 16px (screen padding), 12–14px card padding, 8–12px gaps between stacked elements, 6–8px gaps in tight rows (chips, AMS slot row).

### Elevation / Glass
Card shadow: `0 8px 20–24px rgba(0,0,0,0.35–0.45)`. Sheets: `0 -10px 40px rgba(0,0,0,0.5)`. All translucent surfaces use `backdrop-filter: blur(16–28px) saturate(160–180%)` — in SwiftUI, layer a `Material` (`.ultraThinMaterial`/`.thinMaterial`) with a subtle dark tint.

---

## Screens

### 1. Monitor (Tab 1 — default)
**Purpose:** At-a-glance fleet status; tap a printer to drill into full control.
**Layout:** Large title "NoozleCast" + subtitle "{n} printing · {n} printers", then a vertical stack of printer cards (12px gap), 16px screen padding, bottom padding to clear the tab bar.
**Printer card:** glass card, horizontal layout: 60×60 rounded-14 thumbnail (printer product photo normally; when `state == printing`, thumbnail is REPLACED by a small camera-preview placeholder with a pulsing "LIVE" badge, top-left, `rgba(0,0,0,0.55)` pill, 5px green pulse dot + 7px bold white "LIVE" text) — then name (16px/600) + status dot+label (7px dot, color per state, label per state) on one row; below: if printing, job filename (truncated) + 5px progress bar (accent fill) + "{progress}% · {eta} left"; if not printing, a row of 4 small 15px circular dots showing AMS slot colors (empty slots = `rgba(255,255,255,0.08)`). Trailing chevron.
**States → dot color/label/pulse:** printing → `#22C55E` "Printing" (pulsing), paused → `#F59E0B` "Paused", idle → `#6B6B6B` "Idle", error → `#EF4444` "Error", offline → `#4A4A4A` "Offline".

### 2. Printer Detail (pushed from Monitor/Settings; tab bar hidden)
**Layout:** Full-bleed 250px video preview area at top (dark gradient placeholder with camera glyph at 30% opacity when no real feed is available), glass back-chevron pill (36×36, top-left) and "more" ellipsis pill (top-right) floating over the video, both `rgba(0,0,0,0.45)` + blur(10px); "LIVE"/"OFFLINE" pill (same style as Monitor's live badge) top-left of video. Below the video: printer name (24px/700) + "{model} · {status label}"; if printing/paused, a job card (title + progress % + progress bar + "{eta} remaining"); a row of 4 circular control buttons (52×52, `rgba(255,255,255,0.08)` fill, 1px `rgba(255,255,255,0.1)` border): Pause/Resume (pause-bars ↔ play-triangle icon, label swaps "Pause"/"Resume"/"Start"), Stop (filled square), Light (bulb icon; when on, fill becomes `rgba(42,95,204,0.22)` with accent border/icon), More (ellipsis); a "Temperatures" section with 3 stat chips (Nozzle/Bed/Chamber — chamber chip hidden if printer has none) each showing a 18px icon, "{current}°/{target}°" (bed/nozzle) or "{current}°" (chamber), and a caption; an "AMS Filament" section with a row of 4 tappable slot cards (see AMS Slot spec below) — tapping one opens the AMS Assign sheet.

**AMS Slot card (reused across Detail, AMS sheet's own slot row, and the post-scan assign picker):** 14px-radius card, top 50px swatch (spool's hex color, centered material-name label in black/white depending on swatch lightness) — empty slots show a repeating 45° stripe pattern (`#2a2a2a`/`#1c1c1c`) and "Empty" label; below the swatch, a 9px caption (spool color name, or "Slot {n}" if empty). Occupied+active slot gets a 2px accent-colored border; otherwise a 1px hairline border.

### 3. AMS Assign sheet (modal, presented over Detail or Monitor)
**Layout:** Bottom sheet, backdrop `rgba(0,0,0,0.6)`, sheet `#212121` with 24px top-corner radius, drag-handle bar (36×5, `rgba(255,255,255,0.2)`); header: "{Printer name} · Slot {n}" (17px/700) + either the current occupant (22×22 color swatch + "{material} · {color name}" + red "Remove" text-button) or "Empty slot — assign a spool from inventory" caption; below, a scrollable list of ALL inventory spools as rows (34×34 color swatch, "{material} · {color name}" 14px/600, "{brand} · {location}" 11.5px muted, trailing "{remaining}%") — tapping a row assigns that spool to this slot (and un-assigns it from wherever it previously was).

### 4. Filament Inventory (Tab 2)
**Layout:** Large title "Filament" + "{count} spools · {totalGrams} g on hand" subtitle; horizontal-scrolling filter chip row (All / In AMS / In Storage / PLA / PETG / ABS / TPU — active chip: accent bg + white text; inactive: `rgba(255,255,255,0.07)` bg); 2-column grid of spool cards (12px gap): each card has a 60px color-swatch header with material name overlaid bottom-left (text color/shadow computed for contrast against the swatch color), then color name (12.5px/600), brand (10.5px muted), a 3px remaining-% bar tinted the spool's color, and a location caption ("{Printer} · Slot {n}" or "In storage"). A floating accent-colored circular FAB (52×52, bottom-right, offset above the tab bar) opens the Scan tab.

### 5. Scan (Tab 3) — 4 steps in one flow
**Step "capture":** Title "Scan Filament"; a native-style segmented control (2 options: Barcode / Label Photo — selected segment gets a neutral grey `#6B6B70` capsule, NOT accent-colored, matching native `UISegmentedControl`); below, a full-bleed dark viewfinder card (rounded 24px) with 4 corner brackets, an animated horizontal scan-line (accent-adjacent green-blue glow — currently light-blue `#4f7fe0`), and a caption ("Point at the box barcode" / "Photograph the filament label" depending on mode); large white shutter button (72×72 ring + 58×58 filled circle) + "or enter code manually" caption.
**Step "loading":** Same viewfinder, dimmed, with a centered glass card: spinning ring (accent top-color) + "Looking up filament…".
**Step "review":** Title "Review Details"; a color-swatch preview + "Also matches: {other package/SKU match}" caption (mirrors `filament_to_bambuddy`'s "Also matches" feature); editable fields (Brand, Material, Color name, Net weight) as glass text inputs; sticky "Add to Inventory" primary button (accent fill).
**Step "done":** Success checkmark in an accent-tinted circle (pop-in animation), "Added to Inventory" title, a summary row (swatch + "{material} · {color name}"), then two full-width buttons: "Assign to a Printer" (accent fill — opens a 2-step picker sheet: choose printer → choose AMS slot, reusing the AMS Slot card component) and "Done" (neutral, returns to Inventory tab).

### 6. Settings (Tab 4)
**Layout:** Large title "Settings"; native **grouped list** sections (NOT custom cards — `#1C1C1E` background, 10px radius, 0.5px hairline row separators `rgba(84,84,88,0.55)`, 44–52px row height, 16px horizontal inset):
- "BAMBUDDY SERVER" group: Server (value "bambuddy.local:8000"), API Key (masked, "••••••••3f2c"), Status (green 6px dot + "Connected") — with a caption below the group: "Manage Inventory, Read Status permissions granted." (mirrors Bambuddy API-key permission model).
- "PRINTERS" group: one row per printer (30×30 thumbnail, name, model, chevron) — tapping pushes Printer Detail.
- About footer: centered 64×64 app icon, "NoozleCast 1.0.0", tagline "Local-first control for your farm."

**Note:** A push-notification toggle was intentionally left out of this version — Bambuddy's notification system (providers, per-event toggles, templates) is fully server-owned via its existing API, and there is currently no device-push-registration endpoint for a mobile client to hook into. Revisit once that exists server-side.

---

## Navigation & Tab Bar
Standard **native iOS bottom tab bar** (not a floating pill): full-width, `rgba(22,22,24,0.78)` + `blur(28px) saturate(180%)`, 0.5px top hairline border `rgba(255,255,255,0.15)`, 83px tall (49pt tab bar + 34pt home-indicator safe area). 4 tabs: Monitor (grid glyph), Inventory (spool glyph), Scan (camera glyph), Settings (gear glyph) — active tab icon+label tinted accent blue, inactive `rgba(235,235,245,0.55)`. Tab bar hides when Printer Detail is pushed.

## Interactions
- Tap printer card / Settings printer row → push Printer Detail.
- Tap AMS slot (Detail) → present AMS Assign sheet.
- Tap a spool row in the AMS sheet → assign + dismiss sheet.
- "Remove" in AMS sheet → unassign + dismiss.
- Pause/Resume/Stop/Light in Detail → mutate printer state locally in the prototype; in production these call Bambuddy's printer control endpoints.
- Filter chips in Inventory → client-side filter by AMS/storage/material.
- Scan capture → simulated ~1s "loading" delay before showing prefilled review data (production: real barcode/OCR + Bambuddy/OFD/SpoolmanDB-Community lookup).
- "Add to Inventory" → POST new spool, show success step.
- "Assign to a Printer" (post-scan) → 2-step picker (printer → slot) → assigns and returns to Inventory.

## Assets
- `assets/printers/{x1c,a1,p1s}.png` — official Bambu Lab printer product renders (from the Bambuddy design system; reuse or request updated renders for any other printer models).
- `assets/icons/{hotend,heatbed,chamber}.svg` — hardware telemetry glyphs used in the Temperatures section.
- `assets/icons/app-icon.png` — 1024×1024 app icon (nozzle-drip + broadcast-wave mark, Neptune Blue).
- All other icons (tab bar, controls, chevrons, checkmarks) are simple inline line icons drawn in the prototype (2px stroke, round caps) — recreate as SF Symbols where a close match exists (e.g. `square.grid.2x2`, `circle.grid.cross`, `camera.viewfinder`, `gearshape`, `chevron.left`, `pause.fill`/`play.fill`, `stop.fill`, `lightbulb`) or custom vectors otherwise.

## Files in this bundle
- `Nozzlecast.dc.html` — the full interactive design prototype (open in a browser to click through every screen/state).
- `ios-frame.jsx` — reference source for the iOS device-chrome/glass-pill conventions the prototype follows (status bar, dynamic island, glass pill recipe) — for visual reference only, not for reuse as code.
- `assets/` — image assets listed above.
