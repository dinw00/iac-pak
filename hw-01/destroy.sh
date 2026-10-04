#!/usr/bin/env bash
# destroy.sh — удаляет всё, что создал create.sh.
# Не полагается на то, что в облаке ровно созданные им ресурсы:
# находит своё по префиксу имени (или по метке owner, ключ --by-label) и удаляет найденное.
#
#   ./destroy.sh               # поиск по префиксу "pak-05-"
#   ./destroy.sh --by-label    # поиск по метке owner=pak-05 (задача со звёздочкой 1)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=params.sh
source "$HERE/params.sh"
parse_args "$@"
require_tools yc jq
require_cloud

START_TS=$(date +%s)

# mine: из JSON-списка yc ... list выбирает имена своих ресурсов.
# По префиксу сравниваем с "pak-05-", а не с "pak-05": иначе зацепим чужой pak-050-net.
mine() {
  if [[ "$BY_LABEL" == 1 ]]; then
    jq -r --arg owner "$PREFIX" '.[] | select((.labels.owner // "") == $owner) | .name'
  else
    jq -r --arg p "$PREFIX-" '.[] | select(.name | startswith($p)) | .name'
  fi
}
# Загрузочные диски создаются вместе с машиной и меток не получают,
# поэтому диски ищутся только по префиксу имени (pak-05-web-1-disk и т. п.)
mine_by_prefix() { jq -r --arg p "$PREFIX-" '.[] | select(.name // "" | startswith($p)) | .name'; }

if [[ "$BY_LABEL" == 1 ]]; then
  log "Ищу ресурсы с меткой owner=$PREFIX"
else
  log "Ищу ресурсы с префиксом $PREFIX-"
fi

# delete_all <что> <команда list...> -- <команда delete...>
delete_all() {
  local what="$1"; shift
  local list_cmd=() del_cmd=()
  while [[ "$1" != "--" ]]; do list_cmd+=("$1"); shift; done; shift
  del_cmd=("$@")
  local names
  mapfile -t names < <("${list_cmd[@]}" --format json | mine)
  if (( ${#names[@]} == 0 )); then
    log "  = $what: нечего удалять"
    return
  fi
  local n
  for n in "${names[@]}"; do
    "${del_cmd[@]}" "$n" >/dev/null
    log "  - удалён(а) $what $n"
  done
}

# Порядок обратный созданию: сначала то, что ссылается, потом то, на что ссылаются

step "1/7 Балансировщики"
delete_all "балансировщик" yc load-balancer network-load-balancer list -- yc load-balancer network-load-balancer delete

step "2/7 Целевые группы"
delete_all "целевая группа" yc load-balancer target-group list -- yc load-balancer target-group delete

step "3/7 Виртуальные машины (параллельно)"
mapfile -t VMS < <(yc compute instance list --format json | mine)
if (( ${#VMS[@]} == 0 )); then
  log "  = машины: нечего удалять"
else
  declare -A PIDS=()
  for vm in "${VMS[@]}"; do
    log "  … удаляю $vm"
    yc compute instance delete "$vm" >/dev/null &
    PIDS[$vm]=$!
  done
  for vm in "${!PIDS[@]}"; do
    if wait "${PIDS[$vm]}"; then log "  - удалена машина $vm"; else die "не удалилась машина $vm"; fi
  done
fi

step "4/7 Оставшиеся диски"
mapfile -t DISKS < <(yc compute disk list --format json | mine_by_prefix)
if (( ${#DISKS[@]} == 0 )); then
  log "  = диски: нечего удалять (загрузочные удалились вместе с машинами)"
else
  for d in "${DISKS[@]}"; do yc compute disk delete "$d" >/dev/null; log "  - удалён диск $d"; done
fi

step "5/7 Подсети (сначала отвязываем таблицу маршрутизации)"
mapfile -t SUBNETS < <(yc vpc subnet list --format json | mine)
if (( ${#SUBNETS[@]} == 0 )); then
  log "  = подсети: нечего удалять"
else
  for s in "${SUBNETS[@]}"; do
    if [[ -n "$(yc vpc subnet get "$s" --format json | jq -r '.route_table_id // empty')" ]]; then
      yc vpc subnet update "$s" --disassociate-route-table >/dev/null
      log "  - таблица маршрутизации отвязана от $s"
    fi
    yc vpc subnet delete "$s" >/dev/null
    log "  - удалена подсеть $s"
  done
fi

step "6/7 Таблицы маршрутизации и NAT-шлюзы"
delete_all "таблица маршрутизации" yc vpc route-table list -- yc vpc route-table delete
delete_all "NAT-шлюз" yc vpc gateway list -- yc vpc gateway delete

step "7/7 Сети"
delete_all "сеть" yc vpc network list -- yc vpc network delete

# ---------------------------------------------------------------------------
step "Контроль: что осталось"
# ---------------------------------------------------------------------------
LEFT=0
count_left() {
  local what="$1"; shift
  local names
  mapfile -t names < <("$@" --format json | mine_by_prefix)
  if (( ${#names[@]} > 0 )); then
    log "  ✗ $what: ${names[*]}"
    LEFT=$((LEFT + ${#names[@]}))
  else
    log "  ✓ $what: нет"
  fi
}
count_left "балансировщики"   yc load-balancer network-load-balancer list
count_left "целевые группы"   yc load-balancer target-group list
count_left "машины"           yc compute instance list
count_left "диски"            yc compute disk list
count_left "подсети"          yc vpc subnet list
count_left "таблицы маршрут." yc vpc route-table list
count_left "NAT-шлюзы"        yc vpc gateway list
count_left "сети"             yc vpc network list

UNUSED_ADDR=$(yc vpc address list --format json | jq '[.[] | select(.used != true)] | length')
log "  i неиспользуемых публичных адресов в каталоге: $UNUSED_ADDR (динамические адреса освобождаются сами)"

log ""
if (( LEFT == 0 )); then
  log "Убрано за $(( $(date +%s) - START_TS )) с. Ресурсов с префиксом $PREFIX- не осталось."
  exit 0
else
  log "Осталось ресурсов: $LEFT — запустите destroy.sh ещё раз или удалите вручную."
  exit 1
fi
