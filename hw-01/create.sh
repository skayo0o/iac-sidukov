#!/usr/bin/env bash
set -euo pipefail

# переменные из варианта
PREFIX=sidukov-08
ZONE_A=ru-central1-b
ZONE_B=ru-central1-d
CIDR_A=10.18.1.0/24
CIDR_B="${CIDR_B:-10.18.2.0/24}"
APP_PORT="${APP_PORT:-8024}"
GREETING="${GREETING:-labwork}"
WEB_COUNT="${WEB_COUNT:-3}"
IMAGE_FAMILY=ubuntu-2404-lts

# запуск из любой директории
cd "$(dirname "$0")" 

# вывод аргументов командной строки
usage() { echo "Использование: $0 [--prefix P] [--web-count N] [--port N] [--greeting W]"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)    PREFIX="$2";    shift 2 ;;
    --web-count) WEB_COUNT="$2"; shift 2 ;;
    --port)      APP_PORT="$2";  shift 2 ;;
    --greeting)  GREETING="$2";  shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "неизвестный аргумент $1" >&2; usage; exit 2 ;;
  esac
done
echo "Параметры: PREFIX=$PREFIX WEB_COUNT=$WEB_COUNT APP_PORT=$APP_PORT GREETING=$GREETING"

# проверяем ответ команды get
# проверка стоит прямо перед созданием каждого ресурса
exists() { 
  "$@" >/dev/null 2>&1; 
}   

skip() { 
  echo "  $1 уже есть, пропускаю"; 
}

# сеть и подсети
echo "==> сеть и подсети"
if exists yc vpc network get --name "$PREFIX-net"; then skip "$PREFIX-net"
else yc vpc network create --name "$PREFIX-net"; fi

for s in a b; do
  if [[ $s == a ]]; then Z=$ZONE_A; C=$CIDR_A; else Z=$ZONE_B; C=$CIDR_B; fi
  if exists yc vpc subnet get --name "$PREFIX-subnet-$s"; then skip "$PREFIX-subnet-$s"
  else yc vpc subnet create --name "$PREFIX-subnet-$s" --network-name "$PREFIX-net" --zone "$Z" --range "$C"; fi
done

# NAT-шлюз и таблица маршрутизации
# ОБЯЗАТЕЛЬНО ДО СОЗДАНИЯ 
echo "==> NAT-шлюз"
if exists yc vpc gateway get --name "$PREFIX-nat"; then skip "$PREFIX-nat"
else yc vpc gateway create --name "$PREFIX-nat"; fi
GW_ID=$(yc vpc gateway get --name "$PREFIX-nat" --format json | jq -r .id)

if exists yc vpc route-table get --name "$PREFIX-rt"; then skip "$PREFIX-rt"
else yc vpc route-table create --name "$PREFIX-rt" --network-name "$PREFIX-net" \
       --route "destination=0.0.0.0/0,gateway-id=$GW_ID"; fi

RT_ON_SUBNET=$(yc vpc subnet get --name "$PREFIX-subnet-a" --format json | jq -r '.route_table_id // empty')
if [[ -n "$RT_ON_SUBNET" ]]; then skip "привязка $PREFIX-rt к subnet-a"
else yc vpc subnet update --name "$PREFIX-subnet-a" --route-table-name "$PREFIX-rt"; fi

# файл настройки из шаблона
echo "==> файл настройки из шаблона"
SSH_KEY=$(cat ~/.ssh/id_ed25519.pub)
export APP_PORT GREETING SSH_KEY
envsubst '${APP_PORT} ${GREETING} ${SSH_KEY}' \
  < cloud-init.tpl.yaml > cloud-init.yaml

# веб-серверы
echo "==> веб-серверы"
ZONES=("$ZONE_A" "$ZONE_B"); SUBNETS=("$PREFIX-subnet-a" "$PREFIX-subnet-b")
for i in $(seq 1 "$WEB_COUNT"); do
  idx=$(( (i - 1) % 2 )); NAME="$PREFIX-web-$i"
  if exists yc compute instance get --name "$NAME"; then skip "$NAME"; continue; fi
  yc compute instance create --name "$NAME" --hostname "$NAME" \
    --zone "${ZONES[$idx]}" --platform standard-v3 \
    --cores=2 --core-fraction=20 --memory=2 --preemptible \
    --create-boot-disk image-folder-id=standard-images,image-family="$IMAGE_FAMILY",type=network-hdd,size=20 \
    --network-interface subnet-name="${SUBNETS[$idx]}",nat-ip-version=ipv4 \
    --metadata-from-file user-data=cloud-init.yaml
done

# сервер приложения
echo "==> сервер приложения"
if exists yc compute instance get --name "$PREFIX-app"; then skip "$PREFIX-app"
else yc compute instance create --name "$PREFIX-app" --hostname "$PREFIX-app" \
    --zone "$ZONE_A" --platform standard-v3 \
    --cores=2 --core-fraction=20 --memory=2 --preemptible \
    --create-boot-disk image-folder-id=standard-images,image-family="$IMAGE_FAMILY",type=network-hdd,size=20 \
    --network-interface subnet-name="$PREFIX-subnet-a" \
    --metadata-from-file user-data=cloud-init.yaml; fi

# целевая группа 
echo "==> целевая группа"
if exists yc load-balancer target-group get --name "$PREFIX-tg"; then skip "$PREFIX-tg"
else
  TARGETS=()
  for i in $(seq 1 "$WEB_COUNT"); do
    idx=$(( (i - 1) % 2 ))
    IP=$(yc compute instance get --name "$PREFIX-web-$i" --format json | jq -r '.network_interfaces[0].primary_v4_address.address')
    TARGETS+=(--target "subnet-name=${SUBNETS[$idx]},address=$IP")
  done
  yc load-balancer target-group create --name "$PREFIX-tg" "${TARGETS[@]}"
fi

# балансировщик
echo "==> балансировщик"
if exists yc load-balancer network-load-balancer get --name "$PREFIX-lb"; then skip "$PREFIX-lb"
else
  TG_ID=$(yc load-balancer target-group get --name "$PREFIX-tg" --format json | jq -r .id)
  yc load-balancer network-load-balancer create --name "$PREFIX-lb" --region-id ru-central1 \
    --listener name=http,port=80,target-port="$APP_PORT",external-ip-version=ipv4 \
    --target-group target-group-id="$TG_ID",healthcheck-name=http,healthcheck-interval=2s,healthcheck-timeout=1s,healthcheck-unhealthythreshold=2,healthcheck-healthythreshold=2,healthcheck-http-port="$APP_PORT",healthcheck-http-path=/
fi

LB_IP=$(yc load-balancer network-load-balancer get --name "$PREFIX-lb" --format json | jq -r '.listeners[0].address')
echo "Стенд готов, балансировщик доступен по http://$LB_IP"
