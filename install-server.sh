#!/bin/bash

set -e

echo "✅ Bắt đầu cài đặt N8N Agent..."

APP_DIR="/opt/n8n-agent"
GIT_REPO="https://github.com/tinovn/n8n-agent.git"
AGENT_BIN="n8n-agent"
UPDATE_SCRIPT="$APP_DIR/update-agent.sh"

STEP_LOG="/var/log/n8n-agent-install-steps.log"

log_step() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$STEP_LOG"
}



# ===========================
# 1. Cập nhật hệ thống
# ===========================
echo "🔄 Cập nhật hệ thống..."
apt update && apt upgrade -y

echo "📦 Cài các công cụ hệ thống cần thiết..."
apt install -y dnsutils curl git ca-certificates gnupg lsb-release


# ===========================
# 2. Cài Docker & Compose v2
# ===========================
echo "🐳 Cài Docker & Compose..."
apt install -y ca-certificates curl gnupg lsb-release git

mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable docker
systemctl start docker

log_step "Đã cài Docker & Docker Compose"


# ===========================
# 3. Cài Nginx
# ===========================
echo "🌐 Cài Nginx..."
apt install -y nginx
systemctl enable nginx
systemctl start nginx


log_step "✅ Đã cài Nginx"
# ===========================
# 3b. Cài Certbot & SSL support
# ===========================
echo "🔐 Cài certbot (Let's Encrypt)..."
apt install -y certbot python3-certbot-nginx

log_step "✅ Đã cài Cerbot"

# ===========================
# 4. Clone agent
# ===========================
echo "📥 Clone agent từ GitHub..."
rm -rf "$APP_DIR"
git clone "$GIT_REPO" "$APP_DIR"

cd "$APP_DIR"
chmod +x "$AGENT_BIN"

log_step "✅ Đã cài n8n agent"
# ===========================
# 5. Tạo systemd service
# ===========================
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

# ===========================
# 6. Tạo update-agent.sh script
# ===========================
echo "🧰 Tạo script cập nhật agent..."

cat <<EOF > "$UPDATE_SCRIPT"
#!/bin/bash
set -e

APP_DIR="${APP_DIR}"
AGENT_BIN="${AGENT_BIN}"

echo "🔄 Cập nhật agent từ GitHub..."
systemctl stop n8n-agent

cd "\$APP_DIR"
git reset --hard
git pull origin main
chmod +x "\$AGENT_BIN"

systemctl daemon-reload
systemctl start n8n-agent
EOF

chmod +x "$UPDATE_SCRIPT"

# ===========================
# 7. Tạo auto-update systemd timer
# ===========================
echo "⏲️  Tạo auto-update khi khởi động..."

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

# ===========================
# 8. Kết thúc
# ===========================
echo "🎉 Hoàn tất cài đặt!"
echo "➡️ Agent service: systemctl status n8n-agent"
echo "➡️ Auto-update timer: systemctl list-timers | grep n8n-agent"
echo "➡️ Manual update: sudo $UPDATE_SCRIPT"

log_step "✅ Đã cài xong các thành phần"

# ===========================
# 9. Gọi API cài đặt N8N (/api/n8n/install)
# ===========================

echo "⏳ Đợi 10 giây cho agent khởi động..."
sleep 10
# 🌐 Lấy domain từ hostname đầy đủ
DOMAIN=$(hostname -f)
EMAIL="noreply@tino.org"
# 🌐 Lấy IP public của máy chủ
SERVER_IP=$(curl -s https://api.ipify.org)
echo "🌐 Tên miền sử dụng: $DOMAIN"
echo "🌐 IP máy chủ: $SERVER_IP"
# 🔁 Kiểm tra DNS hostname trỏ đúng IP public
SUCCESS=0
for i in {1..100}; do
    # DOMAIN_IP=$(dig +short "$DOMAIN" | tail -n1)
    DOMAIN_IP=$(dig +short A "$DOMAIN" @8.8.8.8 | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1)
    if [[ "$DOMAIN_IP" == "$SERVER_IP" ]]; then
        echo "✅ DNS trỏ đúng sau $i lần thử: $DOMAIN → $DOMAIN_IP"
        SUCCESS=1
        break
    else
        echo "❌ DNS chưa đúng ($DOMAIN → $DOMAIN_IP), thử lại..."
        sleep 2
    fi
done

if [[ "$SUCCESS" -eq 0 ]]; then
    echo "❌ DNS không trỏ đúng về máy chủ sau 100 lần thử. Bỏ qua bước gọi API."
    exit 1
fi

# 📦 Lấy PORT từ .env nếu có, mặc định 7071
PORT=7071

if [ -f "$APP_DIR/.env" ]; then
  ENV_PORT=$(grep '^PORT=' "$APP_DIR/.env" | cut -d '=' -f2)
  if [ -n "$ENV_PORT" ]; then
    PORT="$ENV_PORT"
  fi

  ENV_API_KEY=$(grep '^AGENT_API_KEY=' "$APP_DIR/.env" | cut -d '=' -f2)
  if [ -n "$ENV_API_KEY" ]; then
    API_KEY="$ENV_API_KEY"
  fi
fi



echo "📡 Gửi request đến: http://localhost:$PORT/api/n8n/install"

curl -s -X POST "http://localhost:$PORT/api/n8n/install" \
  -H "Content-Type: application/json" \
  -H "tng-api-key: $API_KEY" \
  -d '{
    "domain": "'"$DOMAIN"'",
    "email": "'"$EMAIL"'"
  }'


log_step "✅ Đã cài hoàn tất"
