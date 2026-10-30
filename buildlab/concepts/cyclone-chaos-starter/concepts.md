# Cyclone chaos league starter: concepts (3.29, 60 div, WEEK1)

Prices: `buildlab/tools/price.py` (Allflame snapshot, cheapest copy). WEEK1 factor in
`PriceSource.lua` is about x1.2 for items under 1 div. So every core unique below costs under 0.5 div.
Most of the 60 div goes to the 6-link, rare gear (life, suppression, res) and gem levels.
Ruled out: Replica Alberon's Warpath (50.6 div now, chase curve, more than 100 div at week one).
Also ruled out: Pathfinder's Master Distiller (Amethyst: 37% phys as extra chaos). It only works
for *Non-Channelling* skills (3.29 tree text), and Cyclone is channelling.

## A. Occultist: converted chaos hits with Withered (hit)
- **Core**: Cyclone hits converted to chaos. Withering Presence gives 15% more chaos damage,
  +60% chaos res, and Withers nearby enemies every second for 15 s, so stacks build with no
  on-hit roll (good on bosses). Void Beacon: nearby enemies -20% chaos res.
  Unholy Authority: two curses (Despair + Punishment or Enfeeble).
  Profane Bloom: cursed enemies explode for chaos damage (clear).
- **Chaos source**: Replica Innsbury Edge (1H Elder Sword, req 47, 0.02 div): 50% phys converted
  to chaos, Withered on hit. Withering Touch support: 21% phys as extra chaos at gem level 20.
  Ming's Heart (0.01 div): 40-60% phys as extra chaos, but -25% life and -25% ES.
  Treat Ming's as an option for the bossing stage, not a must.
- **Links**: Cyclone, Withering Touch, Void Manipulation, Melee Physical Damage,
  Close Combat, then Fortify or Increased Area. Auras: Herald of Agony, Determination,
  Despair on a curse setup.
- **Scaling**: phys and melee mods apply before conversion, plus chaos mods. Gain-as-chaos is
  taken from phys before conversion. PoB will see this if Withered stacks are set in Config.
  PoB will NOT see the Profane Bloom explosions.
- **Defence**: life with a shield (block). Vile Bastion is weak on a life build, so skip it.
  Chaos res is capped for free. Armour from Determination, a Granite flask, a Life flask.
  Little suppression is reachable from Witch.
- **Levelling**: Witch to act 2 with any melee skill (Frost Blades or Splitting Steel with
  a sceptre or sword). Cyclone from level 28, Withering Touch from 38, Innsbury from 47.
- **Risks**: Witch start is far from the melee clusters (pathing cost). The weapon is a Heist
  replica, so week-one supply is uncertain. Does Innsbury's conversion apply globally, or only to
  that weapon when dual-wielding? Use a shield to avoid the question. Withering Presence ramp time.
- **Refs**: [3.23 Chaos Cyclone Occultist](https://www.poebuilds.cc/poe1/build/sVHvBc-NZr4),
  [Innsbury Cyclone PoB](https://pobarchives.com/build/bTak6bbt),
  [fastaf chaos cyclone](https://mobalytics.gg/poe/builds/fastaf-chaos-cyclone).

## B. Assassin: crit poison Cyclone (crit ailment)
- **Core**: crit poison. Toxic Delivery: 20% more poison on crit, plus poison duration.
  Infused Toxins (Assassination Style option): all damage from hits can poison.
  Mistwalker: Elusive on crit and no extra crit damage taken. Shadowed Blood: unaffected by
  damaging ailments, 40% phys taken recouped.
- **Key items**: Arakaali's Fang (0.24 div; 200% phys, 1-59 chaos, 40% global crit chance,
  15% poison chance). Or a rare crit dagger with flat phys, used dual-wield or with a shield.
  Cospri's Will (0.01): always poison on hit against cursed enemies, frees affixes.
- **Links**: Cyclone, Unbound Ailments, Critical Strike Affliction, Deadly Ailments,
  Void Manipulation, Withering Touch (Withered raises poison damage too).
  Auras: Malevolence, Herald of Agony, Precision or Grace.
- **Scaling**: poison chance to 100%, crit, attack speed (more poison stacks), DoT multi,
  poison duration. PoB shows poison DPS from a configured stack count. It will NOT see
  Herald of Agony virulence ramping, or the duration ramp from Toxic Delivery being up all the time.
- **Defence**: evasion and spell suppression (Shadow has the suppression wheel), Elusive,
  life. Weak on low gear until crit is built up.
- **Levelling**: Viper Strike or Cobra Lash with poison, then Cyclone at 28.
  Crit is poor until about level 70 and an Arakaali's Fang.
- **Risks**: Assassination Style choice in 3.29. Does Infused Toxins add enough over a
  physical/chaos base? How well does poison stack under Cyclone's per-hit damage?
- **Refs**: no dedicated poison Cyclone Assassin found for 3.26-3.29. The closest is a
  [3.27 Poison CoC Assassin with Cyclone](https://pobarchives.com/build/LG6dEX4g),
  which is a different engine.

## C. Pathfinder: non-crit poison with Withered (no-crit ailment)
- **Core**: non-crit poison. Nature's Reprisal: 25% chance to Wither on hit, 50% increased
  Withered effect (15 stacks then give 135% increased chaos taken, which scales poison).
  Master Toxicist: 20% chance for 100% more poison damage, poison spreads on kill during flasks.
  Nature's Adrenaline gives flask uptime. Master Surgeon keeps the life flask always on.
- **Key items**: Replica Innsbury Edge (100% Withered on hit, 50% conversion so
  chaos poison is the base) or a flat-phys rare 1H sword or claw.
  Ming's Heart optional. Atziri's Promise or an Amethyst flask.
- **Links**: Cyclone, Unbound Ailments, Deadly Ailments, Void Manipulation, Withering Touch,
  Melee Physical Damage. Auras: Malevolence, Herald of Agony.
- **Scaling**: flat phys and chaos, poison chance, attack speed, DoT multi, Withered effect.
  PoB averages Master Toxicist. Withered stacks must be set in Config.
- **Defence**: life, suppression from Ranger, evasion. Flasks for sustain
  (Master Surgeon life flask, Jade/Granite). Chaos res from Amethyst.
- **Levelling**: Ranger with any physical melee skill, Cyclone from 28, Withering Touch from 38,
  Innsbury from 47. The best low-gear defence, because the flasks are up all the time.
- **Risks**: Does Nature's Reprisal's Withered effect apply to Withered from the weapon or
  the gem? Does Master Toxicist need a flask active? (Nature's Adrenaline should cover it.)
- **Refs**: none found for Pathfinder poison Cyclone in 3.26-3.29.

## Recommendation
**C (Pathfinder poison)** as the league starter. It has the safest low-gear defence (flasks that
stay up, life flask always on), no crit to build, and the core costs almost nothing. Withered and
poison both scale on bosses. **A (Occultist hit)** has the higher hit-damage ceiling and the best
boss Withered uptime: use it as the alternative or a respec target. **B** needs gear (crit) before
it comes online.

## For the mechanics-checker
1. Master Distiller excludes channelling skills (Cyclone).
2. Is Replica Innsbury Edge's conversion local to the weapon (dual-wield)?
   Does its Withered stack with Withering Touch and Nature's Reprisal effect?
3. Withering Presence: one Withered stack per second, so 15 s to max?
4. 3.29 Herald of Agony and Infused Toxins behaviour.
5. Gain-as-extra-chaos (Ming's, Withering Touch) taken from phys before conversion.
