#!/usr/bin/env bash
# Creates a repository stopped in a merge with three conflicts, for trying the conflict view:
# Sources/Greeter.swift (text: two conflicts, one with a long line, and one line both sides changed in different words, for the word merge), config.txt (changed on main, deleted on feature) and icon.png (binary, changed on both).
# Usage: scripts/make-conflict-repo.sh <target-dir>
set -euo pipefail
target="${1:?target dir}"
rm -rf "$target"
mkdir -p "$target/Sources"
cd "$target"
git init -q -b main
git config user.name "Conflict Demo"
git config user.email "demo@example.com"
git config commit.gpgsign false
git config core.autocrlf false
commit() { git add -A && git commit -q -m "$1"; }

greeter() {
    cat > Sources/Greeter.swift <<EOF
import Foundation

struct Greeter {
    $3

    func greeting() -> String {
        "$1"
    }

    func farewell() -> String {
        "$2"
    }

    func shout() -> String {
        greeting().uppercased()
    }
}
EOF
}

greeter 'Hello, \(name)!' 'Goodbye, \(name).' 'let name: String'
printf 'Config\nretries = 3\n' > config.txt
printf '\x89PNG\x00\x01base' > icon.png
commit "Add greeter"

git switch -q -c feature
greeter 'Hi there, \(name)!' 'See you, \(name).' 'var name: String'
git rm -q config.txt
printf '\x89PNG\x00\x02feature' > icon.png
commit "Friendlier greeter"

git switch -q main
greeter 'Hello, \(name), welcome! It is a pleasure to have you here today, and we hope your stay is as pleasant as it can be.' 'Farewell, \(name).' 'let name: String = ""'
printf 'Config\nretries = 5\n' > config.txt
printf '\x89PNG\x00\x03main' > icon.png
commit "Formal greeter"

if git merge feature >/dev/null 2>&1; then
    echo "The merge did not stop on conflicts." >&2
    exit 1
fi
git status --short
