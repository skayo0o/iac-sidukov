#!/usr/bin/env bash

set -euo pipefail

PREFIX="${PREFIX:-sidukov-08}"

# префикс можно передать аргументом
if [[ "${1:-}" == "--prefix" ]]; then
  PREFIX="$2"
fi

echo "==> удаляем ресурсы с меткой owner=$PREFIX"

# имена ресурсов с меткой owner=$PREFIX
mine() {
  "$@" --format json \
    | jq -r --arg p "$PREFIX" '.[] | select(.labels.owner == $p) | .name'
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

# загрузочные диски удаляются вместе с машинами
echo "==> машины"
for n in $(mine yc compute instance list); do
  yc compute instance delete --name "$n"
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

# загрузочный диск создаётся вместе с машиной и меток не получает,
# поэтому по метке его не найти; показываем диски, не подключённые ни к одной машине
echo "==> диски без машины (проверьте вручную)"
yc compute disk list --format json \
  | jq -r '.[] | select((.instance_ids // []) | length == 0) | "  \(.name // "") \(.id)"'

echo "==> уборка завершена"