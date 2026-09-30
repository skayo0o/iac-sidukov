#!/usr/bin/env bash
set -euo pipefail            # стоп на первой ошибке и на пустой переменной

PREFIX=sidukov-08

# удаляет ресурс, только если он существует
# $1 — тип ресурса в yc, $2 — имя
remove() {
  if yc $1 get "$2" > /dev/null 2>&1; then
    echo "удаляю $2"
    yc $1 delete "$2"
  else
    echo "$2 — уже нет, пропускаю"
  fi
}

echo "==> балансировщик и целевая группа"
remove "load-balancer network-load-balancer" "$PREFIX-lb"
remove "load-balancer target-group" "$PREFIX-tg"

echo "==> машины"
# не считаем машины, а спрашиваем облако, что есть с нашим префиксом
VMS=$(yc compute instance list --format json | jq -r '.[].name' | grep "^$PREFIX-app-" || true)
for vm in $VMS; do
  remove "compute instance" "$vm"
done

echo "==> диск"
remove "compute disk" "$PREFIX-data"

echo "==> подсети и сеть"
remove "vpc subnet" "$PREFIX-subnet-a"
remove "vpc subnet" "$PREFIX-subnet-b"
remove "vpc network" "$PREFIX-net"

echo "==> уборка закончена"
