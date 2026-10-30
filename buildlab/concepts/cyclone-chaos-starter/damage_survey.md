# Damage survey: chaos / poison Cyclone, 3.29, 60 div, WEEK1

Baseline is `v3_boss.xml` (Pathfinder, Replica Innsbury Edge, boss config): **269.7k combined**, of which
**poison 216.6k (80%)** and hit 53.2k. 6.90 attacks/s, **hit chance 79%** (PoB's pinnacle evasion),
19 poison stacks, poison duration 3.48 s, Withered 10.

**Method.** Every "+x%" below is a PoB number from a probe on `v3_boss.xml`, unless it is marked *est*.
Each probe changes one thing: a custom modifier, a gem swap, an extra socket group or a config value
(scratch script, not a build). Each figure is the gain over 269.7k for that one change, so the figures
multiply, roughly. Costs are `price.py` snapshot prices (late league, day 91) times the WEEK1 factors in
`PriceSource.lua`: x1.2 for uniques under 1 div, x2.0 for 1-20 div, x3.6 chase, about x1.9 for
gems and rares. *est* = no poe.ninja price.

Not repeated here (the pob-builder is measuring them): a rare physical weapon instead of Innsbury, supports
in the Chance to Poison slot, the Withering Touch slot, DoT multiplier and clusters with the last 10 div,
and Assassin vs Occultist.

## 0. Three facts about this build that drive everything
1. **Increased damage is saturated.** +50% increased poison damage gives only +7.9%, and +50% increased chaos only +9.4%.
   What scales is: more multipliers, hit chance, attack speed, poison duration, additional poisons, chaos res reduction, Withered.
2. **"Poisons deal damage X% faster" does nothing for sustained DPS.** PoB shows +0% for the Poison Mastery's
   20% faster and for the Watcher's Eye "ailments 10-15% faster" mod. Each poison deals the same total damage over
   a shorter time, so there are fewer stacks and the same DPS. It only helps on short fights. **Duration** does help:
   +20% poison duration = +9.2%.
3. **Withered stacks are coupled to hits per second, and PoB does not model that.** Innsbury Withers on every hit,
   for 2 s. Real stacks are about min(15, attacks/s x hit chance x 2): 6.9 x 0.79 x 2 = **10.9** now (the config's 10 is right).
   With 100% hit chance it is 13.8. With Tumult's ~12 attacks/s it is capped at **15**. Every lever that adds hit chance or attack speed must
   also raise `multiplierWitheredStackCount` in Config. Withered 10 to 13 = +14.1%, to 15 = +23.5%.

## 1. Ascendancies and bloodlines
| Option | What it does for us | Gain (PoB) | Cost | PoB models? | Conflict |
|---|---|---|---|---|---|
| Pathfinder (current) | Nature's Reprisal: Withered 9%/stack (135% at 15). Master Toxicist: 20% more on average. Flask effect | baseline | 0 | yes (Master Toxicist always on: real ~-5%) | - |
| Occultist | Withering Presence (15% more chaos, 15 stacks without on-hit), Void Beacon (-20% chaos res), 2 curses | the WP+VB parts alone: +69% at W15. Net of losing Reprisal and Master Toxicist: *est* +10-15% vs v3 at W10, but **~8% behind Pathfinder once Pathfinder reaches W15** (RT/Tumult) | 0 | yes | Builder measuring |
| Assassin (non-crit) | Opportunistic 25% more (one rare/unique nearby) | +25.3% for the node; net *est* -12% (loses Reprisal and Master Toxicist) | 0 | yes | Builder measuring |
| Trickster | Polymath: 2% more per mastery type (3 types now) | +6-16% *est* | 0 | yes | loses all of Pathfinder |
| Ascendant | Watered-down picks (Trickster's 2%/mastery, Pathfinder's 10% attack speed during flask) | small | 0 | yes | not worth it |
| **Bloodline: Necromantic** (Bitter Lash + "+8% DoT multi") | main-hand skills supported by level 1 **Cruelty** | **+40.4% at PoB's default 40% Cruelty; +11.1% at Cruelty 10%** | 0, but 2 of the 8 shared ascendancy points (drop Nature's Boon) | yes, but Cruelty is set to its 40% maximum by default (`overrideCruelty`) | real Cruelty value on a boss is unknown (RISK) |
| **Bloodline: Lycia** (Bitter Heresy + "25% chaos") | your Consecrated Ground becomes Profane: you get Chaotic Might (30% phys as extra chaos), enemies get Malediction (10% increased damage taken) | **+29.3% when standing in it** | 2 ascendancy points + a Consecrated Ground source (Sulphur flask is up ~15% on bosses; Consecrated Path?) | yes (config checks) | real uptime is probably 30-60%: *est* +10-18% |
| Lycia: Sinner Saint + Hatred | 67% of cold converted to chaos, so Hatred's extra cold can poison | +15.1% | 2 points + 25% reservation (doesn't fit: -191 mana) | yes | reservation |
| King in the Mists: Unseen Hand | +1 ring slot (Ming's Heart / Betrayal's Sting) | +24-28% for the extra ring | costs a belt, an amulet, **or all utility flasks** | yes | kills the Pathfinder flask setup or a 4-6 div slot: poor |
| Bloodline availability | Bloodlines started in 3.27 and appear in 3.28 builds. PoB keeps them as obtainable (it only removes Warden, Warlock, Primalist). | | | | **Not confirmed for 3.29** (poedb and poe-vault are blocked here): mechanics-checker |

