#!/bin/sh
set -eu

service_name="${1:?usage: deploy-railway-service.sh SERVICE SOURCE_PATH [TIMEOUT_SECONDS]}"
source_path="${2:?usage: deploy-railway-service.sh SERVICE SOURCE_PATH [TIMEOUT_SECONDS]}"
timeout_seconds="${3:-1800}"

: "${RAILWAY_PROJECT_ID:?RAILWAY_PROJECT_ID is required}"
: "${RAILWAY_ENVIRONMENT:?RAILWAY_ENVIRONMENT is required}"
: "${RAILWAY_TOKEN:?RAILWAY_TOKEN is required}"

previous_deployment_ids="$(
  railway deployment list \
    --project "$RAILWAY_PROJECT_ID" \
    --environment "$RAILWAY_ENVIRONMENT" \
    --service "$service_name" \
    --limit 100 \
    --json | jq -c 'map(.id)'
)"

# Railway projects linked at the monorepo root otherwise upload the Phoenix
# Dockerfile for nested services. Always make the requested path the archive root.
railway up "$source_path" \
  --path-as-root \
  --project "$RAILWAY_PROJECT_ID" \
  --environment "$RAILWAY_ENVIRONMENT" \
  --service "$service_name" \
  --message "GitHub Actions ${GITHUB_SHA:-manual}" \
  --detach \
  --yes

deadline="$(( $(date +%s) + timeout_seconds ))"
deployment_id=""
last_status=""

while [ "$(date +%s)" -lt "$deadline" ]; do
  deployments="$(
    railway deployment list \
      --project "$RAILWAY_PROJECT_ID" \
      --environment "$RAILWAY_ENVIRONMENT" \
      --service "$service_name" \
      --limit 10 \
      --json
  )"

  if [ -z "$deployment_id" ]; then
    deployment_id="$(
      printf '%s' "$deployments" |
        jq -r --argjson previous "$previous_deployment_ids" \
          '[.[] | select(.id as $id | $previous | index($id) | not)][0].id // ""'
    )"
  fi

  if [ -n "$deployment_id" ]; then
    status="$(
      printf '%s' "$deployments" |
        jq -r --arg deployment_id "$deployment_id" \
          '.[] | select(.id == $deployment_id) | .status'
    )"

    if [ "$status" != "$last_status" ]; then
      printf '%s: %s\n' "$service_name" "${status:-waiting}"
      last_status="$status"
    fi

    case "$status" in
      SUCCESS)
        if [ -n "${GITHUB_OUTPUT:-}" ]; then
          printf 'deployment_id=%s\n' "$deployment_id" >>"$GITHUB_OUTPUT"
        fi
        exit 0
        ;;
      FAILED|CRASHED|REMOVED|CANCELLED|CANCELED|SKIPPED)
        railway logs "$deployment_id" \
          --project "$RAILWAY_PROJECT_ID" \
          --service "$service_name" \
          --environment "$RAILWAY_ENVIRONMENT" \
          --deployment \
          --lines 200 || true
        printf '%s deployment %s ended with %s\n' \
          "$service_name" "$deployment_id" "$status" >&2
        exit 1
        ;;
    esac
  fi

  sleep 5
done

printf 'Timed out waiting for %s after %s seconds\n' \
  "$service_name" "$timeout_seconds" >&2
exit 1
