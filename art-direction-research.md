# Top-Down CTF Shooter Art Direction Research
## Deep Analysis for 8v8 Arena Shooter Broadcast Replay

**Context:** Torch-lit dungeon arena with illustrated flagstone floor, crates/barrels/machinery cover, glowing pedestals. Currently using reused pixel-astronaut sprites, no visible flags, territory gradient washes. Target: art that genre fans CRAVE, not AI-default recolor.

---

## 1. CHARACTER DESIGN — Player Sprites

### What Fans Love (Reference Analysis)

**Teeworlds/DDNet "Tees"** — The gold standard for beloved top-down multiplayer characters:
- **Extreme simplicity wins**: Round blob body + two round eyes + NO limbs = instantly readable at 16px
- **Team color = BODY fill**: The entire character mass is team-colored (not just trim)
- **Facing via eye position**: Both eyes shift left/right/up/down to show aim direction
- **Personality through accessories**: Hats, ninja suit, flag carried overhead add identity without breaking silhouette
- **Why fans love it**: Zero visual ambiguity even in 64-player chaos; cute without being "cartoony" in a way that undermines competitive stakes

**Nuclear Throne / Enter the Gungeon** — Character readability at small pixel scale:
- **Distinctive top-down silhouette**: Fish (Nuclear Throne) reads as oval + tail fin; Gungeoneers read as cape + gun
- **High contrast outline**: 1px black stroke separates character from any background
- **Facing via asymmetric sprite**: Characters have clear "front" — gun pointing direction is the primary read
- **Animation is minimal but punchy**: Walk cycle = 2-3 frames; dodge/roll = single stretched frame with motion blur pixel-streak
- **Why fans love it**: Each character has personality even at 24px; you know who you're playing

**Hotline Miami** — Top-down violence clarity:
- **Human figures = simple geometric shapes**: Circle head + rectangle torso + thin limbs
- **HIGH saturation team colors**: The player's jacket is VIBRANT pink/orange/green, not muted
- **Facing via head orientation**: Head sprite rotates 360° smoothly, body is secondary
- **Blood contrast**: Bright red blood pools on muted floor tiles = instant death-state read
- **Why fans love it**: Brutal clarity — no question who's alive, who's dead, who's facing where

**Realm of the Mad God** — Pixel sprite clarity in bullet-hell:
- **8-directional sprites**: Character has 8 distinct facing angles (not smooth rotation)
- **Class silhouette > team color**: Wizard robe shape ≠ knight armor shape; you identify role before color
- **White outline on dark ground**: 1px white stroke around ALL sprites = survives any background
- **Status effects = aura/glow**: Invulnerability = white glow border; poisoned = green tint
- **Why fans love it**: You can track 50 players + 200 bullets on screen and never lose your character

### CONCRETE CHARACTER SPEC for Your CTF Arena

**Base Design:**
- **Form**: Top-down human soldier, 24×24px base canvas (exports clean at 32px, readable at 16px)
- **Silhouette**: Clear head (6×6px circle) + shoulders/torso (12×16px rounded rectangle) + NO legs (boots visible as 2px footer only)
- **Team color application**: Jersey/armor chest plate is FULL team color (red or blue, saturated), not a trim accent
  - Red team: `#E63946` (warm crimson)
  - Blue team: `#457B9D` (steel blue)
- **Facing indicator**: Head sprite rotates in 8 directions (45° increments); gun sprite extends from hand in aim direction
- **Outline**: 1px black stroke (`#1A1A1A`) around entire silhouette for floor separation
- **Personality layer**: Optional helmet/hat/visor detail in neutral gray (`#6C6C6C`) on head — keeps soldier/tactical feel vs. blob

**Palette Integration (Warm Torch-Lit Dungeon):**
- Skin tone: `#D4A574` (warm tan, reads against stone)
- Accent metal (belt/boots): `#4A4A4A` (dark gray, not pure black)
- Highlight/rim light: `#FFA94D` (warm orange from torchlight, 1px on shoulders/head top)

**Animation States:**
- Idle: Static, gentle 2-frame head-bob (0.5s loop)
- Moving: 3-frame run cycle, legs implied by motion blur trail (2px fade)
- Carrying flag: Flag sprite rides 4px above head, slight side-to-side sway (2-frame, 0.3s)
- Dead: Sprite falls flat, desaturated 50%, red blood pool expands underneath (3-frame growth, max 16px radius)

