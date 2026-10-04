#!/usr/bin/env bash
# ДЗ 1. Удаляет всё, что создал create.sh.
# Не полагается на то, что в облаке ровно созданные им ресурсы: спрашивает облако,
# что заведено с нашим префиксом (или с меткой owner, ключ --by-label), и удаляет найденное.
# Отрабатывает на любом состоянии стенда: чего уже нет, того он просто не найдёт.
#
#   bash destroy.sh               # поиск по префиксу pak-05-
#   bash destroy.sh --by-label    # поиск по метке owner=pak-05 (задача со звёздочкой 1)
set -euo pipefail # стоп на первой ошибке и на пустой переменной

# ---- параметры варианта ----
PREFIX="${PREFIX:-pak-05}"   # префикс имён ресурсов
BY_LABEL=0                   # 1 — искать по метке owner, а не по префиксу имени

# ---- аргументы командной строки ----
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)   PREFIX="${2:?у $1 нет значения}"; shift 2 ;;
    --by-label) BY_LABEL=1; shift ;;
    -h|--help)  echo "параметры: --prefix ($PREFIX), --by-label"; exit 0 ;;
    *)          echo "неизвестный аргумент: $1" >&2; exit 1 ;;
  esac
done

# Какие ресурсы считаем своими. Префикс сравниваем вместе с дефисом:
# "pak-05-" не зацепит чужой "pak-050-net".
if [ "$BY_LABEL" = 1 ]; then
  echo "ищу ресурсы с меткой owner=$PREFIX"
  MINE="select(.labels.owner == \"$PREFIX\")"
else
  echo "ищу ресурсы с префиксом $PREFIX-"
  MINE="select((.name // \"\") | startswith(\"$PREFIX-\"))"
fi
# Загрузочные диски создаются вместе с машиной и меток не получают,
# поэтому диски ищем только по имени.
BY_NAME="select((.name // \"\") | startswith(\"$PREFIX-\"))"

# Порядок обратный созданию: сначала то, что ссылается на другие ресурсы.

echo "==> балансировщики"
yc load-balancer network-load-balancer list --format json | jq -r ".[] | $MINE | .name" \
  | while read -r name; do
      yc load-balancer network-load-balancer delete "$name" >/dev/null
      echo "удалён балансировщик $name"
    done

echo "==> целевые группы"
yc load-balancer target-group list --format json | jq -r ".[] | $MINE | .name" \
  | while read -r name; do
      yc load-balancer target-group delete "$name" >/dev/null
      echo "удалена целевая группа $name"
    done

echo "==> машины"
yc compute instance list --format json | jq -r ".[] | $MINE | .name" \
  | while read -r name; do
      yc compute instance delete "$name" >/dev/null
      echo "удалена машина $name"
    done

echo "==> оставшиеся диски"
# загрузочные удаляются вместе с машиной; здесь — всё, что почему-то осталось
yc compute disk list --format json | jq -r ".[] | $BY_NAME | .name" \
  | while read -r name; do
      yc compute disk delete "$name" >/dev/null
      echo "удалён диск $name"
    done

echo "==> подсети: сначала отвязываем таблицу маршрутизации"
yc vpc subnet list --format json | jq -r ".[] | $MINE | .name" \
  | while read -r name; do
      if [ -n "$(yc vpc subnet get --name "$name" --format json | jq -r '.route_table_id // empty')" ]; then
        yc vpc subnet update --name "$name" --disassociate-route-table >/dev/null
        echo "таблица маршрутизации отвязана от $name"
      fi
      yc vpc subnet delete "$name" >/dev/null
      echo "удалена подсеть $name"
    done

echo "==> таблицы маршрутизации"
yc vpc route-table list --format json | jq -r ".[] | $MINE | .name" \
  | while read -r name; do
      yc vpc route-table delete "$name" >/dev/null
      echo "удалена таблица маршрутизации $name"
    done

echo "==> NAT-шлюзы"
yc vpc gateway list --format json | jq -r ".[] | $MINE | .name" \
  | while read -r name; do
      yc vpc gateway delete "$name" >/dev/null
      echo "удалён NAT-шлюз $name"
    done

echo "==> сети"
yc vpc network list --format json | jq -r ".[] | $MINE | .name" \
  | while read -r name; do
      yc vpc network delete "$name" >/dev/null
      echo "удалена сеть $name"
    done

echo "==> что осталось с префиксом $PREFIX-"
LEFT=0
for kind in "compute instance" "compute disk" "vpc subnet" "vpc route-table" "vpc gateway" \
            "vpc network" "load-balancer network-load-balancer" "load-balancer target-group"; do
  # shellcheck disable=SC2086  # kind — это две части команды yc, их нужно разбить
  names=$(yc $kind list --format json | jq -r ".[] | $BY_NAME | .name" | paste -sd' ' -)
  if [ -n "$names" ]; then
    echo "✗ $kind: $names"
    LEFT=1
  else
    echo "✓ $kind: пусто"
  fi
done

if [ "$LEFT" = 0 ]; then
  echo "==> убрано за $SECONDS с, ресурсов с префиксом $PREFIX- не осталось"
  exit 0
else
  echo "==> остались ресурсы: запустите destroy.sh ещё раз или удалите вручную" >&2
  exit 1
fi
