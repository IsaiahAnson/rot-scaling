<img src="icon.png" width="128" align="right" alt="RotScaling icon">

# RotScaling

A difficulty mod for **Grain Rot** (UE 5.7) built on [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS).

Grain Rot gets easier the deeper you go. Your gear and stats outgrow the curve, and dungeon enemies stop being a threat. RotScaling puts the threat back by scaling every enemy with the dungeon level.

## What it does

Every enemy that spawns is buffed, on top of whatever scaling the game already applies:

| Stat | Scaling |
| --- | --- |
| Max health | +25% at level 1, +12% per level after |
| Damage | +15% at level 1, +8% per level after (all damage types) |
| Move speed | +5% at level 1, +2% per level, capped at +40% |
| Crit chance | +0.5 points per level, capped at +15 |

A level 10 dungeon therefore runs at roughly double enemy health and +87% damage. Speed and crit are capped deliberately: uncapped speed breaks enemy pathing, and runaway crit turns fights into coin flips.

Only enemies are touched. Players, soul vessels and friendly NPCs are identified from their character preset (`UHeldenCharacterPreset.CharacterType`) and left alone.

## Multiplayer

Host only. Enemy stats are authoritative on the server and replicate through the stats component, so **only the host needs this installed** - joiners fight the same buffed enemies with no mod of their own. On a client the mod detects it has no authority (no `GameMode` exists client-side) and idles.

## Install

Requires a working UE4SS install (experimental build, Aug 2026 or later).

1. Download the release zip.
2. Copy `Mods\RotScaling` into `Grain Rot\Helden\Binaries\Win64\ue4ss\Mods\`.
3. Copy the `UE4SS_Signatures` folder into `Grain Rot\Helden\Binaries\Win64\ue4ss\` (merge with any existing one).
4. Launch. `enabled.txt` loads the mod without editing `mods.txt`.

The AOB signatures are required on UE 5.7 - without them UE4SS fails its pattern scan at boot. A game update may break them.

## Tuning

Everything lives in the `CFG` block at the top of `Scripts/main.lua`:

```lua
BASE_HP_PCT         = 25,   -- health at level 1
HP_PCT_PER_LEVEL    = 12,
BASE_DMG_PCT        = 15,   -- damage at level 1
DMG_PCT_PER_LEVEL   = 8,
BASE_SPEED_PCT      = 5,
SPEED_PCT_PER_LEVEL = 2,
SPEED_CAP_PCT       = 40,
CRIT_PTS_PER_LEVEL  = 0.5,
CRIT_CAP_PTS        = 15,
```

The scaling is linear in the dungeon level `L`:

```
multiplier = 1 + (BASE_PCT + PER_LEVEL_PCT * (L - 1)) / 100
```

Halve the per-level numbers for a gentler curve, or raise them for something genuinely nasty. Set `VERBOSE = true` to log every scaled enemy to `UE4SS.log`.

## How it works

Enemy stats live in `AHeldenCharacter.CharacterStats` (`UHeldenStatsComponent`):

- `TotalStats.MaxHealth` is multiplied and `CurrentHealth` keeps its fraction, so an enemy caught mid-fight is never visibly healed.
- `TotalStats.TypedDamage[i].Damage.min/max` is multiplied per damage entry. Nested struct-in-array writes are the least certain lever, so it fails soft and reports - health and speed still land regardless.
- `WalkSpeed` / `RunSpeed` / `SprintSpeed` are multiplied under a hard cap, and `CritChance` takes additive points.

The dungeon level comes from `HeldenGameState.CurrentDungeonRun.DungeonActor.CurrentSeed.Level`, with a scan over all dungeon actors as a fallback for a mod loaded mid-run. That field reads one below the level shown in game, so `+1` is applied.

Intake is event-driven: `NotifyOnNewObject` on `HeldenCharacter` queues spawns, a bounded per-frame drain applies them, and a slow catch-up sweep picks up anything missed. Per-run state is keyed on the run seed, never on actor addresses - the dungeon actor is reused in place between runs.

No timers, no key polling, no hotkeys, and no external processes.

## License

MIT - see [LICENSE](LICENSE).
