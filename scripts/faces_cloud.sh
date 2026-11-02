#!/bin/zsh
# Runs People (scripts/faces.py) on GitHub Actions instead of this Mac: free Linux runners, every 6 hours.
# The workflow goes in its own private repo (bottomless-faces) so only you can read its secrets: the app token reaches
# every photo, and anyone with write access to a repo can read that repo's Actions secrets.
#   scripts/faces_cloud.sh deploy          create or update the runner repo and its secrets
#   scripts/faces_cloud.sh run [shards]    start a run now (1-4 parallel index jobs; 4 for a big backlog)
#   scripts/faces_cloud.sh status          recent runs
set -euo pipefail
ROOT=${0:A:h:h}
REPO=${FACES_REPO:-$(gh api user --jq .login)/bottomless-faces}

case ${1:-status} in
  deploy)
    gh repo view $REPO >/dev/null 2>&1 || \
      gh repo create $REPO --private --description "Runs Bottomless People (face grouping) on GitHub Actions" >/dev/null
    T=$(mktemp -d)
    trap 'rm -rf $T' EXIT
    git clone -q https://github.com/$REPO.git $T 2>/dev/null
    mkdir -p $T/scripts $T/.github/workflows
    cp $ROOT/scripts/faces.py $ROOT/faces-runner/state.sh $T/scripts/
    cp $ROOT/faces-runner/requirements.txt $ROOT/faces-runner/README.md $T/
    cp $ROOT/faces-runner/people.yml $T/.github/workflows/people.yml
    cd $T
    git add -A
    if ! git diff --cached --quiet; then
      git commit -qm "Update from bottomless $(git -C $ROOT rev-parse --short HEAD 2>/dev/null || echo local)"
      git branch -M main
      git push -q -u origin main
    fi
    # Piped in, never printed or put on a command line.
    tr -d '\n' < $ROOT/.secrets/api_url | gh secret set BOTTOMLESS_API_URL -R $REPO
    tr -d '\n' < $ROOT/.secrets/app_token | gh secret set BOTTOMLESS_TOKEN -R $REPO
    echo "deployed to https://github.com/$REPO (runs every 6 hours)" ;;
  run)
    gh workflow run people.yml -R $REPO -f shards=${2:-1}
    echo "started; see https://github.com/$REPO/actions" ;;
  status)
    gh run list -R $REPO -w People -L 5 ;;
esac
