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

Upstream's values point at test instances it hosts, which a fork cannot read or
reach. Instead, on ingestion shards `start_playwright_fast_environment.sh`
starts local stand-ins (defined in `docker/development/docker-compose-playwright-fast.yml`),
seeds them, and runs Metabase's first-time setup. Set the secrets once per fork
to point at those containers:

```bash
R=<owner>/OpenMetadata
gh secret set TEST_AIRFLOW_HOST_PORT --repo $R --body "http://localhost:8080"
# ...one call per row below
```

## Secrets used by `AutoPilot.spec.ts`

| Secret | Value |
|---|---|
| `TEST_AIRFLOW_HOST_PORT` | `http://localhost:8080` |
| `TEST_MYSQL_HOST_PORT` | `mysql:3306` |
| `TEST_MYSQL_USERNAME` | `openmetadata_user` |
| `TEST_MYSQL_PASSWORD` | `openmetadata_password` |
| `TEST_MYSQL_DATABASE_SCHEMA` | `autopilot_mysql` |
| `TEST_KAFKA_BOOTSTRAP_SERVERS` | `kafka:9092` |
| `TEST_KAFKA_SCHEMA_REGISTRY_URL` | `http://schema-registry:8081` |
| `TEST_METABASE_HOST_PORT` | `http://metabase:3000` |
| `TEST_METABASE_USERNAME` | `admin@openmetadata.org` |
| `TEST_METABASE_PASSWORD` | `OpenMetadata_Pw1` |

Each secret maps to the `PLAYWRIGHT_` variable of the same suffix. The MySQL
and Metabase credentials are fixtures created by the start script, so the
secrets must match it exactly. Hosts are service names on `ometa_network`, not
`localhost`, because the connection test and the AutoPilot agents run inside
the ingestion container. Airflow is the exception: that container is Airflow,
and its api-server listens on `8080` (`ingestion/ingestion_dependency.sh`).

Rest (`ApiIngestionClass`) and MlFlow need no secrets: they use a public
OpenAPI URL and a self-bootstrapping SQLite backend respectively.
