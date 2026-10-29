---
name: AirPlayr Design System
description: Swiss International Electric Blue aesthetic for AirPlayr web, macOS, and iOS
colors:
  primary: "#0066ff"
  primary-hover: "#2563eb"
  accent-cyan: "#00e5ff"
  bg-canvas: "#030712"
  surface-card: "#080d1a"
  text-primary: "#ffffff"
  text-secondary: "#94a3b8"
  text-muted: "#64748b"
  border-subtle: "rgba(255, 255, 255, 0.12)"
  border-strong: "#ffffff"
  glow-blue: "rgba(0, 102, 255, 0.4)"
  glow-cyan: "rgba(0, 229, 255, 0.3)"
typography:
  display:
    fontFamily: "'Plus Jakarta Sans', -apple-system, BlinkMacSystemFont, sans-serif"
    fontSize: "clamp(3.2rem, 7vw, 6.2rem)"
    fontWeight: 900
    lineHeight: 0.95
    letterSpacing: "-0.05em"
  headline:
    fontFamily: "'Plus Jakarta Sans', -apple-system, BlinkMacSystemFont, sans-serif"
    fontSize: "1.75rem"
    fontWeight: 800
    lineHeight: 1.1
    letterSpacing: "-0.04em"
  body:
    fontFamily: "'Plus Jakarta Sans', -apple-system, BlinkMacSystemFont, sans-serif"
    fontSize: "15px"
    fontWeight: 400
    lineHeight: 1.6
    letterSpacing: "-0.01em"
  brand:
    fontFamily: "'Plus Jakarta Sans', sans-serif"
    fontSize: "26px"
    fontWeight: 800
    textTransform: "uppercase"
    rWeight: 800
    rGradient: "linear-gradient(135deg, #00e0ff 0%, #0a2eff 100%)"
  code:
    fontFamily: "'JetBrains Mono', 'SF Mono', Menlo, Consolas, monospace"
    fontSize: "11px"
    fontWeight: 700
    letterSpacing: "0.08em"
rounded:
  none: "0px"
  subtle: "2px"
  card: "4px"
  native: "12px"
spacing:
  xs: "4px"
  sm: "8px"
  md: "16px"
  lg: "24px"
  xl: "48px"
  xxl: "80px"
components:
  button-monolith:
    backgroundColor: "{colors.text-primary}"
    textColor: "{colors.bg-canvas}"
    rounded: "{rounded.none}"
    padding: "14px 28px"
  button-monolith-hover:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.text-primary}"
  button-monolith-outline:
    backgroundColor: "transparent"
    textColor: "{colors.text-primary}"
    rounded: "{rounded.none}"
    padding: "14px 28px"
---

# AirPlayr Design System Specification

## Overview

AirPlayr embodies an **Electric Blue Swiss International System** rooted in structural honesty, mathematical grids, bold sans-serif typography, and zero-compromise precision.

The design language rejects decorative skeuomorphism, rounded bubble elements, and fuzzy low-contrast components in favor of high-legibility typographic hierarchies, asymmetric architectural column layouts, monolithic action buttons, and pure electric blue / cyan technical highlights.

Across web, macOS, and iOS companion surfaces, visual weight communicates system status: frame rate, container specifications, lossless audio passthrough, and local network topologies.

---

## Colors

The palette balances pitch-black canvas depth with solid architectural whites and saturated electric cyan/blue routing vectors:

- **Canvas Background (`#030712`)**: True deep night black canvas minimizing display power and maximizing dynamic contrast.
- **Surface Elevation (`#080d1a`)**: Subtle dark navy container surface for specification blocks, technical tables, and routing matrices.
- **Electric Blue (`#0066ff`, `#2563eb`)**: High-energy primary interaction color symbolizing digital transport streams.
- **Cyan Accent (`#00e5ff`)**: Pure technical beacon used for active states, square punctuation marks, and mono technical tags.
- **Architectural White (`#ffffff`)**: Primary structural borders (2px solid), main headlines, and monolithic primary CTA blocks.
- **Muted Slates (`#94a3b8`, `#64748b`)**: Secondary editorial text and specification annotations.

---

## Typography

Type hierarchy is anchored by **Plus Jakarta Sans** (SIL Open Font License — 100% free and open-source for commercial use), completely avoiding proprietary Apple San Francisco licensing restrictions on web surfaces. Paired with JetBrains Mono for telemetry:

