---
name: build-concept
description: Runs the multi-agent build workflow (theorycrafter, mechanics-checker, pob-builder, economist, critic) to turn a Path of Exile build request or idea into a checked Path of Building build. Use when the user asks to create, adapt, cost or review a build concept.
---

# Build concept workflow

You are the lead. You coordinate the agents in `.claude/agents/`; you do not do their jobs
yourself. Keep the user in the loop at the two decision points marked **ASK**.

## 0. Brief
Turn the request into a brief and write it to `buildlab/concepts/<slug>/brief.md`:
skill or idea, class/ascendancy if fixed, budget (divines) and league phase (default: 30 div,
WEEK1), content (league start, mapping, bossing), constraints (no Mageblood, SSF...).
Run `buildlab/tools/setup.sh` once if `luajit` is missing.

## 1. Concepts
Ask the **theorycrafter** for 2-3 concepts (or to adapt the user's idea / a pobb.in link).
**ASK** the user which concept to build, unless they said to pick.

## 2. Check the mechanics
Send the concept's risky interactions to the **mechanics-checker**. A WRONG on a core
interaction sends you back to step 1. Note what PoB does not model.

## 3. Build
Have the **pob-builder** assemble it (reference build -> `improve.sh`, or `generate.sh` with the
key uniques forced) and evaluate it. In parallel, the **economist** prices it.

## 4. Review and iterate (at most 2 rounds)
The **critic** reviews the build with the mechanics-checker's notes and the economist's prices.
Send the fixes back to the pob-builder (and the economist if the budget moved). Stop after two
rounds or when the critic says playable.

## 5. Deliver
Write `buildlab/concepts/<slug>/final.md`:
- the concept in 3-4 lines, the pobb.in link (`buildlab/tools/pobb.sh`) or the PoB code,
- DPS, max hit per damage type, life/ES, block/suppression, cost range,
- what PoB does not show and its estimated effect,
- the critic's remaining warnings,
- the upgrade path (next 3 purchases).
**ASK** the user if they want another iteration or a variant.

## Usage
Agent work uses your plan's usage quickly. Keep runs small: one concept built at a time, quick
generator mode for drafts, full mode only for the final version.
