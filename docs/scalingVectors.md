### Damage scaling vectors (notes for the build doctor, from poewiki.net)

The build doctor (Classes/BuildDoctor.lua) splits a main skill's damage into
the layers below, measures how far each is invested and what more of it would
bring, and tries to balance them: the layers multiply, so the weakest one has
the most to give.

#### The goal: crazy builds from math and own knowledge
Top players' builds (poe.ninja) are a measuring stick, not an ingredient: the
generator must reach their level from the game's math and what it learns from
its own generations. Everything that uses player data can be switched off with
the generator option `playerKnowledge = false` (their archetype, mined unique
packages, layer targets; poe.ninja meta was already opt-in), and progress is
measured in that mode: generate with it off, compare with the players.
What carries the build without them:
- the layers above, measured on the build itself (test doses, full commitments for layers that only pay together, caps);
- enablers found in the game data (mods that add a layer, scale with a stackable stat, remove a drawback, turn one stat into another);
- what earlier generations learnt (which plans paid off for which kind of skill), accumulated by the data generation runs.

#### Damage modes
- **Hit** (attack / spell / secondary): (base + added x effectiveness) x increased x more x crit x speed x (1 - resistance) x damage taken.
- **Direct damage over time** (skill DoTs: Righteous Fire, Essence Drain, Vortex, Death Aura...): base (often a share of life / ES for RF) x increased (generic, damage over time, the type) x more x (1 + DoT multiplier) x (1 - resistance) x damage taken. No crit, no speed (except via duration / stacking), no conversion, no added damage, attack / spell increases don't apply (unless the skill says so).
- **Ailments from hits** (ignite, bleed, poison): base = the flat damage of the hit (base + added, after conversion), never the hit's increased / more for attacks / spells; scaled by Damage, Damage over Time, the element / type, the ailment's own increases, DoT multiplier of the DoT's type, "faster" ailments. Crit: always ignites, +50% DoT multiplier for ailments from crits (not the crit multiplier, unless Perfect Agony); Elemental Overload removes that bonus. Resistance penetration, lucky, double damage, attack / spell / melee / area damage don't apply.
  - Ignite: 90% of the fire base per second for 4 s, doesn't stack (the strongest one deals damage; Emberwake: up to 3). Duration only matters for uptime.
  - Bleed: 70% of physical per second for 5 s (210% while moving / aggravated), one stack (Crimson Dance: 8 stacks of 35%).
  - Poison: 30% of physical + chaos per second for 2 s, stacks without limit: DPS = per-poison DPS x poisons alive (rate of hits x duration). Duration and hit rate scale it (unlike ignite).
- **Total DoT on one enemy is capped at about 35.8 million per second** (2^31-1 / 60), after the enemy's damage taken: past it, more DoT is worthless (only hits or a second enemy).

- **Righteous Fire** (direct DoT): deals 70% of maximum life + 70% of maximum ES as base fire damage per second; burns you for 90% of life + 70% of ES per second: life and ES are its base damage (the "added damage" layer is the pool), so a RF build stacks maximum life (% increased and "more" maximum life: Blood Magic's 10% more, life masteries) and regeneration to survive the burn. Scaled by damage, fire, elemental, area, DoT, burning damage, fire DoT multiplier, -fire resistance (Flammability, exposure, Ramako's -20% while stationary), fire damage taken; not by spell damage (its "more spell damage" buff is for other spells: Fire Trap, Fireball, Scorching Ray). Can't be used with Chaos Inoculation. Capped by the DoT cap.

