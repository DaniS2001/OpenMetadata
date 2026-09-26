#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 <fixture.tar.zst> <openmetadata-distribution.tar.gz> [ingestion-image.tar.zst]" >&2
  exit 2
fi

fixture_path=$(realpath "$1")
distribution_path=$(realpath "$2")
ingestion_image_path=${3:+$(realpath "$3")}
workspace_root=${GITHUB_WORKSPACE:-$(pwd)}

# Connector targets for the AutoPilot specs (see docker-compose-playwright-fast.yml).
# Their images are ~2 GB, so on ingestion shards start pulling them now, in
# parallel with fixture extraction and stack startup; pulling them serially later
# pushed startup past the caller's 5-minute limit.
connector_images=(
  "${PW_CONNECTOR_MYSQL_IMAGE:-mysql:8.0.44@sha256:9c3380eac945af0736031b200027f581925927c81e010056214a4bd6b6693714}"
  "${PW_CONNECTOR_KAFKA_IMAGE:-confluentinc/cp-kafka:7.6.0}"
  "${PW_CONNECTOR_SCHEMA_REGISTRY_IMAGE:-confluentinc/cp-schema-registry:7.6.0}"
  "${PW_CONNECTOR_METABASE_IMAGE:-metabase/metabase:v0.52.8}"
)
connector_pull_pids=()
if [[ -n "$ingestion_image_path" ]]; then
  for connector_image in "${connector_images[@]}"; do
    docker pull --quiet "$connector_image" >/dev/null 2>&1 &
    connector_pull_pids+=("$!")
  done
fi
runtime_root="/dev/shm/openmetadata-playwright-${GITHUB_RUN_ID:-local}-${PW_SHARD_ID:-local}"
compose_file="docker/development/docker-compose-postgres.yml"
fast_compose_file="docker/development/docker-compose-playwright-fast.yml"
fingerprint_script="$workspace_root/.github/scripts/playwright_cache_fingerprint.py"

if [[ ! -d /dev/shm ]]; then
  echo "/dev/shm is required for the Playwright fast environment" >&2
  exit 1
fi

sudo mkdir -p "$runtime_root/data" "$runtime_root/server" "$runtime_root/logs" "$runtime_root/tmp"
sudo chown -R "$(id -u):$(id -g)" "$runtime_root"
mkdir -p \
  "$runtime_root/airflow/dag-generated-configs" \
  "$runtime_root/airflow/dags" \
  "$runtime_root/airflow/logs" \
  "$runtime_root/airflow/tmp"
