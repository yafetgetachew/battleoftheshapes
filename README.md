# 🔺🟦🔴🟨 B.O.T.S — BATTLE OF THE SHAPES 🟨🔴🟦🔺

> *"In a world where geometry has gone ABSOLUTELY FERAL, only the bravest polygons survive."*

A **LAN multiplayer arena brawler** where you and your soon-to-be-former friends duke it out as sentient geometric shapes. Pick a shape, throw fireballs, dodge lightning, and watch friendships crumble.

## 🎮 Quick Start

```bash
love .
```

That's it. You're welcome.

## 🕹️ Controls

Choose your scheme in **Settings**:

| Action | WASD (Default) | Arrows |
|--------|----------------|--------|
| Move | `A` / `D` | `←` / `→` |
| Jump | `Space` | `Enter` |
| Cast Fireball | `W` | `↑` |
| Special Ability | `E` | `↓` |
| Dash | Double-tap `A`/`D` | Double-tap `←`/`→` |

`Escape` to quit • `R` to restart after game over

## 🌐 Multiplayer

**Host**: Select "Host Game" → share your IP with friends

**Join**: Select "Join by IP" → enter host's IP → press Enter

**Dedicated Server** (headless, **source-only**):

The shipped builds are for the *video game* part.
The dedicated server lives in `server/` and is intentionally **not included** in the packaged zips.

Run it from this repo:
```bash
love server/
love server/ --players 2 --port 27020
```

It’ll sit there quietly, waiting for connections… like a very patient polygon bouncer.

## ⚔️ The Shapes

| Shape | Life | Will | Speed | Special Ability |
|-------|------|------|-------|-----------------|
| 🟦 Square | 120 | 80 | 325 | **Laser Beam** — Sustained damage ray |
| 🔺 Triangle | 90 | 110 | 390 | **Triple Spikes** — Three fast projectiles |
| 🔴 Circle | 100 | 100 | 350 | **Rolling Boulder** — Ground-rolling rock |
| 🟨 Rectangle | 140 | 60 | 275 | **Falling Block** — Tipping pillar attack |

## 💥 Combat

- **Fireballs** (`W`/`↑`): Cost 10 Will, deal 15 damage, auto-aim at nearest enemy
- **Special Abilities** (`E`/`↓`): Unique per shape, costs 30-50 Will
- **Dash** (double-tap): Quick dodge, deals damage on collision
- **Collision**: Lower player takes damage. High ground wins. Obi-Wan was right.
- **Lightning**: Random strikes every 4-10 seconds. Watch for the warning!
- **Victory**: Last shape standing. No mercy.

## ⚙️ Settings

- Control scheme (WASD or Arrows)
- Player count (2 or 3)
- Server mode (dedicated relay)
- Aim assist (auto-target or manual)
- Demo invulnerability
- Background music toggle

## 🎨 Features

- **Parallax moonlit background** with drifting clouds and stars
- **Dynamic camera** with velocity lead and impact zoom
- **Screen shake & hit pause** for impactful combat
- **Damage numbers** floating up on hits
- **Death explosions** with particle effects
- **Low health heartbeat** warning
- **Landing dust** and idle breathing animations
- **Victory fanfare** with loser fade effects

## 📁 Project Structure

```
battleoftheshapes/
├── main.lua          # Game entry point & main loop
├── conf.lua          # LÖVE2D configuration
├── player.lua        # Player class & input handling
├── physics.lua       # Gravity, collision, ground resolution
├── projectiles.lua   # Fireballs & particle effects
├── abilities.lua     # Shape-specific special abilities
├── shapes.lua        # Shape definitions & stats
├── sounds.lua        # Procedural & file-based audio
├── background.lua    # Parallax background system
├── lightning.lua     # Lightning strike hazard
├── dropbox.lua       # Power-up drop system
├── hud.lua           # Health/will bars UI
├── selection.lua     # Character selection screen
├── network.lua       # LAN multiplayer networking
├── config.lua        # Settings & configuration
├── assets/
│   ├── fonts/        # Game fonts
│   └── sounds/       # Music & sound effects
├── server/           # Dedicated server (source-only)
│   ├── main.lua
│   └── conf.lua
└── builds/           # Build outputs (gitignored)
```

---

*No shapes were permanently harmed. They respawn. Probably.*

**B.O.T.S** — *May the best polygon win.* 🏆

