#!/usr/bin/env bash
# Creates a synthetic repository with many commits, parallel branches and merges for graph benchmarks.
# Usage: scripts/make-synthetic-repo.sh <target-dir> [commit-count] [branch-count]
set -euo pipefail
target="${1:?target dir}"
count="${2:-100000}"
branches="${3:-8}"
rm -rf "$target"
mkdir -p "$target"
git -C "$target" init -q -b main
python3 -I - "$count" "$branches" <<'PY' | git -C "$target" fast-import --quiet
import sys
count, branches = int(sys.argv[1]), int(sys.argv[2])
out = sys.stdout
mark = 0
heads = {}  # branch name -> mark
def commit(branch, parents, msg, i):
    global mark
    mark += 1
    out.write(f"commit refs/heads/{branch}\n")
    out.write(f"mark :{mark}\n")
    out.write(f"author Dev {i % 7} <dev{i % 7}@example.com> {1700000000 + i * 60} +0000\n")
    out.write(f"committer Dev {i % 7} <dev{i % 7}@example.com> {1700000000 + i * 60} +0000\n")
    data = msg.encode()
    out.write(f"data {len(data)}\n{msg}\n")
    if parents:
        out.write(f"from :{parents[0]}\n")
        for p in parents[1:]:
            out.write(f"merge :{p}\n")
    content = f"line {i}\n".encode()
    out.write(f"M 644 inline file{i % 50}.txt\ndata {len(content)}\n")
    out.write(content.decode())
    out.write("\n")
    heads[branch] = mark
    return mark
commit("main", [], "Initial commit", 0)
for i in range(1, count):
    b = f"feature/{i % branches}" if i % 10 else "main"
    if b not in heads:
        commit(b, [heads["main"]], f"Start {b}", i)
        continue
    # every 97th commit on a feature branch merges main in, every 500th commit merges the branch back
    if b != "main" and i % 97 == 0:
        commit(b, [heads[b], heads["main"]], f"Merge main into {b}", i)
    elif b == "main" and i % 500 == 0:
        fb = f"feature/{(i // 500) % branches}"
        if fb in heads:
            commit("main", [heads["main"], heads[fb]], f"Merge {fb}", i)
        else:
            commit("main", [heads["main"]], f"Commit {i}", i)
    else:
        commit(b, [heads[b]], f"Commit {i} on {b}", i)
PY
git -C "$target" commit-graph write --reachable --quiet 2>/dev/null || true
echo "$(git -C "$target" rev-list --all --count) commits in $target"
