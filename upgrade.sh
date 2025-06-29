#!/bin/bash

# Cấu hình
COMPOSE_FILE="/opt/n8n/docker-compose.yml"
BACKUP_PATH="${COMPOSE_FILE}.bak.$(date +%F_%H-%M-%S)"
ENV_FILE="/opt/n8n/.env"
N8N_HOST=$(grep '^N8N_HOST=' "$ENV_FILE" | cut -d '=' -f2)

# Backup
echo "🛡️ Backup file cũ..."
cp "$COMPOSE_FILE" "$BACKUP_PATH"

# Tính RAM giới hạn (60%)
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
LIMIT_MB=$((TOTAL_RAM_MB * 60 / 100))

# Ghi file mới
cat > "$COMPOSE_FILE" <<EOF
version: '3.8'

services:
  postgres:
    image: postgres:16
    restart: unless-stopped
    environment:
      POSTGRES_USER: \${POSTGRES_USER}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
      POSTGRES_DB: \${POSTGRES_DB}
    volumes:
      - n8n_postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -d \${POSTGRES_DB} -U \${POSTGRES_USER}"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    restart: unless-stopped
    command: redis-server --requirepass "\${REDIS_PASSWORD}"
    volumes:
      - n8n_redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "\${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  n8n:
    image: n8nio/n8n:latest
    restart: unless-stopped
    ports:
      - "127.0.0.1:5678:5678"
    environment:
      N8N_HOST: \${N8N_HOST}
      N8N_PROTOCOL: https
      WEBHOOK_URL: https://\${N8N_HOST}/
      GENERIC_TIMEZONE: \${GENERIC_TIMEZONE}
      NODE_OPTIONS: --max-old-space-size=512
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_DATABASE: \${POSTGRES_DB}
      DB_POSTGRESDB_USER: \${POSTGRES_USER}
      DB_POSTGRESDB_PASSWORD: \${POSTGRES_PASSWORD}
      EXECUTIONS_MODE: queue
      QUEUE_BULL_REDIS_HOST: redis
      QUEUE_BULL_REDIS_PORT: 6379
      QUEUE_BULL_REDIS_PASSWORD: \${REDIS_PASSWORD}
      N8N_RUNNERS_ENABLED: true
      OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS: false
      EXECUTIONS_DATA_PRUNE: true
      EXECUTIONS_DATA_MAX_AGE: 168
      N8N_SAVE_EXECUTIONS: false
      N8N_BASIC_AUTH_ACTIVE: true
      N8N_BASIC_AUTH_USER: \${N8N_BASIC_AUTH_USER}
      N8N_BASIC_AUTH_PASSWORD: \${N8N_BASIC_AUTH_PASSWORD}
    volumes:
      - n8n_data:/home/node/.n8n
      - /tmp:/tmp
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    mem_limit: ${LIMIT_MB}m
  nocodb:
    image: nocodb/nocodb:latest
    restart: always
    ports:
      - "8080:8080"  # Truy cập NocoDB từ http://localhost:8080
    environment:
      NC_DB_TYPE: "pg"
      NC_DATABASE: \${POSTGRES_DB}
      NC_DB_HOST: postgres # e.g., 'postgres_db' if it's another service in same compose file
      NC_DB_PORT: 5432
      NC_DB_USER: \${POSTGRES_USER}
      NC_DB_PASSWORD: \${POSTGRES_PASSWORD}
      NC_ADMIN_EMAIL: \${NC_ADMIN_EMAIL}
      NC_ADMIN_PASSWORD: \${NC_ADMIN_PASSWORD}
      NC_PUBLIC_URL: "https://\${N8N_HOST}/nocodb"
      NC_BACKEND_URL: "https://\${N8N_HOST}/nocodb"
      NC_DISABLE_TELE: "true"
    depends_on:
      postgres:
        condition: service_healthy
    volumes:
      - n8n_nocodb_data:/usr/app/data  # Lưu cấu hình NocoDB

volumes:
  n8n_postgres_data:
  n8n_redis_data:
  n8n_data:
  n8n_nocodb_data:
EOF

# Restart
echo "🚀 Restart n8n..."
cd /opt/n8n
docker compose down
docker compose up -d

echo "✅ Đã cập nhật docker-compose.yml (dùng biến từ .env)"
echo "📁 Backup tại: $BACKUP_PATH"


cd /opt/n8n
docker compose down
docker compose up -d
