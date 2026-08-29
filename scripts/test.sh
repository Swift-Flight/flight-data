#!/usr/bin/env bash
#
# Runs the full suite, integration tests included, against throwaway servers.
#
# The integration suites skip without a database, and a skipped suite is not a
# passing one — this package's whole value is what it proves against real
# infrastructure. Rather than asking a contributor to read CONTRIBUTING and
# assemble the right environment, this starts what is needed, runs everything,
# and cleans up.
#
#   ./scripts/test.sh                 # everything
#   ./scripts/test.sh --filter Foo    # arguments pass through to swift test
#
# Set FLIGHT_KEEP_SERVERS=1 to leave the containers running between runs.
#
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v docker >/dev/null; then
  echo "docker is needed to start the test servers." >&2
  echo "Already have servers? Export FLIGHT_POSTGRES_TEST_DATABASE_URL="postgres://postgres:flight@127.0.0.1:$pg_port/flight_test" (and friends) and run swift test directly." >&2
  exit 1
fi

pg_name="flight-test-postgres"
vk_name="flight-test-valkey"
pg_port=${FLIGHT_TEST_PG_PORT:-55498}
vk_port=${FLIGHT_TEST_VALKEY_PORT:-56398}

# The outage suites stop and start a server mid-test, so they get their own
# throwaway containers rather than the shared ones. Their ports and names are
# pinned in the test sources (PostgresOutageServer, OutageServer) because the
# tests drive `docker stop`/`docker start` themselves.
#
# These were previously gated on variables nothing ever set, which meant the
# only coverage of the pool-wedge fix — the bug that turns a blip into an
# outage lasting until someone restarts the pod — never ran.
pg_outage_name="flight-postgres-outage"
vk_outage_name="flight-valkey-outage"
pg_outage_port=55499
vk_outage_port=56399

cleanup() {
  if [ "${FLIGHT_KEEP_SERVERS:-0}" != "1" ]; then
    docker rm -f "$pg_name" >/dev/null 2>&1 || true
    docker rm -f "$vk_name" >/dev/null 2>&1 || true
    docker rm -f "$pg_outage_name" >/dev/null 2>&1 || true
    docker rm -f "$vk_outage_name" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

start() { # name image port args...
  local n="$1" image="$2" port="$3"; shift 3
  if docker ps --format '{{.Names}}' | grep -qx "$n"; then return; fi
  docker rm -f "$n" >/dev/null 2>&1 || true
  docker run -d --name "$n" -p "$port" "$@" "$image" >/dev/null
}

echo "── starting servers"
start "$pg_name" postgres:16-alpine "$pg_port:5432" \
  -e POSTGRES_PASSWORD=flight -e POSTGRES_DB=flight_test
start "$vk_name" valkey/valkey:8-alpine "$vk_port:6379"
start "$pg_outage_name" postgres:16-alpine "$pg_outage_port:5432" \
  -e POSTGRES_PASSWORD=flight -e POSTGRES_DB=flight_test
start "$vk_outage_name" valkey/valkey:8-alpine "$vk_outage_port:6379"

echo "── waiting for postgres"
for _ in $(seq 1 60); do
  docker exec "$pg_name" pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 1
done
docker exec "$pg_name" pg_isready -U postgres >/dev/null 2>&1 || {
  echo "postgres did not become ready" >&2; exit 1; }

# Valkey needs the same wait. It usually wins the race against a Swift build,
# but "usually" is how a suite becomes intermittently red for reasons nobody
# can reproduce.
echo "── waiting for valkey"
for _ in $(seq 1 60); do
  docker exec "$vk_name" valkey-cli ping 2>/dev/null | grep -q PONG && break
  sleep 1
done
docker exec "$vk_name" valkey-cli ping 2>/dev/null | grep -q PONG || {
  echo "valkey did not become ready" >&2; exit 1; }

echo "── waiting for the outage servers"
for _ in $(seq 1 60); do
  docker exec "$pg_outage_name" pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 1
done
docker exec "$pg_outage_name" pg_isready -U postgres >/dev/null 2>&1 || {
  echo "the outage postgres did not become ready" >&2; exit 1; }
for _ in $(seq 1 60); do
  docker exec "$vk_outage_name" valkey-cli ping 2>/dev/null | grep -q PONG && break
  sleep 1
done
docker exec "$vk_outage_name" valkey-cli ping 2>/dev/null | grep -q PONG || {
  echo "the outage valkey did not become ready" >&2; exit 1; }

export FLIGHT_POSTGRES_TEST_DATABASE_URL="postgres://postgres:flight@127.0.0.1:$pg_port/flight_test" FLIGHT_MIGRATE_TEST_DATABASE_URL="postgres://postgres:flight@127.0.0.1:$pg_port/flight_test" FLIGHT_VALKEY_TEST_URL="redis://127.0.0.1:$vk_port"
export FLIGHT_POSTGRES_OUTAGE_TEST=1 FLIGHT_VALKEY_OUTAGE_TEST=1
echo "── running the suite"
./CI/run-tests.sh "$@"
status=$?
exit $status
