#!/usr/bin/env bash
# Runs `firebase deploy` for one target list, asserting on the exact argument
# array it then executes. Needs FIREBASE_BIN and PROJECT_ID in the environment.
set -euo pipefail

targets="${1:?usage: run_deploy.sh <comma-separated targets>}"
project="schedulingapp-88727"

args=(deploy --project "$PROJECT_ID" --non-interactive --only "$targets")

has_project=0
has_non_interactive=0
for i in "${!args[@]}"; do
  case "${args[$i]}" in
    *--force*)
      echo "::error::A deploy command contains --force. It deletes every prod TTL policy missing from firestore.indexes.json (all five were lost this way on 2026-07-21). Never."
      exit 1
      ;;
    --non-interactive) has_non_interactive=1 ;;
    --project) [ "${args[$((i + 1))]}" = "$project" ] && has_project=1 ;;
  esac
done
if [ "$has_non_interactive" -ne 1 ]; then
  echo "::error::A deploy command lacks --non-interactive; a prompt would hang the run."
  exit 1
fi
if [ "$has_project" -ne 1 ]; then
  echo "::error::A deploy command does not name --project $project."
  exit 1
fi

echo "+ firebase ${args[*]}"
exec "$FIREBASE_BIN" "${args[@]}"
