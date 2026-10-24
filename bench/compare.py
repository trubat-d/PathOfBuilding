"""Prints a benchmark results file as a table, compared with the previous one.
    python3 bench/compare.py results/<label>.jsonl [results/<other>.jsonl]
"""
import json
import os
import sys


def load(path):
    rows = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            r = json.loads(line)
            key = (r["skill"], r["ascendancy"], r["investment"], r["mode"], r.get("archetype") or "")
            rows[key] = r
    return rows


def previous_file(path):
    folder = os.path.dirname(os.path.abspath(path))
    files = sorted(
        (os.path.join(folder, f) for f in os.listdir(folder) if f.endswith(".jsonl")),
        key=os.path.getmtime,
    )
    files = [f for f in files if os.path.abspath(f) != os.path.abspath(path)]
    return files[-1] if files else None


def fmt(n):
    if n is None:
        return "-"
    n = float(n)
    if n >= 1e6:
        return f"{n / 1e6:.2f}M"
    if n >= 1e3:
        return f"{n / 1e3:.1f}k"
    return f"{n:.0f}"


def main():
    cur = load(sys.argv[1])
    prev_path = sys.argv[2] if len(sys.argv) > 2 else previous_file(sys.argv[1])
    prev = load(prev_path) if prev_path else {}
    if prev_path:
        print(f"Compared with {os.path.basename(prev_path)}")
    print(f"{'case':<46} {'score':>14} {'DPS':>16} {'min hit':>14} {'EHP':>14} {'sustain':>7} {'s':>4}")
    total = 0.0
    for key in sorted(cur):
        r = cur[key]
        name = f"{key[0]} / {key[1]} / {key[2]}" + (f" / {key[4]}" if key[4] else "")
        if "error" in r:
            print(f"{name:<46} ERROR {r['error'][:80]}")
            continue
        p = prev.get(key)

        def delta(field, as_score=False):
            v = r.get(field)
            if not p or p.get(field) is None or v is None:
                return fmt(v) if not as_score else f"{v:.2f}"
            if as_score:
                return f"{v:.2f} ({v - p[field]:+.2f})"
            change = (v / p[field] - 1) * 100 if p[field] else 0
            return f"{fmt(v)} ({change:+.0f}%)"

        if p and "score" in p:
            total += r["score"] - p["score"]
        print(f"{name:<46} {delta('score', True):>14} {delta('dps'):>16} {delta('minHit'):>14} {delta('ehp'):>14} {r.get('sustain', 0):>7.2f} {r.get('seconds', 0):>4}")
        if r.get("penalties"):
            for label in r["penalties"]:
                print(f"{'':<6}- {label}")
    if prev:
        print(f"Total score change: {total:+.2f}")


if __name__ == "__main__":
    main()
