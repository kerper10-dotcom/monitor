#!/bin/bash
# Install one bot in its directory. Usage: install-bot.sh /home/ubuntu/bots/njuskalo-monitor
set -euo pipefail

BOT_DIR="${1:?bot directory required}"
cd "$BOT_DIR"

python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip -q
pip install -r requirements.txt -q
playwright install chromium
playwright install-deps chromium 2>/dev/null || sudo playwright install-deps chromium || true

mkdir -p logs
chmod +x scripts/run_monitor.sh 2>/dev/null || true

if [[ ! -f .env ]]; then
  cat > .env <<'EOF'
TZ=Europe/Zagreb
EOF
  echo "Created .env in $BOT_DIR — add TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID if not in monitor.py"
fi

echo "OK: $BOT_DIR"