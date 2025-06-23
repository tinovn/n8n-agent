#!/bin/bash
set -e

APP_DIR="/opt/n8n-agent"
AGENT_BIN="n8n-agent"
UPGRADE_SCRIPT="$APP_DIR/upgrade.sh"

echo "🔄 Cập nhật n8n-agent từ GitHub..."
systemctl stop n8n-agent
cd "$APP_DIR"
git reset --hard
git pull origin main
chmod +x "$AGENT_BIN"

# Chạy upgrade.sh nếu có, sau đó xóa
if [[ -f "$UPGRADE_SCRIPT" ]]; then
  echo "⚙️ Đã phát hiện upgrade.sh → chạy..."
  chmod +x "$UPGRADE_SCRIPT"
  "$UPGRADE_SCRIPT"
  echo "🧹 Xoá upgrade.sh sau khi chạy xong..."
  rm -f "$UPGRADE_SCRIPT"
fi

systemctl daemon-reload
systemctl start n8n-agent
echo "✅ Đã cập nhật và khởi động lại n8n-agent"
