# PROJECT_DESIGN — Onyx Quiet Premium

## 1. Product Context

- Product: Onyx — client Flutter Direct Play self-hosted
- Target user: foyer / propriétaire de bibliothèque privée
- Target surface: app Flutter entière (`app/lib`) — login, shell, home, catalogues, fiches, demandes, settings, lecteur, player studio
- Primary job-to-be-done: trouver un titre vite, le lire sans friction, contrôler audio/subs/épisodes
- Success criteria: UI plus pro et cohérente ; aucune feature cassée ; desktop ≥900px et mobile
- Content/data: posters TMDB/API, progressions, titres, métadonnées, demandes
- Interaction requirements: nav shell, search, detail → play, player controls, studio layout
- Technical constraints: Flutter + Provider + Material 3 + media_kit ; MediaHub hors scope

## 2. Existing UI Read

- Current visual vocabulary: dark `#0A0A0A`, glass headers, Netflix red `#E50914`, Inter, rows/carousels, modular player HUD
- Strongest existing cue to preserve: glass chrome léger + posters full-bleed + shell desktop sticky
- Components/tokens to reuse: `glass_chrome.dart`, `liquid_glass_panel.dart`, `MediaCard`, `MediaRow`, `HeroCarousel`, player modular controls
- Patterns to preserve: IndexedStack tabs, continue watching, hero, horizontal media rows, player auto-hide HUD
- Patterns to evolve: tokens couleur/typo, focus states, progress accent, login atmosphere, densités/espacements
- Patterns to remove or avoid: rouge Netflix, glow purple, cards empilées inutiles, Inter-as-brand, glass partout
- Accessibility: dark contrast, 44px targets mobile, focus desktop, reduced motion

## 3. Taste Direction

- Product identity: client cinéma privé calme — le média parle, l’UI se tait
- Recommended taste: **Quiet Premium** (Apple TV–adjacent restraint, sans copier)
- Direction to avoid: concepts théâtraux forts (velours/or, film grain, nixie, cockpit), clones Netflix, neon SaaS
- Why more useful: moins de bruit → scan plus rapide, contrôles plus lisibles, sensation « produit fini »
- Distinctive: typo Manrope + labels Geist, accent focus bleu mesuré, glass rationné
- Quiet: surfaces plates charcoal, pas de flare décoratif, player HUD qui disparaît

## 4. Selected References

### design.md Cinematic Glass (incumbent brief)
- Why: déjà documenté ; aligné dark + glass
- Transferable: charcoal layers, Manrope/Geist, blur 20–40, inner highlight border, accent `#007AFF` sparingly
- Non-transferable: over-glass everywhere, scale-on-focus 1.1 agressif
- Risk: blur cost sur desktop — limiter aux headers/overlays/contrôles

### Quiet media restraint (Apple TV–adjacent, not a brand copy)
- Why: match explicite utilisateur « calme / premium discret »
- Transferable: content-first posters, large breathing margins, sparse chrome, soft focus rings, system-native affordances on iOS/Android
- Non-transferable: SF Pro exclusif, product icons/logo Apple, tvOS parallax marketing
- Risk: trop générique « dark app » — Manrope + accent bleu + glass mesuré portent l’identité

### Vercel / Linear (weaken heavily)
- Why: précision Operate
- Transferable: hierarchy, hairline borders, calm density
- Reject: dashboard chrome, issue-tracker metaphors

## 5. Visual Theme & Atmosphere

- Design thesis: **Quiet theater chrome** — OLED black stage, frosted controls only when needed, posters as the only spectacle
- Emotional tone: calme, confiance, contrôle effortless
- Personality: premium privé, jamais flashy
- First viewport (Home): hero média + logo/titre discret + continue watching ; chrome glass top/bottom seulement
- Visual weight: 1) artwork 2) title/progress 3) nav 4) chrome décoratif (quasi zéro)

## 6. Color Palette & Roles