chmod 0777 "$runtime_root/airflow"/*
export PW_RUNTIME_ROOT="$runtime_root"
export PW_POSTGRES_DATA_DIR="$runtime_root/data/postgres"
export PW_OPENSEARCH_DATA_DIR="$runtime_root/data/opensearch"
export PW_SERVER_LOG="$runtime_root/logs/openmetadata-server.log"
export PW_SERVER_PID_FILE="$runtime_root/openmetadata-server.pid"
export PW_SERVER_CAPTURE_PID_FILE="$runtime_root/openmetadata-server-capture.pid"
export PW_SERVER_OUTPUT_PIPE="$runtime_root/openmetadata-server.pipe"
export PW_REQUEST_METRICS="$runtime_root/logs/request-metrics.json"
export PW_AIRFLOW_CONTAINER=""
export PW_AUTH_LINK="$workspace_root/openmetadata-ui/src/main/resources/ui/playwright/.auth"
export PW_ENTITY_STATE_LINK="$workspace_root/openmetadata-ui/src/main/resources/ui/playwright/output/entity-response-data.json"

startup_complete=false
cleanup_failed_start() {
  local exit_code=$?
  trap - EXIT
  if [[ "$startup_complete" != "true" ]]; then
    "$workspace_root/.github/scripts/stop_playwright_fast_environment.sh" || true
  fi
  exit "$exit_code"
}
trap cleanup_failed_start EXIT

sudo tar --numeric-owner --zstd -C "$runtime_root/data" -xf "$fixture_path"

manifest="$runtime_root/data/fixture-manifest.json"
if [[ ! -f "$manifest" ]]; then
  echo "The Playwright fixture does not contain a manifest" >&2
  exit 1
fi

current_fixture_compatibility_hash=$(python3 "$fingerprint_script" --kind fixture)
current_schema_hash=$(python3 "$fingerprint_script" --kind schema)
current_seed_hash=$(python3 "$fingerprint_script" --kind seed)
current_seed_version=$(sed -n 's:.*<version>\([^<]*\)</version>.*:\1:p' pom.xml | head -1)
if [[ "$(jq -r .version "$manifest")" != "2" ||
      "$(jq -r .compatibilityHash "$manifest")" != "$current_fixture_compatibility_hash" ||
      "$(jq -r .schemaHash "$manifest")" != "$current_schema_hash" ||
      "$(jq -r .seedHash "$manifest")" != "$current_seed_hash" ]]; then
  jq . "$manifest" >&2
  echo "The Playwright fixture does not match the fixture format, schema, seed, or setup code" >&2
  exit 1
fi
if [[ "$(jq -r .seedVersion "$manifest")" != "$current_seed_version" ]]; then
  echo "The Playwright fixture seed version does not match the checked-out source" >&2
  exit 1
fi
if ! jq -e '
  (.sourceSha | type == "string" and test("^[0-9a-f]{40}$")) and
  (.createdAt | type == "string" and length > 0) and
  (.postgresImage | type == "string" and test("^[^ @]+@sha256:[0-9a-f]{64}$")) and
  (.opensearchImage | type == "string" and test("^[^ @]+@sha256:[0-9a-f]{64}$"))
' "$manifest" >/dev/null; then
  echo "The Playwright fixture has invalid provenance or image digests" >&2
  exit 1
fi
if ! PW_SEARCH_CLUSTER_ALIAS=$(
  jq -er '.searchClusterAlias | select(type == "string" and length > 0)' "$manifest"
); then
  echo "The Playwright fixture does not declare its search cluster alias" >&2
  exit 1
fi
if [[ ! "$PW_SEARCH_CLUSTER_ALIAS" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "The Playwright fixture has an invalid search cluster alias" >&2
  exit 1
fi
export PW_SEARCH_CLUSTER_ALIAS

playwright_state="$runtime_root/data/playwright-state"
if [[ ! -s "$playwright_state/auth/admin.json" ||
      ! -s "$playwright_state/auth/admin-api-token.json" ||
      ! -s "$playwright_state/entity-response-data.json" ]]; then
  echo "The Playwright fixture does not contain seeded auth and entity state" >&2
  exit 1
fi
playwright_state_hash=$(
  cd "$playwright_state"
  find . -type f -print0 |
    sort -z |
    xargs -0 sha256sum |
    sha256sum |
    cut -d ' ' -f1
)
if [[ "$(jq -r .playwrightStateHash "$manifest")" != "$playwright_state_hash" ]]; then
  echo "The seeded Playwright state does not match the fixture manifest" >&2
  exit 1
fi

mkdir -p "$(dirname "$PW_ENTITY_STATE_LINK")"
for state_link in "$PW_AUTH_LINK" "$PW_ENTITY_STATE_LINK"; do
  if [[ -e "$state_link" || -L "$state_link" ]]; then
    echo "Refusing to replace existing Playwright state path: $state_link" >&2
    exit 1
  fi
done
ln -s "$playwright_state/auth" "$PW_AUTH_LINK"
ln -s "$playwright_state/entity-response-data.json" "$PW_ENTITY_STATE_LINK"

if [[ "${PW_PROTOCOL:-http}" == "h2" ]]; then
  for storage_state in "$playwright_state/auth"/*.json; do
    if [[ "$(basename "$storage_state")" == "admin-api-token.json" ]]; then
      continue
    fi
    temporary_state="${storage_state}.tmp"
    jq '(.origins[]?.origin) |= sub("^http://localhost:8585$"; "https://localhost:8585")' \
      "$storage_state" > "$temporary_state"
    mv "$temporary_state" "$storage_state"
  done
fi

export PW_POSTGRES_IMAGE
export PW_OPENSEARCH_IMAGE
PW_POSTGRES_IMAGE=$(jq -r .postgresImage "$manifest")
PW_OPENSEARCH_IMAGE=$(jq -r .opensearchImage "$manifest")

if [[ -n "$ingestion_image_path" ]]; then
  ingestion_manifest_path="${ingestion_image_path%.tar.zst}.manifest.json"
  if [[ ! -s "$ingestion_manifest_path" ]]; then
    echo "The Playwright ingestion image has no sidecar manifest" >&2
    exit 1
  fi
  current_ingestion_compatibility_hash=$(python3 "$fingerprint_script" --kind ingestion)
  ingestion_archive_hash=$(sha256sum "$ingestion_image_path" | cut -d ' ' -f1)
  if [[ "$(jq -r .version "$ingestion_manifest_path")" != "1" ||
        "$(jq -r .compatibilityHash "$ingestion_manifest_path")" != "$current_ingestion_compatibility_hash" ||
        "$(jq -r .archiveHash "$ingestion_manifest_path")" != "$ingestion_archive_hash" ]]; then
    jq . "$ingestion_manifest_path" >&2
    echo "The Playwright ingestion image does not match its source or archive digest" >&2
    exit 1
  fi
  if ! jq -e '
    (.sourceSha | type == "string" and test("^[0-9a-f]{40}$")) and
    (.createdAt | type == "string" and length > 0) and
    (.image | type == "string" and test("^openmetadata-playwright-ingestion:[0-9a-f]{64}$")) and
    (.imageId | type == "string" and test("^sha256:[0-9a-f]{64}$"))
  ' "$ingestion_manifest_path" >/dev/null; then
    echo "The Playwright ingestion image manifest is invalid" >&2
    exit 1
  fi
  zstd -dc "$ingestion_image_path" | docker image load >/dev/null
  ingestion_image=$(jq -r .image "$ingestion_manifest_path")
  ingestion_image_id=$(jq -r .imageId "$ingestion_manifest_path")
  if [[ -z "$ingestion_image" || -z "$ingestion_image_id" ||
        "$(docker image inspect "$ingestion_image" --format '{{.Id}}')" != "$ingestion_image_id" ]]; then
    echo "The restored Playwright ingestion image does not match the fixture" >&2
    exit 1
  fi
fi

# Pre-pull the compose images with retries so a transient Docker Hub blip does
# not fail the shard on the very first step. Docker Hub's auth endpoint is
# unreliable enough that a single request per image regularly times out (see
# run 30730142750 where chromium-14/19/20 all failed on
# `Get "https://auth.docker.io/token?..."` with no test having run). Separating
# the pull from `docker compose up` also gives a clearer error when pulls
# actually fail — no orphan containers, exit before the health-wait loop.
pull_image_with_retry() {
  local image=$1
  if docker image inspect "$image" >/dev/null 2>&1; then
    return 0  # already cached from a previous invocation on the same runner
  fi
  local delay=10
  local attempt
  for attempt in 1 2 3; do
    if docker pull --quiet "$image"; then
      return 0
    fi
    if [[ $attempt -eq 3 ]]; then
      echo "docker pull failed for $image after 3 attempts" >&2
      return 1
    fi
    echo "docker pull $image failed on attempt $attempt; retrying in ${delay}s" >&2
    sleep "$delay"
    delay=$(( delay * 2 ))
  done
}

# Pulled together rather than one after the other: the whole of this script
# runs under a 5m `timeout` in setup-openmetadata-test-environment, and the two
# pulls are the bulk of it. import-export-02 on run 34826046448 spent 22s on
# postgres and 3m44s on opensearch, leaving 54s for compose-up and the health
# waits, and was killed at 5m03s — overlapping them would have brought it in
# under the budget. `wait` is checked per job so a failed pull still stops the
# script with its own message instead of being swallowed.
pull_image_with_retry "$PW_POSTGRES_IMAGE" &
postgres_pull_pid=$!
pull_image_with_retry "$PW_OPENSEARCH_IMAGE" &
opensearch_pull_pid=$!

pull_failed=0
wait "$postgres_pull_pid" || pull_failed=1
wait "$opensearch_pull_pid" || pull_failed=1
if [[ $pull_failed -ne 0 ]]; then
  exit 1
fi

docker compose -f "$compose_file" -f "$fast_compose_file" up -d --no-build postgresql opensearch

for service in postgresql opensearch; do
  # -a: without it an exited container yields an empty id and we never reach docker logs below
  container_id=$(docker compose -f "$compose_file" -f "$fast_compose_file" ps -a -q "$service")
  for _ in $(seq 1 90); do
    status=$(docker inspect "$container_id" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}')
    [[ "$status" == "healthy" ]] && break
    sleep 2
  done
  status=$(docker inspect "$container_id" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}')
  if [[ "$status" != "healthy" ]]; then
    docker logs "$container_id" >&2
    echo "$service did not become healthy" >&2
    exit 1
  fi
  expected_image="$PW_POSTGRES_IMAGE"
  if [[ "$service" == "opensearch" ]]; then
    expected_image="$PW_OPENSEARCH_IMAGE"
  fi
  expected_image_id=$(docker image inspect "$expected_image" --format '{{.Id}}')
  if [[ "$(docker inspect "$container_id" --format '{{.Image}}')" != "$expected_image_id" ]]; then
    echo "$service did not start from the immutable image declared by the fixture" >&2
    exit 1
  fi
done

for seeded_index in table_search_index tag_search_index user_search_index; do
  index_response=$(mktemp "$runtime_root/tmp/${seeded_index}.XXXXXX")
  if ! curl -fsS \
    "http://127.0.0.1:9200/${PW_SEARCH_CLUSTER_ALIAS}_${seeded_index}/_count" \
    > "$index_response" ||
    ! jq -e '.count | numbers | select(. > 0)' "$index_response" >/dev/null; then
    cat "$index_response" >&2 || true
    curl -fsS 'http://127.0.0.1:9200/_cat/aliases?v' >&2 || true
    curl -fsS 'http://127.0.0.1:9200/_cat/indices?v' >&2 || true
    echo "The restored Playwright fixture has no seeded ${seeded_index} data for alias ${PW_SEARCH_CLUSTER_ALIAS}" >&2
    exit 1
  fi
  rm -f "$index_response"
done

curl -fsS -X PUT "http://127.0.0.1:9200/_all/_settings" \
  -H 'Content-Type: application/json' \
  -d '{"index":{"number_of_replicas":0}}' >/dev/null

tar -xzf "$distribution_path" -C "$runtime_root/server" --strip-components=1

server_config="$workspace_root/conf/openmetadata.yaml"
if [[ "${PW_PROTOCOL:-http}" == "h2" ]]; then
  server_config="$workspace_root/conf/openmetadata-h2-test.yaml"
fi

mkfifo "$PW_SERVER_OUTPUT_PIPE"
python3 "$workspace_root/.github/scripts/capture_playwright_server_output.py" \
  --input "$PW_SERVER_OUTPUT_PIPE" \
  --log "$PW_SERVER_LOG" \
  --metrics "$PW_REQUEST_METRICS" \
  --shard-id "${PW_SHARD_ID:-local}" &
capture_pid=$!
echo "$capture_pid" > "$PW_SERVER_CAPTURE_PID_FILE"

(
  cd "$runtime_root/server"
  export AUTHENTICATION_MAX_ACTIVE_SESSIONS_PER_USER="${AUTHENTICATION_MAX_ACTIVE_SESSIONS_PER_USER:-10000}"
  export DB_DRIVER_CLASS=org.postgresql.Driver
  export DB_HOST=127.0.0.1
  export DB_PARAMS='allowPublicKeyRetrieval=true&useSSL=false&serverTimezone=UTC'
  export DB_PORT=5432
  export DB_SCHEME=postgresql
  export DB_USER=openmetadata_user
  export DB_USER_PASSWORD=openmetadata_password
  export ELASTICSEARCH_HOST=127.0.0.1
  export ELASTICSEARCH_CLUSTER_ALIAS="$PW_SEARCH_CLUSTER_ALIAS"
  export ELASTICSEARCH_PORT=9200
  export ELASTICSEARCH_SCHEME=http
  export LOG_DIR="$runtime_root/logs"
  export LOG_LEVEL="${LOG_LEVEL:-WARN}"
  export OM_DATABASE=openmetadata_db
  export OPENMETADATA_HEAP_OPTS="${OPENMETADATA_HEAP_OPTS:--Xms1g -Xmx1g}"
  export OPENMETADATA_OPTS="${OPENMETADATA_OPTS:-} -Djava.io.tmpdir=$runtime_root/tmp"
  export PIPELINE_SERVICE_CLIENT_ENDPOINT=http://127.0.0.1:8080
  export REQUEST_LOG_LEVEL=INFO
  export SEARCH_TYPE=opensearch
  if [[ -n "$ingestion_image_path" ]]; then
    export SERVER_HOST_API_URL=http://host.docker.internal:8585/api
  else
    export SERVER_HOST_API_URL=http://127.0.0.1:8585/api
  fi
  export SERVER_ENABLE_VIRTUAL_THREAD=true
  export SERVER_H2_KEYSTORE_PATH="$workspace_root/openmetadata-service/src/test/resources/localhost-h2.p12"
  exec ./bin/openmetadata-server-start.sh "$server_config"
) > "$PW_SERVER_OUTPUT_PIPE" 2>&1 &
server_pid=$!
echo "$server_pid" > "$PW_SERVER_PID_FILE"

for _ in $(seq 1 90); do
  if curl -fsS http://127.0.0.1:8586/healthcheck >/dev/null; then
    break
  fi
  if ! kill -0 "$server_pid" 2>/dev/null; then
    tail -n 500 "$PW_SERVER_LOG" >&2
    echo "OpenMetadata exited before becoming healthy" >&2
    exit 1
  fi
  sleep 2
done

if ! curl -fsS http://127.0.0.1:8586/healthcheck >/dev/null; then
  tail -n 500 "$PW_SERVER_LOG" >&2
  echo "OpenMetadata did not become healthy" >&2
  exit 1
fi

admin_api_token="$playwright_state/auth/admin-api-token.json"
auth_base_url="http://localhost:8585"
if [[ "${PW_PROTOCOL:-http}" == "h2" ]]; then
  auth_base_url="https://localhost:8585"
fi
if ! python3 "$workspace_root/.github/scripts/rotate_playwright_auth_state.py" \
  --auth-dir "$playwright_state/auth" \
  --base-url "$auth_base_url"; then
  echo "Could not regenerate the cached Playwright sessions" >&2
  exit 1
fi
if ! refreshed_admin_token=$(jq -er '.token | select(type == "string" and length > 0)' "$admin_api_token"); then
  echo "Session regeneration returned no admin access token" >&2
  exit 1
fi

seed_search_url="http://localhost:8585/api/v1/search/query"
seed_search_args=(-fsS --retry 4 --retry-all-errors --retry-delay 1 --get)
if [[ "${PW_PROTOCOL:-http}" == "h2" ]]; then
  seed_search_url="https://localhost:8585/api/v1/search/query"
  seed_search_args+=(--insecure)
fi
seed_search_response=$(mktemp "$runtime_root/tmp/seed-search.XXXXXX")
if ! curl "${seed_search_args[@]}" \
  -H "Authorization: Bearer $refreshed_admin_token" \
  --data-urlencode 'q=provider_address_texas' \
  --data-urlencode 'index=table_search_index' \
  --data-urlencode 'from=0' \
  --data-urlencode 'size=1' \
  "$seed_search_url" > "$seed_search_response" ||
  ! jq -e '(.hits.hits // []) | length > 0' "$seed_search_response" >/dev/null; then
  cat "$seed_search_response" >&2 || true
  echo "OpenMetadata cannot query seeded data through search alias ${PW_SEARCH_CLUSTER_ALIAS}" >&2
  exit 1
fi
rm -f "$seed_search_response"

if [[ -n "$ingestion_image_path" ]]; then
  # Started first so they boot while Airflow does; readiness and seeding happen
  # after Airflow is healthy, at the end of this block. schema-registry is started
  # there too: it needs a healthy Kafka, and waiting for that here would
  # serialize Airflow's boot behind Kafka's. The background pulls started at the
  # top of this script have usually finished by now; the retrying pull below
  # skips images already present, and retries any background pull that failed.
  wait "${connector_pull_pids[@]}" || true
  for connector_image in "${connector_images[@]}"; do
    pull_image_with_retry "$connector_image"
  done
  docker compose -f "$compose_file" -f "$fast_compose_file" up -d --no-build mysql kafka metabase

  PW_AIRFLOW_CONTAINER=openmetadata_ingestion
  export PW_AIRFLOW_CONTAINER
  airflow_seed_container="${PW_AIRFLOW_CONTAINER}_seed"
  docker create --name "$airflow_seed_container" "$ingestion_image" >/dev/null
  docker cp \
    "$airflow_seed_container:/opt/airflow/dags/." \
    "$runtime_root/airflow/dags"
  docker rm "$airflow_seed_container" >/dev/null
  chmod -R a+rwX "$runtime_root/airflow"
  docker run --detach \
    --name "$PW_AIRFLOW_CONTAINER" \
    --network ometa_network \
    --add-host host.docker.internal:host-gateway \
    --publish 8080:8080 \
    --log-driver local \
    --log-opt max-size=10m \
    --log-opt max-file=1 \
    --log-opt compress=false \
    --env AIRFLOW__API__AUTH_BACKENDS=airflow.api.auth.backend.basic_auth,airflow.api.auth.backend.session \
    --env AIRFLOW__CORE__EXECUTOR=LocalExecutor \
    --env AIRFLOW__OPENMETADATA_AIRFLOW_APIS__DAG_GENERATED_CONFIGS=/opt/airflow/dag_generated_configs \
    --env DB_HOST=postgresql \
    --env DB_PORT=5432 \
    --env AIRFLOW_DB=airflow_db \
    --env DB_USER=airflow_user \
    --env DB_SCHEME=postgresql+psycopg2 \
    --env DB_PASSWORD=airflow_pass \
    --env OPENMETADATA_SERVER_URL=http://host.docker.internal:8585/api \
    --volume /var/run/docker.sock:/var/run/docker.sock \
    --volume "$runtime_root/airflow/dag-generated-configs:/opt/airflow/dag_generated_configs" \
    --volume "$runtime_root/airflow/dags:/opt/airflow/dags" \
    --volume "$runtime_root/airflow/logs:/opt/airflow/logs" \
    --volume "$runtime_root/airflow/tmp:/tmp" \
    --entrypoint /bin/bash \
    "$ingestion_image" \
    /opt/airflow/ingestion_dependency.sh >/dev/null

  for _ in $(seq 1 120); do
    if curl -fsS -X POST http://127.0.0.1:8080/auth/token \
      -H 'Content-Type: application/json' \
      -d '{"username":"admin","password":"admin"}' |
      jq -e '.access_token | length > 0' >/dev/null; then
      break
    fi
    if ! docker inspect "$PW_AIRFLOW_CONTAINER" --format '{{.State.Running}}' | grep -qx true; then
      docker logs --tail 500 "$PW_AIRFLOW_CONTAINER" >&2
      echo "Airflow exited before becoming healthy" >&2
      exit 1
    fi
    sleep 2
  done

  if ! curl -fsS -X POST http://127.0.0.1:8080/auth/token \
    -H 'Content-Type: application/json' \
    -d '{"username":"admin","password":"admin"}' |
    jq -e '.access_token | length > 0' >/dev/null; then
    docker logs --tail 500 "$PW_AIRFLOW_CONTAINER" >&2
    echo "Airflow did not become healthy" >&2
    exit 1
  fi

  wait_for_connector_health() {
    local service=$1 container_id status
    container_id=$(docker compose -f "$compose_file" -f "$fast_compose_file" ps -a -q "$service")
    for _ in $(seq 1 90); do
      status=$(docker inspect "$container_id" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}')
      [[ "$status" == "healthy" ]] && return 0
      sleep 2
    done
    docker logs --tail 200 "$container_id" >&2
    echo "Connector target $service did not become healthy" >&2
    exit 1
  }

  wait_for_connector_http() {
    local service=$1 url=$2
    for _ in $(seq 1 120); do
      curl -fsS "$url" >/dev/null 2>&1 && return 0
      sleep 2
    done
    docker compose -f "$compose_file" -f "$fast_compose_file" logs --tail 200 "$service" >&2
    echo "Connector target $service did not become ready at $url" >&2
    exit 1
  }

  wait_for_connector_health mysql
  wait_for_connector_health kafka
  docker compose -f "$compose_file" -f "$fast_compose_file" up -d --no-build schema-registry
  wait_for_connector_http schema-registry http://127.0.0.1:18081/subjects
  wait_for_connector_http metabase http://127.0.0.1:13000/api/health

  # The credentials below are fixtures for throwaway containers, and must match
  # the fork's TEST_MYSQL_* and TEST_METABASE_* secrets (see
  # openmetadata-ui/.../playwright/CI_SECRETS.md). Grants mirror the restricted
  # ingestion account in ingestion/tests/cli_e2e_v2/mysql/source.py, plus read
  # access to mysql.general_log: AutoPilot also runs the usage and lineage
  # agents, which read queries from it, and the cli_e2e_v2 pilot does not.
  docker compose -f "$compose_file" -f "$fast_compose_file" exec -T mysql \
    mysql -uroot -ppassword <<'SQL'
CREATE USER IF NOT EXISTS 'openmetadata_user'@'%' IDENTIFIED BY 'openmetadata_password';
GRANT PROCESS, SHOW_ROUTINE ON *.* TO 'openmetadata_user'@'%';
GRANT SELECT, SHOW VIEW, EXECUTE ON autopilot_mysql.* TO 'openmetadata_user'@'%';
GRANT SELECT ON mysql.general_log TO 'openmetadata_user'@'%';
CREATE TABLE IF NOT EXISTS autopilot_mysql.bot_entity (id INT PRIMARY KEY, name VARCHAR(64) NOT NULL);
CREATE TABLE IF NOT EXISTS autopilot_mysql.alert_entity (id INT PRIMARY KEY, name VARCHAR(64) NOT NULL);
CREATE TABLE IF NOT EXISTS autopilot_mysql.chart_entity (id INT PRIMARY KEY, name VARCHAR(64) NOT NULL);
INSERT IGNORE INTO autopilot_mysql.bot_entity VALUES (1, 'ingestion-bot'), (2, 'profiler-bot');
INSERT IGNORE INTO autopilot_mysql.alert_entity VALUES (1, 'failed-tests'), (2, 'schema-change');
INSERT IGNORE INTO autopilot_mysql.chart_entity VALUES (1, 'daily-orders'), (2, 'revenue');
SQL

  # IngestionLogStreamLive.spec.ts needs a Kafka ingestion that is still running
  # while it watches the logs. The sink saves topics in bulk batches of 100, and
  # the connector only polls a topic for sample messages once it is saved, so a
  # broker with fewer than 100 topics finishes in about a second. Empty topics
  # make each of those polls block for its full 10s timeout, which is what keeps
  # the run alive; 500 gives five of them. Created in one batch with the Kafka
  # client already in the ingestion image, rather than one CLI JVM per topic.
  docker exec -i "$PW_AIRFLOW_CONTAINER" python - <<'PY'
from confluent_kafka.admin import AdminClient, NewTopic

admin = AdminClient({"bootstrap.servers": "kafka:9092"})
topics = [NewTopic(f"playwright_filler_{index:03d}", num_partitions=1, replication_factor=1) for index in range(500)]
for future in admin.create_topics(topics).values():
    future.result()
PY

  metabase_setup_token=$(curl -fsS http://127.0.0.1:13000/api/session/properties | jq -er '."setup-token"')
  jq -n --arg token "$metabase_setup_token" '{
      token: $token,
      user: {
        email: "admin@openmetadata.org",
        password: "OpenMetadata_Pw1",
        first_name: "Playwright",
        last_name: "AutoPilot",
        site_name: "OpenMetadata Playwright"
      },
      prefs: {site_name: "OpenMetadata Playwright", site_locale: "en", allow_tracking: false}
    }' |
    curl -fsS -X POST http://127.0.0.1:13000/api/setup \
      -H 'Content-Type: application/json' -d @- >/dev/null
fi

{
  echo "PW_RUNTIME_ROOT=$PW_RUNTIME_ROOT"
  echo "PW_POSTGRES_DATA_DIR=$PW_POSTGRES_DATA_DIR"
  echo "PW_OPENSEARCH_DATA_DIR=$PW_OPENSEARCH_DATA_DIR"
  echo "PW_SERVER_LOG=$PW_SERVER_LOG"
  echo "PW_SERVER_PID_FILE=$PW_SERVER_PID_FILE"
  echo "PW_SERVER_CAPTURE_PID_FILE=$PW_SERVER_CAPTURE_PID_FILE"
  echo "PW_REQUEST_METRICS=$PW_REQUEST_METRICS"
  echo "PW_AIRFLOW_CONTAINER=$PW_AIRFLOW_CONTAINER"
  echo "PW_AUTH_LINK=$PW_AUTH_LINK"
  echo "PW_ENTITY_STATE_LINK=$PW_ENTITY_STATE_LINK"
  echo "PW_POSTGRES_IMAGE=$PW_POSTGRES_IMAGE"
  echo "PW_OPENSEARCH_IMAGE=$PW_OPENSEARCH_IMAGE"
  echo "PW_SEARCH_CLUSTER_ALIAS=$PW_SEARCH_CLUSTER_ALIAS"
} >> "$GITHUB_ENV"

startup_complete=true
echo "Fast Playwright environment is ready"
