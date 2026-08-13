---
name: Quiet Premium
colors:
  surface: '#121414'
  surface-dim: '#121414'
  surface-bright: '#37393a'
  surface-container-lowest: '#0c0f0f'
  surface-container-low: '#1a1c1c'
  surface-container: '#1e2020'
  surface-container-high: '#282a2b'
  surface-container-highest: '#333535'
  on-surface: '#e2e2e2'
  on-surface-variant: '#c4c7c7'
  inverse-surface: '#e2e2e2'
  inverse-on-surface: '#2f3131'
  outline: '#8e9192'
  outline-variant: '#444748'
  surface-tint: '#c9c6c5'
  primary: '#c9c6c5'
  on-primary: '#313030'
  primary-container: '#0a0a0a'
  on-primary-container: '#7b7979'
  inverse-primary: '#5f5e5e'
  secondary: '#c8c6c5'
  on-secondary: '#313030'
  secondary-container: '#474746'
  on-secondary-container: '#b7b5b4'
  tertiary: '#adc6ff'
  on-tertiary: '#002e69'
  tertiary-container: '#00091f'
  on-tertiary-container: '#0A84FF'
  error: '#ffb4ab'
  on-error: '#690005'
  error-container: '#93000a'
  on-error-container: '#ffdad6'
  primary-fixed: '#e5e2e1'
  primary-fixed-dim: '#c9c6c5'
  on-primary-fixed: '#1c1b1b'
  on-primary-fixed-variant: '#474646'
  secondary-fixed: '#e5e2e1'
  secondary-fixed-dim: '#c8c6c5'
  on-secondary-fixed: '#1c1b1b'
  on-secondary-fixed-variant: '#474746'
  tertiary-fixed: '#d8e2ff'
  tertiary-fixed-dim: '#adc6ff'
  on-tertiary-fixed: '#001a41'
  on-tertiary-fixed-variant: '#004493'
  background: '#121414'
  on-background: '#e2e2e2'
  surface-variant: '#333535'
typography:
  display-lg:
    fontFamily: Manrope
    fontSize: 48px
    fontWeight: '700'
    lineHeight: 56px
    letterSpacing: -0.02em
  headline-lg:
    fontFamily: Manrope
    fontSize: 32px
    fontWeight: '600'
    lineHeight: 40px
    letterSpacing: -0.01em
  headline-lg-mobile:
    fontFamily: Manrope
    fontSize: 24px
    fontWeight: '600'
    lineHeight: 32px
  body-md:
    fontFamily: Manrope
    fontSize: 16px
    fontWeight: '400'
    lineHeight: 24px
  label-md:
    fontFamily: Geist
    fontSize: 14px
    fontWeight: '500'
    lineHeight: 20px
    letterSpacing: 0.05em
  caption-sm:
    fontFamily: Manrope
    fontSize: 12px
    fontWeight: '500'
    lineHeight: 16px
rounded:
  sm: 0.25rem
  DEFAULT: 0.5rem
  md: 0.75rem
  lg: 1rem
  xl: 1.5rem
  full: 9999px
spacing:
  container-max: 1440px
  gutter: 24px
  margin-desktop: 80px
  margin-tablet: 40px
  margin-mobile: 20px
  unit-xsmall: 4px
  unit-small: 8px
  unit-medium: 16px
  unit-large: 32px
  unit-xlarge: 64px
---

## Brand & Style

**Quiet Premium** — OLED charcoal stage, content-first posters, frosted chrome only where it earns its keep (nav, menus, player HUD). Calm restraint over theatrical concepts. No Netflix-red branding; the mark is a light play tile on dark.

## Colors

- **Background (#0A0A0A)** / **Surface (#141414)** / **Elevated (#1C1C1C)**
- **Accent / progress / focus (#0A84FF)** — sparingly
- **Text** primary `#F5F5F7`, secondary `#A1A1A6`, muted `#6E6E73`
- **Semantic** success `#30D158`, warning `#FF9F0A`, error `#FF453A`
- Glass hairlines ~8% white; no purple/neon washes

## Typography

**Manrope** for UI and display (tight tracking on titles). Labels use Manrope Medium with slight tracking rather than a second face until Geist is packaged.

- **Scale:** Use tight tracking on large display text to maintain a premium "editorial" look. 
- **Hierarchy:** Primary information (Movie Titles) uses Semi-Bold; secondary information (Metadata, Year, Rating) uses Medium weight with reduced opacity rather than a lighter color.
- **Rendering:** All text should utilize `antialiased` rendering to maintain sharpness against blurred backgrounds.

## Layout & Spacing

The layout follows a **Fluid Grid** model with significant "breathable" margins to evoke a high-end gallery feel. 

- **Safe Zones:** Content must maintain a minimum 80px margin on desktop/TV to prevent edge-crowding.
- **Rhythm:** An 8px linear scale governs all padding and margins. 
- **Grid:** Use a 12-column grid for browse screens and a centered, focused layout for the player interface.
- **Mobile Adaptivity:** On mobile, the grid collapses to 4 columns, and the wide margins are reduced to 20px, while maintaining the same 8px spacing logic.

## Elevation & Depth

Depth is conveyed through **Glassmorphism** and z-index stacking rather than traditional drop shadows.

- **Backdrop Blur:** Use a `20px` to `40px` Gaussian blur on all elevated containers.
- **Inner Borders:** Every glass element features a 1px solid top-border at 15% white opacity to simulate a "highlight" on a glass edge.
- **Surface Tiers:**
    - **Base:** Primary Deep Charcoal (#0A0A0A).
    - **Level 1 (Cards):** Secondary Slate at 40% opacity with backdrop blur.
    - **Level 2 (Modals/Overlays):** Secondary Slate at 60% opacity with heavy backdrop blur.
- **Shadows:** Use only one type of shadow: a very large, soft ambient occlusion shadow (0px 30px 60px rgba(0,0,0,0.5)) to lift modals off the glass surface.

## Shapes

The shape language is defined by large, generous radii that feel soft and organic.

- **Base Radius:** 16px (rounded-lg) for standard cards and buttons.
- **Container Radius:** 24px (rounded-xl) for main player controls and modals.
- **Icon Enclosures:** Always circular or use a 12px radius to maintain a "squircle" aesthetic.
- **Interactive States:** When focused, elements should subtly scale up (e.g., 1.05x) rather than just changing color.

## Components

### Buttons
- **Primary:** Glass background (white at 15% opacity), 1px border, Semi-bold text.
- **Focused:** Solid White background with Deep Charcoal text, scaled 1.1x.
- **Icon Buttons:** Circular, blurred glass background, minimal thin-stroke icons.

### Progress Bar (Video Scrubber)
- **Track:** 4px height, Secondary Slate at 30% opacity.
- **Progress:** Accent Blue (#0A84FF), no glow.
- **Handle:** White circle, visible only on hover/scrub.

### Cards (Media)
- **Standard:** 16:9 or 2:3 aspect ratios, 16px corner radius.
- **Hover/Focus:** 1px white stroke (20% opacity) and 1.05x scale increase. Metadata appears below the card in 70% opacity white.

### Lists
- Horizontal carousels with "peek" visibility for the next item.
- Vertical lists use 1px slate dividers with 50% transparency.

### Additional Components
- **Transport Controls:** Large, centered play/pause icon with a background blur ring.
- **Metadata Badges:** Small, "Geist" font labels (e.g., "4K", "HDR", "AD") enclosed in a pill-shaped stroke with 50% opacity.