#### Layers
- **Increased** (additive): one pool; each more % is worth less as the pool grows (diminishing).
- **More** (multiplicative): each is a separate multiplier.
- **Added / flat**: for hits, x the skill's damage effectiveness; for ailments, the base they're computed from (very strong for ailment builds); never for skill DoTs.
- **DoT multiplier**: one additive pool, independent of increased / more; only the DoT's own damage type.
- **Crit** (hits only): chance = (base + additional) x (1 + increased) x more, capped at 100%; base is the weapon's (attacks) or the gem's (spells: 5-10%, e.g. Winter Orb / Ethereal Knives 10%). Additional (flat) chance comes before increases: Assassin's Mark, Increased Critical Strikes, brittle, Seething Fury. Multiplier: 150% base (50% extra), the extra damage only on crits; expected factor = 1 + chance x (multiplier - 1). The two multiply: neither pays alone (5% chance with x3 = 1.1; 90% with x5 = 4.6). Ailments from crits get +50% DoT multiplier instead (Perfect Agony: the crit multiplier); Elemental Overload: no crit multiplier and no crit ailment bonus. Critical strike rolls once per use (most skills): crit is all-or-nothing per cast.
- **Enemy resistance** (hits and DoT): damage x (1 - resistance). Bosses have high elemental resistances (pinnacle 50% elemental, 30% chaos in PoB's boss setup); lowered by curses (Frostbite, Flammability, Conductivity, Elemental Weakness...), exposure (-10% base; Elementalist +25%, masteries / items extra), "reduced resistances", Ramako (-20% fire vs DoT while stationary); floor -200%. Each point of resistance removed is worth more the lower it already is? No: from 50% to 0% is x2, from 0 to -50% only x1.5 (linear in the remaining 1 - res).
- **Penetration** (hits only, never DoT or ailments): applied after reductions, can go past -200%; Inevitable Judgement ignores resistance on crits. Inversion (Invert the Rules, Rakiata's Dance...) multiplies capped resistance by -1: strong against high resistances, harmful against negative ones.
- **Conversion / gain as extra** (hits; ailments through their base): order physical -> lightning -> cold -> fire -> chaos, never backwards; gain as extra is computed on the source before it is converted away and adds damage (a multiplier on the whole pool: 30% physical as extra cold = x1.3 before other scaling); converted damage keeps every type it went through, so increases to any of them apply ("double dipping" the increased pool, not more multipliers). Over 100% conversion is scaled down (skill conversion first). The extra damage then gets the new type's own penetration, curses, exposure: conversion lets an elemental layer stack onto a physical skill.
- **Curses**: one curse by default (more: Whispers of Doom, Occultist, Doedre's Damning, Cospri's Will, amulet implicit, Anathema = max power charges...); marks: one per target and one mark per player. Curse effect = added x (1 + increased - reduced) x more: curse effect scales every curse at once. Damage curses: elemental resistance (Frostbite / Flammability / Conductivity -res, Elemental Weakness), damage taken (Despair chaos / DoT, Vulnerability physical / ailments), crit (Assassin's Mark: extra crit chance and multiplier). A second curse slot is a whole extra layer for any build.
- **Damage taken by the enemy** (one more multiplier for everything the enemy takes, hits and DoT of that type): shock (up to 50% by default, strongest only, from lightning hits relative to the ailment threshold: about 25M lightning damage for 50% on Sirus; non-damaging sources 15%; "shocks always increase damage taken by at least X%"; shock effect raises it toward the maximum, maximum shock effect raises the cap), wither (chaos taken, stacks up to 15 x 6%), intimidate / unnerve (attack / spell), Vulnerability / Despair curses, Sap...
- **Added damage effectiveness**: added flat damage on hits is multiplied by the skill's effectiveness (Ball Lightning 60%, Blade Vortex 30%, Discharge 600%, Ethereal Knives ~230%, Arc 120%): flat damage is strong for high-effectiveness skills, weak for fast multi-hit ones. Gain as extra is not affected by it.
- **Impale** (physical attacks): each impale records 10% of the hit's physical damage before mitigation and deals it on the next 5 hits; with 5 stacks x 10% = 50% of the hit added (more with max impales +1, impale effect). Scales only with the hit's physical damage and impale effect; armour applies when dealt (ignored with the mastery / Poacher's Mark / Crushed). A separate layer for physical attacks, worth most for fast hitters.
- **Exposure**: per element, only the strongest applies (-10% by default; Scorching Ray -25%, Frost Bomb / Wave of Conviction -15%, Elemental Equilibrium -25%), stacks with curses and penetration ("exposure you inflict applies an extra -X%": Elementalist, masteries): a separate resistance layer from curses, so an elemental build wants curse + exposure + penetration together.
- **Withered**: +6% chaos damage taken per stack, up to 15 (x1.9 at 15), each stack its own 2 s duration; effect only in steps of 16.67%. Chaos hits and poison / chaos DoT.
- **Culling strike** (hits only): kills at 10% life or less (Headsman 20%, Eternal Struggle 15%), bosses included: worth about x1.11 boss DPS (x1.25 at 20%); DoT can't cull.
- **Poison specifics**: one stack per hit (chance above 100% is worthless; Lethal Dose / Betrayal's Sting add stacks copying the first one's DPS); from physical + chaos by default; each part scaled by its own type's increases (physical, elemental...) plus chaos / poison / DoT; only chaos DoT multiplier; mitigated only by chaos damage taken. Crits don't poison by themselves. Duration (poison duration, ailment duration, Temporal Chains) multiplies the stacks alive; "faster" changes DPS per stack but not the total.
- **Explosions** (on kill / corpses): secondary damage from the monster's maximum life, scaled by global (not attack / spell) stats, 0% base crit unless the skill's; they can carry ailments (an explosion that ignites makes a huge ignite from monster life): a clear layer, nothing against a single boss.
- **Speed**: more hits per second for hits and for stacking ailments (poison: stacks alive = hits x duration); ignite / bleed (one stack) only need enough hits to keep the strongest one up, so speed adds little to them; skill DoTs (RF) don't use it.
- **Caps to respect**: crit chance 100%, poison / ignite chance 100%, total DoT on one enemy ~35.8M per second (PoB caps each ailment, not the sum of RF + ignite + burning ground), negative resistance -200% (penetration goes past it), shock 50% by default.

#### Resources: what the pools are spent on (mana, life, reservation)
- **Mana is a budget with competing uses**: unreserved for Mind over Matter (part of hits taken from mana), or reserved for auras (each aura a damage or defence layer: Zealotry / Wrath / Hatred / Anger / Malevolence / Pride, Determination / Grace / Discipline / Purity...). For most builds, reserving the mana for auras gives more than MoM: MoM only looks good one step at a time because the mana it uses is still unreserved. Mana stackers are the exception: their damage needs a big unreserved pool (Archmage, "per X mana", Indigon), so they keep MoM and run auras without reservation (Divine Blessing) or on life (Blood Magic, life reservation).
- **Keystones that empty a pool make others useless**: Blood Magic / Eternal Youth (no mana) with Mind over Matter; Chaos Inoculation (1 life) with life nodes or Righteous Fire.
- The doctor compares whole plans for a pool ("MoM + free mana" vs "auras reserving it, MoM dropped, points re-spent"), not single nodes.

#### What the experiments showed (Winter Orb, best player 28.3M vs ours 6.0M)
- The gap is a product of layers: enemy multiplier x2.1 (Frostbite, exposure, 37% penetration, shock, chill), crit x1.45, increased x1.35, speed x1.31 (`BuildDoctor:Profile`, `bench/layer_profiles.lua`).
- Each layer comes from cheap sources picked together: crit multiplier on every rare jewel (+288%), penetration notables (+26%), the right curse, golems, a shock source. Given only those, our build went 17.49 -> 18.18 (the player: 18.25).
- Those sources pay off only inside the right design basin: power charge stacking (Tulfall + Ralakesh's Impatience), crit (chance and multiplier), one defence pool (Chaos Inoculation and energy shield). A one-at-a-time search can't reach a basin that needs several commitments at once, and patching a finished build can't rebuild it.
- `BuildDoctor:PredictCombos` finds the basin from the math and the game data: each idea tested in its full form on a build (a stacking idea with the payoff and enabler lines of its best uniques), combinations scored as the product of their parts. Winter Orb: power charges with Tulfall + Ralakesh's Impatience x1.96, crit x1.91, together x3.75. The automatic mode builds the best combinations from scratch.
- Commitment lenses steer, they must not decide: three lenses at full weight made a build that looked like 17.3 and was 14.9; forced crit supports pushed the main link's more multipliers out (x2.3 vs x10.6). Lenses now fade (half after the second rares, gone before the finishing steps), and plans and moves are judged on the real score.

#### Where the remaining gap was (Winter Orb, measured by hybrid builds)
Hybrids of our best pure build and the top player's (tree + tree jewels, gear,
gem links, level swapped in every combination; Shapley shares of log DPS, the
player's hand-set shock removed): the player x2.4, of which gear x1.74, tree
x1.33, links x1.01. Item by item, the gear share is Tulfall (adds cold damage
per power charge, frenzy charge on reaching maximum; x0.58 without it) and
Badge of the Brotherhood (frenzy charges = power charges; x0.68 without it);
in the tree, six rare jewels of four crit multiplier mods (x1.06 each), Bitter
Frost (x1.21: chill effect as cold damage taken), +1 maximum power charge
notables (x1.21 each, since every charge feeds Tulfall, Badge, Malachai's Loop).
What hid them from the generator (all fixed):
- **Couplings through the configuration**: charges an item generates were only
  switched on when AutoConfig ran, so pieces were tested without them.
- **A binding constraint as a hard cut**: a build at the edge of its mana saw
  speed (frenzy charges) as a loss and mana recovery as worthless until
  something needed it. While the build is made, the shortfall is priced at the
  cost of the recovery (a Lagrangian relaxation); the end judges on the cut.
- **Values that grow with the build**: chill (and Bitter Frost) scale with the
  hit size, so the keystone was worthless early, and timeless jewels conquered
  it before it paid; jewels made for the half-built tree.

#### Reaching the top players (Winter Orb, pure mode)
Scored the same way (eval_build: same scorer, uber boss, a player's states held
by hand cleared and AutoConfig run): the top three players 18.12 / 20.9M DPS,
18.05 / 15.0M, 15.90 / 12.8M; our power + crit builds, made without any player
data at the players' median cost, 18.34 / 13.3M (level 92) and 18.40 / 12.0M
(level 100). What it took, past the layers above:
- **Every channel priced against the others**: a jewel socket against the
  passives it costs (clusters judged with rare jewels in the sockets they
  add); a resistance from a passive against an affix tier or a jewel mod
  (RequirementsToGearMove); a unique jewel against the rare it displaces.
- **The configuration following every test**: charges an item generates, a
  piece that keeps charges at maximum (budget fitting threw out Ralakesh's
  Impatience, worth +0.02 alone and 1.1 in the build).
- **Gear made again after the last tree changes**: the rares made for an
  earlier tree held back the finished build by ~0.4.
- **Rollbacks that restore everything**: a trial that remade the rares and was
  undone left slots empty.
- **Kill speed as a defence**: the defence term counts the fight's length
  (boss life / DPS, at least 8 s).

#### A mid-tier guide build (Pohx's Righteous Fire, loadout {8})
A guide build at level 95 for about 79 divines, no chase item: 16.14 / 3.38M
DPS with its own configuration, 15.05 / 1.16M under ours. The difference was
one condition: **stationary**. Chieftain's Ramako ("Nearby Enemy Monsters'
Fire Resistance against Damage over Time is -20% while you are Stationary")
and Rational Doctrine (Consecrated Ground while stationary) were worth x2.3,
and the generator never counted them (AutoConfig assumed stationary only for
channelled skills). Now:
- **A boss is fought standing in place, but not all the time**: a build with
  "while stationary" lines is calculated stationary and its damage blended
  with the damage it keeps while moving, for the share of the fight the fight
  simulation spends moving and dodging (BuildScorer:Evaluate). Pohx under our
  scoring: 15.79 / 2.36M.
- **Mid-tier as an option** (options.midTier, the Uniques window's "No chase
  uniques"): no Mageblood, Headhunter, Pearl of Tsoatha, Forbidden jewels...
  (PriceSource.chaseUniques) and no unique over 30 divines; with a total
  budget it is the level of a player without the league's top items.
- **A second damage skill when the hands are free**: Righteous Fire, totems
  and persistent minions take no action time, so another skill that scales
  off the same layers adds to them (Pohx's Fire Trap; Scorching Ray found by
  the generator: +108% on our RF). Measured bare, the best few with their own
  supports and their own cost checked, kept in a 4-link if the whole build
  scores better (SecondaryDamageMove). Never for a cast or attack main skill:
  PoB's full DPS would count both as used all the time.

#### Every fully built build kept (loadouts)
A generation that fully builds several builds (tries, archetypes in
parallel) keeps them all in the opened build as loadouts (Modules/
BuildLoadouts): tree, item set, skill set and configuration set with the same
"{n}" tag, each with the configuration it was scored with; bench/
merge_loadouts.lua merges files and checks every loadout calculates as its
source did.

#### Spending the budget, and where a generation spends its time
- **The total budget is spent, not only respected**: the level is the one
  whose rares fit six times in the total (80 divines: High), and the fit only
  took parts away, so a mid-tier build ended at 47 of its 80 divines. The rare
  gear slots are now made at the next level and kept by score per extra
  divine while under the total (SpendBudgetMove: 47 -> 74 div, +0.20).
- **Profile** (bench/profile.lua, PROFILE=1; a 3186 s mid-tier RF): half the
  time is the 100,000 quick scores (16 ms each, PoB's calculation), the rest
  in the steps that remake rares (FinalRares ~100 s a call), the tree
  (AllocateTree, RefineTree) and the build doctor's plans (both kept: they
  gain 0.1-0.6). Supreme Ostentation took 24% for a jewel it never kept: its
  baseline is now made only when a trial wins, and a trial stops after the
  tree when the rares can't make it a gain. PoB's environment reuse
  (accelerate flags) was no faster for node trials and not exact: not used.

#### Self damage (Boneshatter)
PoB counts the trauma stacks the attack rate keeps up - 120 on a fast
Boneshatter - and each hit then deals its user damage per stack: 12,316 a hit
against 5,313 life, yet the build scored 34M DPS. The self damage of a skill
(SelfHitDamage: trauma, Scold's Bridle, Heartbound Loop...) is now a life
cost per use in the sustain check, and AutoConfig holds trauma at what the
recovery pays for (self damage per second at most the life recovery, one hit
at most 40% of the pool). The top players' builds leech enough to keep theirs
(19.29 / 65M); with it the generator builds for the recovery: mid-tier 18.69 /
15.6M at 80 div, 19.17 / 26.9M at 292 div, level with the best player's 19.16
(same scoring, 297 div).

#### Builds made around one unique, and commitments that stay kept
The top Cyclone of Tumult players (150-420M DPS) build around Voidforge
("Gain 700% of Weapon Physical Damage as Extra Damage of a random Element"):
with Overwhelm (8% base crit for weapon attacks, a Slayer notable), Masterful
Form and 65% crit x6.3. Every part swapped alone into our build scored below
it: the generator never finds such a design one step at a time.
- **Anchors** (IdeaMiner.Anchors): uniques with one line far above an affix
  ("as Extra Damage" from 100%, "more Damage" from 40%) the skill can use
  are ideas of their own, the unique forced from the start.
- **A kept commitment stays kept**: a crit commitment blocks the keystones
  that undo it (Elemental Overload, Resolute Technique), as passives and as
  keystone tattoos - the first Voidforge build committed to crit, then took
  Elemental Overload as a tattoo and ended at 7% crit.
- **A commitment takes what it needs**: crit for a weapon below 8% base crit
  takes Overwhelm.
Mid-tier Cyclone of Tumult: 18.59 / 17.5M (claw) -> 18.91 / 23.8M built
around Voidforge, 75% crit x5.5 (Flicker Strike: 18.27, below its 18.39).

#### The configuration a build is made with is the one it is judged with
A mid-tier Righteous Fire scored 17.0 with the configuration the generator
left it and 10.5 from a blank one (the fair evaluation): its burn was paid by
Consecrated Ground's regeneration, switched on by AutoConfig while a passive
gave it and put back by a snapshot after the passive was gone. Endurance
charges (AutoConfig switched charges on, never off) and Phasing (left from a
pair of uniques tried) the same. AutoConfigure now starts from a blank set of
conditions, buffs, multipliers, overrides and charges every time, as the
evaluation does: the generator's score and the fair one agree (16.64 / 16.64,
16.42 / 16.42), and charges an item seems to give that AutoConfig doesn't
confirm stay off until it runs again. (Also: PoB's tree undo state dropped
the bloodline - secondaryAscendClassId read from a field never set.)

#### What a player would build, not what the boss numbers like most
- Eldritch implicits: the base lines; the "while a Unique Enemy / Pinnacle
  Atlas Boss is in your Presence" versions only when asked (Boss implicits):
  a build mostly clears maps.
- Expedition flasks (Iron Flask's ward) only for a build with a ward pool of
  its own: expensive, and 200 ward is not a reason.
- A rare keeps its base's implicit (a Void Sceptre's elemental damage), and
  its lines read prefixes, suffixes, crafted.
- A cluster jewel's arm (the third notable, a small passive) is left
  unallocated when the tree spends the point better; a Large one's sockets
  are tried with Medium clusters, not only the build's rare jewel.
- The generation log, its assumptions, the configuration switched on and the
  Animate Guardian's items are written in the build's notes, so a shared
  link (pobb.in) shows what was assumed.
