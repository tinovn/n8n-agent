#!/bin/bash

set -e

# ========== CẤU HÌNH ==========
APP_DIR="/opt/n8n-agent"
GIT_REPO="https://github.com/tinovn/n8n-agent.git"
AGENT_BIN="n8n-agent"
UPDATE_SCRIPT="$APP_DIR/update-agent.sh"
UPGRADE_SCRIPT="$APP_DIR/upgrade.sh"
STEP_LOG="/var/log/n8n-agent-install-steps.log"
EMAIL="noreply@tino.org"

log_step() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$STEP_LOG"
}

echo "✅ Bắt đầu cài đặt n8n-agent server..."

# ========== 1. Cập nhật hệ thống ==========
echo "🔄 Đang cập nhật hệ thống..."
apt update && apt upgrade -y
apt install -y dnsutils curl git ca-certificates gnupg lsb-release jq

# ========== 2. Cài Docker & Compose ==========
echo "🐳 Cài Docker & Docker Compose Plugin..."
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable docker
systemctl start docker
log_step "✅ Đã cài Docker"

# ========== 3. Cài Nginx & Certbot ==========
echo "🌐 Cài Nginx và Certbot..."
apt install -y nginx certbot python3-certbot-nginx
systemctl enable nginx
systemctl start nginx
log_step "✅ Đã cài Nginx và Certbot"

# ========== 4. Clone agent ==========
echo "📥 Clone n8n-agent từ GitHub..."
rm -rf "$APP_DIR"
git clone "$GIT_REPO" "$APP_DIR"
cd "$APP_DIR"
chmod +x "$AGENT_BIN"
log_step "✅ Đã clone n8n-agent"

# ========== 5. Tạo systemd service ==========
echo "🛠 Tạo systemd service..."
cat <<EOF > /etc/systemd/system/n8n-agent.service
[Unit]
Description=N8N Agent Service
After=network.target

[Service]
ExecStart=${APP_DIR}/${AGENT_BIN}
Restart=always
User=root
Environment=NODE_ENV=production
WorkingDirectory=${APP_DIR}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable n8n-agent
systemctl start n8n-agent
log_step "✅ Đã tạo service n8n-agent"

# ========== 6. Tạo update-agent.sh ==========
echo "🧰 Tạo script cập nhật agent..."
cat <<EOF > "$UPDATE_SCRIPT"
#!/bin/bash
set -e

APP_DIR="${APP_DIR}"
AGENT_BIN="${AGENT_BIN}"
UPGRADE_SCRIPT="\$APP_DIR/upgrade.sh"

echo "🔄 Cập nhật n8n-agent từ GitHub..."
systemctl stop n8n-agent
cd "\$APP_DIR"
git reset --hard
git pull origin main
chmod +x "\$AGENT_BIN"

# Chạy upgrade.sh nếu có, sau đó xóa
if [[ -f "\$UPGRADE_SCRIPT" ]]; then
  echo "⚙️ Đã phát hiện upgrade.sh → chạy..."
  chmod +x "\$UPGRADE_SCRIPT"
  "\$UPGRADE_SCRIPT"
  echo "🧹 Xoá upgrade.sh sau khi chạy xong..."
  rm -f "\$UPGRADE_SCRIPT"
fi

systemctl daemon-reload
systemctl restart n8n-agent
echo "✅ Đã cập nhật và khởi động lại n8n-agent"
EOF

chmod +x "$UPDATE_SCRIPT"
log_step "✅ Đã tạo update script"

# ========== 7. Tạo systemd timer để auto-update ==========
echo "⏲️ Tạo systemd timer để auto-update khi reboot..."
cat <<EOF > /etc/systemd/system/n8n-agent-update.service
[Unit]
Description=Auto Update N8N Agent on Boot
After=network.target

[Service]
Type=oneshot
ExecStart=${UPDATE_SCRIPT}
RemainAfterExit=true
EOF

cat <<EOF > /etc/systemd/system/n8n-agent-update.timer
[Unit]
Description=Run n8n-agent update on boot

[Timer]
OnBootSec=30s
AccuracySec=1s
Unit=n8n-agent-update.service

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable n8n-agent-update.timer
systemctl start n8n-agent-update.timer
log_step "✅ Đã tạo systemd timer auto-update"

# ========== 8. Gửi request /api/n8n/install nếu DNS đúng ==========
echo "🌐 Kiểm tra DNS hostname trỏ đúng IP để gọi API /api/n8n/install"

sleep 10
DOMAIN=$(hostname -f)
SERVER_IP=$(curl -s https://api.ipify.org)
PORT=7071
API_KEY=""

# Đọc PORT và API_KEY từ .env nếu có
if [ -f "$APP_DIR/.env" ]; then
  PORT_FROM_ENV=$(grep '^PORT=' "$APP_DIR/.env" | cut -d '=' -f2)
  [ -n "$PORT_FROM_ENV" ] && PORT="$PORT_FROM_ENV"

  API_FROM_ENV=$(grep '^AGENT_API_KEY=' "$APP_DIR/.env" | cut -d '=' -f2)
  [ -n "$API_FROM_ENV" ] && API_KEY="$API_FROM_ENV"
fi

SUCCESS=0
for i in {1..100}; do
  DOMAIN_IP=$(dig +short A "$DOMAIN" @8.8.8.8 | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1)
  if [[ "$DOMAIN_IP" == "$SERVER_IP" ]]; then
    echo "✅ DNS chính xác: $DOMAIN → $DOMAIN_IP"
    SUCCESS=1
    break
  else
    echo "❌ DNS chưa đúng ($DOMAIN → $DOMAIN_IP), thử lại lần $i..."
    sleep 2
  fi
done

systemctl restart n8n-agent
sleep 3
if [[ "$SUCCESS" -eq 1 ]]; then
  echo "📡 Gửi request tới: http://localhost:$PORT/api/n8n/install"
  curl -s -X POST "http://localhost:$PORT/api/n8n/install" \
    -H "Content-Type: application/json" \
    -H "tng-api-key: $API_KEY" \
    -d '{"domain": "'"$DOMAIN"'", "email": "'"$EMAIL"'"}'
  log_step "✅ Đã gọi API /api/n8n/install"
else
  echo "⚠️ DNS không trỏ đúng sau 100 lần thử → bỏ qua gọi API"
  log_step "⚠️ Bỏ qua gọi API vì DNS không đúng"
fi

# ========== 9. Kết thúc ==========
echo "🎉 Cài đặt hoàn tất!"
echo "➡️ Agent service: systemctl status n8n-agent"
echo "➡️ Auto-update: systemctl list-timers | grep n8n-agent"
echo "➡️ Manual update: $UPDATE_SCRIPT"

log_step "✅ Toàn bộ cài đặt hoàn tất"
