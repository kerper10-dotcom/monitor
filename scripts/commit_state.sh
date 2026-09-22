#!/usr/bin/env bash
# Commita njuskalo.db i saved_ads.json. Ako se dva joba sudare, spoji baze.
set -euo pipefail
cd "$(dirname "$0")/.."

git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
if [ -n "${GH_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
  git remote set-url origin "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
fi
git fetch origin main
# checkout@v4 na ovom repou već radi -B main. Ako je HEAD ipak detached, vrati ga na main
# bez diranja izmjena u radnom stablu.
if [ "$(git rev-parse --abbrev-ref HEAD)" = "HEAD" ]; then
  git checkout -B main
fi

git add njuskalo.db saved_ads.json
if git diff --staged --quiet; then
  echo "No DB/saved_ads changes to commit"
  exit 0
fi
git commit -m "Update njuskalo.db and saved_ads.json [skip ci]"

resolve_conflict() {
  if [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; then
    python3 scripts/merge_state.py
    git add njuskalo.db saved_ads.json
    GIT_EDITOR=true git rebase --continue || return 1
    return 0
  fi
  return 1
}

for attempt in 1 2 3 4 5; do
  if git pull --rebase --autostash origin main; then
    if git push origin HEAD:main; then
      exit 0
    fi
    echo "push odbijen, pokušaj ${attempt}"
  elif resolve_conflict; then
    echo "rebase konflikt spojen, pokušaj ${attempt}"
  elif git rev-parse --is-shallow-repository | grep -qx true; then
    echo "plitki clone, dohvaćam povijest"
    git fetch --unshallow origin main || git fetch --depth=200 origin main
  else
    echo "pull nije uspio, pokušaj ${attempt}"
  fi
  sleep $((attempt * 3))
done

echo "commit_state: push nije uspio"
exit 1
