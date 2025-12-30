#!/bin/bash

LOG_FILE="/var/log/springboot-migration.log"
RESULT_FILE="/tmp/migration_outputs.txt"
: > "$RESULT_FILE"  # Clear result file at the start

exec > >(tee -a "$LOG_FILE") 2>&1

# === Timestamped logging ===
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $*"
}

set -euo pipefail
trap '{
  log "❌ Migration script failed on line $LINENO"
  echo "migration_ran=false" >> "$RESULT_FILE"
  echo "batch_id=null" >> "$RESULT_FILE"
  exit 1
}' ERR

# === 1. Set Paths ===
ENV_PATH="/lp/dev/"
ENV_FILE="/etc/profile.d/springboot_env.sh"
FLYWAY_DIR="/tmp/flyway/sql"
S3_MIGRATION_PATH="s3://lp-mediaconvstack-artifact-repo-dev-740994137015/learning-platform/dev/{{COMMIT_HASH}}/"

# === 2. Fetch Environment Variables from SSM ===
log "📥 Fetching env vars from SSM: $ENV_PATH"
PARAMS=$(aws ssm get-parameters-by-path --path "$ENV_PATH" --recursive --with-decryption --region us-east-1)

log "Writing environment variables to $ENV_FILE"
echo "# Auto-generated Spring Boot env vars" > "$ENV_FILE"
echo "$PARAMS" | jq -r '.Parameters[] | "\(.Name)=\(.Value)"' | while IFS='=' read -r full_name value; do
  var_name=$(basename "$full_name")
  echo "export $var_name=\"$value\"" >> "$ENV_FILE"
done

chmod +x "$ENV_FILE"
source "$ENV_FILE"

# === 3. Set DB vars ===
DB_HOST="$LEARNING_PLATFORM_DB_HOST"
DB_USER="$LEARNING_PLATFORM_DB_USER"
DB_NAME="$LEARNING_PLATFORM_DB_NAME"
DB_PORT="$LEARNING_PLATFORM_DB_PORT"
DB_PASSWORD="$LEARNING_PLATFORM_DB_PASSWORD"

# === 4. Prepare Migration Directory ===
log "📁 Setting up Flyway directory at: $FLYWAY_DIR"
mkdir -p "$FLYWAY_DIR"
rm -rf "$FLYWAY_DIR"/*

# === 5. Download SQL Files from S3 ===
log "☁️ Syncing migrations from S3: $S3_MIGRATION_PATH"
aws s3 sync "$S3_MIGRATION_PATH" "$FLYWAY_DIR"

if [ -z "$(ls -A "$FLYWAY_DIR")" ]; then
  log "⚠️ No migration files found in $FLYWAY_DIR. Exiting."
  echo "migration_ran=false" >> "$RESULT_FILE"
  echo "batch_id=null" >> "$RESULT_FILE"
  exit 0
fi

# === Ensure PostgreSQL client is installed ===
if ! command -v psql >/dev/null 2>&1; then
  log "❌ psql not found. Installing PostgreSQL client..."
  sudo amazon-linux-extras enable postgresql14
  sudo yum clean metadata
  sudo yum update -y
  sudo yum install -y postgresql
  log "Verifying psql version..."
  psql --version
else
  log "✅ psql is already installed: $(psql --version)"
fi

# === Ensure Flyway is installed ===
FLYWAY_CLI_PATH="/opt/flyway/flyway"

if [ ! -f "$FLYWAY_CLI_PATH" ]; then
  log "🔧 Flyway not found. Installing Flyway CLI..."
  FLYWAY_VERSION="9.20.1"
  TEMP_DIR="/tmp/flyway-install"
  mkdir -p "$TEMP_DIR"
  curl -L "https://repo1.maven.org/maven2/org/flywaydb/flyway-commandline/${FLYWAY_VERSION}/flyway-commandline-${FLYWAY_VERSION}-linux-x64.tar.gz" -o "$TEMP_DIR/flyway.tar.gz"
  tar -xzf "$TEMP_DIR/flyway.tar.gz" -C "$TEMP_DIR"
  sudo mkdir -p /opt/flyway
  sudo cp -r "$TEMP_DIR/flyway-${FLYWAY_VERSION}"/* /opt/flyway/
  sudo chmod +x /opt/flyway/flyway
  log "✅ Flyway $FLYWAY_VERSION installed at $FLYWAY_CLI_PATH"
else
  log "✅ Flyway already installed at $FLYWAY_CLI_PATH"
fi

# === 6. Run Flyway Migration ===
export PGPASSWORD="$DB_PASSWORD"
log "🔖 Getting current timestamp before migration..."
DEPLOY_START_TIME=$(psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT current_timestamp" | xargs)

log "🚀 Running Flyway Migration"
/opt/flyway/flyway \
  -url="jdbc:postgresql://${DB_HOST}:${DB_PORT}/${DB_NAME}" \
  -user="${DB_USER}" \
  -password="${DB_PASSWORD}" \
  -schemas=learning_platform \
  -locations=filesystem:"$FLYWAY_DIR" \
  migrate

log "✅ Flyway migration complete."

# === 7. Log Applied Migrations ===
log "🔍 Fetching applied migrations after $DEPLOY_START_TIME..."
applied_versions=$(psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -t -c "
  SELECT version
  FROM learning_platform.flyway_schema_history
  WHERE success = true AND installed_on > TIMESTAMP '$DEPLOY_START_TIME'
  ORDER BY installed_on ASC
" | xargs)

if [[ -z "$applied_versions" ]]; then
  log "✅ No new migrations applied. Nothing to log."
  echo "migration_ran=false" >> "$RESULT_FILE"
  echo "batch_id=null" >> "$RESULT_FILE"
  exit 0
fi

batch_id=$(psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT COALESCE(MAX(batch_id), 0) + 1 FROM learning_platform.schema_rollback_log" | xargs)
log "📝 Logging to rollback table with batch_id $batch_id"

for version in $applied_versions; do
  log "🧾 Logging version $version"
  psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -c "
    INSERT INTO learning_platform.schema_rollback_log (migration_version, applied_at, batch_id)
    VALUES ('$version', current_timestamp, $batch_id)
  "
done

log "✅ Migration batch $batch_id recorded successfully."

# === 8. Output for External Fetching ===
echo "migration_ran=true" >> "$RESULT_FILE"
echo "batch_id=$batch_id" >> "$RESULT_FILE"