**Image Generation Prompt:**
```
Top-down pixel art soldier sprite, 24x24 pixels, head-on bird's eye view. Round head with helmet, broad shoulders, compact torso in [RED/BLUE] jersey, no visible legs. Clean 1-pixel black outline, warm torch-lit shading with orange rim light on shoulders. Character facing DOWN (south), weapon held in right hand extending downward. Simple, readable, competitive game aesthetic — NOT cute, NOT sci-fi. Inspired by Hotline Miami clarity + Nuclear Throne silhouette strength. 8-bit pixel art, limited palette, high contrast.
```

---

## 2. WEAPONS / GUNS

### What Fans Love

**Nuclear Throne / Enter the Gungeon** — Weapon rendering gold standard:
- **Gun is LARGER than you expect**: 12–16px long on a 24px character = 50–66% of body size
- **Gun points in aim direction**: Separate sprite layer, rotates independently of body
- **Muzzle position matters**: Flash/projectile spawns from gun TIP, not character center
- **Weapon silhouette = identity**: Shotgun = wide barrel, rifle = long thin, pistol = compact L-shape
- **Why fans love it**: You see what gun someone has from across the screen; feels tactile

**Teeworlds** — Cartoony weapon clarity:
- **Held weapon floats BESIDE the Tee**: Gun sprite is external to body, positioned at "hand" location
- **Large, simplified shapes**: Hammer = literal hammerhead, shotgun = boxy rectangle
- **Color-coded by type**: Laser = green glow, shotgun = brown/gray, hammer = brown handle + metal head
- **Why fans love it**: Zero ambiguity; weapon type identified in 0.1 seconds

**Realm of the Mad God** — Held weapon subtlety:
- **Weapon = small detail**: Staff/sword/bow is 4–6px, held in hand position
- **Projectile matters more than gun**: You identify weapon by WHAT IT SHOOTS (spiral vs. straight line)
- **Why fans love it**: Clean character silhouette isn't cluttered; the action is in the projectiles

### CONCRETE WEAPON SPEC

**Weapon Rendering:**
- **Gun sprite**: 10–14px long, 3–4px wide, separate layer from character
- **Attachment**: Rotates around character center, offset 6px from center toward aim direction
- **Gun barrel**: Always points toward cursor/aim point (smooth rotation, not 8-directional)
- **Weapon types** (if multiple):
  - Rifle: 14px long, thin (2px wide), gray metal `#6C6C6C` + brown stock `#8B4513`
  - Shotgun: 10px long, wide barrel (4px), dark gray `#4A4A4A`
  - Pistol: 8px L-shape, light gray `#A8A8A8`

**Visual Priority:**
- Gun should be CLEARLY visible (not hidden under character sprite)
- Render order: Floor → shadows → characters → guns → muzzle flashes → projectiles

**Image Generation Prompt:**
```
Top-down pixel art assault rifle weapon sprite, 14x4 pixels, bird's eye view. Held horizontally, barrel pointing right. Gray metal body with brown grip, simple military rifle silhouette. Clean 1-pixel black outline, designed to rotate around a character's center point. 8-bit pixel art, tactical aesthetic, readable at small scale. Separate sprite layer, transparent background.
```

---

## 3. TRACERS / BULLET TRAILS

### What Fans Love

**Nuclear Throne** — Punchy projectile design:
- **Thick, bright projectiles**: 3×3px to 5×5px, solid fill, HIGH saturation
- **Color = weapon type**: Yellow bullets (pistol), red lasers, green plasma
- **No trail initially**: Projectile itself is visible; trail only added for FAST weapons (laser)
- **Fade is FAST**: If a trail exists, it fades in 0.1–0.15 seconds (3–5 frames at 30fps)
- **Why fans love it**: Screen doesn't clutter; you track active threats, not history

**Enter the Gungeon** — Bullet-hell clarity:
- **Outlined projectiles**: 2px core + 1px outline = 4×4px total, reads against ANY background
- **Varied shapes**: Circles, diamonds, skulls, cards — shape = danger type
- **Minimal trail**: Small fast bullets have NO trail; slow projectiles have 2-frame fade (0.06s)
- **Why fans love it**: You dodge current threats, not visual noise

**Hotline Miami** — Instant-hit gunfire:
- **Tracers = instant line**: Bullet appears as a 1px line from gun to impact point
- **Flash duration**: Line visible for exactly 2 frames (0.06s at 30fps), then GONE
- **Impact spark**: 3×3px yellow/white burst at hit location, fades over 3 frames
- **Why fans love it**: Feedback is immediate and clear, then vanishes before cluttering