- Background: `#0A0A0A`
- Surface: `#141414`
- Surface elevated: `#1C1C1C`
- Surface hover: `#252525`
- Primary text: `#F5F5F7` (≥ `#E8E8ED`)
- Secondary text: `#A1A1A6`
- Muted text: `#6E6E73`
- Accent / focus / progress: `#0A84FF` (ex-`#007AFF`, un peu plus OLED)
- On-accent: `#FFFFFF`
- Border: `rgba(255,255,255,0.08)` / `#2C2C2E`
- Focus ring: `#0A84FF` @ 0.9, 2px
- Success: `#30D158` · Warning: `#FF9F0A` · Error: `#FF453A`
- Constraints: **no `#E50914`** ; accent ≤ ~5% surface ; pas de purple/neon

## 7. Typography Rules

- Display/UI: **Manrope** (Google Fonts)
- Labels/meta: **Geist** si dispo via google_fonts / fallback Manrope Medium tracking +0.02em
- Display hero: Manrope 700, tight tracking (−0.02em)
- Section titles: Manrope 600, 20–24
- Body: Manrope 400, 15–16, line-height 1.45–1.6
- Captions: Manrope/Geist 500, 12–13, secondary color
- Weights: avoid ultra-light ; prefer 500/600 for UI chrome

## 8. Component Styling

### Buttons
- Primary: fill blanc 92% / text near-black ; radius 12 ; no heavy shadow
- Secondary: glass or hairline border white 12%
- Icon buttons: 44×44 min, circular glass on player only

### Media cards
- Radius 12–14 ; no card fill behind poster
- Hover desktop: 1px white 16% stroke + slight brightness ; play affordance optionnelle
- Progress: 3–4px `#0A84FF` bottom edge

### Navigation
- Desktop: frosted top strip (blur 24–30), tabs text weight, accent underline/dot not filled pill blob
- Mobile: bottom bar frosted, selected = accent icon + label, unselected muted

### Forms (login)
- Quiet radial charcoal (no red wash) ; fields elevated surface ; focus border accent

### Player HUD
- Controls over video with quiet glass (no neon glow) ; timeline accent blue ; hide after idle
- Settings panel: frosted shell, segmented tabs, radio-check track rows (no left accent bar)
- Episodes sheet / skip intro / next episode: same Quiet Premium glass language
- Player Studio shop + drawers: elevated surface cards, soft borders, Manrope hierarchy
- Pack Cinéma Essentiel (boutique): Passer intro · Vitesse · Affichage · Audio · Chapitres · Temps restant · ±30s — Quiet Premium pills/icons, wired to live player actions

### Empty / loading / error
- Centered quiet copy ; spinner accent ; no illustration clutter

## 9. Layout Principles

- Spacing: 4/8/12/16/24/32/48/64
- Desktop margins: ≥48–80 horizontal on large
- Mobile margins: 16–20
- Home: hero full-bleed → rows with title above (more space above than below)
- Breakpoint shell: 900px wide vs compact (existant)
- Density: browse medium ; player sparse

## 10. Depth, Motion, And Interaction

- Elevation: base flat → glass level 1 (nav) → glass level 2 (menus)
- Shadow: one soft ambient for floating menus only (`0 24 48 black 45%`)
- Motion: 180–280ms ease-out ; hero crossfade ; control fade ; respect `disableAnimations` / reduced motion
- Touch: 44×44 mobile ; 8px gaps

## 11. Do's And Don'ts

### Do
- Keep every feature wired and discoverable
- Let posters dominate
- Use accent only for focus, selection, progress, links
- Align shell + player + login on same tokens

### Don't
- Netflix red, purple gradients, neon glow
- Glass on every card
- Fake metrics / marketing sections
- Break Player Studio or request flows for aesthetics

## 12. Implementation Mapping

- Tokens: `app/lib/theme/app_colors.dart`, `app_theme.dart`
- Chrome: `glass_chrome.dart`, `liquid_glass_panel.dart`, `control_chrome.dart`
- Shell: `main_shell.dart`, `app_top_bar.dart`
- Browse: `home_screen.dart`, media widgets, library screens, detail widgets
- Auth: `login_screen.dart`
- Player: HUD overlays, progress colors, settings sheets
- Optional: `PROJECT_DESIGN.md` + update `design.md` after ship (Impeccable documenter)

## 13. Evaluation Plan

- `flutter analyze` on touched files
- Manual: login → home → movie/show → play → audio/subs/episodes → requests → studio
- Responsive: compact + wide
- Contrast on charcoal
- No feature regression
- Better-than-original: feels quieter and more intentional than Netflix-red Inter dark
