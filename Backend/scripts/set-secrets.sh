#!/usr/bin/env bash
# Writes the Anthropic / Soniox keys (and optionally the Simulator dev token) into the stack's
# Secrets Manager secret, keeping the generated session_secret. Keys are read silently, so they
# never land in shell history or the process list.
#
#   Backend/scripts/set-secrets.sh [stack-name]        (default: gist-it-backend)
set -euo pipefail

STACK="${1:-gist-it-backend}"
ARN=$(aws cloudformation describe-stacks --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='SecretArn'].OutputValue" --output text)
echo "Secret: $ARN"

read -rsp "Anthropic API key (empty = keep current): " ANTHROPIC; echo
read -rsp "Soniox API key (empty = keep current): " SONIOX; echo
read -rsp "Simulator dev token (empty = keep current, '-' = disable): " DEV; echo

CURRENT=$(aws secretsmanager get-secret-value --secret-id "$ARN" --query SecretString --output text)
UPDATED=$(CURRENT="$CURRENT" ANTHROPIC="$ANTHROPIC" SONIOX="$SONIOX" DEV="$DEV" node -e '
  const s = JSON.parse(process.env.CURRENT);
  if (process.env.ANTHROPIC) s.anthropic_api_key = process.env.ANTHROPIC;
  if (process.env.SONIOX) s.soniox_api_key = process.env.SONIOX;
  if (process.env.DEV === "-") s.dev_token = "";
  else if (process.env.DEV) s.dev_token = process.env.DEV;
  process.stdout.write(JSON.stringify(s));
')
# Pass the value through a 0600 temp file, not argv.
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
chmod 600 "$TMP"
printf '%s' "$UPDATED" > "$TMP"
aws secretsmanager put-secret-value --secret-id "$ARN" --secret-string "file://$TMP" >/dev/null
echo "Updated. Running functions pick it up within 5 minutes."
