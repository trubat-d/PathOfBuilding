This page explains how the build generator works: what it searches, how it scores a build, how it uses several processor cores, and how to measure a change to it. The window is opened from the Build Ideas button ("Generate Build"); the code starts in [`BuildGenerator:Run()`](../src/Classes/BuildGenerator.lua).

#### Scoring
Every decision is made by [`BuildScorer`](../src/Classes/BuildScorer.lua) on PoB's own calculator output, so a build is only as good as PoB says it is.

- **Damage**: the main skill's DPS (combined parts for skills like Kinetic Blast), reduced when the skill can't be paid for in a long fight.
- **Tankiness**: mostly the maximum hit taken of the weakest damage type, then all damage types, a little EHP, and how many times over the build takes the toughest pinnacle (or uber) boss hit.
- **Defence targets**: past its target (the max hit: 2.5x the focus's floor; the boss hit: taken twice over; avoidance: half the hit damage avoided) each layer counts for a third, so damage isn't traded for tankiness the build doesn't need.
- **Boss fight**: the pressure between a pinnacle boss's big hits (its regular hits and ground effects, a tenth of its worst hit a second, less what is avoided) against what the build recovers, simulated over a minute: dying before the end costs score. Our Righteous Fire build held 40 seconds; the top players' builds the whole fight.
- **Avoidance**: the share of incoming hit damage the build takes on average (melee, projectile, spell and spell projectile hits) after evasion, dodge, block and spell suppression, with its own weight in every focus. Top players build max block or 100% suppression and value it about as much as doubling their damage; inside EHP it was worth a few % damage.
- **Focus**: the weights of damage and tankiness. "Damage, with a minimum max hit" (`DPS_FLOOR`) is damage first with a 10,000 max hit floor; below the floor every missing bit costs more than damage can pay back.
- **Penalties**: elemental resistances below the cap, missing attributes, reservation over 100% (more the further over), self-damage over time bigger than regeneration, a defence checklist (freeze, shock, bleed, poison, stun...) and drawbacks PoB doesn't calculate ([`GeneratorRules`](../src/Modules/GeneratorRules.lua)).
- **Passives PoB doesn't calculate**: cluster notables whose effect PoB can't read (Fan the Flames' ignite spread, Blast-Freeze, Remarkable's extra brands, Purposeful Harbinger...) get a value for the build ([`GeneratorRules`](../src/Modules/GeneratorRules.lua) `uncountedNodes`): ignite spread is worth a lot to an ignite build without Ignite Proliferation, nothing to a hit build.
- **Smooth play**: only buffs that are always up count in full. Vaal skills and guard skills are switched off, buffs that stay where they are cast (Sigil of Power) aren't used, and a flask that comes and goes counts for less than its average uptime (none below half the time).
- **Flasks**: their real uptime from a simulated fight (used whenever down and charged, charges lost at the maximum, none gained while up with an Enkindling enchantment); tinctures from their mana burn.

The score is logarithmic in damage and in the max hit, so doubling the damage is worth the same at 1 million as at 100 million.

#### Ideas, priorities and learning
- **Ideas from the game data** ([`IdeaMiner`](../src/Classes/IdeaMiner.lua)): uniques whose lines scale with a stat ("per 1% Chance to Block", "per Power Charge", "per 500 Evasion Rating"...) make that stat an idea to stack, scanned like the written archetypes, with the stat lens and the planner's investment in that stat.
- **Learnt priorities** ([`GeneratorLearning`](../src/Modules/GeneratorLearning.lua)): a quick build ranks archetypes by how they start, but a full build gains more over it for some (mines +4.2, physical weapons +3.6) than others (Dexterity stacking +2.2). Archetypes are fully built in the order of quick score + learnt gain + a bonus for little-tried ones (an upper confidence bound, as bandit algorithms use), from the benchmark (`Data/GeneratorPriors.json`) and every automatic generation on the computer (`GeneratorLearning.json` in the user folder).
- **Alternatives**: the automatic mode keeps every idea's full build; those within 1 point of the best are listed and can be opened.
- **Explanation**: each build says what it is built around and what carries it (each part taken out alone: the damage and max hit it would lose).

#### The main skill as used in a fight
PoB shows one skill part at a time and leaves counts like Toxic Rain's overlapping pods at 1. [`SkillProfiles`](../src/Classes/SkillProfiles.lua) sets what a player realistically gets on a pinnacle boss (and while mapping), for about 30 of the most played skills: the part shown (Tornado Shot's combined projectiles, Ball Lightning's bolts in range, Explosive Arrow's sustainable fuses...), the best element (Elemental Hit), counts (3 Toxic Rain pods or Storm Rain beams overlapping, Perforate spikes, Shrapnel Ballista projectiles), parts that add up on one target (Earthquake's impact and aftershock, Kinetic Blast's projectile and 2 explosions, Glacial Cascade's bursts, a third of Spark's possible hits), stacks kept up (Blade Vortex blades), conditions (Cyclone channelled). The assumption is noted in the log ("Main skill as used in a fight"). Boneshatter's trauma is PoB's own sustainable trauma.

