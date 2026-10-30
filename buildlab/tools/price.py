#!/usr/bin/env python3
"""price.py <name substring> [...]: poe.ninja prices (divines, today's) from the price cache.
Prices are the cheapest listed copy: a low roll. The generator moves them to a league phase
(PHASE: START, WEEK1, MID, LATE) with its own factors."""
import json, os, sys
path = os.environ.get("POB_PRICE_CACHE") or os.path.join(os.path.dirname(__file__), "..", "data", "prices.json")
d = json.load(open(path))
for q in sys.argv[1:]:
    q = q.lower()
    for kind in ("uniques", "gems", "tattoos", "oils"):
        for k, v in (d.get(kind) or {}).items():
            if q in k.lower():
                print(f"{kind[:-1]:7} {v:8.2f}  {k}")
