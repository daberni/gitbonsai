#!/bin/zsh
# Builds `GitBonsai Dev.app` and launches it isolated, for checking a change in the real app with a GUI tool (Accessibility tree, screenshots).
# Usage: scripts/launch-dev.sh [--appearance light|dark] [--language en|de] [--default key=value]… [--foreground] [--no-build] [repository]
#   Without a repository it generates a small one: main with a tag, a feature branch merged back and one ahead.
#   The app gets a throwaway home (caches, avatar cache and git configuration live there) and a defaults domain of its own, never the user's: the preferences daemon ignores a changed home, so the script launches a copy of the bundle with its own identifier and deletes that domain afterwards.
#   It starts in the background, without taking the keyboard focus or showing in front; --foreground brings it to the front.
#   Prints the process id, the repository and the home; `kill <pid>` ends it, and the home is removed when the app quits.
set -euo pipefail

root=${0:A:h:h}
appearance=""
language=""
foreground=0
build=1
defaults=()
repo=""
while (( $# )); do
	case $1 in
		--appearance) appearance=$2; shift 2 ;;
		--language) language=$2; shift 2 ;;
		--default) defaults+=("$2"); shift 2 ;;
		--foreground) foreground=1; shift ;;
		--no-build) build=0; shift ;;
		-*) print -u2 "unknown option $1"; exit 2 ;;
		*) repo=${1:A}; shift ;;
	esac
done

app=$root/.build/app/GitBonsai\ Dev.app
(( build )) && $root/scripts/make-app-bundle.sh >/dev/null

home=$(mktemp -d -t gitbonsai-dev)
cat > $home/.gitconfig <<GITCONFIG
[user]
	name = GitBonsai Dev
	email = dev@example.com
[commit]
	gpgsign = false
GITCONFIG

if [[ -z $repo ]]; then
	repo=$home/garden
	git init -q -b main $repo
	g() { HOME=$home GIT_CONFIG_GLOBAL=$home/.gitconfig git -C $repo "$@" }
	print '# Bonsai' > $repo/README.md
	g add -A && g commit -q -m "Plant the seed" && g tag v0.1
	g checkout -q -b feature/leaves
	print 'struct Leaf {\n\tlet color: String\n}' > $repo/Leaves.swift
	g add -A && g commit -q -m "Grow the first leaves"
	g checkout -q main
	print 'A small tree.' >> $repo/README.md
	g commit -q -am "Describe the tree"
	g merge -q --no-ff -m "Merge feature/leaves" feature/leaves
	g checkout -q feature/leaves
	print 'struct Leaf {\n\tlet color: String  \n\tlet size: Int\n}' > $repo/Leaves.swift
	g commit -q -am "Measure the leaves"
	g checkout -q main
fi

# Launch arguments set preferences for this launch only (NSArgumentDomain); the app ignores `-Key value` pairs when it opens folders.
arguments=($repo)
[[ -n $appearance ]] && arguments+=(-AppleInterfaceStyle ${(C)appearance})
[[ -n $language ]] && arguments+=(-AppleLanguages "($language)")
for pair in $defaults; do arguments+=("-${pair%%=*}" "${pair#*=}"); done

# A copy with its own bundle identifier keeps its preferences apart from the installed and the dev app.
bundle_id=app.gitbonsai.dev.check-${home:t:e}
copy=$home/GitBonsai\ Check.app
cp -R $app $copy
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" $copy/Contents/Info.plist
codesign --force --sign - $copy 2>/dev/null

open_options=(-n)
(( foreground )) || open_options+=(-g)
open $open_options --env HOME=$home --env CFFIXED_USER_HOME=$home --env GIT_CONFIG_GLOBAL=$home/.gitconfig $copy --args $arguments

# `open` returns before the app is up; its process is the newest one of the bundle.
pid=""
for _ in {1..50}; do
	pid=$(pgrep -n -f "$copy/Contents/MacOS/GitBonsai" || true)
	[[ -n $pid ]] && break
	sleep 0.1
done
[[ -n $pid ]] || { print -u2 "GitBonsai Dev did not start"; exit 1 }

# The home and the defaults domain go away with the app.
( while kill -0 $pid 2>/dev/null; do sleep 2; done; defaults delete $bundle_id; rm -f ~/Library/Preferences/$bundle_id.plist; rm -rf $home ) >/dev/null 2>&1 &!

print "pid:        $pid"
print "repository: $repo"
print "home:       $home"
print "defaults:   $bundle_id"
print "traces:     /usr/bin/log stream --level debug --predicate 'subsystem == \"app.gitbonsai\"'"
print "quit:       kill $pid"