## 2. Uniques and cheap key items
| Item | Effect for us | Gain (PoB) | WEEK1 cost | Fits 60? | Conflict / risk |
|---|---|---|---|---|---|
| **Betrayal's Sting** (ring) | 25-40% chance to inflict an **additional poison** | **+25.7%** (32% roll) | 0.06 → ~0.07 (supply risk in week 1: lvl 80, boss drop; *est* 0.1-3) | yes | **-(20-30)% all elemental res**, and replaces Viper Coil (45 cold res, 107 life): about 70 res to rebuild |
| **Ming's Heart** (ring) | 40-60% phys as extra chaos | +28.5% added; ~+24% replacing Viper Coil | 0.01 → 0.01 | yes | -25% max life: **6,033 → ~5,230** (phys max hit drops with it), res hole |
| Grasping Nightshade (tincture) | melee weapon hits inflict 2-3 Withered | = Withered 15: **+23.5%** (redundant once RT/Tumult cap stacks) | *est* 0.1-1 (not in snapshot) | yes | takes a flask slot; mana burn on a mana-tight build; Pathfinder flask nodes don't apply |
| Chaos/flat-chaos gloves: The Embalmer | 13-17 to 23-29 chaos, 20-25% poison duration; its Vile Toxins only supports gems in the gloves | ~+10% vs nothing, *est* +2-6% net of losing current gloves (12% AS, 12% suppression) | 0.01 (Foulborn listed) | yes | loses suppression |
| Sin's Rebirth (flask) | Unholy Might = 100% phys converted to chaos, in 3.29 | +7.3% (almost all on hits) | 0.05 → 0.06 | yes | takes the Sulphur slot |
| Atziri's Promise (current variant 5-8%) | phys as extra chaos while up | +4.0% | 0.02 → 0.03 | yes | flask slot |
| Watcher's Eye (Malevolence) | +18-22% DoT multi (the "faster" mod is worth 0) | +9.3% | *est* 3-10 (PoB floor 3) | yes | replaces a 3.8 div Cobalt jewel |
| Eyes of the Greatwolf (DoT multi variant, doubled) | +24-36% DoT multi | *est* +5% net of the amulet | 1 → 2 | yes | loses 122 life, flat phys, res |
| Aul's Uprising (Malevolence) | frees Malevolence's reservation (then Haste +12.4%) | *est* ~0 net (lose amulet's 18 DoT + flat phys ≈ -15%) | 0.03 | yes | |
| Bottled Faith | 7-10% increased damage taken on its ground (crit part useless) | *est* +5% | 14 → ~28 | no | |
| Darkness Enthroned + abyss jewels | two abyss sockets at 50-100% effect: flat phys/chaos to attacks | *est* +5-10% | 0.01 + jewels 1-3 | maybe | loses the 175-life belt |
| Forbidden Flame/Flesh | a second Ranger notable: no damage notable (Distiller excludes channelling) | ~0 | ≥10 each | no | |
| Timeless jewels | no strong poison or chaos DoT notable found in the repo data | unclear | 0.06-0.14 + search | n/a | not measured |
| Dendrobate / Cospri's Will (body) | free Chance to Poison / always poison vs cursed | | 0.01 | yes | **loses Bronn's Lithe's +5 Cyclone levels**: not worth it |
| Fleshrender, Saresh's Darkness, Voidheart | | | | **not obtainable** (Mirage / legacy) | |
| Voidforge | 700% of weapon phys as random element, "deal no non-elemental damage" | | ~20 | | no chaos at all |

## 3. Gems
| Option | Gain (PoB) | WEEK1 cost | PoB? | Notes |
|---|---|---|---|---|
| **Cyclone of Tumult** (transfigured) 21/20 | **+56.3%**; 20/20 +53.0%; with Withered 13: +78% | 20/20: 2.0 → **~3.8**; 21/20c: 5.7 → ~10.7; lvl 1: 1.5 → 2.8 | yes, assumes max 5 stages | 80% (instead of 200%) attack speed multiplier, +30% more attack speed per stage at Q20, -10% movement speed per stage (not modelled), stages build every 0.4 s and decay. **Mana cost 83 → 194-204/s against ~165/s of sustain: needs a fix** |
| **Added Chaos Damage replacing Melee Physical Damage** | **+23.4%** (MPD also has less attack speed: 6.90 → 7.68 without it) | 0.09 → ~0.17 | yes | overlaps the builder's Chance to Poison slot work; this is the MPD slot |
| Cruelty replacing MPD | +5.3% (default 40% Cruelty) | 0.9 → 1.7 | max by default | RISK on the real value |
| Close Combat / Rage / Swift Affliction / Sadism / Efficacy / Vile Toxins / Deadly Ailments / Momentum replacing MPD | -16 / -23 / -19 / -64 / -7 / -9 / -8 / +0.4% | | | all worse than MPD |
| Awakened Unbound Ailments 5 | +9.4% (lvl 1: +1.4%) | *est* 30-60 at lvl 5 | yes | not worth it |
| Awakened Void Manipulation 5 / Awakened MPD 5 | +3.7% / +3.2% | *est* 10-40 | yes | no |
| Corrupting the main gem: 20 → 21 | +2.1% | | yes | |
| **Summon Chaos Golem** 20 | **+8.9%** (Flame +7.0%, Lightning +6.2%, Carrion and Stone 0) | 0.01 → 0.02 | yes | one socket, no reservation |
| Herald of Purity 20 | +8.1% | 0.11 → 0.2 | yes | uses all the remaining mana (190 unreserved → 0) |
| Precision 20 | +17.7% (hit chance 79 → 92%) | 0.08 → 0.15 | yes | uses all the remaining mana; **redundant with Resolute Technique** |
| Haste | +12.4% | 0.2 | yes | doesn't fit (-191 mana) |
| Hatred / Wrath / Pride | 0 / 0 / +0.1% | | yes | poison ignores cold and lightning; Pride affects physical hits only |
| Herald of Agony virulence | 0 (virulence only buffs the Agony Crawler in PoB) | | partly | the "5 vs 40 virulence" config has no effect on Cyclone |
| Withering Step / Despair | already in v3 | | | |
| Curses / exposure | no chaos exposure exists. Despair is already the chaos-res curse. A second curse adds no poison scaling | | | |

## 4. Passive tree and clusters (distances in points from v3's tree)
| Option | Gain (PoB) | Points | Notes |
|---|---|---|---|
| **Resolute Technique** (hits can't be evaded, never crit) | **+24.9%**; **+48.4% with Withered 14** (13.8 real) | **7** | no conflict (non-crit build). Free in divines. The biggest per-cost lever |
| Precise Technique (40% more attack damage if accuracy > life) | +7.9% (hits only in PoB) | 2 | PoB applies "attack damage" to hits only, not poison: checker should confirm |
| DoT Mastery: 15% increased duration of ailments on enemies | +6.9% | 4 | |
| Corruption (20% Withered effect) | +5.2% | 19 | too far |
| Wasting (+10% chaos DoT multi) / Acrimony (+15%) / Growth and Decay (+12%) | +4.7% / ~+7% / ~+5.6% | 8 / 17 / 14 | (+10 DoT multi = +4.7%) |
| Chaos Mastery: 40% phys converted to chaos | +5.8% (hits only) | 9 | |
| Chaos Mastery: 5% chance to inflict 15 Withered | not modelled | 9 | redundant at Tumult speed |
| Poison Mastery (adjacent) | 0 on bosses: 300% vs non-poisoned is a mapping effect, 20% faster is worth 0 | 1 | |
| Perfect Agony | a different archetype (crit chance near 100% needed) | 4 | not measured; separate rebuild |
| Elemental Overload / Point Blank / Crimson Dance | n/a | | elemental, projectile, bleed only. Poison stacks are already unlimited |
| Large/medium cluster notables (builder's lever) | Unholy Grace (30% chaos, 10% speed) +11.0%; Fuel the Fight +8.5%; Wicked Pall / Unwaveringly Evil 30% chaos ~+5%; Low Tolerance ~0 on bosses | | the "increased" pool is saturated: prefer speed and duration notables |

## 5. Item mods (where they roll, top tier)
| Mod | Where | Top tier | Gain |
|---|---|---|---|
| +% DoT multiplier (generic suffix) | one-hand weapon, amulet: 24-26 (ilvl 82). Two-hand: 41-45 | | +10 = +4.7% |
| +% Chaos DoT multiplier | Elder / Hunter gloves and amulet suffix 16-20. Veiled 24-28 (one-hand). Corrupted helmet/ring implicit 10-15 (DoT) | | same |
| Exarch eldritch implicit: chaos DoT multi "while a Pinnacle Atlas Boss is in your Presence" | gloves, amulet: up to 37-38 (plain: 19-20) | | ~+15% at 30 *est*; embers cost *est* 2-5 div |
| Poison duration | Hunter ring suffix 9-10%. Explicit 13-18% (weapon/quiver). 10-20% at ilvl 83 | | +20% duration = +9.2% |
| Flat phys / chaos to attacks | rings, amulet, gloves, quiver | | +20 avg phys = +7.6%; +20 avg chaos = +5.6% |
| Attack speed | gloves, rings, shield, weapon | | +10% = +5.1% |
| Accuracy | gloves, helmet, rings, amulet, weapon | | +500 = +12.8%; +1000 = +21.9% (moot with RT) |
| Mana fix for Tumult: "Channelling Skills have -4 to Total Mana Cost" | Elreon veiled prefix (rings, amulet) | | needed for Tumult; *est* 1-3 div each |

## 6. Other mechanics
- **Gain as extra chaos** (Ming's 50%, Chaotic Might 30%, Atziri's 7%): taken from phys before conversion, so it grows both
  the hit and the poison base. +20% gain = +11.5%. PoB models it.
- **Phys converted to chaos** (Chaos Mastery, Unholy Might): helps only the hit part (poison already uses phys and chaos). +6-7%.
- **Phys to lightning/cold to chaos chains**: only Lycia's Sinner Saint converts elemental to chaos (+15% with Hatred). Nothing else in 3.29 data.
- **Chaos res reduction** beats penetration (penetration doesn't apply to DoT): -10% res = +9.6%, -20% (Void Beacon) = +19.3%.
- **Malediction** (10% increased taken): +5.3%.
- **Crit poison** (Perfect Agony, Toxic Delivery) and **Impale**: other archetypes. Impale is physical-hit only, which is useless here.
- **Plague Bearer**: capped by a plague value: negligible single-target (not measured).

## Top 10 by damage per divine (WEEK1)
| # | Lever | Gain | Cost | Gain per div |
|---|---|---|---|---|
| 1 | Resolute Technique (+ Withered 14) | +25% (+48%) | 0 div, 7 points | free |
| 2 | Added Chaos Damage instead of Melee Physical Damage | +23% | 0.2 | ~120%/div |
| 3 | Ming's Heart (replacing Viper Coil) | ~+24% | 0.01 | huge, but -13% life |
| 4 | Betrayal's Sting (replacing a ring) | +26% | 0.1-3 *est* | 10-250%/div, -25% res |
| 5 | Summon Chaos Golem | +9% | 0.02 | huge |
| 6 | DoT Mastery 15% ailment duration | +7% | 0 div, 4 points | free |
| 7 | Grasping Nightshade (only without RT/Tumult) | +23% | 0.1-1 *est* | high |
| 8 | Herald of Purity **or** Precision (only without RT) | +8% / +18% | 0.2 | high, uses all free mana |
| 9 | **Cyclone of Tumult 20/20** | **+53%** (+78% with W13) | ~3.8 (+ mana fix 2-6 *est*) | ~8-14%/div, the biggest absolute |
| 10 | Sin's Rebirth / Atziri's Promise in the Sulphur slot | +7% / +4% | 0.06 | high |
Then: Exarch boss-presence chaos DoT gloves (~+15% *est*, 2-5 div), Watcher's Eye (+9%, 3-10 div).
Bloodlines (Necromantic +11-40%, Lycia +10-29%) would rank 1-3 if they exist in 3.29.

## Proposed builds (both Pathfinder, Replica Innsbury Edge, Bronn's Lithe kept)
**B1: Pathfinder Tumult**, for bossing at full budget.
Cyclone of Tumult 20/20 · Resolute Technique · Added Chaos Damage instead of MPD · Withered 15 (real at ~12 attacks/s) ·
Betrayal's Sting · Chaos Golem · DoT Mastery. Mana: 2 x "Channelling -4 mana cost" (Elreon veiled), or more leech.
- PoB (probe): **1.14M** (909k without Betrayal's Sting). Measured parts: RT + Tumult + Added Chaos + W15 = 784k (20/20) / 801k (21c).
- Expected real: **~650-950k, about 2.4-3.5x the 270k**. Discounts: Master Toxicist uptime -5%, Tumult stages lost when
  repositioning -10-25%, no Withered ramp at fight start.
- Cost: +6-12 div over v3 (Tumult 3.8, mana rings, res rebuild after Betrayal's -25%). Tight against the 50-60 realistic total:
  use Tumult 20/20 (not 21c), skip Betrayal's Sting first if over.
- Mapping: keep plain Cyclone. Tumult's -50% channelling movement speed at 5 stages is a boss tool.

**B2: Pathfinder no-Tumult, cheap fix** (if mana or budget blocks Tumult).
Resolute Technique · Added Chaos instead of MPD · Withered 14 · Chaos Golem (+ Betrayal's Sting or Ming's Heart).
- PoB: **537k** without the ring, **671k** with Betrayal's Sting. Expected real **~480-620k, 1.8-2.3x**. Under 2 div plus the res rebuild.
  Mana is unchanged (84.5/s).

## For the mechanics-checker
1. Are bloodline ascendancies obtainable in 3.29, and do they take 2 of the 8 shared points? (Necromantic Bitter Lash, Lycia Bitter Heresy)
2. Cruelty's real magnitude on a pinnacle boss (PoB assumes the 40% maximum).
3. Cyclone of Tumult in 3.29: 5 stages, +25% more attack speed per stage (+0.25%/quality), -10% movement speed per stage, decay. Does Bronn's Lithe's +5 to socketed Movement gems apply? (PoB: yes, it is a Movement skill)
4. Withered from Innsbury: does each hit add one 2-second stack (steady state about hits/s x 2)?
5. Betrayal's Sting "additional poison" chance: PoB adds it to stacks. Is it capped at 100%, and does it stack with other sources?
6. Precise Technique's "more Attack Damage": hits only (PoB) or also poison from attacks?
7. Resolute Technique: no catch for a non-crit poison build? (Expected: none.)

## Reference builds
- Cyclone of Tumult is the main Cyclone version on 3.28 ladders (mostly Slayer and Champion crit hit builds). Poison is a side source in some of them,
  e.g. StickyJim's 3.28 Tumult Slayer with Tainted Pact (pobb.in/6J_tMUF-X3WF, reported via search; about 23M of 57M is poison).
  No Pathfinder or Occultist poison Tumult build was found.
- 3.27 poison CoC Assassin with Cyclone (a different engine): https://pobarchives.com/build/LG6dEX4g
- Bloodlines in 3.28 builds (Lycia bloodline on an Ascendant): https://www.poe-vault.com/guides/scourge-arrow-ascendant-build-guide
