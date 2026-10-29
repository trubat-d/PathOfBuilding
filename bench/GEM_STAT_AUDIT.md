# Gem stats PoB doesn't calculate (audit, 2026-10-29)

`bench/unmapped_stats.lua` (run from `src`) lists every gem stat with no entry in
PoB's stat map: those stats do nothing in PoB's numbers, so the generator, which
judges every gem by PoB's numbers, saw no value in them. 116 supports and 483
active gems have at least one; most are display, animation, targeting or
duration-of-a-buff-PoB-sets-by-config stats. The ones that change what a build is
worth, and what was done:

| Gem | Stat | Effect | Now |
|---|---|---|---|
| Returning Projectiles | projectiles_return, returning damage less | the way back hits the target again after piercing it (poewiki Return), 66% less; pierces all on the way back | CalcOffence `ReturnHitMultiplier` (pierce chance x return damage), clear term +1.5 projectiles; not for Tornado Shot, Spark, Winter Orb, Forbidden Rite or ProjectileCannotReturn skills |
| Fire Trap of Blasting, trap quality | trap_%_chance_to_trigger_twice | 50% (or quality) chance of a second detonation | mapped to DPS MORE for traps |
| Awakened Brutality / Controlled Destruction / Melee Physical Damage | 10% chance to crush / unnerve / intimidate on hit | debuffs that raise damage taken | AutoConfig turns the enemy condition on from the gem's chance and the hit rate |
| Melee Splash, Ancestral Call, Spell Cascade (all versions) | splash / extra targets / extra cascades | clear only (single target unchanged) | clear term area factor |
| Mind over Matter (not a gem) | degen taken from mana | a Righteous Fire's burn empties mana; MoM's pool and mana for skills are gone | scorer: drained MoM pool left out of max hit / EHP, the mana share of the burn lands on life, mana degen taken from skill sustain |

Already handled elsewhere (stat unmapped but PoB or the generator counts the
effect through a configuration or another stat): Arcane Surge, Cruelty, Trinity
(resonance), Inspiration (righteous charges), Fortify, Momentum, Close Combat,
Intensify / Pinpoint / Overloaded Intensity, Withering Touch, Maim, Blind, Power
Charge On Critical, Double Strike (skill dpsMultiplier), trap / mine / totem
flags.

Not modelled (clear, minions or rare triggers; small for the generator's boss +
clear score): Annihilation, Behead, Chain range, Greater Fork's chance, Kinetic
Instability, Living Lightning, Hiveborn, Foulgrasp, Windburst, Manaforged Arrows
trigger chance, Summon Phantasm, Feeding Frenzy, Gluttony's Disgorge, Hex Bloom,
Coursing Current, Charged Traps / Mines charges, Ice Bite, Culling Strike's life
on cull, proliferation radii.
