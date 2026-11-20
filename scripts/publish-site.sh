#!/bin/zsh
# Publishes site/ (the landing page) to the public repo's gh-pages branch, served by
# GitHub Pages at https://med-abdullah.github.io/attending/.
#
#   ./scripts/publish-site.sh
#
# The first time, turn on Pages for the gh-pages branch (Settings › Pages, or
# gh api -X POST repos/med-abdullah/attending/pages -f "source[branch]=gh-pages" -f "source[path]=/").
set -euo pipefail
cd "${0:A:h}/.."
public=${PUBLIC_REPO:-$HOME/Developer/Attending}
[[ -d "$public/.git" ]] || { print -u2 "No public repo at $public."; exit 1; }
[[ -f site/index.html ]] || { print -u2 "No site/index.html."; exit 1; }
work=$(mktemp -d)
trap 'git -C "$public" worktree remove --force "$work" 2>/dev/null || true; rm -rf "$work"' EXIT
git -C "$public" fetch -q origin gh-pages 2>/dev/null || true
if git -C "$public" rev-parse -q --verify origin/gh-pages >/dev/null; then
  git -C "$public" worktree add -q -B gh-pages "$work" origin/gh-pages
else
  git -C "$public" worktree add -q --orphan -b gh-pages "$work"
fi
find "$work" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
cp -R site/. "$work/"
touch "$work/.nojekyll"
cd "$work"
git add -A
git commit -qm "Landing page" || { print "The site is already up to date."; exit 0; }
git push -q origin gh-pages
print "Published https://med-abdullah.github.io/attending/"
