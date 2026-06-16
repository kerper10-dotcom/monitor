#!/bin/bash
# Deploy both Njuskalo bots to Oracle VM from your Mac.
# Usage: ./oracle/deploy-from-mac.sh <PUBLIC_IP>
set -euo pipefail

VM_IP="${1:?Usage: ./oracle/deploy-from-mac.sh <PUBLIC_IP>}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/oracle_njuskalo}"
SSH_USER="${SSH_USER:-ubuntu}"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=accept-new ${SSH_USER}@${VM_IP}"
RSYNC="rsync -avz -e \"ssh -i $SSH_KEY -o StrictHostKeyChecking=accept-new\""

BASE="$(cd "$(dirname "$0")/.." && pwd)"
PARENT="$(dirname "$BASE")"
MRVICA="$PARENT/njuskalo-monitor-mrvica"

echo "==> Testing SSH to $VM_IP..."
$SSH "echo Connected as \$(whoami)@\$(hostname)"

echo "==> Server base setup..."
$SSH "bash -s" < "$BASE/oracle/setup-server.sh"

echo "==> Upload njuskalo-monitor..."
rsync -avz -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=accept-new" \
  --exclude venv --exclude .git --exclude __pycache__ --exclude logs --exclude .DS_Store \
  "$BASE/" "${SSH_USER}@${VM_IP}:/home/ubuntu/bots/njuskalo-monitor/"

if [[ -d "$MRVICA" ]]; then
  echo "==> Upload njuskalo-monitor-mrvica..."
  rsync -avz -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=accept-new" \
    --exclude venv --exclude .git --exclude __pycache__ --exclude logs --exclude .DS_Store \
    "$MRVICA/" "${SSH_USER}@${VM_IP}:/home/ubuntu/bots/njuskalo-monitor-mrvica/"
else
  echo "WARN: mrvica bot not found at $MRVICA"
fi

echo "==> Install Python envs..."
$SSH "bash /home/ubuntu/bots/njuskalo-monitor/oracle/install-bot.sh /home/ubuntu/bots/njuskalo-monitor"
[[ -d "$MRVICA" ]] && $SSH "bash /home/ubuntu/bots/njuskalo-monitor/oracle/install-bot.sh /home/ubuntu/bots/njuskalo-monitor-mrvica"

echo "==> Setup cron (staggered hourly)..."
$SSH 'bash -s' <<'CRON'
(set -e
CRON1="5 * * * * /home/ubuntu/bots/njuskalo-monitor/scripts/run_monitor.sh"
CRON2="35 * * * * /home/ubuntu/bots/njuskalo-monitor-mrvica/scripts/run_monitor.sh"
TMP=$(mktemp)
crontab -l 2>/dev/null | grep -v njuskalo-monitor > "$TMP" || true
echo "$CRON1" >> "$TMP"
echo "$CRON2" >> "$TMP"
crontab "$TMP"
rm "$TMP"
echo "Crontab:"
crontab -l
)
CRON

echo ""
echo "==> DEPLOY DONE"
echo "Test main bot:  ssh -i $SSH_KEY ${SSH_USER}@${VM_IP} '/home/ubuntu/bots/njuskalo-monitor/scripts/run_monitor.sh'"
echo "Logs:           ssh -i $SSH_KEY ${SSH_USER}@${VM_IP} 'tail -f /home/ubuntu/bots/njuskalo-monitor/logs/monitor-$(date +%Y%m%d).log'"