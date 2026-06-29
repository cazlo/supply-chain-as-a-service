#!/usr/bin/env python3
"""New-code (diff) coverage gate — a faithful port of the upstream backend
ci.yml "New code coverage gate" step, adapted for the vendored monorepo.

It diffs the working tree against MERGE_BASE, collects the line numbers added
or changed under backend/src/, cross-references lcov.info to compute coverage on
*only those lines*, prints the uncovered ones (to drive iteration), and exits
non-zero when the percentage is below NEW_CODE_MIN (default 70), matching the
gate the reviewer runs. Changes smaller than 10 instrumented lines are exempt,
as upstream does, because the percentage is noisy at that scale.

Env:
  MERGE_BASE      git ref to diff against (required)
  LCOV            path to lcov.info (default /tmp/lcov.info)
  NEW_CODE_MIN    failing threshold, percent (default 70)
  COVERAGE_SCOPE  only count files under this prefix (default artifact-keeper/backend/src/)
  COVERAGE_STRIP  strip this prefix from diff paths to match lcov SF paths
                  (default artifact-keeper/)
"""
import os
import re
import subprocess
import sys

merge_base = os.environ["MERGE_BASE"]
lcov_path = os.environ.get("LCOV", "/tmp/lcov.info")
min_pct = int(os.environ.get("NEW_CODE_MIN", "70"))
scope = os.environ.get("COVERAGE_SCOPE", "artifact-keeper/backend/src/")
strip = os.environ.get("COVERAGE_STRIP", "artifact-keeper/")

# Step 1: added/changed line numbers per file, from a zero-context unified diff.
diff = subprocess.run(
    ["git", "diff", "-U0", merge_base, "--", "*.rs"],
    capture_output=True, text=True, cwd="/work",
).stdout

new_lines = {}  # lcov-comparable path -> set(line numbers)
current = None
for line in diff.split("\n"):
    if line.startswith("+++ b/"):
        path = line[6:]
        # Only gate first-party backend source; tests/ aren't built under --lib
        # and generated/vendored noise must not dilute the signal.
        if path.startswith(scope):
            current = path[len(strip):] if path.startswith(strip) else path
        else:
            current = None
    elif line.startswith("@@") and current:
        m = re.search(r"\+(\d+)(?:,(\d+))?", line)
        if m:
            start = int(m.group(1))
            count = int(m.group(2)) if m.group(2) else 1
            new_lines.setdefault(current, set()).update(range(start, start + count))

if not new_lines:
    print("New code coverage: N/A (no changed backend/src lines)")
    sys.exit(0)

# Step 2: walk lcov, counting hit/miss only for the changed lines.
hit = miss = 0
uncovered = {}
match = None  # (path, lineset)
for line in open(lcov_path):
    line = line.strip()
    if line.startswith("SF:"):
        sf = line[3:]
        match = None
        for f, lns in new_lines.items():
            if sf.endswith(f):
                match = (f, lns)
                break
    elif line.startswith("DA:") and match is not None:
        f, lns = match
        parts = line[3:].split(",")
        lineno, count = int(parts[0]), int(parts[1])
        if lineno in lns:
            if count > 0:
                hit += 1
            else:
                miss += 1
                uncovered.setdefault(f, []).append(lineno)

total = hit + miss
if total == 0:
    print("New code coverage: N/A (no instrumented new lines)")
    sys.exit(0)

pct = hit * 100 // total
print(f"New code coverage: {pct}% ({hit}/{total} changed lines covered)")

if uncovered:
    print("Uncovered changed lines (add --lib unit tests for these):")
    for f, lns in sorted(uncovered.items()):
        rng = ", ".join(str(n) for n in sorted(lns))
        print(f"  {f}: {rng}")

if total < 10:
    print(f"Gate skipped: only {total} instrumented changed lines (<10, noisy).")
    sys.exit(0)

if pct < min_pct:
    print(f"FAIL: new-code coverage {pct}% is below the {min_pct}% threshold.")
    sys.exit(1)

print(f"PASS: new-code coverage {pct}% >= {min_pct}%.")
