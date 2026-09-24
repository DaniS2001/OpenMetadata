# Playwright CI secrets in a fork

GitHub never copies repository secrets to a fork. The Playwright workflow
(`.github/workflows/playwright-e2e-reusable.yml`) maps `secrets.TEST_*` to the
`PLAYWRIGHT_*` environment variables the connector support classes read, and
those classes fall back to an empty string (`process.env.X ?? ''`). In a fresh
fork every value is therefore blank, and the AutoPilot specs fail before any
connection is attempted:

```
Test Connection did not request its connection definition.
Visible validation errors: Host Port is required.
```

Set the secrets once per fork:

```bash
R=<owner>/OpenMetadata
gh secret set TEST_AIRFLOW_HOST_PORT --repo $R --body "http://localhost:8080"
```

## Secrets used by `AutoPilot.spec.ts`

| Secret | Env var | Connector | Service in the CI stack |
|---|---|---|---|
| `TEST_AIRFLOW_HOST_PORT` | `PLAYWRIGHT_AIRFLOW_HOST_PORT` | Airflow | Yes |
| `TEST_MYSQL_HOST_PORT` | `PLAYWRIGHT_MYSQL_HOST_PORT` | Mysql | No |
| `TEST_MYSQL_USERNAME` | `PLAYWRIGHT_MYSQL_USERNAME` | Mysql | No |
| `TEST_MYSQL_PASSWORD` | `PLAYWRIGHT_MYSQL_PASSWORD` | Mysql | No |
| `TEST_MYSQL_DATABASE_SCHEMA` | `PLAYWRIGHT_MYSQL_DATABASE_SCHEMA` | Mysql | No |
| `TEST_KAFKA_BOOTSTRAP_SERVERS` | `PLAYWRIGHT_KAFKA_BOOTSTRAP_SERVERS` | Kafka | No |
| `TEST_KAFKA_SCHEMA_REGISTRY_URL` | `PLAYWRIGHT_KAFKA_SCHEMA_REGISTRY_URL` | Kafka | No |
| `TEST_METABASE_HOST_PORT` | `PLAYWRIGHT_METABASE_HOST_PORT` | Metabase | No |
| `TEST_METABASE_USERNAME` | `PLAYWRIGHT_METABASE_USERNAME` | Metabase | No |
| `TEST_METABASE_PASSWORD` | `PLAYWRIGHT_METABASE_PASSWORD` | Metabase | No |
| `TEST_METABASE_DB_SERVICE_NAME` | `PLAYWRIGHT_METABASE_DB_SERVICE_NAME` | Metabase | No |

Rest (`ApiIngestionClass`) and MlFlow need no secrets: they use a public
OpenAPI URL and a self-bootstrapping SQLite backend respectively.

## Airflow

`http://localhost:8080` is the only correct value. The connection test runs
inside the ingestion container, which starts `airflow api-server --port 8080`
(`ingestion/ingestion_dependency.sh`) and defaults `AIRFLOW__API__BASE_URL` to
the same address. The container's own log shows only the task-execution API on
`8793`; the api-server logs to a separate file.

## Mysql, Kafka, Metabase

`start_playwright_fast_environment.sh` starts only `postgresql` and
`opensearch`, plus the Airflow container on ingestion shards. Nothing in the
stack serves these three connectors, so a value that fills the form moves the
failure rather than fixing it: the spec clicks Test Connection and then waits
out the 8-minute test timeout on the Connection status dialog.

To make them pass, point the secrets at an instance reachable from the
ingestion container on `ometa_network` — an external test instance, or a
container added to the fast environment for ingestion shards.
