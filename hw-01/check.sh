#!/usr/bin/env bash

# все проверки должны выполниться, код возврата собираем сами
set -uo pipefail

PREFIX="${PREFIX:-sidukov-08}"
APP_PORT="${APP_PORT:-8024}"
GREETING="${GREETING:-labwork}"
WEB_COUNT="${WEB_COUNT:-3}"
FAIL=0

# ssh без вопросов про ключ хоста
SSH_OPTS=(
  -o BatchMode=yes
  -o ConnectTimeout=5
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
)

# адрес балансировщика, если его нет, проверять нечего
LB_IP=$(yc load-balancer network-load-balancer get \
  --name "$PREFIX-lb" \
  --format json 2>/dev/null \
  | jq -r '.listeners[0].address // empty')

if [[ -z "$LB_IP" ]]; then
  echo "==> балансировщик $PREFIX-lb не найден"
  exit 1
fi

# балансировщик отвечает кодом 200
CODE=$(curl -s \
  -o /dev/null \
  -w '%{http_code}' \
  --max-time 5 \
  "http://$LB_IP")

if [[ "$CODE" == 200 ]]; then
  echo "==> балансировщик отвечает: $CODE"
else
  echo "==> балансировщик отвечает: $CODE"
  FAIL=1
fi

# 20 запросов, собираем уникальные имена ответивших машин
HOSTS=$(
  for i in $(seq 1 20); do
    curl -s --max-time 3 "http://$LB_IP" \
      | grep -o "$GREETING on [a-z0-9-]*" \
      | awk '{print $3}'
  done | sort -u
)
N=$(grep -c . <<< "$HOSTS")
LIST=$(paste -sd, <<< "$HOSTS")

if (( N >= WEB_COUNT && N > 1 )); then
  echo "==> ответили машины ($N из $WEB_COUNT): $LIST"
else
  echo "==> ответили машины ($N из $WEB_COUNT): ${LIST:-нет}"
  FAIL=1
fi

# сервер приложения доступен с web-1 по внутреннему адресу
WEB_IP=$(yc compute instance get \
  --name "$PREFIX-web-1" \
  --format json 2>/dev/null \
  | jq -r '.network_interfaces[0].primary_v4_address.one_to_one_nat.address // empty')

APP_INT=$(yc compute instance get \
  --name "$PREFIX-app" \
  --format json 2>/dev/null \
  | jq -r '.network_interfaces[0].primary_v4_address.address // empty')

APP_CODE=$(ssh "${SSH_OPTS[@]}" "student@$WEB_IP" \
  "curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://$APP_INT:$APP_PORT" \
  2>/dev/null)

if [[ "$APP_CODE" == 200 ]]; then
  echo "==> сервер приложения ($APP_INT) доступен с web-1"
else
  echo "==> сервер приложения недоступен с web-1"
  FAIL=1
fi

# 0 если всё прошло, 1 если хотя бы одна проверка не прошла
exit $FAIL