1. **Brand Wordmark**:
   - `Plus Jakarta Sans`, 26px, 800 ExtraBold, uppercase `AIRPLAY` with `-0.03em` tracking.
   - Distinct 800 ExtraBold `R` with diagonal electric cyan-to-blue gradient (`#00e0ff` to `#0a2eff`).
2. **Display & Hero**:
   - `Plus Jakarta Sans`, 900 Black weight, `-0.05em` tracking, tight line height (0.95).
   - Uppercase structural manifestos (`FORM FOLLOWS FRAME RATE`).
3. **Technical Specifications & Headings**:
   - Monospace section tags (`01 // PROTOCOL ROUTING MATRIX`, `COMPATIBILITY // ISO/IEC STANDARDS`).
   - `JetBrains Mono` / `SF Mono`, 11px, 700 Bold, uppercase with `0.1em` letter spacing.
4. **Editorial Prose & Technical Logs**:
   - `Plus Jakarta Sans`, 14px–16px, 400 Regular, 1.6 line height for effortless long-form scanning.
   - Inline code elements wrapped in `rgba(0, 229, 255, 0.08)` tint with 1px cyan borders.
   - `Inter` / `SF Pro Text`, 14px–16px, 400 Regular, 1.6 line height for effortless long-form scanning.
   - Inline code elements wrapped in `rgba(0, 229, 255, 0.08)` tint with 1px cyan borders.

---

## Layout

The spatial framework is governed by a **12-Column Architectural Grid System**:

- **Grid Lines Overlay**: Subtle vertical 1px columns positioned across the viewport with `rgba(0, 229, 255, 0.03)` opacity.
- **2-Tier Navigation Header**:
  - **Tier 1 (Header Primary)**: 2-column split between Brand Mark / Title on the left and Action Monoliths (GitHub / Download DMG) on the right.
  - **Tier 2 (Header Secondary)**: Dedicated full-width horizontal navigation bar separated by a crisp 1px rule, giving all section routes ample breathing space.
- **Split Matrix Layouts**: 2fr/1fr asymmetric hero splits pairing typographic manifestos with modular numerical specification sidebars (`0.00s`, `100%`, `4K 60P`).

---

## Elevation & Depth

- **Zero Soft Drop Shadows**: Web components eliminate floating fuzzy drop shadows in favor of 1px and 2px architectural borders.
- **Luminous Radiance (Glows)**: Monolithic interaction targets project sharp chromatic glow on hover (`box-shadow: 0 0 24px var(--blue-glow)`).
- **Glass & Backdrop Blur**: Mobile and desktop navigation overlays apply 24px hardware-accelerated saturating blur with crisp border dividers.

---

## Shapes

- **Web Affordances**: Pure monolithic geometry (`border-radius: 0px` on buttons, cards, and specification tables; 2px on code pills).
- **Native macOS & iOS Surfaces**: Continuous squircles (`RoundedRectangle(cornerRadius: 8–16, style: .continuous)`) respecting platform conventions while maintaining dark cinema styling.

---

## Components

### Monolithic Button
- Solid white `#ffffff` rectangle with heavy uppercase black typography.
- Inverts on hover to electric blue `#0066ff` with white text and radiant blue bloom.

### Spec Block
- Left-bordered or boxed architectural block featuring oversized numerical metrics (2.8rem, 900 weight) anchored by monospace labels.

### Grid Item Matrix
- Modular 3-column container cards displaying protocol identifiers (`PROTO.01`, `PROTO.02`), bold headings, and architectural dividers.

---

## Do's and Don'ts

### Do
- Keep navigation organized into 2 distinct rows so brand and actions are never cramped by navigation links.
- Use uppercase typography for structural labels, section headers, and callouts.
- Rely on high-contrast rules (`1px` and `2px` solid lines) to partition interface sections.
- Pair high-resolution native brand icon assets with bold typography.

### Don't
- Never place navigation links directly between brand logos and action buttons in a crowded single row.
- Never introduce random colored shadows, glow artifacts, or badges without functional purpose.
- Never use generic rounded pill buttons on web surfaces.
- Never advertise hardware-specific marketing terms (e.g. "Fold Display", dual-screen badges) in standard UI copy.
