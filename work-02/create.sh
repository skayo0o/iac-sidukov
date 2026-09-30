#!/usr/bin/env bash
set -euo pipefail            # стоп на первой ошибке и на пустой переменной

# ---- параметры варианта ----
PREFIX=sidukov-08            # префикс имён ресурсов
ZONE_A=ru-central1-b         # зона A
ZONE_B=ru-central1-d         # зона B
CIDR_A=10.18.1.0/24          # подсеть в зоне A
CIDR_B=10.18.2.0/24          # подсеть в зоне B
APP_PORT=8024                # порт, на котором отвечает nginx
GREETING=labwork             # слово из варианта, оно же на странице
VM_COUNT="${1:-3}"           # 1-й аргумент скрипта или 3 по умолчанию
DISK_SIZE="${2:-10}"         # 2-й аргумент скрипта или 10 по умолчанию
BOOT_SIZE=20                 # загрузочный диск, ГБ — из варианта
IMAGE_FAMILY=ubuntu-2404-lts # образ машин, одинаковый у всех вариантов

# запуск из любой директории
cd "$(dirname "$0")"

# проверки до начала создания ресурсов
if ! [ "$VM_COUNT" -ge 1 ] 2>/dev/null; then
  echo "!ОШИБКА!"
  echo "число машин должно быть целым и больше 0'"
  exit 1
fi
if ! [ "$DISK_SIZE" -ge 1 ] 2>/dev/null; then
  echo "!ОШИБКА!"
  echo "размер диска должен быть целым числом ГБ'"
  exit 1
fi
if [ ! -f ~/.ssh/id_ed25519.pub ]; then
  echo "!ОШИБКА!"
  echo "не найден SSH-ключ по пути ~/.ssh/id_ed25519.pub"
  exit 1
fi
if yc vpc network get "$PREFIX-net" > /dev/null 2>&1; then
  echo "!ОШИБКА!"
  echo "сеть $PREFIX-net уже существует"
  exit 1
fi

echo "==> стенд $PREFIX: машин $VM_COUNT, доп. диск $DISK_SIZE ГБ"

echo "==> сеть и подсети"
yc vpc network create --name "$PREFIX-net"

yc vpc subnet create --name "$PREFIX-subnet-a" --network-name "$PREFIX-net" \
  --zone "$ZONE_A" --range "$CIDR_A"
yc vpc subnet create --name "$PREFIX-subnet-b" --network-name "$PREFIX-net" \
  --zone "$ZONE_B" --range "$CIDR_B"

echo "==> файл настройки из шаблона"
SSH_KEY=$(cat ~/.ssh/id_ed25519.pub)
export APP_PORT GREETING SSH_KEY
envsubst '${APP_PORT} ${GREETING} ${SSH_KEY}' \
  < cloud-init.tpl.yaml > cloud-init.yaml

# дополнительный диск создаем раньше чем машины,
# чтобы потом его можно было подключить к первой машине
echo "==> дополнительный диск"
yc compute disk create --name "$PREFIX-data" --zone "$ZONE_A" \
  --size "$DISK_SIZE" --type network-hdd

echo "==> машины"
ZONES=("$ZONE_A" "$ZONE_B")
SUBNETS=("$PREFIX-subnet-a" "$PREFIX-subnet-b")

for i in $(seq 1 "$VM_COUNT"); do
  idx=$(( (i - 1) % 2 ))
  # диск подключаем только к первой машине
     DISK_ARG=""
     if [ "$i" -eq 1 ]; then
       DISK_ARG="--attach-disk disk-name=$PREFIX-data,device-name=data"
     fi
  yc compute instance create \
    --name "$PREFIX-app-$i" \
    --zone "${ZONES[$idx]}" \
    --platform standard-v3 \
    --cores=2 --core-fraction=20 --memory=2 \
    --preemptible \
    --create-boot-disk image-folder-id=standard-images,image-family="$IMAGE_FAMILY",type=network-hdd,size="$BOOT_SIZE" \
    --network-interface subnet-name="${SUBNETS[$idx]}",nat-ip-version=ipv4 \
    --hostname "$PREFIX-app-$i" \
    --metadata-from-file user-data=cloud-init.yaml \
    $DISK_ARG
done

echo "==> целевая группа"

# собираем список машин: имя подсети и внутренний адрес каждой
TARGETS=""
for i in $(seq 1 "$VM_COUNT"); do
  idx=$(( (i - 1) % 2 ))
  IP=$(yc compute instance get "$PREFIX-app-$i" --format json \
    | jq -r '.network_interfaces[0].primary_v4_address.address')
  TARGETS="$TARGETS --target subnet-name=${SUBNETS[$idx]},address=$IP"
done

yc load-balancer target-group create --name "$PREFIX-tg" $TARGETS

echo "==> балансировщик"

# идентификатор целевой группы: балансировщик ссылается на неё по нему
TG_ID=$(yc load-balancer target-group get --name "$PREFIX-tg" --format json | jq -r .id)

yc load-balancer network-load-balancer create \
  --name "$PREFIX-lb" \
  --region-id ru-central1 \
  --listener name=http,port=80,target-port="$APP_PORT",external-ip-version=ipv4 \
  --target-group target-group-id="$TG_ID",healthcheck-name=http,healthcheck-interval=2s,healthcheck-timeout=1s,healthcheck-unhealthythreshold=2,healthcheck-healthythreshold=2,healthcheck-http-port="$APP_PORT",healthcheck-http-path=/

# ожидание готовности стенда
echo "==> ждём, пока все машины станут HEALTHY"
HEALTHY=0
for try in $(seq 1 30); do
  HEALTHY=$(yc load-balancer network-load-balancer target-states \
    --name "$PREFIX-lb" --target-group-id "$TG_ID" --format json \
    | jq -r '.[].status' | grep -c '^HEALTHY$' || true)
  echo "   проверка $try: готово $HEALTHY из $VM_COUNT"
  if [ "$HEALTHY" -eq "$VM_COUNT" ]; then
    break
  fi
  sleep 10
done

LB_IP=$(yc load-balancer network-load-balancer get --name "$PREFIX-lb" --format json \
  | jq -r '.listeners[0].address')
echo "Стенд готов, балансировщик доступен по http://$LB_IP"