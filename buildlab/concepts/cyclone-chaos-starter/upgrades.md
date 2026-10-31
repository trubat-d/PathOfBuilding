# Upgrades for v4 (bosses, Cyclone of Tumult) and v4_map (plain Cyclone), 3.29, 60 div WEEK1

## Method
- Single-change probes with the headless calculator (scratch script `probe.lua` in the session scratchpad), on `v4.xml` and
  `v4_map.xml`. Nothing in the repo builds was edited.
- **Honest Withered is recomputed in every probe:** off-phase W = hits/s × hit chance × 2 s × 25% (Nature's Reprisal);
  Nightshade on-time t solves `0.01·Mana·t²/1.8 = unreserved mana + spare mana/s · t` (one Mana Burn stack per 0.9 s,
  1%/s each), followed by 8 s off: W = (15·t + W_off·8)/(t + 8). PoB floors the Withered count, so DPS is interpolated
  between floor and ceiling (≈ 4.3% per stack on bosses).
- Baselines with honest Withered: **v4 1.731M** (W 12.3, Nightshade 12.6 s on), **v4_map 1.157M** (W 12.8).
  Life 5,252, phys max hit 9,956 (boss) / 11,038 (map), suppression 42%, block 63%.
- Prices: `price.py` × the WEEK1 factors in `PriceSource.lua` (the snapshot is late league): ×1.2 under ~0.8 div,
  ×2.0 for 0.8-16 div, ×3.57 chase, ×1.875 gems / oils / rares. **est** = my estimate (no poe.ninja price). eval.sh's own
  rare estimator over-prices crafted mods (it put a bench craft on the ring at +12.6 div), so I don't use it for rares.

## Five things that drive the results
1. **The amulet has no anoint, and the tree has no masteries.** Both are almost free.
2. **Vile Toxins is the weakest link in the 6-link.** Infused Channelling (29% more damage, 14% less damage taken
   from hits while Infused) is better on both builds.
3. **Mana leech is at its cap** (20% of maximum mana per second = 185/s). Extra leech gives 0. What helps is maximum mana,
   cost reduction and the leech recovery cap. Mana feeds Withered through Nightshade's on-time.
4. **The Silver flask is Onslaught:** -13.7% DPS when it's down, and it's down about 84% of the time on bosses. This is
   the largest honest discount, bigger than Master Toxicist's.
5. **`v4_map` uses PoB's default "Pinnacle boss" enemy,** so "while a Pinnacle Atlas Boss is in your presence" mods also
   show on the mapping build. I counted them as 0 for mapping.

## 1. Damage ideas (single changes on v4 / v4_map)
| Idea | Bosses | Map | Life / phys max hit | WEEK1 cost | Fix applied / note |
|---|---|---|---|---|---|
| **Anoint Fatal Toxins** | +9.8% | +9.8% | = / = | 0.61 | none (+10 chaos res) |
| Anoint Force Shaper / Acrimony / Corruption / Heart of Darkness / Serpentine Spellslinger | +8.1 / +6.5 / +5.7 / +5.6 / +4.8% | same | = | 0.60 / 0.11 / 0.12 / 0.52 / 0.18 | one anoint slot. Corruption works only because Withered rounds to 10%/stack at 170% (10% more effect gives 0) |
| **Vile Toxins → Infused Channelling 20/20** | +7.5% | +7.5% | = / **11,105** with Infusion (map 12,320); ele / chaos +16% | 0.43 | none. PoB: Infusion is a Config switch |
| Vile Toxins → Melee Physical Damage | +8.1% | +8.0% | = | 0.5 | -10% attack speed, +16 mana/s |
| Vile Toxins → Deadly Ailments | +2.4% (+5.8% with the ring craft) | -0.2 / +4.5% | = | 0.26 | mana -96/s → Withered falls to 10.3; fixed with the -3 channelling craft, still worse than Infused |
| Vile Toxins → Cruelty | +13.7% in PoB, **-12.3% at 5% Cruelty** | | | 1.7 | Cruelty scales with hit damage relative to the target's life: about 0 on a pinnacle boss. Rejected |
| **Tree: Weapon Artistry branch (7085, 45491, 1201) → Strong Arm (38777, 10282, 35663)** | +7.5% | +7.5% | +26 / +34; block -4 | 0 | same 118 points |
| Defiance branch → Strong Arm / Aggressive Bastion | +4.7 / +3.0% | | block -3 / +5 | 0 | weaker than the swap above |
| **Gloves eldritch implicits:** Exarch "boss in presence +32% chaos DoT multi" and Eater "boss +13% suppression" | **+13.8%** (T1 37%: +16.0%) | 0 on maps (plain +20% Exarch: +8.6%) | = ; suppression 42 → 55% | **est 1-2** (Grand ember + ichor on the current gloves) | gloves are the only non-unique armour piece |
| Eater alternative "Withered expires 43-45% slower (boss)" | est +4.5% (W off-phase 8 → 11.5; hand calc, PoB doesn't model expiry) | | | est 1 | instead of suppression |
| **Amulet: chaos res (over-capped) → +16-20% chaos DoT multi** (Elder/Hunter suffix) | +6.9% (+18: +7.8%) | same | = | est 2-3 net (new rare: life, flat phys, DoT multi, fire res, chaos DoT) | chaos res stays 75 (over-cap 22, plus Fatal Toxins' +10) |
| Amulet open prefix: Elder "4% of non-chaos as extra chaos" | +2.5% | | | est 1-2 more | |
| **Ring: bench craft "Channelling Skills have -3 to Total Mana Cost"** (open prefix) | +2.5% (via Withered) | +1.2% | mana spare +47 → **+79/s**, Nightshade 12.6 → 17.9 s | est 0.3 | needs Elreon's unveil unlocked; else an Elreon -4 ring (+3.4%) |
| Ring Int → Hunter "9% poison duration, 20% poison damage" | +7.9% | | | est 2-4 | **Int -41:** needs Hard Knocks or an Int amulet |
| Ming's Heart (Venom Coil out) | +24.9% (+22.5% fixed) | | **life 5,278 → 4,519 (-14%), phys -14%** | 0.01 | fix: Profane Chemistry branch → Diamond Skin + Hard Knocks + Life mastery; Int still -11. Not recommended unless paired with Delirious |
| Ashes of the Stars (amulet) | +7.3% | | life -302, fire 65, Int -8 | 0.28 | loses 122 life, 18 DoT, res: net negative |
| Tumult 21/20 / Added Chaos 21 / Chance to Poison 21 / Unbound 21 | +2.1 / +3.0 / +1.9 / +1.2% | | | 10.7 / ~0.1-0.5 each (21c) | corrupted 21s of the supports are good value if cheap; Tumult 21c is not |
| Large chaos cluster (Unholy Grace, Grim Oath, Wicked Pall; socket 46882 at 3 points) | +7.8% sim | | -156 phys, block -3 | est 3-8 | needs ~8 points: Bladedancer + Defiance branches (7) + 1 more. Marginal |
| DoT mastery (15% ailment duration) | ≈ +7.9% (stat weight) | | | 0 | needs 4 points to a DoT notable; net ≈ +2% after the points. Skip |
| Precision / Watcher's Eye (damage) | 0 | | | | Resolute Technique makes accuracy useless; Purity of Elements has no damage WE mods, Malevolence isn't run |
| Golem swaps / Despair 21 / Herald 21 | Flame -1.8%, Stone -8.2% (+378 phys), Maelström -8.2% / 0 / 0 | | | | keep Chaos Golem 20 |
| Despair on Hit (Hunter ring) with the brand off | -17% vs brand | | chaos res 70 | | the item curse is far weaker than the level 20 gem. Keep Arcanist Brand |
| Lifetap | -17% (VT slot) | | | | mana fixed, but loses a link |

Stat weights on v4 (bosses): +10 DoT multi (any kind) +4.3%; +10% phys as extra chaos +6.3%; +10% attack speed +4.4%;
+10% poison duration +5.3%; +10% additional poison +6.9%; -5 enemy chaos res +4.8%; +30% chaos +5.7%; +10 avg flat
phys/chaos +1.4/+1.5%; +10% curse effect +2.9%; -4 channelling cost +4.3% (Withered); +50 mana regen +4.3%.

## 2. Survivability
| Idea | Life | Phys max hit | Other | DPS | Cost | Fix / note |
|---|---|---|---|---|---|---|
| **Dexterity 18103 → Vigour (+1 max endurance; Ralakesh's counts it full)** | = | **+540** | ele +1,066 | 0 | 0 | 118 points |
| **Granite flask in slot 3 on bosses** (Quicksilver is off there anyway) | = | **+884** while up (21% uptime) | adds a flask window for Master Toxicist | 0 | 0.01 | press it for slams. Basalt: +679 |
| **Infusion** (from Infused Channelling) | = | +1,149 | ele/chaos +16% | +7.5% | 0.43 | while channelling |
| Life Mastery "15% life if no life mods on body" (Bronn's has none) | **+303** for 1 point | +390 | | 0 | 0 | needs a point: Heart of Oak → mastery: net +142 life (loses its conditional 2%/s regen) |
| Profane Chemistry branch (3) → Life15 + Bloodless + shield block mastery | +203 | +323 | **block +8** | 0 | 0 | life flask loses 1 charge / 3 s |
| Bloodless (1 point) | +202 | +260 | | 0 | 0 | needs a point |
| Anoint Discipline and Training / Constitution / Tireless | +283 / +256 / +202 | +364 / +330 / +260 | Tireless: +16 mana/s | -9.8% (loses Fatal Toxins) | 1.25 / 1.49 / 0.52 | one anoint slot |
| Anoint As The Mountain | | | block 63 → 75 | -8.0% vs Fatal Toxins | 0.28 | |
| **Watcher's Eye (Purity: 12% phys taken as fire + 12% as cold)** replacing Venom Eye | -20 | **+1,923 (+19%)**; +2,005 on the package | +5% mana | -4.4% (-4.0% on package) | est 1-3 (thin week-one supply) | a 2-point socket (31683) keeps both jewels instead |
| **Eater gloves boss suppression** | | | 42 → 55-57% | 0 | in the glove cost | |
| **Shield chaos res → +17-22% suppression** (dex shield suffix) | | | 54 → 72% (package) | 0 | est 2-3 | chaos res → 66: needs +9 (Ralakesh's top roll, or a res jewel) |
| Quickstep / Reflexes (2 points) | | | +13 / +14 suppression | | 0 | needs points |
| Spell block: Arcane Guarding / Safeguard anoint | | | 0 → 10% | -8% vs Fatal Toxins | 0.08 / ~0.1 | suppression is the better layer here |
| Poison: armour mastery (bleed immune, helmet armour > evasion) + life flask with the poison-immunity suffix instead "of Sealing" | | | poison handled by the life flask | 0 | 1 point + ~0.05 | Tolerance anoint (30% avoid) costs Fatal Toxins |
| Freeze when Silver is down: Instilling Orb "Used when you become Frozen" on the Silver flask | | | reactive freeze break | | est 0.02 | not modelled; check that the enchant exists in 3.29. The shield mastery "20% avoid elemental ailments" is the 1-point alternative |
| **Imbalanced Guard off** | | 8,395 (-1,561) | | | | IG stays: a 10k hit gets ~44.5% DR with it, under the 50% cap |
| Purity → Determination (with a free +38% res, IG kept) | | 11,038 (+1,082) | | | res fix est 8+ div | Vigour + Granite give more for nothing. Rejected |
| Steelskin (CwDT) | | 12,749 while up | | | | already in the build, PoB keeps it off |
| **Bloodsoaked Blade** (1 point: tinctures inflict Weeping Wounds, 1% life/s per stack, instead of Mana Burn) | | | | | | same ~12-13 s on-time; the drain moves to life. Rejected |

## 3. Fixing PoB's optimistic assumptions
- **Silver / Onslaught (PoB: always on, real ~16%: 6.3 s per 40 charges at 1 charge/s).** Off costs -13.7%. Fixes: belt
  suffixes "35-40% increased flask charges gained" and "10-20% reduced flask charges used" (×1.4/0.8 = ×1.75 uptime if
  "charges gained" also scales Nature's Adrenaline: **risk**), so 16 → 28%: about +1.6% honest DPS. Mageblood makes it
  permanent (beyond budget, +~13% honest). Master Alchemist (halves charge use) can't fit: it sits behind Nature's Boon and
  needs 2 more Pathfinder points, which means dropping Nature's Adrenaline, the only charge source on bosses.
- **Master Toxicist (PoB 100%, real ≈ 55%: life 13%, Silver 16%, Quicksilver / Jade 21% each, staggered):** honest factor
  1.11 / 1.20 = -7.5%. Granite in slot 3 adds a 21% window, and the belt mods above raise every window by ×1.75. Pressing
  the four utility flasks in rotation gives a union of 85-95%, so about +5-6% honest. Whether the tincture counts as a "Flask
  Effect" is still unknown.
- **Tumult stages (PoB fixed at 5):** use **Dash** (0.15 s fixed cast, inside the 400 ms decay window) instead of Flame Dash
  to reposition, and keep channelling (Tumult moves you). Recast Arcanist Brand only between damage phases. Despair-on-hit
  items are 17% weaker. Quicksilver on bosses offsets part of the -50% channelling movement.
- **Withered / Nightshade mana:** after the package, spare mana is +81/s (was +47) and Nightshade lasts 18 s (was 12.6 s)
  before Mana Burn would empty the pool. Turn it off by hand when mana drops below ~30%.

## 4. Recommended package (within the 6-8 div margin), measured together
Fatal Toxins anoint · Infused Channelling for Vile Toxins · ring -3 channelling craft · Weapon Artistry → Strong Arm ·
Dexterity → Vigour · gloves Exarch/Eater (boss chaos DoT 32% / suppression 13%) · amulet chaos DoT 16% instead of
chaos res · Granite in slot 3 (bosses). Also Dash for Flame Dash and the Instilling Orb on the Silver flask (not in PoB).

| | v4 base (honest W) | Package | |
|---|---|---|---|
| Bosses, PoB | 1.731M | **2.678M (+54.7%)** | Silver off: 2.307M |
| Mapping, PoB | 1.157M | **1.580M (+36.5%)** | boss-presence glove mods excluded |
| Bosses, honest (Silver 16%, Toxicist 55%, 3-4 Tumult stages) | ≈ 1.06-1.25M | **≈ 1.64-1.93M** | |
| Life / phys max hit | 5,252 / 9,956 | 5,278 / **12,742** (Infusion; 10,531 without; Granite +~880 when up) | |
| Suppression / block | 42 / 63% | 54 / 59% | -4% block from Weapon Artistry |
| Mana spare / Nightshade on-time | +47/s / 12.6 s | +81/s / 18.2 s | |
| Cost | | **≈ 5-6 div** (0.61 + 0.43 + 0.3 est + 1.5 est + 2-3 est net + 0.05) | Watcher's Eye (+2 est) brings it to 7-8 |

## 5. Ranking within budget (gain per divine, bosses)
**Damage**
| # | Change | Gain | Cost | Per div |
|---|---|---|---|---|
| 1 | Weapon Artistry branch → Strong Arm | +7.5% (block -4) | 0 | free |
| 2 | Anoint Acrimony (or Corruption) | +6.5% (+5.7%) | 0.11 (0.12) | ~59%/div |
| 3 | Vile Toxins → Infused Channelling | +7.5% (+ defence) | 0.43 | 17%/div |
| 4 | Anoint Fatal Toxins (best absolute anoint; one slot) | +9.8% | 0.61 | 16%/div |
| 5 | Gloves Exarch boss chaos DoT + Eater suppression | +13.8% | est 1.5 | ~9%/div |
| 6 | Ring bench -3 channelling cost | +2.5% (+mana safety) | est 0.3 | ~8%/div |
| 7 | Amulet chaos res → chaos DoT 16-20 | +6.9-7.8% | est 2-3 | ~3%/div |
| 8 | Eater "Withered expires slower" instead of suppression | est +4.5% | est 1 | ~4%/div |
| 9 | Ring Hunter poison duration (needs Int) | +7.9% | est 2-4 + Int fix | ~2%/div |
| 10 | Corrupted 21 Added Chaos / Chance to Poison | +3.0 / +1.9% | ~0.1-0.5 (21c, scarce) | high if found |
Not ranked: Ming's Heart (+22.5% for 0.01 div, but -14% life), Cruelty (PoB artefact), Tumult 21c (0.2%/div).

**Defence**
| # | Change | Gain | Cost |
|---|---|---|---|
| 1 | Dexterity 18103 → Vigour | phys +540, ele +1,066 | 0 |
| 2 | Granite in boss slot 3 | phys +884 while up | 0.01 |
| 3 | Infusion (Infused Channelling) | phys +1,149, ele/chaos +16% | 0.43 (counted in damage) |
| 4 | Profane Chemistry branch → Life15 + Bloodless + shield block mastery | +203 life, +8% block | 0 |
| 5 | Heart of Oak → Life mastery 15% (alternative to 4) | +142 life | 0 |
| 6 | Instilling Orb "Used when Frozen" on the Silver flask | freeze break | est 0.02 |
| 7 | Eater boss suppression on gloves | 42 → 55% | in damage #5 |
| 8 | Armour mastery bleed immunity + poison-immunity life flask | poison covered | 1 point + 0.05 |
| 9 | Watcher's Eye 2× phys taken as elemental | phys +16-19%, -4% DPS | est 1-3 |
| 10 | Shield +18 suppression (+9 chaos res fix) | 54 → 72% | est 2-3 |

## 6. Beyond 60 div (on top of the package)
| Step | Change | Gain (PoB) | Cost WEEK1 | Per div |
|---|---|---|---|---|
| **80 div** | Elder Legion Sword with the 3rd prefix "+43-59% DoT multi for poison inflicted with this weapon" (same base stats) | +15.5% (T2 45) / +19.0% (T1 55) | est 15-25 more | ~0.8%/div |
| 80 | Shield +18 suppression + Watcher's Eye if not taken | suppression 72%, phys +16% | est 4-6 | defence |
| 80 | Gloves to T1 (Exceptional): 37% / 15% | +1.7%, suppression +2 | est 4-8 | 0.3%/div |
| **120 div** | Awakened Unbound Ailments 5 | +10.0% | est 20-40 (no ninja price) | 0.3-0.5%/div |
| 120 | Awakened Added Chaos Damage 5 | +8.9% | est 15-30 | 0.3-0.6%/div |
| 120 | Kalandra's Touch reflecting Betrayal's Sting | +16.1% | 8.0 + res fix (lightning 62, Int -11 after Diamond Skin, Weathered Hunter, Hard Knocks) | ~1%/div but -567 life |
| **200 div** | Mageblood (Silver, Granite, Jade, Quicksilver permanent) | PoB -0.5%; **honest ≈ +20-22%** (Onslaught always +13%, Toxicist 100% +8%), Granite always on (phys +~880), permanent freeze immunity | 107 (×3.57 chase) + res fix (belt 45/40 res, 175 life) | ~0.2%/div |
| 200 | Large chaos cluster (8 points) | +7.8% | est 3-8 | low |
| no | Stranglegasp (4 anoints) | +4.1% | ~390 | no |
| no | Tumult 21/20 | +2.2% | 10.7 | 0.2%/div |

## 7. Bloodline ascendancies in 3.29
- **Repo:** `src/TreeData/3_29/tree.lua` has 16 `alternate_ascendancies` (Trialmaster, Oshabi, King in the Mists, Catarina,
  Aul, Lycia, Olroth, Farrul, Delirious, Breachlord, Necromantic, Brinerot, Abyssal, Reliquarian, Luminary, plus the legacy
  ones). PoB removes only Warden, Warlock and Primalist as legacy, so the rest are current in 3.29 data. Web: bloodlines share
  the 8 ascendancy points (2 points, so drop Nature's Boon), and Delirious is unlocked by completing Simulacrum (a real
  hurdle in week one). poedb.tw doesn't resolve in this session (not fetched; it needs allowing).
- **Delirious, "That didn't happen!"** (40% less damage from hits; 4 s later lose 40% of what you took; non-cluster tree
  jewels do nothing; path node +10% life recovery rate). On the package: **phys max hit 12,742 → 17,684 instant**
  (ele 43k, chaos 39k), DPS -9.9% (the two Cobalt jewels go dead, Nature's Boon branch goes), life 5,034. By hand, the delayed
  40% (~2.1k) against ~1.8k of regen and leech in 4 s gives **≈ 16.9k honest (+33%)**. The dead jewels can be sold (eval
  ~7.6 div), which pays for the Elder sword step. PoB parses "from Hits" as all damage taken, so DoT is over-reduced in PoB.
  It's the only fix that lifts the phys max hit over Shaper Slam without a big investment. Watcher's Eye won't work with it.
- **Necromantic Bitter Lash** (Cruelty): supports only gems in the main-hand weapon, and Cyclone sits in Bronn's Lithe, so
  it does nothing. The survey's +40% was wrong.
- **King in the Mists, +1 ring:** needs a "Price": no utility flasks (kills Pathfinder), no amulet, or no belt. Not worth it.
- **Aul:** elemental ailment immunity needs a body armour with no gems. Impossible with the 6-link.
- **Lycia Bitter Heresy:** needs a Consecrated Ground source (none in the build). Not measured again.

## 8. Risks for the mechanics-checker
1. Infused Channelling: when Infusion is gained and lost while channelling (PoB uses a switch), and whether 29% more is unconditional.
2. Does "increased Flask Charges gained" scale Nature's Adrenaline's 3 charges / 3 s?
3. Eldritch "Pinnacle Atlas Boss in your presence": which bosses count (not map bosses).
4. Elder "poison inflicted with this weapon" multi applies to Cyclone's poisons (sword + shield: main hand only).
5. Delirious: delayed life loss with Imbalanced Guard and Steelskin; does the 40% count mitigated damage?
6. Dash's 0.15 s fixed cast vs Tumult's 400 ms stage decay: are stages kept?
7. Instilling Orb "Used when you become Frozen" in 3.29, and whether the Silver flask's freeze immunity removes an existing freeze.
8. Cruelty's real magnitude against a pinnacle boss (I assume ~0).
9. Strong Arm's "increased damage with ailments" with one-handed weapons applies to Cyclone's poison.
10. Withered effect rounding (floor of 6 × effect): PoB shows 9% at 150-169%, 10% at 170% (Corruption).

## Reference builds
No 3.29 Pathfinder poison Cyclone of Tumult build found. 3.29 Cyclone builds are Slayer crit (for example
https://pobarchives.com/build/LG6dEX4g, https://pobarchives.com/build/pnfFTWVy); 3.29 Pathfinder poison is Vaal Blade Vortex
(https://pobarchives.com/builds/KVGTP3y8?arch=spell). Bloodline rules: https://mobalytics.gg/poe/guides/bloodline-ascendancies,
https://www.poe-vault.com/news/2025/10/26/bloodline-ascendancy-reveal-for-path-of-exile-keepers-of-the-flame.
