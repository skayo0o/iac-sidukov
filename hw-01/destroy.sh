#!/usr/bin/env bash

set -euo pipefail

PREFIX="${PREFIX:-sidukov-08}"

# префикс можно передать аргументом
if [[ "${1:-}" == "--prefix" ]]; then
  PREFIX="$2"
fi

# имена ресурсов с "$PREFIX-"
mine() {
  "$@" --format json \
    | jq -r --arg p "$PREFIX-" '.[] | select((.name // "") | startswith($p)) | .name'
}

# сначала что ссылается на другие ресурсы
echo "==> балансировщики"
for n in $(mine yc load-balancer network-load-balancer list); do
  yc load-balancer network-load-balancer delete --name "$n"
done

echo "==> целевые группы"
for n in $(mine yc load-balancer target-group list); do
  yc load-balancer target-group delete --name "$n"
done

echo "==> машины"
for n in $(mine yc compute instance list); do
  yc compute instance delete --name "$n"
done

# загрузочные диски удаляются вместе с машинами, но проверяем отдельно
echo "==> диски"
for n in $(mine yc compute disk list); do
  yc compute disk delete --name "$n"
done

# подсеть ссылается на таблицу
echo "==> отвязка таблиц от подсетей"
for n in $(mine yc vpc subnet list); do
  RT=$(yc vpc subnet get \
    --name "$n" \
    --format json \
    | jq -r '.route_table_id // empty')

  if [[ -n "$RT" ]]; then
    yc vpc subnet update \
      --name "$n" \
      --disassociate-route-table
  fi
done

echo "==> таблицы маршрутизации"
for n in $(mine yc vpc route-table list); do
  yc vpc route-table delete --name "$n"
done

echo "==> NAT-шлюзы"
for n in $(mine yc vpc gateway list); do
  yc vpc gateway delete --name "$n"
done

echo "==> подсети"
for n in $(mine yc vpc subnet list); do
  yc vpc subnet delete --name "$n"
done

echo "==> сети"
for n in $(mine yc vpc network list); do
  yc vpc network delete --name "$n"
done

# зарезервированные адреса тарифицируются даже без машин
echo "==> адреса"
for n in $(mine yc vpc address list); do
  yc vpc address delete --name "$n"
done

echo "==> уборка завершена"
