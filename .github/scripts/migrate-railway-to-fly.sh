#!/bin/sh
set -eu

source_service="${1:-pgvector-railway}"
destination_app="${2:-relay-feir-db}"
destination_database="${3:-agent_social_prod}"
proxy_port="${FLY_DATABASE_PROXY_PORT:-15432}"

migration_tmp_dir="$(mktemp -d)"
dump_file="$migration_tmp_dir/relay.dump"
proxy_log="$migration_tmp_dir/proxy.log"
proxy_pid=""

cleanup() {
  if [ -n "$proxy_pid" ]; then
    kill "$proxy_pid" 2>/dev/null || true
  fi

  if [ -f "$dump_file" ]; then
    unlink "$dump_file"
  fi

  if [ -f "$proxy_log" ]; then
    unlink "$proxy_log"
  fi

  rmdir "$migration_tmp_dir" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

source_vars="$(railway variables --service "$source_service" --json)"
source_user="$(printf '%s' "$source_vars" | jq -r '.POSTGRES_USER')"
source_database="$(printf '%s' "$source_vars" | jq -r '.POSTGRES_DB')"
source_password="$(printf '%s' "$source_vars" | jq -r '.POSTGRES_PASSWORD')"

railway ssh --service "$source_service" -- pg_dump --format=plain --clean --if-exists --no-owner --no-acl --username "$source_user" --dbname "$source_database" >"$dump_file"

if [ ! -s "$dump_file" ]; then
  echo "Railway database dump is empty" >&2
  exit 1
fi

flyctl proxy "$proxy_port:5432" --app "$destination_app" >"$proxy_log" 2>&1 &
proxy_pid="$!"

ready=false
attempt=1

while [ "$attempt" -le 30 ]; do
  if PGPASSWORD="$source_password" pg_isready --host 127.0.0.1 --port "$proxy_port" --username postgres --dbname "$destination_database" >/dev/null 2>&1; then
    ready=true
    break
  fi

  sleep 1
  attempt=$((attempt + 1))
done

if [ "$ready" != true ]; then
  sed -n '1,120p' "$proxy_log"
  exit 1
fi

PGPASSWORD="$source_password" psql --set ON_ERROR_STOP=1 --host 127.0.0.1 --port "$proxy_port" --username postgres --dbname "$destination_database" --file "$dump_file"

PGPASSWORD="$source_password" psql --host 127.0.0.1 --port "$proxy_port" --username postgres --dbname "$destination_database" --tuples-only --no-align --command "SELECT json_build_object('humans', (SELECT count(*) FROM humans), 'content', (SELECT count(*) FROM content_envelopes), 'messages', (SELECT count(*) FROM messages), 'migrations', (SELECT count(*) FROM schema_migrations));"
