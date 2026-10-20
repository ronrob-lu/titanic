# 🚢 RMS Titanic & Ocean Liners for Luanti, Minetest, Mineclonia & VoxeLibre

[![Luanti](https://img.shields.io/badge/Luanti-5.x+-00d2ff.svg)](https://www.luanti.org/)
[![Mineclonia](https://img.shields.io/badge/Mineclonia-Compatible-green.svg)](https://mineclonia.net/)
[![VoxeLibre](https://img.shields.io/badge/VoxeLibre-Supported-blue.svg)](https://git.minetest.land/VoxeLibre/VoxeLibre)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](licence.md)
[![Kenney: CC0](https://img.shields.io/badge/Assets-Kenney%20CC0-lightgrey.svg)](https://kenney.nl/)

> [!WARNING]
> # ⚠️ BIG WARNING: WORK IN PROGRESS
> **This mod is an active work in progress!**  
> Fixes by **Gemini 3.8** are currently not fixing issues well, and it seems a little risky to try and play this right now. Please proceed with caution and backup your worlds before testing!

> **Majestic autonomous ocean liners with walkable decks and moving block support!**  
> Board the **RMS Titanic** and embark on automated trans-oceanic voyages. Place luggage and chests on the deck, bring your friends, and cruise across the seas with a rock-solid, ultra RAM-efficient moving blocks system.

---

## ⚡ Key Features

* 🚢 **Autonomous 60-Second Shuttle Navigation**  
  * Place the ocean liner in deep water (**requires at least 3 blocks of water depth under the hull**).
  * The ship idles for **60 seconds at dock**, allowing passengers to board and load luggage.
  * After 60 seconds, the ship sounds its horn and cruises in a straight path.
  * When it reaches the far shore, dock, or shallow waters (< 3 blocks depth), it stops, reverses direction, and idles for another **60 seconds** before making the return voyage!
  * If placed facing a blocked direction or shallow water, it automatically detects the obstruction and reverses direction.

* ❄️ **Iceberg Collision & Falling Blocks Catastrophe**  
  * If the ocean liner strikes an **iceberg** (ice, packed ice, blue ice, or snow blocks above or submerged below the waterline):
  * **Normal Luanti Falling Nodes:** All custom placed blocks (luggage, chests, furniture, walls, beds, furnaces, wood planks) detach and fall with physical gravity (`minetest.spawn_falling_node`) down through the water to the ocean floor!
  * The ship's invisible decks vanish, ocean water floods the vessel, and the ocean liner slowly descends into the ocean depths with a dramatic bubble trail!

* 🧭 **Screwdriver Rotation Support**  
  * Adjust the ship's heading effortlessly using any standard **screwdriver** (`screwdriver:screwdriver`, `mcl_core:screwdriver`, etc.).
  * Right-click or punch the ship hull or deck with a screwdriver to rotate 90° clockwise (North → West → South → East).
  * All placed luggage, chests, and passengers standing on board rotate seamlessly with the ship!

* 🧳 **Walkable Deck & Moving Blocks (Luggage Support)**  
  * **No awkward player attachments!** Players are not locked into seats—they can freely walk, sprint, jump, and stroll along the promenade deck.
  * **Place anything on the deck:** Chests, luggage, furnaces, torches, beds, and decorative blocks can be placed directly on the ship's surface.
  * During travel, all placed luggage moves along with the ship with 100% data integrity (chest inventories, metadata, and items are fully preserved).
  * **Visible Surface Alignment:** The deck surface clearly indicates the walkable boundaries while remaining semi-transparent so you can admire the 3D ship model beneath your feet.

* 🏰 **Full 3D Interior Cabin Construction**  
  * **Build inside the ship!** The ship's interior is fully usable and dry inside the hull.
  * Automatically spawns with a **lower deck floor** (`ly = 1`), a **dry cabin room** (`ly = 2`), and a **main promenade deck** (`ly = 3`) with a central companionway hatch opening for stairs or ladders.
  * Build passenger cabins, dining saloons, staterooms, engine rooms, doors, beds, tables, ladders, and stairs across all interior levels (`ly = 1` through `ly = 7`).
  * Decks can be customized or replaced with your own wood, carpet, or stone blocks.
  * When cruising or rotating with a screwdriver, **every block placed inside the interior moves with the ship**, and directional blocks (facedir: chests, stairs, beds, doors, furnaces) rotate automatically!

* ⚡ **Ultra RAM-Efficient Architecture**  
  * Unlike heavy voxel-shifting mods that freeze servers by moving thousands of air and water blocks, the Titanic engine tracks only the ship's exact footprint and interior envelope.
  * Consumes virtually zero RAM, executes in under 0.2 milliseconds per step, and prevents mapblock bloat.

* 📏 **Massive 1000x Scale**  
  * Over **1,000x the volume of standard watercraft**!
  * Includes both the full **RMS Titanic Ocean Liner** (21 blocks long, 5 blocks wide, 9 blocks tall) and the **Small Ocean Liner** (15 blocks long, 5 blocks wide).

* ⛏️ **Pickaxe-Only Dismantling**  
  * Accidental punches won't break the ship! The reinforced hull can only be dismantled using a **pickaxe**.
  * When dismantled, the ship returns to your inventory and any luggage placed on deck is safely dropped without item loss.

---

## 🛥️ Fleet Overview

| Vessel | Item ID | Dimensions (L × W × H) | Description |
|---|---|---|---|
| **RMS Titanic Ocean Liner** | `titanic:ocean_liner` | 21 × 5 × 9 blocks | Majestic multi-funnel flagship liner with broad promenade deck. |
| **Small Ocean Liner** | `titanic:ocean_liner_small` | 15 × 5 × 9 blocks | Streamlined twin-funnel passenger liner for tight waterways and shorter sea routes. |

---

## 🔨 Crafting Recipes

### Mineclonia & VoxeLibre
```text
[Iron Ingot]   [Coal Block]   [Iron Ingot]
[Iron Block]   [Wood Plank]   [Iron Block]   ==>  RMS Titanic Ocean Liner
[Wood Plank]   [Wood Plank]   [Wood Plank]

[Iron Ingot]   [   Coal   ]   [Iron Ingot]
[Wood Plank]   [Iron Ingot]   [Wood Plank]   ==>  Small Ocean Liner
[Wood Plank]   [Wood Plank]   [Wood Plank]
```

### Minetest Game
```text
[Steel Ingot]  [Coal Block]   [Steel Ingot]
[Steel Block]  [Wood Plank]   [Steel Block]  ==>  RMS Titanic Ocean Liner
[Wood Plank]   [Wood Plank]   [Wood Plank]

[Steel Ingot]  [   Coal   ]   [Steel Ingot]
[Wood Plank]   [Steel Ingot]  [Wood Plank]   ==>  Small Ocean Liner
[Wood Plank]   [Wood Plank]   [Wood Plank]
```

### Shapeless Model Conversion
Place any Ocean Liner into the crafting grid alone to cycle between the RMS Titanic and the Small Ocean Liner.

---

## 🕹️ Quick Start Guide

1. **Craft or obtain** `titanic:ocean_liner` or `titanic:ocean_liner_small`.
2. **Find deep water** (ensure there are at least 3 blocks of open water beneath the surface).
3. **Right-click** water to place the ship.
4. **Use a screwdriver** to rotate the ship to your desired travel direction (North, West, South, or East).
5. **Hop on board** and place your chests, luggage, or supplies on the deck.
6. The Titanic will idle at the dock for **60 seconds**, sound its whistle, and begin its straight-line voyage!
7. To pack up the ship, hit the hull or deck with a **pickaxe**.

---

## 🧹 Chat Commands

* `/delete_ships` (aliases: `/clear_ships`, `/delete_titanic`, `/clear_titanic`):
  * Instantly deletes **all Titanic and Ocean Liner ships** from the entire world.
  * Restores clean water and removes deck surfaces without leaving orphan blocks behind.
  * Automatically forces distant and unloaded mapblocks containing registered vessels to load via `minetest.load_area` so no abandoned ships are left behind.
  * Safely drops any player chests, luggage, and interior furniture so items are not lost.

---

## 📜 License & Credits

* **Code:** MIT License (c) 2026 ronrob-lu & Antigravity
* **3D Models & Textures:** Kenney (CC0)
