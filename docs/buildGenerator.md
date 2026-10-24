This page explains how the build generator works: what it searches, how it scores a build, how it uses several processor cores, and how to measure a change to it. The window is opened from the Build Ideas button ("Generate Build"); the code starts in [`BuildGenerator:Run()`](../src/Classes/BuildGenerator.lua).

#### Scoring
Every decision is made by [`BuildScorer`](../src/Classes/BuildScorer.lua) on PoB's own calculator output, so a build is only as good as PoB says it is.

- **Damage**: the main skill's DPS (combined parts for skills like Kinetic Blast), reduced when the skill can't be paid for in a long fight.
- **Tankiness**: mostly the maximum hit taken of the weakest damage type, then all damage types, a little EHP, and how many times over the build takes the toughest pinnacle (or uber) boss hit.
- **Avoidance**: the share of incoming hit damage the build takes on average (melee, projectile, spell and spell projectile hits) after evasion, dodge, block and spell suppression, with its own weight in every focus. Top players build max block or 100% suppression and value it about as much as doubling their damage; inside EHP it was worth a few % damage.
- **Focus**: the weights of damage and tankiness. "Damage, with a minimum max hit" (`DPS_FLOOR`) is damage first with a 10,000 max hit floor; below the floor every missing bit costs more than damage can pay back.
- **Penalties**: elemental resistances below the cap, missing attributes, reservation over 100% (more the further over), self-damage over time bigger than regeneration, a defence checklist (freeze, shock, bleed, poison, stun...) and drawbacks PoB doesn't calculate ([`GeneratorRules`](../src/Modules/GeneratorRules.lua)).
- **Passives PoB doesn't calculate**: cluster notables whose effect PoB can't read (Fan the Flames' ignite spread, Blast-Freeze, Remarkable's extra brands, Purposeful Harbinger...) get a value for the build ([`GeneratorRules`](../src/Modules/GeneratorRules.lua) `uncountedNodes`): ignite spread is worth a lot to an ignite build without Ignite Proliferation, nothing to a hit build.
- **Smooth play**: only buffs that are always up count in full. Vaal skills and guard skills are switched off, buffs that stay where they are cast (Sigil of Power) aren't used, and a flask that comes and goes counts for less than its average uptime (none below half the time).
- **Flasks**: their real uptime from charges gained and used (a flask that gains no charges while up, from an Enkindling enchantment, is up for its duration then refills); tinctures from their mana burn.

The score is logarithmic in damage and in the max hit, so doubling the damage is worth the same at 1 million as at 100 million.

#### Archetypes
An archetype ([`BuildArchetypes`](../src/Classes/BuildArchetypes.lua)) is what the generator commits to before optimising everything else around it: keystones (crit, Elemental Overload, Resolute Technique, Chaos Inoculation, Avatar of Fire...), auras and supports (Pride + Brutality for impale, Hatred for physical weapons), uniques that scale with a stat (mana, intelligence, strength, dexterity, life) and playstyles (mines, traps, totems). The scan builds a quick version of every archetype that fits the skill; the automatic mode then builds the best three fully and keeps the best one.

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
9. Every affordable unique in every slot, poe.ninja's popular uniques, rare jewels, timeless jewels, Forbidden Flame / Flesh, Watcher's Eye (mods tried in pairs and triples), Split Personality, cluster jewels (Large ones, then Medium or Small ones in the sockets they add), anoint, tattoos.
10. Flasks (unique ones too, Enkindling enchantments), pantheon, bandit, aura stacking (auras chosen with reservation and costs ignored, the tree re-spent, what still can't be paid for dropped), the main link filled, the rares made again for the finished build.
11. Optional: unique / keystone ideas ([`SynergyFinder`](../src/Classes/SynergyFinder.lua)), packages the top players use together, the top players' gear and main link tried in the build, the passives most top players of the class take (read from their PoB codes) allocated as a set with the tree trimmed around them.
12. Ascendancy and supports checked again (each support swapped against every other one), the tree rebuilt with shorter paths ([`TreeOptimizer`](../src/Classes/TreeOptimizer.lua)), then a short second round (aura stacking, supports, ascendancy) on the rebuilt tree.

Every late move is kept only when the full score (with flask uptimes) is better.

Items and gems follow what can be found at the investment level, not only prices: below High investment there are no exceptional gems (Enlighten, Empower, Enhance) and no scarce uniques (Split Personality, Watcher's Eye, Cinderswallow Urn, Forbidden jewels... `PriceSource.scarceUniques`). Gem setups always fit the items' real sockets: uniques with a fixed count (Crest of Desire's single socket) or abyssal sockets pack the setups again, and a main link that no longer fits moves to a 4-link. Items whose granted supports change what a gem does there (traps, totems, triggers: `behaviourSupports`, from `bench/unique_audit.lua`) get no utility setup.

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

#### Measuring a change
The [benchmark](../bench/README.md) generates fixed cases headless and compares them with an earlier run. Because generation is deterministic, two runs of the same code give the same builds, and a difference between two versions is the change's effect on that case (builds are path dependent, so judge a change on several cases). `GEN_OPTS="name=value,..."` switches generator options for A/B runs; `stage_test.lua` runs one step on a saved build; `profile_gen.lua` times every method; `eval_build.lua`, `ablate_build.lua` and `transplant.lua` compare generated builds with top players' builds.