#### Archetypes
An archetype ([`BuildArchetypes`](../src/Classes/BuildArchetypes.lua)) is what the generator commits to before optimising everything else around it: keystones (crit, Elemental Overload, Resolute Technique, Chaos Inoculation, Avatar of Fire...), auras and supports (Pride + Brutality for impale, Hatred for physical weapons), uniques that scale with a stat (mana, intelligence, strength, dexterity, life) and playstyles (mines, traps, totems). The scan builds a quick version of every archetype that fits the skill; the automatic mode then builds the best three fully and keeps the best one.

Trigger archetypes ([`TriggerSetups`](../src/Classes/TriggerSetups.lua)) apply to spells that can be triggered: Cast while Channelling (a channelling skill such as Cyclone or Flameblast), Cast On Critical Strike (an attack such as Cyclone, Ice Shot or Power Siphon), Arcanist Brand, and Spellslinger (a wand attack in a link of its own). The spell stays the main skill of the link, with the trigger skill and support linked after it and kept there whatever supports change, so PoB counts its damage at the trigger rate (`Modules/CalcTriggers`). The trigger skill is the one that scores best with the weapons it can use. On quick test builds they score below self-cast (Ice Nova: self-cast 15.55, Cast while Channelling 14.04, Spellslinger 13.80, Arcanist Brand 13.20, Cast On Critical Strike 12.02 without crit investment), as PoB sees them: their worth is mostly playing while moving.

Stat stacking archetypes (Intelligence, Strength, Dexterity, mana, life, energy shield) commit to their stat: while the build is made, the stat counts on its own in the score (a "lens"), so rares, passives, jewels and uniques follow it before the items that pay it back are all in place. The final score leaves the lens out, so archetypes are compared as they are. On a Ball Lightning Intelligence build this doubled the damage of the finished build.

A quick build ranks archetypes by how they start, so the scan also runs the cheap late steps that change the ranking the most (every affordable unique, a Watcher's Eye for the archetype's auras, the supports again). The automatic mode fully builds the best three, and up to five when more start within 0.5 of the best one; archetypes whose quick builds came out the same (one that adds nothing usable) are built once.

