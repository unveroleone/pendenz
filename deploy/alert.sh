#!/bin/sh
# Tells the owner in Telegram that a systemd unit on this host failed. pendenz-alert@.service runs it
# with the name of the failed unit and takes the bot token and the chat from alert.env.
set -eu
unit="$1"
# The end of the unit's log. Cut by bytes so the message stays below Telegram's 4096 characters;
# iconv drops a character that the cut split.
log=$(journalctl -u "$unit" -n 20 --no-pager -o cat 2>/dev/null | tail -c 3000 | iconv -c -f UTF-8 -t UTF-8 || true)
text="Pendenz on $(hostname): $unit failed.

$log"
curl --fail --silent --show-error --max-time 20 --retry 3 \
    --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
    --data-urlencode "text=$text" \
    "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" >/dev/null
