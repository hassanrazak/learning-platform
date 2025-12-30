#!/bin/bash

set -e  # Exit on error

LOG_FILE="/var/log/springboot-deploy.log"

# Function to prefix logs with a timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Redirect stdout/stderr to log file
exec > >(tee -a "$LOG_FILE") 2>&1

log "🔑 Fetching environment variables from SSM..."

# Ensure the jq tool is available
if ! command -v jq &> /dev/null; then
    log "❌ jq not found. Installing jq before running this script."
    if command -v yum &> /dev/null; then
        sudo yum install -y jq
    elif command -v apt-get &> /dev/null; then
        sudo apt-get update && sudo apt-get install -y jq
    else
        log "❌ Package manager not found. Cannot install jq."
        exit 1
    fi
fi

# === 1. Set Environment Variables ===
ENV_PATH="/lp/dev/"
ENV_FILE="/etc/profile.d/springboot_env.sh"

log "Fetching SSM parameters from path: ${ENV_PATH}"

PARAMS=$(aws ssm get-parameters-by-path --path "$ENV_PATH" --recursive --with-decryption --region us-east-1)

# Clear and recreate the environment file
log "Creating environment file: $ENV_FILE"
echo "# Auto-generated env vars for Spring Boot app" > "$ENV_FILE"

# Parse and write env vars
log "Writing environment variables to $ENV_FILE"
echo "$PARAMS" | jq -r '.Parameters[] | "\(.Name)=\(.Value)"' | while IFS='=' read -r full_name value; do
    var_name=$(basename "$full_name")
    echo "$var_name=\"$value\"" >> "$ENV_FILE"
done

chmod +x "$ENV_FILE"  # Ensure it can be sourced
log "Made $ENV_FILE executable"

log "📦 Downloading JAR from S3..."
# REFACTOR THIS ENTRY LATER AS USE A GITHUB SECRET INSTEAD
aws s3 cp s3://lp-mediaconvstack-artifact-repo-dev-740994137015/learning-platform/dev/{{COMMIT_HASH}}/learning-platform-0.0.1-SNAPSHOT.jar /opt/myapp/app.jar

log "🚀 Setting up systemd service..."

# === 2. Create systemd service ===
cat > /etc/systemd/system/springboot-app.service <<EOF
[Unit]
Description=Spring Boot Application
After=network.target

[Service]
User=root
EnvironmentFile=-$ENV_FILE
ExecStart=/usr/bin/java -jar /opt/myapp/app.jar
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=springboot-app

[Install]
WantedBy=multi-user.target
EOF

log "Reloading systemd daemon and starting service"

# === 3. Reload, Enable, Start ===
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable springboot-app
systemctl restart springboot-app

# === 4. Status Check ===
if systemctl is-active --quiet springboot-app; then
    log "✅ Spring Boot app is running"
else
    log "❌ Spring Boot app failed to start"
    journalctl -u springboot-app --no-pager -n 20
fi
