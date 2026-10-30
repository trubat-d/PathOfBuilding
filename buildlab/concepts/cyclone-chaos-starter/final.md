# Pathfinder poison Cyclone (chaos), 60 div league starter, 3.29

## Concept
Cyclone poisons on every hit (100% poison chance from Chance to Poison and the tree). Replica Innsbury Edge converts
half its physical damage to chaos and Withers on every hit; Nature's Reprisal makes each Withered stack 9%,
so 15 stacks mean 135% increased chaos damage taken, which boosts poison. Master Toxicist adds 20% more poison
damage while a flask is up, and Nature's Adrenaline and Nature's Boon keep four magic utility flasks running.
Defence: life, Imbalanced Guard and Iron Reflexes with armour, 71% block from an Imbalanced Guard shield setup,
Unwavering Stance against stuns, flasks for freeze, shock and ignite.

- **PoB:** https://pobb.in/gj-eLjty-fZM (code in `v3.txt`; boss settings in `v3_boss.xml` / `v3_boss.txt`)
- **Main link:** Cyclone, Withering Touch, Void Manipulation, Chance to Poison, Unbound Ailments, Melee Physical Damage
- **Auras:** Herald of Agony, Malevolence. Withering Step; Despair on Arcanist Brand.
- **Ascendancy:** Nature's Reprisal, Master Toxicist, Nature's Adrenaline, Nature's Boon
- **Uniques:** Replica Innsbury Edge, Bronn's Lithe (6-link), Crown of the Inward Eye, Ralakesh's Impatience (endurance variant)
- **Anoint:** Fatal Toxins

## Numbers (`eval.sh`, BUDGET=60 PHASE=WEEK1)
| | Mapping (`v3`) | Boss (`v3_boss`) |
|---|---|---|
| Combined DPS | 431.7k | 269.7k |
| Settings | all flasks up, Withered 15, virulence 10 | Silver and Sulphur off, Withered 10, virulence 5 |
| Life / ES / EHP | 6,033 / 267 / 35.2k | same |
| Max hit: phys / fire, cold, lightning / chaos | 12,600 / 26,786 / 24,132 | same |
| Resistances | 75 / 75 / 75, chaos 75 | same |
| Spell suppression / block / spell block | 40% / 71% / 0% | same |
| Mana | cost 95.9/s, regen + leech ~165/s | cost 82.8/s |

**Cost:** 39.4 div by eval. The eval prices the 6-link Bronn's Lithe and Replica Innsbury Edge at about 0, and the
critic thinks the shield (2.2) and amulet (1.3) are underpriced (more like 3-5 and 4-8 div). Realistic total:
**about 50-60 div**. The two rings are the most expensive slots (11.4 and 6.3 div).

All rare items were written by hand and checked against PoB's mod data (`ModExplicit.lua`, `ModJewel.lua`,
`Essence.lua`), not against the trade site.

## What PoB does not show
- **Master Toxicist uptime:** PoB counts its 20% chance of 100% more poison damage as always on. Real uptime is
  about 60%: boss DPS about 255k instead of 270k (builder's arithmetic, not a PoB number).
- **Flask uptime:** Nature's Adrenaline gives each flask 1 charge per second. On bosses, Silver and Sulphur are up
  only about 15% of the time, which is why `v3_boss` turns them off. Without Silver, freeze and chill protection is gone.
- **Ramps:** Withered stacks and Herald of Agony virulence drop off as soon as you stop hitting. PoB uses fixed counts.
- **Not modelled:** Master Toxicist's poison spread on kill (clear only).
- **Steelskin** (Cast when Damage Taken) is off in PoB: turning it on raised the phys max hit to 17.0k because PoB
  treats a temporary guard as permanent.

## Critic's remaining warnings
- **Physical hits:** the 12.6k phys max hit is set by life under Imbalanced Guard's 50% cap. Shaper Slam still
  one-shots it (survives 91% of the hit). Only more life raises it (about +1k max hit per +500 life).
- **Spell suppression is 40%:** no legal way to add more on the current items was found.
- **No poison avoidance**, and the life flask's effect ends at full life.
- **Despair on Arcanist Brand** means casting a brand mid-channel.
- **Replica Innsbury Edge** is a Heist replica: supply is thin in week one. Fallback: a flat physical rare one-hander
  (3-8 div), which loses the Withered on every hit (15 to 8 stacks cut poison by about a quarter in `v1`).

## Upgrade path (next 3 purchases)
1. **6-link Bronn's Lithe**, about 6-8 div. Until then: Tabula Rasa (1-3 div) or a 5-link.
2. **Amulet** at its real price (4-8 div): life, flat physical, damage-over-time multiplier, anointed with Fatal Toxins.
3. **Spell suppression** on the gloves and any slot that can roll it, towards 100%: the biggest remaining defence gap.
   Not measured; check in PoB before buying.

## History
- `v1`: generator draft adapted to poison. Mana didn't sustain; config overstated.
- `v2`: critic round 1 fixes (Melee Physical Damage instead of Deadly Ailments, 100% poison chance, magic flasks,
  gear). 584k, but several rares couldn't exist.
- `v3`: legal items, more life (4,967 to 6,033), boss variant.
