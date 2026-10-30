# Mechanics check: concept C (Pathfinder non-crit poison Cyclone), 3.29

Sources: this repo's 3.29 data (`src/TreeData/3_29/tree.lua`, `src/Data/`, `src/Modules/`).
poewiki and poedb were not reachable from the session, so no wiki or patch-note check yet.

No core interaction is WRONG. The concept stands, with the corrections below.

| # | Claim | Verdict | PoB |
|---|---|---|---|
| 1a | Nature's Reprisal: 25% chance to Wither for 2 s on hit, 50% increased effect of Withered | RIGHT (tree) | Chance = `CanWither` flag; stacks set in Config. Effect: floor(6 × 1.5) = 9% per stack, 135% at 15 |
| 1b | Master Toxicist: 20% chance for 100% more poison damage, spread on kill | PARTLY: both need an active flask; spread radius 1.5 m | Damage averaged (20% more) behind "Do you have a Flask active?". Spread not modelled |
| 1c | Nature's Adrenaline | RIGHT, but only 3 charges every 3 s, not permanent flasks | Flask uptime: Config switch |
| 1d | Master Surgeon keeps the life flask on | PARTLY: effect not removed at full life, no queueing, 50% less flask recovery | Only the 50% less |
| 1e | Master Distiller excludes channelling (Cyclone) | RIGHT | Not modelled at all |
| 1f | Notables | Judgement: Nature's Reprisal, Master Toxicist, Nature's Adrenaline; Master Surgeon if survival needs it; skip Master Distiller | |
| 2 | Reprisal's Withered effect applies to Withered from every source | UNCLEAR in game, global in PoB | Test in game |
| 3 | Withered: 15 stacks, 6% increased chaos damage taken each; boosts poison | RIGHT (numbers from tree reminder text); poison boost per PoB, wiki unchecked | Config "# of Withered Stacks" |
| 4a | Replica Innsbury Edge | Elder Sword, (100-140)% inc phys, 50% phys converted to chaos, Withered on hit with this weapon, 0.2% chaos leech; level ~47 (snippet) | Yes |
| 4b | Weapon conversion applies to Cyclone hits | UNCLEAR wording (local/global); with a shield it doesn't matter | PoB converts while equipped |
| 4c | Chaos damage poisons by default | NOT by default: needs a poison chance source (supports, Herald of Agony, mods) | Poison chance modelled |
| 5 | Gain-as-extra-chaos from physical before conversion | RIGHT in PoB. Withering Touch tops at 24% (gem 15) in PoB data, not "21% at 20" | Yes |
| 6 | Herald of Agony, Unbound/Deadly Ailments, Void Manipulation, Cyclone 3.29 changes | UNCLEAR: gems exist in 3.29 data; patch notes unchecked | HoA virulence = Config stack count, no ramp |

## PoB does not model
- Master Toxicist's poison spread on kill (clear only).
- Master Distiller bonuses (correctly excluded).
- Herald of Agony's virulence ramp, Withering Presence's ramp, Withered stack refresh/expiry: static Config counts.

## To check by hand (poewiki / poedb)
1. Replica Innsbury Edge: local vs global conversion wording, level requirement.
2. Nature's Reprisal: does the Withered effect apply to all sources?
3. 3.29 changes to Cyclone and Herald of Agony.