**Realm of the Mad God** — Bullet hell that works:
- **Small projectiles**: 2×2px to 4×4px, no trail
- **High contrast**: White/yellow/cyan bullets on dark ground; black bullets on light ground
- **Survival = reading patterns**: No visual effects that obscure incoming fire
- **Why fans love it**: 50+ bullets on screen remain readable

### CONCRETE TRACER SPEC

**For Your CTF Arena (Tactical Shooter Feel):**

**Bullet projectile (visible during flight):**
- **Size**: 3×3px or 4×4px depending on weapon
- **Color by team**:
  - Red team: `#FF6B6B` (bright red-orange, reads as "danger")
  - Blue team: `#4ECDC4` (bright cyan, reads as "cold")
- **Core + outline**: 2×2px color core + 1px darker outline (50% darker)
- **Speed**: 800–1200 px/second (visible travel time, not instant-hit)

**Fading trail (OPTIONAL, only for tracer weapons):**
- **Structure**: 4–6 copies of bullet sprite, each progressively transparent
- **Spacing**: 8px between trail segments
- **Fade timing**: Each segment fades from 80% opacity to 0% over 0.12 seconds (4 frames at 30fps)
- **Length**: Trail max length = 32px (4 segments × 8px spacing)
- **When to use**: Only for "tracer round" weapons or lasers; standard rifle = NO trail (projectile only)

**Muzzle flash:**
- **Shape**: 6×6px star burst at gun barrel tip
- **Color**: `#FFE66D` (warm yellow-white)
- **Duration**: Visible for EXACTLY 1 frame (0.033s at 30fps), then gone
- **Additive blend**: Flash should lighten whatever it overlaps (not block visibility)

**Impact effect:**
- **Spark**: 5×5px cross-shaped burst at impact point
- **Color**: `#FFA94D` (warm orange, matches torch lighting)
- **Duration**: 3-frame fade (0.1s)
- **If hit character**: Small red blood splatter (4×4px) appears, persists 1 second then fades

**Image Generation Prompt (Projectile):**
```
Pixel art bullet sprite, 4x4 pixels, top-down view. Bright cyan glowing projectile with darker outline. Small, punchy, high contrast. Designed for tactical team shooter, must read clearly against stone dungeon floor. 8-bit style, simple geometric shape (circle or diamond).
```

**Image Generation Prompt (Muzzle Flash):**
```
Pixel art muzzle flash, 6x6 pixels, top-down view. Bright yellow-white star burst, 4-point cross shape. High intensity, warm color matching torchlight. Designed to appear for 1 frame at gun barrel tip. Additive glow effect, transparent background.
```

---

## 4. FLAGS — CTF Visual Conventions

### What Fans Love

**TagPro** — The CTF visual language:
- **Flag at base = LARGE icon**: Flag is 32×32px on 64×64px tile = 50% of base size
- **Flag sprite = literal flag**: Rectangle fabric on pole, team color fill, gentle wave animation
- **Carrier indicator = OUTLINE**: Player carrying flag gets thick (3px) glowing outline in flag color
- **+ Flag icon rides above**: 16×16px flag sprite hovers 8px above carrier's head
- **Status visibility**: Flag state shown in HUD (at base / taken / dropped), but ALSO visible in-world
- **Why fans love it**: Zero ambiguity; flag status = instant read from anywhere on screen

**Team Fortress 2 / Halo CTF (Broadcast View):**
- **Flag at base = vertical banner**: Tall fabric flag on pole, waves in wind
- **Carrier = glowing aura**: Player carrying flag has team-color glow particle effect
- **+ Flag on back**: 3D flag model attached to player spine (TF2) or held in hand (Halo)
- **Broadcast overlay**: Commentator view adds flag icons to player nameplates
- **Why fans love it**: Carrier is THE most visible player on the field; can't hide

**Soldat CTF** (from Wikipedia research):
- **Flag = physics object**: Flag waves dynamically as player moves (ragdoll/cloth sim)
- **Visible flag pole**: Long pole held by carrier, extends above character
- **Why fans love it**: Tactile, physics-driven = feels real, not UI

**Teeworlds CTF:**
- **Flag at base = upright banner**: Tall (24px height) flag sprite on pole at spawn
- **Carrier = flag above head**: Flag sprite moves WITH player, positioned directly above Tee's head
- **Team-color flag fill**: Red flag = solid red rectangle, blue flag = solid blue
- **Why fans love it**: Simple, unambiguous, never blocks gameplay

