#!/usr/bin/env python3
"""Showcase builds left out of everything learnt or measured from players.

Some poe.ninja builds are made to show a DPS number, not to be played: a
billion DPS with 1 life and no energy shield, uncapped resistances, a max hit
any boss slam exceeds, buffs held by hand in the configuration. Mined
archetypes, unique packages, layer targets and the parity benchmark take only
playable builds: a build is a showcase when any of these holds (from the
stats PoB saved in the code, PlayerStat):

- its smallest maximum hit taken is below MIN_HIT (4,000);
- its total effective HP is below MIN_EHP (10,000);
- its pool (life + energy shield + ward) is below MIN_POOL (2,000);
- its DPS is more than OUTLIER times the median of the same skill's builds
  while its defences are thin (max hit below twice MIN_HIT or EHP below
  2.5 times MIN_EHP): a number made to be shown.
(Resistances are not checked: some builds run below 0 on purpose - minion
builds, Petrified Blood, Chaos Inoculation with chaos, life recovery
builds - and their max hit already says whether they survive.)

    python3 bench/playable.py <codes folder>     # lists the showcase builds and why

Used by mine_archetypes.py, mine_packages.py, layer_targets.py and
pro_parity.py (their --keep-showcase flag turns it off).
"""
import base64
import math
import os
import re
import statistics
import sys
import zlib
from collections import defaultdict

MIN_HIT = 4000
MIN_EHP = 10000
MIN_POOL = 2000
OUTLIER = 10


def decode(path):
    code = open(path).read().strip().replace("-", "+").replace("_", "/")
    return zlib.decompress(base64.b64decode(code + "=" * (-len(code) % 4))).decode("utf-8", "replace")


def stats_from_xml(xml):
    out = {}
    for name, value in re.findall(r'<PlayerStat stat="([^"]*)" value="([^"]*)"', xml):
        try:
            out[name] = float(value)
        except ValueError:
            out[name] = math.inf if value == "inf" else None
    return out


def dps_of(stats):
    return max(stats.get("FullDPS") or 0, stats.get("CombinedDPS") or 0, stats.get("TotalDPS") or 0)


def reasons(stats, median_dps=None):
    """Why a build is a showcase (empty: playable). Missing stats are not held against it."""
    why = []
    hits = [stats.get(k) for k in ("PhysicalMaximumHitTaken", "FireMaximumHitTaken", "ColdMaximumHitTaken",
                                   "LightningMaximumHitTaken", "ChaosMaximumHitTaken")]
    hits = [h for h in hits if h is not None]
    if hits and min(hits) < MIN_HIT:
        why.append("max hit %d" % min(hits))
    ehp = stats.get("TotalEHP")
    if ehp is not None and ehp < MIN_EHP:
        why.append("EHP %d" % ehp)
    if "Life" in stats or "EnergyShield" in stats:
        pool = (stats.get("Life") or 0) + (stats.get("EnergyShield") or 0) + (stats.get("Ward") or 0)
        if pool < MIN_POOL:
            why.append("pool %d" % pool)
    dps = dps_of(stats)
    thin = (hits and min(hits) < 2 * MIN_HIT) or (ehp is not None and ehp < 2.5 * MIN_EHP)
    if median_dps and dps > OUTLIER * median_dps and thin:
        why.append("DPS %.3g, %.0fx the skill's median, with thin defences" % (dps, dps / median_dps))
    return why


def survey(paths, skill_of):
    """{path: reasons} for code files, with each skill's median DPS for the outlier rule"""
    stats = {}
    for p in paths:
        try:
            stats[p] = stats_from_xml(decode(p))
        except Exception:
            stats[p] = {}
    by_skill = defaultdict(list)
    for p, s in stats.items():
        d = dps_of(s)
        if d > 0:
            by_skill[skill_of(p)].append(d)
    medians = {k: statistics.median(v) for k, v in by_skill.items() if v}
    return {p: reasons(s, medians.get(skill_of(p))) for p, s in stats.items()}


def skill_from_file(path):
    return os.path.basename(path).rsplit("__", 1)[0].replace("_", " ")


def showcase_set(folder):
    paths = [os.path.join(folder, f) for f in os.listdir(folder) if f.endswith(".txt")]
    found = survey(paths, skill_from_file)
    return {os.path.basename(p): why for p, why in found.items() if why}


def main():
    folder = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("CODES", "/home/claude/ninja/codes")
    bad = showcase_set(folder)
    total = len([f for f in os.listdir(folder) if f.endswith(".txt")])
    for f, why in sorted(bad.items()):
        print(f"{f}: {', '.join(why)}")
    print(f"{len(bad)} of {total} builds are showcases")


if __name__ == "__main__":
    main()