#### The pipeline
1. Configuration from what the build does ([`AutoConfig`](../src/Classes/AutoConfig.lua)): charges it generates, ailments it keeps up, conditions it meets.
2. Supports for the main link, one at a time, plus the archetype's and the playstyle's.
3. Passive tree: greedy by score gained per point, with the best candidates re-checked before each pick ("lazy greedy"); masteries as their own candidates; ascendancy and bloodline notables.
4. Item bases, the archetype's uniques.
5. Rare items ([`RareItemGenerator`](../src/Classes/RareItemGenerator.lua)): every mod that can roll on the base is scored alone, then the item is filled one mod at a time; one crafting bench mod; influences and Exarch / Eater implicits by budget.
6. Supports again; curse, aura, guard, movement setups linked like real builds ([`GemSetup`](../src/Classes/GemSetup.lua)).
7. Tree again for the gear.
8. Influenced rares.
9. Every affordable unique in every slot, poe.ninja's popular uniques, rare jewels, timeless jewels, Forbidden Flame / Flesh, Watcher's Eye (mods tried in pairs and triples), Split Personality, jewels that allocate passives in their radius without a path ([`RadiusJewelFinder`](../src/Classes/RadiusJewelFinder.lua): Thread of Hope in every ring size and nearby socket, Intuitive Leap, Impossible Escape for every keystone; each passive in reach valued once, each placement estimated against what a passive point is worth in the build, the best three applied for real with the tree trimmed and refilled), cluster jewels (Large ones, then Medium or Small ones in the sockets they add), anoint, tattoos.
10. Flasks (unique ones too, Enkindling enchantments), pantheon, bandit, aura stacking (auras chosen with reservation and costs ignored, the tree re-spent, what still can't be paid for dropped), the main link filled, the rares made again for the finished build.
11. Unique combos ([`UniqueComboFinder`](../src/Classes/UniqueComboFinder.lua)): the most promising uniques of each gear slot (one at a time, slightly worse ones included) scored two at a time in different slots, and pairs where one unique grants a state (Elusive, Onslaught, Unholy Might, Arcane Surge, Phasing, Adrenaline, Consecrated Ground...) and the other pays off in it ("while Elusive"...) with that state switched on. Pairs gaining more together than apart are applied with the build adapted, and kept only if they beat the same adaptation without them. AutoConfig keeps such a state on when the build has a line granting it reliably (a chance on hit at the main skill's hit rate; from kills only while mapping).
    Optional: unique / keystone ideas ([`SynergyFinder`](../src/Classes/SynergyFinder.lua)), packages the top players use together, the top players' gear and main link tried in the build, the passives most top players of the class take (read from their PoB codes) allocated as a set with the tree trimmed around them.
12. Ascendancy and supports checked again (each support swapped against every other one), the tree rebuilt with shorter paths ([`TreeOptimizer`](../src/Classes/TreeOptimizer.lua)), then a short second round (aura stacking, supports, ascendancy) on the rebuilt tree.

13. Rebuild and repair (large neighbourhood search): the finished build is partly undone and rebuilt, again and again, each round kept only if the build is better: the weakest branches of the passive tree pruned as a whole (10 to 20 points, by score lost per point; they can't grow straight back that round) and the points re-spent; one or two rares made again; two supports chosen again. Rares and passives are also made again in turns before that, until neither gains.

Every late move is kept only when the full score (with flask uptimes) is better. Bought items must gain more the more they cost (up to 0.04 at the investment level's item limit), and resistances or attributes still missing at the end are fixed by swapping a rare's bench craft.

Items and gems follow what can be found at the investment level, not only prices: below High investment there are no exceptional gems (Enlighten, Empower, Enhance) and no scarce uniques (Split Personality, Watcher's Eye, Cinderswallow Urn, Forbidden jewels... `PriceSource.scarceUniques`). Gem setups always fit the items' real sockets: uniques with a fixed count (Crest of Desire's single socket) or abyssal sockets pack the setups again, and a main link that no longer fits moves to a 4-link. Items whose granted supports change what a gem does there (traps, totems, triggers: `behaviourSupports`, from `bench/unique_audit.lua`) get no utility setup.

An Animate Guardian (from High investment, when sockets are free) wears the uniques that buff nearby allies best for the build (Kingmaker, Mask of the Tribunal, Replica Leer Cast, Victario's Flight...): their ally lines become the player's own in a Custom Modifier group of the configuration ("Animate Guardian (generated)"), where PoB counts them. On the Boneshatter test build: Kingmaker and Mask of the Tribunal, +0.16.

Rares follow the budget: below Endgame investment, a rare has only the good natural mods a player can realistically craft or buy for it (3 at League start, 4 at Budget and Mid, 5 at High; plus the bench craft).

The configuration choice "Clearing + bossing" configures and scores the build on a pinnacle boss (damage, the boss fight, max hits: the build opens with that configuration), while what only matters while mapping still counts: clear speed weighs more, and Eldritch implicits are also measured while mapping (killed recently, normal enemies), that score added at a third.

Headhunter's stolen rare modifiers are counted as a typical set (40% increased damage, 20% attack and cast speed, 20% movement speed) behind a configuration switch ("Headhunter: rare modifiers stolen?"): on while mapping, off against a boss. For a build made to clear ("Mapping", "Clearing + bossing", or the clear speed focus) the belt still counts for clear speed while the boss numbers stay without it.

Enemy debuffs the build keeps up are switched on in the configuration like ailments: intimidate, unnerve, blind, maim, hinder, ash, frost, crush, scorch, brittle, sap (a line that inflicts it on hit, with its chance, at the main skill's hit rate), and exposure from Wave of Conviction or Frost Bomb.

Supports that bring a damage source of their own are kept to the main skills they fit: Decay only for chaos skills that aren't attacks, Summon Phantasm only for minion skills (with white gear at the start, Decay's fixed damage beat a weak wand attack and the whole build then scaled Decay), and Culling Strike never (top players get it from another skill that hits). Channelling skills move with Frostblink or Flame Dash, never with a travel skill that stops the channel. The first curse is one that adds damage; Enfeeble, Temporal Chains and Warlord's Mark only come with more curse slots.

Curses are tried on every way to apply them, each with what it costs in play (PoB counts a curse in full however it is applied): Arcanist Brand and casting by hand take time from the main skill, Hextouch on a movement skill only curses what it hits, Blasphemy reserves mana, a mark on Mark On Hit is free for attacks.

#### Several tries
"Tries" generates the same build several times with small differences: from the second try on, the early choices (supports, passives per point, ascendancy, weapon finalists) see each option's gain through a fixed ±15% factor of its own, which sends the search down other paths; the real scores still decide, and the best try is kept. With background threads the tries run at once.

The same inputs always give the same build: passive nodes are walked in id order and equal gains are compared to 1e-9 with fixed tie-breaks (LuaJIT changes the order of `pairs()` from run to run).

#### Several processor cores
[`ParallelGenerator`](../src/Classes/ParallelGenerator.lua) runs work in background threads, each with its own headless Path of Building ([`GeneratorWorker`](../src/Modules/GeneratorWorker.lua)):

- the archetype scan builds several quick builds at once;
- the automatic mode builds the best three archetypes at once;
- "Compare with top players" scores the strongest poe.ninja builds and takes them apart at once;
- with three or more workers (six cores), a generation in the app shares the gear slots out between threads for each pass of rare items.

Each worker holds its own copy of the game data (about 1 GB), so at most 3 run together by default (2 below six cores); `main.generatorWorkers` overrides it. Without background threads (headless runs, inside a worker) everything runs in one thread as before.

#### Tuning
`bench/tune.py` tries generator settings (`GEN_OPTS`: lensWeight, pastTarget, fightWeight, avoidanceWeight, ehpWeight...) on a set of cases and scores every build with the same reference scorer (`bench/rescore.lua`), so settings that change how the search scores can be compared.

#### Measuring a change
The [benchmark](../bench/README.md) generates fixed cases headless and compares them with an earlier run. Because generation is deterministic, two runs of the same code give the same builds, and a difference between two versions is the change's effect on that case (builds are path dependent, so judge a change on several cases). `GEN_OPTS="name=value,..."` switches generator options for A/B runs; `stage_test.lua` runs one step on a saved build; `profile_gen.lua` times every method; `eval_build.lua`, `ablate_build.lua` and `transplant.lua` compare generated builds with top players' builds.

The "Uniques (forced/excluded)" button beside the archetype opens a list where uniques can be excluded (never used: too rare, too expensive, not owned) or forced (equipped early in the slot where they score best, jewels in the nearest free socket, and the build made around them, whatever their price or rules). The choices are kept between sessions (BuildIdeasUniques.json in the settings folder) and also apply to the Build Ideas search. Stranglegasp is excluded unless forced: its value is its four anoints, which have to be found already on it.
