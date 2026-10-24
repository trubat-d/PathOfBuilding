This page explains how the build generator works: what it searches, how it scores a build, how it uses several processor cores, and how to measure a change to it. The window is opened from the Build Ideas button ("Generate Build"); the code starts in [`BuildGenerator:Run()`](../src/Classes/BuildGenerator.lua).

#### Scoring
Every decision is made by [`BuildScorer`](../src/Classes/BuildScorer.lua) on PoB's own calculator output, so a build is only as good as PoB says it is.

- **Damage**: the main skill's DPS (combined parts for skills like Kinetic Blast), reduced when the skill can't be paid for in a long fight.
- **Tankiness**: mostly the maximum hit taken of the weakest damage type, then all damage types, a little EHP, and how many times over the build takes the toughest pinnacle (or uber) boss hit.
- **Focus**: the weights of damage and tankiness. "Damage, with a minimum max hit" (`DPS_FLOOR`) is damage first with a 10,000 max hit floor; below the floor every missing bit costs more than damage can pay back.
- **Penalties**: elemental resistances below the cap, missing attributes, reservation over 100% (more the further over), self-damage over time bigger than regeneration, a defence checklist (freeze, shock, bleed, poison, stun...) and drawbacks PoB doesn't calculate ([`GeneratorRules`](../src/Modules/GeneratorRules.lua)).
- **Flasks**: their real uptime from charges gained and used; tinctures from their mana burn.

The score is logarithmic in damage and in the max hit, so doubling the damage is worth the same at 1 million as at 100 million.

#### Archetypes
An archetype ([`BuildArchetypes`](../src/Classes/BuildArchetypes.lua)) is what the generator commits to before optimising everything else around it: keystones (crit, Elemental Overload, Resolute Technique, Chaos Inoculation, Avatar of Fire...), auras and supports (Pride + Brutality for impale, Hatred for physical weapons), uniques that scale with a stat (mana, intelligence, strength, dexterity, life) and playstyles (mines, traps, totems). The scan builds a quick version of every archetype that fits the skill; the automatic mode then builds the best three fully and keeps the best one.

A quick build ranks archetypes by how they start, so the scan also runs the cheap late steps that change the ranking the most (every affordable unique, a Watcher's Eye for the archetype's auras, the supports again).

#### The pipeline
1. Configuration from what the build does ([`AutoConfig`](../src/Classes/AutoConfig.lua)): charges it generates, ailments it keeps up, conditions it meets.
2. Supports for the main link, one at a time, plus the archetype's and the playstyle's.
3. Passive tree: greedy by score gained per point, with the best candidates re-checked before each pick ("lazy greedy"); masteries as their own candidates; ascendancy and bloodline notables.
4. Item bases, the archetype's uniques.
5. Rare items ([`RareItemGenerator`](../src/Classes/RareItemGenerator.lua)): every mod that can roll on the base is scored alone, then the item is filled one mod at a time; one crafting bench mod; influences and Exarch / Eater implicits by budget.
6. Supports again; curse, aura, guard, movement setups linked like real builds ([`GemSetup`](../src/Classes/GemSetup.lua)).
7. Tree again for the gear.
8. Influenced rares.
9. Every affordable unique in every slot, poe.ninja's popular uniques, rare jewels, timeless jewels, Forbidden Flame / Flesh, Watcher's Eye (mods tried in pairs and triples), Split Personality, cluster jewels, anoint, tattoos.
10. Flasks (unique ones too), pantheon, bandit, aura stacking, the main link filled, the rares made again for the finished build.
11. Optional: unique / keystone ideas ([`SynergyFinder`](../src/Classes/SynergyFinder.lua)), packages the top players use together, the top players' gear and main link tried in the build.
12. Ascendancy and supports checked again (each support swapped against every other one), the tree rebuilt with shorter paths ([`TreeOptimizer`](../src/Classes/TreeOptimizer.lua)), then a short second round (aura stacking, supports, ascendancy) on the rebuilt tree.

Every late move is kept only when the full score (with flask uptimes) is better.

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
