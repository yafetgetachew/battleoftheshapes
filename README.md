# 🔺🟦🔴🟨 B.O.T.S — BATTLE OF THE SHAPES 🟨🔴🟦🔺

> *"In a world where geometry has gone ABSOLUTELY FERAL, only the bravest polygons survive."*

Welcome to **B.O.T.S** (Battle Of The Shapes), the LAN multiplayer arena brawler where you and two of your soon-to-be-former friends duke it out as sentient geometric shapes. Yes, you read that right. A **square**, a **triangle**, a **circle**, and a **rectangle** walk into a bar, and only ONE walks out. The others got fireballed.

## 🎮 What Is This Glorious Masterpiece?

B.O.T.S is a **3-player local area network (LAN) battle royale** built with [LÖVE2D](https://love2d.org/). Pick your favorite shape (we don't judge), connect over the network, and then OBLITERATE your friends with horizontal fireballs, tactical jumping, and the sheer psychological warfare of being a triangle.

Oh, and **lightning strikes randomly from the sky**. Because of COURSE it does.

## 📦 Installation (a.k.a. "How Do I Make Shapes Fight?")

### Prerequisites

1. **LÖVE2D** (version 11.4+) — [Download here](https://love2d.org/)
2. **lua-enet** — The networking library that makes the magic happen
   - On macOS: `luarocks install enet`
   - On Linux: `sudo luarocks install enet`
   - On Windows: included with some LÖVE builds, or grab from [lua-enet](http://leafo.net/lua-enet/)

### Running the Game

```bash
cd /path/to/BOTS
love .
```

That's it. That's the whole thing. You're welcome.

## 🕹️ Controls

**NEW!** You can now choose your preferred control scheme from the **Settings** menu!

### Control Scheme Options

**WASD + Space** (Default)
| Action | Key |
|--------|-----|
| Move Left | `A` |
| Move Right | `D` |
| Jump | `Space` |
| Cast Fireball | `W` |

**Arrows + Enter**
| Action | Key |
|--------|-----|
| Move Left | `←` |
| Move Right | `→` |
| Jump | `Enter` |
| Cast Fireball | `↑` |

**Universal Controls**
| Action | Key |
|--------|-----|
| Quit | `Escape` |
| Restart (Game Over) | `R` |

> 💡 **Tip**: Access the Settings menu from the main menu to switch between control schemes. Your preference is saved automatically!

## 🌐 LAN Multiplayer (Shapes Across the Network)

### Hosting a Game (Player 1)

1. Launch the game
2. Marvel at the **BATTLE OF THE SHAPES** splash screen (it pulses, you're welcome)
3. Select **"Host Game"**
4. You're now hosting on your local IP address, port `27015`
5. Tell your friends your IP address (try `ifconfig` or `ipconfig` if you forgot it)
6. Wait for Players 2 and 3 to connect
7. Pick your shape. The fate of geometry depends on you

### Joining a Game (Players 2 & 3)

1. Launch the game on another computer on the same LAN
2. Admire the splash screen (we worked hard on it)
3. Select **"Join by IP"** and enter the host's IP address
4. Press `Enter` to connect
5. Pick your shape and prepare for TOTAL SHAPE WARFARE

## ⚔️ Gameplay Mechanics (The Science of Shape Violence)

### Shapes
Each shape has unique stats because balance is an illusion:

| Shape | Life | Will | Speed | Jump | Vibe |
|-------|------|------|-------|------|------|
| 🟦 Square | 120 | 100 | 250 | 500 | Reliable, boring, deadly |
| 🔺 Triangle | 90 | 130 | 300 | 550 | Fast, pointy, menacing |
| 🔴 Circle | 110 | 110 | 270 | 480 | Smooth, round, diplomatic (lies) |
| 🟨 Rectangle | 140 | 80 | 220 | 460 | THICC, tanky, unstoppable |

### 🔥 Fireballs
- Cost: **10 Will** per shot
- Damage: **30** on hit
- Direction: Always horizontal, aimed at the nearest enemy
- Pro tip: Will regenerates over time, so SPAM AWAY

### 💥 Collision Damage
When two shapes collide, the **lower player** (the one closer to the ground, a.k.a. higher Y coordinate) takes **2 damage per second**. In other words: GET ON TOP. Literally. The high ground wins. Obi-Wan was right.

### ⚡ Lightning Strikes
Because no battle arena is complete without ACTS OF GOD:
- Lightning strikes at **random positions** every **4–10 seconds**
- A **warning indicator** appears for 1 second before the strike (you've been warned, shape)
- Deals **20 damage** to any shape within a **50-pixel radius**
- The host controls lightning. The host IS the weather

### 💀 Victory Condition
Last shape standing wins. That's it. No mercy. No second chances. Just sweet, geometric victory.

## 🏗️ Technical Architecture (For the Nerds)

```
Player 1 (Host/Server)  ←──ENet UDP──→  Player 2 (Client)
         ↑                                          
         └──────────ENet UDP──────────→  Player 3 (Client)
```

- **Protocol**: ENet over UDP (port 27015)
- **Architecture**: Host-authoritative with client-side prediction
- **Tick Rate**: ~20 Hz state sync
- **Serialization**: Custom pipe-delimited format (because JSON is for cowards)

## 🔧 Recent Updates

### Version 1.2 - Networking & Display Fixes
- ✅ **Fixed network synchronization**: Remote players no longer run conflicting local physics
- ✅ **Simplified connection flow**: Removed Browse Games; use "Join by IP" to connect directly
- ✅ **Consolidated lightning sync**: Single network message instead of multiple per tick
- ✅ **Fixed fullscreen scaling**: UI elements now use virtual game coordinates inside scaled transform

### Version 1.1 - Quality of Life Improvements
- ✅ **Fixed lightning synchronization**: Clients now see lightning strikes and warnings in real-time
- ✅ **Fixed fullscreen scaling**: Game now properly scales to native resolution with correct aspect ratio
- ✅ **Added control scheme configuration**: Choose between WASD+Space or Arrows+Enter from the Settings menu

## 🙏 Credits

- **Game Engine**: [LÖVE2D](https://love2d.org/) — the engine that proves Lua can do anything
- **Networking**: [lua-enet](http://leafo.net/lua-enet/) — reliable UDP for unreliable friends
- **Design Philosophy**: "What if shapes could commit violence?"
- **Lightning System**: Inspired by the realization that every game needs random chaos
- **Testing**: Three friends who no longer speak to each other

---

*No shapes were permanently harmed in the making of this game. They respawn. Probably.*

**B.O.T.S** — *May the best polygon win.* 🏆