### CONCRETE FLAG SPEC

**Flag at Base (Planted):**
- **Design**: Vertical banner on stone pedestal (your existing glowing pedestals)
- **Flag fabric**: 16×24px rectangular banner, team color (`#E63946` red or `#457B9D` blue)
- **Pole**: 2px wide, 32px tall, dark wood `#4A3728`
- **Animation**: Gentle wave (3-frame loop, 0.4s), fabric ripples right-to-left
- **Base glow**: Pedestal emits soft team-color glow (12px radius, 40% opacity) to match your existing pedestals
- **Symbol**: Simple emblem in center of flag (crown for red, shield for blue) in lighter tint (`#FFFFFF` at 30% opacity)

**Flag Carried (on Player):**
- **Position**: Flag sprite hovers 10px directly above carrier's head (follows character movement)
- **Size**: Scaled to 12×16px (smaller than planted version, doesn't block view)
- **Animation**: Faster wave (2-frame loop, 0.2s) to show motion
- **Carrier outline**: Character sprite gains 2px glowing outline in ENEMY flag color
  - Carrying red flag (as blue player): `#E63946` outline with 60% opacity outer glow (4px)
  - Carrying blue flag (as red player): `#457B9D` outline with 60% opacity outer glow
- **Visual priority**: Carrier should be THE most visible element on screen (brighter than non-carriers)

**Flag Dropped (on Ground):**
- **Position**: Flag lies flat on ground, tilted 45° as if fallen
- **Pulsing glow**: Flag pulses brightness (0.6s cycle, 80%–100% opacity) to attract attention
- **Return timer**: If your game has auto-return, a circular progress ring appears around flag (team color, decrements)

**Image Generation Prompt (Flag at Base):**
```
Pixel art CTF flag sprite, 16x24 pixel banner on 32-pixel wooden pole, top-down perspective. Vibrant red/blue fabric with simple emblem (crown/shield), gentle wave animation. Medieval banner style, warm torch-lit shading. Flag mounted on glowing stone pedestal. 8-bit pixel art, clean readable design for team capture-the-flag game.
```

**Image Generation Prompt (Carried Flag):**
```
Pixel art CTF flag sprite, 12x16 pixels, top-down view. Small red/blue banner waving, designed to float above player character's head. Simple readable flag shape, high contrast. 8-bit pixel art, transparent background, game token sprite.
```

---

## 5. FLOOR / TERRITORY — Showing Team Zones WITHOUT Gradient Wash

### What Fans Love (What DOESN'T Work)

**Anti-pattern: Gradient washes** (your current approach):
- **Why fans hate it**: Looks like a Photoshop layer effect, not designed art
- **Problem**: Covers your hand-illustrated flagstone floor, makes it look "recolored"
- **Breaks immersion**: Gradients feel like UI overlaid on world, not part of world

### What Works: Territory as DESIGNED WORLD ELEMENTS

**Team Fortress 2 CTF Maps:**
- **Distinct floor materials per base**: Red base = warm wood planks + red brick; blue base = cold concrete + blue metal panels
- **Base boundary = architectural**: Doorways, stairs, material changes mark territory transition
- **NO solid color zones**: Neutral area uses distinct third material (gray stone, dirt)
- **Why fans love it**: Territory feels like physical space, not a colored overlay

**Teeworlds / DDNet:**
- **Base floor = team-color tile**: Red base has RED floor tiles (solid fill), blue base has BLUE tiles
- **Hard boundary**: Sharp edge where red tiles end and gray neutral tiles begin (no gradient)
- **Neutral middle = different material**: Gray or brown tiles in center
- **Why fans love it**: Clarity without artificiality; it's the ground ITSELF, not a filter

**Realm of the Mad God:**
- **No territory marking**: Game doesn't show territory at all
- **Base = distinctive structure**: Spawn point has unique buildings/walls
- **Why fans love it**: Clean; you navigate by landmarks, not color zones

**Hotline Miami:**
- **Floor pattern = room identity**: Kitchen = checkered tile, hallway = carpet, bathroom = small tile
- **Color used sparingly**: Wall paint color varies by room, but floor is realistic material
- **Why fans love it**: Believable space; color is diegetic (in-world), not painted on

### CONCRETE TERRITORY SPEC for Your Dungeon Arena

**Approach: Floor Material Transition (NOT gradient wash)**

**Red Base (Left Side):**
- **Floor material**: Your existing flagstone, but WARMER tint
  - Base flagstone: `#8B7355` (warm brown-gray stone)
  - Grout lines: `#6B5345` (darker warm brown)
- **Accent elements**:
  - Red banner tapestries on walls (vertical 8×32px banners, `#E63946`)
  - Red glowing braziers (your existing torch aesthetic) at base corners
  - Small red pennant flags on crates in red territory (4×6px)
- **Boundary**: Hard edge where warm stone meets neutral stone (NO blend/gradient)

**Blue Base (Right Side):**
- **Floor material**: Your existing flagstone, but COOLER tint
  - Base flagstone: `#6B7B8C` (cool blue-gray stone)
  - Grout lines: `#4A5A6B` (darker cool blue)
- **Accent elements**:
  - Blue banner tapestries on walls (vertical 8×32px banners, `#457B9D`)
  - Blue glowing braziers at base corners (cool blue flame)
  - Small blue pennant flags on crates in blue territory (4×6px)
- **Boundary**: Hard edge where cool stone meets neutral stone

**Neutral Middle (Center Arena):**
- **Floor material**: Your existing flagstone, NEUTRAL tint
  - Base flagstone: `#7A7A7A` (true gray stone, no warm/cool bias)
  - Grout lines: `#5A5A5A` (darker neutral gray)
- **Accent elements**:
  - No team colors; torches are warm orange (neutral)
  - Cover objects (crates/barrels) are natural wood/metal colors

**Key Principle:**
- **Territory = FLOOR ITSELF changes color/material**, not a wash laid on top
- **Sharp boundaries**, no gradients (pixel art grid-aligned edge)
- **Diegetic team markers**: Banners, pennants, brazier glow are IN-WORLD objects, not UI
- **Your illustrated art style PRESERVED**: The flagstone illustration quality remains; only the tint/hue shifts

**Alternative (If Floor Recoloring Feels Wrong):**
- **Keep floor 100% neutral**, remove territory color entirely
- **Mark bases with ARCHITECTURE**: Red base has red stone walls (partial enclosure), blue base has blue stone walls
- **Flags + base structures = territory read**: Players learn "left = red, right = blue" from landmarks, not floor color

**Image Generation Prompt:**
```
Top-down pixel art dungeon flagstone floor tile, 32x32 pixels. Illustrated hand-painted style with visible grout lines between stones. Warm brown-gray tint for red team base area. Torch-lit shading with subtle warm highlights. Medieval dungeon aesthetic, tactical game environment. NOT a gradient overlay — the stone itself is tinted warm. 8-bit pixel art, tileable texture.
```

---

## 6. OVERALL ART DIRECTION — "Art Fans Love" vs. "AI-Default Recolor"

### The 5 Things That Separate Beloved from Generic

#### 1. **TEAM COLOR = PHYSICAL, NOT OVERLAY** ⭐ (Highest Impact)
- **Generic AI**: Gradient wash filter laid over existing art
- **What fans love**: Team color is IN the object (jerseys, floor tiles, banners) — not on top of it
- **Why it matters**: Reads as intentional design, not a lazy recolor
- **Your fix**: Character jerseys, floor material tint, base banners = team color baked into the asset

#### 2. **STRONG SILHOUETTES > DETAIL**
- **Generic AI**: Characters have lots of detail (belts, pockets, straps) but unclear shape
- **What fans love**: You can identify character, weapon, flag from silhouette ALONE (black outline test)
- **Why it matters**: Competitive games demand instant recognition at speed
- **Your fix**: Simplified character shape (round head, broad shoulders, NO fiddly limbs), large gun sprite, flag above head

#### 3. **HIGH CONTRAST + SATURATION** (Not Muted/Tasteful)
- **Generic AI**: Desaturated "realistic" colors, low contrast for "polish"
- **What fans love**: PUNCHY team colors (vibrant red, vibrant blue), high-contrast outlines, bright projectiles
- **Why it matters**: Readability in motion > photorealism
- **Your fix**: Use `#E63946` (hot red) and `#457B9D` (bold blue), not muted tints; 1px black outlines on EVERYTHING

#### 4. **VISUAL EFFECTS FADE FAST** (Not Persistent)
- **Generic AI**: Trails/glows/effects linger 0.5–1.0 seconds, creating clutter
- **What fans love**: Muzzle flash = 1 frame; tracer fade = 3–5 frames; blood appears then fades in 1 second
- **Why it matters**: Screen stays clean; you track current state, not history
- **Your fix**: All temporary effects (flashes, impacts, trails) fade in under 0.15 seconds

#### 5. **DIEGETIC DESIGN** (In-World, Not UI-on-World)
- **Generic AI**: Territory = colored circle under player; flag = HUD icon; status = floating text
- **What fans love**: Territory = actual floor tiles; flag = physical object on pole; carrier = glowing outline (still in-world, not UI chrome)
- **Why it matters**: Immersion; game feels like a PLACE, not a spreadsheet with avatars
- **Your fix**: No gradient washes; floor MATERIAL changes color; banners and braziers mark territory; flag is a sprite object, not an icon

---

## RANKED: Highest-Impact Art Changes for Your CTF Replay

### 🥇 #1: REPLACE TERRITORY GRADIENT → FLOOR MATERIAL TINT
**Impact: Massive.** This is the "recolor" everyone sees. Shifting to floor tiles that are INHERENTLY team-colored (warm red-brown vs. cool blue-gray stone) + team banners/pennants on walls makes the arena feel designed, not filtered.

**Effort:** Medium (requires tinting your existing flagstone illustration in 3 variants: red-warm, blue-cool, neutral-gray).

---

### 🥈 #2: REPLACE ASTRONAUT SPRITES → TACTICAL SOLDIER CHARACTERS
**Impact: Massive.** Generic reused sprites scream "placeholder." A purpose-built top-down soldier (clear head, team jersey, gun visible, 1px black outline, warm torch-lit shading) looks like ART, not asset-flip.

**Effort:** High (new character sprite + 8 facing angles + gun sprite + animation frames).

---

### 🥉 #3: ADD VISIBLE FLAGS (Planted + Carried + Dropped)
**Impact: Large.** "No visible flag objects" = broken CTF visual language. Fans EXPECT to see flags. A waving banner at base + small flag riding above carrier's head + glowing dropped flag = instant legitimacy.

**Effort:** Medium (3 flag sprite states + glow effects + carrier outline shader).

---

### 4: GUNS VISIBLE + MUZZLE FLASHES
**Impact: Medium-Large.** Seeing WHO is shooting and FROM WHERE is core to shooter feel. Current "no gun visible" reads as incomplete. A clear gun sprite (rotates with aim) + 1-frame yellow muzzle flash = punchy feedback.

**Effort:** Medium (gun sprite per weapon type + muzzle flash particle effect).

---

### 5: BRIGHT, FADING PROJECTILE TRACERS
**Impact: Medium.** If bullets are currently instant-hit or invisible, adding a 4×4px team-color projectile (red-orange vs. cyan) with optional short trail makes combat visceral. MUST fade fast (0.1s) or it clutters.

**Effort:** Low (projectile sprite + fade shader).

---

## SUMMARY: THE SINGLE BIGGEST LEVER

**Kill the gradient washes. Make team color PART of the floor/world, not laid on top.**

This one change transforms "AI recolor" into "designed arena." Everything else (characters, flags, guns) can improve incrementally, but the gradient wash is the visual smell that screams "this isn't real art." Replace it with floor material tinting + diegetic team markers (banners, braziers, pennants), and the viewer immediately sees intention and craft.

Second-biggest: **Replace the astronaut sprites with purpose-built soldiers.** Reused assets from another game break immersion instantly; custom art (even simple pixel art) signals "this is a real game."

---

## REFERENCE GAME TAKEAWAYS (Quick Hits)

| Game | Key Visual Lesson |
|------|-------------------|
| **Teeworlds** | Team color = body fill; facing = eye position; simplicity wins |
| **TagPro** | Carrier gets thick glowing outline + flag above head; zero ambiguity |
| **Nuclear Throne** | Big gun (50% of character size); thick projectiles; fast fade (0.1s) |
| **Hotline Miami** | High-contrast outlines; 1-frame muzzle flash; bright blood on muted floor |
| **Realm of the Mad God** | White outline on ALL sprites; no trails (clutter = death in bullet hell) |
| **Soldat** | Physics-driven flags (wave realistically); ragdoll bodies; gory = readable |
| **Team Fortress 2** | Territory = architecture (walls, floor material), not color zones |
| **Enter the Gungeon** | Distinct character silhouettes; 1px black stroke on everything; personality through accessories |

---

**End of Report** — All specs above are ready to paste into image generation prompts or hand to a pixel artist. Grounded in what fans of Teeworlds, TagPro, Nuclear Throne, Hotline Miami, and Soldat actually love, NOT generic "make it look good" advice.
