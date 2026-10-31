# Pathfinder poison Cyclone (chaos), 60 div league starter, 3.29

## Concept
Cyclone of Tumult poisons on every hit with a rare physical Legion Sword; Resolute Technique makes every hit land.
Withered (Nature's Reprisal: 9% per stack) is stacked by Grasping Nightshade (2-3 per hit) and boosts the poison.
Betrayal's Sting adds extra poisons; Master Toxicist, Infused Channelling, Added Chaos Damage, chaos
damage-over-time multipliers and the Fatal Toxins anoint multiply it. Plain Cyclone for mapping (Tumult slows you
down). Defence: life, Imbalanced Guard and Iron Reflexes, 67% block, Unwavering Stance, flasks against freeze,
shock and ignite, Granite on bosses.

- **Bosses (Cyclone of Tumult):** https://pobb.in/4lL4M_E7aXiJ (`v5.xml`, code in `v5.txt`)
- **Mapping (plain Cyclone):** https://pobb.in/P5W9NATIiWsg (`v5_map.xml`, code in `v5_map.txt`)
- **Main link (Bronn's Lithe, 6-link):** Cyclone of Tumult (Cyclone for mapping), Infused Channelling,
  Void Manipulation, Chance to Poison, Unbound Ailments, Added Chaos Damage
- **Auras and utility:** Herald of Agony, Purity of Elements, Summon Chaos Golem, Withering Step, Flame Dash
  (Dash is better for Tumult stages), Despair on Arcanist Brand, Vaal Haste, Cast when Damage Taken with Steelskin
- **Ascendancy:** Nature's Reprisal, Master Toxicist, Nature's Adrenaline, Nature's Boon
- **Keystones and key notables:** Resolute Technique, Imbalanced Guard, Iron Reflexes, Unwavering Stance, Magebane,
  Cannibalistic Rite, Strong Arm, Vigour; Life Mastery and Bloodless. 118 passive points at level 95 (checked in PoB).
- **Uniques:** Bronn's Lithe, Crown of the Inward Eye, Ralakesh's Impatience (endurance), Betrayal's Sting,
  Grasping Nightshade (tincture, in a flask slot)
- **Weapon:** rare Legion Sword, 165% increased physical, 22-44 flat physical, 26% attack speed, +23% DoT multiplier
- **Other key items:** gloves with the Exarch implicit "+32% chaos damage over time multiplier while a Pinnacle
  Atlas Boss is in your presence" (bosses only) and Eater +10% suppression; Elder amulet with +16% chaos DoT
  multiplier, anointed with Fatal Toxins; ring bench craft "Channelling Skills have -3 to Total Mana Cost".

## Numbers (`eval.sh`, BUDGET=60 PHASE=WEEK1)
| | Bosses (`v5`) | Bosses, Silver off | Mapping (`v5_map`) |
|---|---|---|---|
| Combined DPS (PoB) | 2.59M | 2.23M | 1.57M |
| Poison / hit | 2.41M / 181k | | 1.45M / 123k |
| Life / ES | 5,481 / 267 | same | same |
| Max hit: phys / fire, cold, lightning / chaos | 12,763 / 27,125 / 25,493 | same | 13,065 / 27,125 / 25,493 |
| Resistances | 75 / 75 / 75, chaos 75 | same | same |
| Spell suppression / block / spell block | 51% / 67% / 0% | same | 41% / 67% / 0% |
| Mana | cost 127/s, regen + leech ~208/s | | |

Config: Withered 12 (honest average 12.8: Nightshade 15 for about 18 s, ~7 for 8 s; PoB rounds down), virulence 5
(bosses) / 10 (mapping). Bosses: Life, Silver, Granite and Nightshade active. Mapping: all flasks except Granite.

**Honest boss DPS: about 1.5-1.8M.** From the Silver-off 2.23M: Master Toxicist up about 50-60% of the time
(about -8%), and Tumult at 3-4 stages on average against a moving boss instead of PoB's fixed 5 (-12 to -25%).
The glove's chaos DoT multiplier only works on pinnacle bosses: on map bosses, use the Silver-off figure minus ~11%.

**Cost:** 50.4 div by eval. With the 6-link (6-8 div), Betrayal's Sting and the tincture (about 2 div):
**about 58-59 div**, so very little margin. Rare and eldritch items were written by hand and checked against
PoB's mod data, not against the trade site.

## What PoB does not show
- **Tumult stages:** fixed at 5 in PoB (no setting). Stages decay 400 ms after you stop channelling. -12% at 4 stages,
  -25% at 3. Tumult's 50% less movement speed at full stages isn't modelled either: use plain Cyclone for mapping.
  Dash (0.15 s cast) instead of Flame Dash keeps the stages.
- **Grasping Nightshade:** its Withered isn't linked to hits in PoB (Config set by hand), and its Mana Burn isn't
  modelled: one stack every 0.9 s, 1% of maximum mana per second per stack, off at 0 mana, then 8 s cooldown.
- **Master Toxicist** is counted as always on; real uptime about 50-60%. Belt mods for flask charges gained or used
  could raise it to 85-95% (not measurable in PoB, not applied). Tinctures may not count as a "Flask Effect".
- **Silver flask (Onslaught):** about 13-16% uptime on bosses from Nature's Adrenaline. Without it, no freeze immunity.
- **Infused Channelling:** its more damage and less damage taken need about a second of channelling to start.
- **Withered** averages assume you keep hitting; it drops off within 2 s when you stop.
- Steelskin (Cast when Damage Taken) stays off in PoB: PoB counts the temporary guard as permanent.

## Remaining warnings
- **Physical hits:** phys max hit about 12.8-13.1k under Imbalanced Guard's 50% cap; Shaper Slam one-shots it
  (survives 93% of the hit). More life, or the Delirious bloodline later, raises it.
- **Spell suppression 51% on bosses, 41% mapping.** Spell block is 0%.
- **No poison avoidance.**
- **The budget is nearly spent** (58-59 of 60 div). The sword is the most important item.
- **Despair on Arcanist Brand** means casting a brand mid-channel.

## Upgrade path
1. **6-link Bronn's Lithe** (6-8 div). Until then: a 5-link, dropping Unbound Ailments.
2. **Grasping Nightshade and Betrayal's Sting** (about 2 div together).
3. **The Legion Sword:** a mid-tier roll first (~1-3 div), then the 165% / 22-44 / 26% / +23% roll (~10 div).

Beyond 60 div (see `upgrades.md`):
- **~80 div:** an Elder Legion Sword with "+45-55% DoT multiplier for poison inflicted with this weapon" (+16-19%).
- **~120 div:** Awakened Unbound Ailments (+10%) or Awakened Added Chaos (+9%).
- **~200 div:** Mageblood (about +20% realistic: Onslaught and Master Toxicist always up).
- **Defence:** the Delirious bloodline ("That didn't happen!") for about +30% phys max hit, once Simulacrum is done.

## History
- `v1`-`v3`: generator draft to legal poison build on Replica Innsbury Edge: 270k bosses (with an overstated
  Withered count).
- `dmg_*`, `top_*`: a rare physical sword instead of the Innsbury (+100%), Resolute Technique (+46%),
  Added Chaos Damage, Chaos Golem: 676k bosses.
- `fix_*`: blockers fixed instead of rejected: Tumult's mana (Cannibalistic Rite), Betrayal's Sting's resistances
  and Int, Vile Toxins' Withered (Nightshade): 1.62M in PoB.
- `v4`: legal 118-point tree, honest Withered, budget-fitting sword: 1.71M in PoB, about 1.0-1.2M honest on bosses.
- `v5`: upgrade package from `upgrades.md` (Fatal Toxins, Infused Channelling, Strong Arm and Vigour, eldritch
  gloves, DoT multiplier amulet, mana craft, Granite): 2.59M in PoB, about 1.5-1.8M honest on bosses.
- `damage_survey.md`: every damage source considered, with gains and costs. `upgrades.md`: the upgrade survey on v4.
