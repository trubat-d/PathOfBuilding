# Pathfinder poison Cyclone (chaos), 60 div league starter, 3.29

## Concept
Cyclone of Tumult poisons on every hit with a rare physical Legion Sword; Resolute Technique makes every hit land.
Withered (Nature's Reprisal: 9% per stack) is stacked by Grasping Nightshade (2-3 per hit) and boosts the poison.
Betrayal's Sting adds extra poisons; Master Toxicist, Vile Toxins and Added Chaos Damage multiply it. Plain Cyclone
for mapping (Tumult slows you down). Defence: life, Imbalanced Guard and Iron Reflexes, 63% block,
Unwavering Stance, flasks against freeze, shock and ignite.

- **Bosses (Cyclone of Tumult):** https://pobb.in/RFwiIv2993LT (`v4.xml`, code in `v4.txt`)
- **Mapping (plain Cyclone):** https://pobb.in/NUZCL5BcpRbl (`v4_map.xml`, code in `v4_map.txt`)
- **Main link (Bronn's Lithe, 6-link):** Cyclone of Tumult (Cyclone for mapping), Vile Toxins, Void Manipulation,
  Chance to Poison, Unbound Ailments, Added Chaos Damage
- **Auras and utility:** Herald of Agony, Purity of Elements, Summon Chaos Golem, Withering Step, Flame Dash,
  Despair on Arcanist Brand, Vaal Haste, Cast when Damage Taken with Steelskin
- **Ascendancy:** Nature's Reprisal, Master Toxicist, Nature's Adrenaline, Nature's Boon
- **Keystones and key notables:** Resolute Technique, Imbalanced Guard, Iron Reflexes, Unwavering Stance, Magebane,
  Cannibalistic Rite (mana cost for Tumult). 118 passive points at level 95 (checked in PoB).
- **Uniques:** Bronn's Lithe, Crown of the Inward Eye, Ralakesh's Impatience (endurance), Betrayal's Sting,
  Grasping Nightshade (tincture, in a flask slot)
- **Weapon:** rare Legion Sword, 165% increased physical, 22-44 flat physical, 26% attack speed, +23% DoT multiplier

## Numbers (`eval.sh`, BUDGET=60 PHASE=WEEK1)
| | Bosses (`v4`) | Bosses, Silver off | Mapping (`v4_map`) |
|---|---|---|---|
| Combined DPS (PoB) | 1.71M | 1.48M | 1.12M |
| Poison / hit | 1.57M / 144k | | 1.03M / 94k |
| Life / ES | 5,252 / 267 | same | same |
| Max hit: phys / fire, cold, lightning / chaos | 9,956 / 22,399 / 21,008 | same | 11,038 / 22,399 / 21,008 |
| Resistances | 75 / 75 / 75, chaos 75 | same | same |
| Spell suppression / block / spell block | 42% / 63% / 0% | same | same |
| Mana | cost 161/s, regen + leech ~208/s | | cost 72/s |

Config: Withered 12 (Nightshade 15 for 12-13 s, ~7 for 8 s while it recharges), virulence 5 (bosses) / 10 (mapping).
Bosses: Life, Silver and Nightshade active. Mapping: all flasks active.

**Honest boss DPS: about 1.0-1.2M.** From the Silver-off 1.48M: Master Toxicist up about 50-60% of the time
(about -8%), and Tumult at 3-4 stages on average against a moving boss instead of PoB's fixed 5 (-12 to -25%).

**Cost:** 43.7 div by eval, sword included at about 10 div. With the 6-link (6-8 div), Betrayal's Sting and the
tincture (about 2 div): **about 52-54 div**, 6-8 div of margin. Rare items were written by hand and checked against
PoB's mod data, not against the trade site.

## What PoB does not show
- **Tumult stages:** fixed at 5 in PoB (no setting). Stages decay 400 ms after you stop channelling. -12% at 4 stages,
  -25% at 3. Tumult's 50% less movement speed at full stages isn't modelled either: use plain Cyclone for mapping.
- **Grasping Nightshade:** its Withered isn't linked to hits in PoB (Config set by hand), and its Mana Burn isn't
  modelled: one stack every 0.9 s, 1% of maximum mana per second per stack, off at 0 mana, then 8 s cooldown.
  Switch it off by hand at about 10 s so Tumult keeps its mana and stages.
- **Master Toxicist** is counted as always on; real uptime about 50-60%. Tinctures may not count as a "Flask Effect":
  test in game.
- **Silver flask:** about 13% uptime on bosses from Nature's Adrenaline. Without it, no freeze immunity.
- **Withered** averages assume you keep hitting; it drops off within 2 s when you stop.
- Steelskin (Cast when Damage Taken) stays off in PoB: PoB counts the temporary guard as permanent.

## Remaining warnings
- **Physical hits:** phys max hit about 10-11k under Imbalanced Guard's 50% cap; Shaper Slam one-shots it
  (survives 72% of the hit on the boss setup). Only more life raises it.
- **Spell suppression is 42%.** Spell block is 0%.
- **No poison avoidance.**
- **Mana is tight on Tumult:** 161/s cost against ~208/s, before Nightshade's burn.
- **The sword is the build.** A weaker roll (125% / 14-28 / 18% / +14%, about 1 div) gives 1.37M instead of 1.71M in PoB.
- **Despair on Arcanist Brand** means casting a brand mid-channel.

## Upgrade path (next 3 purchases)
1. **6-link Bronn's Lithe** (6-8 div). Until then: a 5-link, dropping Unbound Ailments.
2. **Grasping Nightshade** and **Betrayal's Sting** (cheap, about 2 div together): big damage for little.
3. **The Legion Sword:** start with a mid-tier roll (~1-3 div), then the 165% / 22-44 / 26% / +23% roll (~10 div).

## History
- `v1`-`v3`: generator draft to legal poison build on Replica Innsbury Edge: 270k bosses (with an overstated
  Withered count).
- `dmg_*`, `top_*`: a rare physical sword instead of the Innsbury (+100%), Resolute Technique (+46%),
  Added Chaos Damage, Chaos Golem: 676k bosses.
- `fix_*`: blockers fixed instead of rejected: Tumult's mana (Cannibalistic Rite), Betrayal's Sting's resistances
  and Int, Vile Toxins' Withered (Nightshade): 1.62M in PoB.
- `v4`: legal 118-point tree, honest Withered, budget-fitting sword: 1.71M in PoB, about 1.0-1.2M honest on bosses.
- `damage_survey.md`: every damage source considered, with gains and costs.
