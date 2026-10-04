#!/usr/bin/env bash
# create.sh — поднимает стенд ДЗ 1 целиком с нуля.
# Повторный запуск на поднятом стенде не падает и не создаёт дубликатов:
# перед каждым созданием проверяется, что ресурса ещё нет.
#
#   ./create.sh                  # параметры варианта 05
#   ./create.sh --web-count 3    # аргумент важнее переменной окружения и умолчания

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=params.sh
source "$HERE/params.sh"
parse_args "$@"

require_tools yc jq curl ssh sed
require_cloud
[[ -f "$SSH_KEY" ]] || die "нет публичного ключа $SSH_KEY (создайте: ssh-keygen -t ed25519) или укажите --ssh-key"
TEMPLATE="$HERE/cloud-init.yaml.tpl"
[[ -f "$TEMPLATE" ]] || die "нет шаблона $TEMPLATE"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
START_TS=$(date +%s)

skip()    { log "  = $* уже есть, пропускаю"; }
created() { log "  + создан(а) $*"; }

# ---------------------------------------------------------------------------
# Проверка существования: смотрим КОД ВОЗВРАТА yc ... get, а не вывод.
# Ошибки не глотаются через `|| true`: если создание упадёт, скрипт остановится.
# ---------------------------------------------------------------------------
exists() {
  local kind="$1" name="$2"
  case "$kind" in
    network)  yc vpc network get "$name" ;;
    subnet)   yc vpc subnet get "$name" ;;
    gateway)  yc vpc gateway get "$name" ;;
    rt)       yc vpc route-table get "$name" ;;
    instance) yc compute instance get "$name" ;;
    tg)       yc load-balancer target-group get "$name" ;;
    nlb)      yc load-balancer network-load-balancer get "$name" ;;
    *)        die "exists: неизвестный тип $kind" ;;
  esac >/dev/null 2>&1
}

get_id()      { yc "$@" --format json | jq -r '.id'; }
internal_ip() { yc compute instance get "$1" --format json | jq -r '.network_interfaces[0].primary_v4_address.address'; }

log "Стенд: префикс $PREFIX, зоны $ZONE_A / $ZONE_B, подсети $SUBNET_A_CIDR / $SUBNET_B_CIDR,"
log "       порт $PORT, слово $WORD, веб-серверов $WEB_COUNT, окружение $ENV_NAME"

# ---------------------------------------------------------------------------
step "1/7 Сеть"
# ---------------------------------------------------------------------------
if exists network "$NET"; then
  skip "сеть $NET"
else
  yc vpc network create --name "$NET" --labels "$LABELS" >/dev/null
  created "сеть $NET"
fi

# ---------------------------------------------------------------------------
step "2/7 NAT-шлюз и таблица маршрутизации"
# ---------------------------------------------------------------------------
if exists gateway "$NAT_GW"; then
  skip "NAT-шлюз $NAT_GW"
else
  yc vpc gateway create --name "$NAT_GW" --labels "$LABELS" >/dev/null
  created "NAT-шлюз $NAT_GW"
fi
GW_ID=$(get_id vpc gateway get "$NAT_GW")

if exists rt "$RT"; then
  skip "таблица маршрутизации $RT"
else
  yc vpc route-table create --name "$RT" --network-name "$NET" \
    --route "destination=0.0.0.0/0,gateway-id=$GW_ID" \
    --labels "$LABELS" >/dev/null
  created "таблица маршрутизации $RT (0.0.0.0/0 -> $NAT_GW)"
fi
RT_ID=$(get_id vpc route-table get "$RT")

# ---------------------------------------------------------------------------
step "3/7 Подсети"
# ---------------------------------------------------------------------------
ensure_subnet() {
  local name="$1" zone="$2" cidr="$3"
  if exists subnet "$name"; then
    skip "подсеть $name"
    # скрипт не умеет менять существующее — только предупреждает о расхождении
    local cur
    cur=$(yc vpc subnet get "$name" --format json | jq -r '.v4_cidr_blocks[0]')
    [[ "$cur" == "$cidr" ]] || log "  ! у $name диапазон $cur, а запрошен $cidr — скрипт это не исправит"
  else
    yc vpc subnet create --name "$name" --network-name "$NET" --zone "$zone" \
      --range "$cidr" --labels "$LABELS" >/dev/null
    created "подсеть $name ($zone, $cidr)"
  fi
}
ensure_subnet "$SUBNET_A" "$ZONE_A" "$SUBNET_A_CIDR"
ensure_subnet "$SUBNET_B" "$ZONE_B" "$SUBNET_B_CIDR"

# Закрытый сервер приложения живёт в подсети A, ей нужен выход через NAT-шлюз.
# Привязку тоже проверяем: подсеть могла остаться от прерванного запуска без таблицы.
CUR_RT=$(yc vpc subnet get "$SUBNET_A" --format json | jq -r '.route_table_id // ""')
if [[ "$CUR_RT" == "$RT_ID" ]]; then
  skip "привязка $RT к $SUBNET_A"
else
  yc vpc subnet update "$SUBNET_A" --route-table-id "$RT_ID" >/dev/null
  created "привязка $RT к $SUBNET_A"
fi

# ---------------------------------------------------------------------------
step "4/7 Виртуальные машины"
# ---------------------------------------------------------------------------
# Экранирование значения для правой части sed s|...|...|
sed_escape() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }
SSH_KEY_TEXT=$(<"$SSH_KEY")

render_cloud_init() {
  local host="$1" role="$2" out="$3"
  sed -e "s|{{SSH_USER}}|$(sed_escape "$SSH_USER")|g" \
      -e "s|{{SSH_KEY}}|$(sed_escape "$SSH_KEY_TEXT")|g" \
      -e "s|{{PORT}}|$PORT|g" \
      -e "s|{{WORD}}|$WORD|g" \
      -e "s|{{HOST}}|$host|g" \
      -e "s|{{ROLE}}|$role|g" \
      "$TEMPLATE" > "$out"
}

# create_vm <имя> <зона> <подсеть> <роль> <public|private>
create_vm() {
  local name="$1" zone="$2" subnet="$3" role="$4" access="$5"
  local user_data="$TMP_DIR/$name.yaml"
  render_cloud_init "$name" "$role" "$user_data"

  local extra=()
  [[ "$VM_PREEMPTIBLE" == 1 ]] && extra+=(--preemptible)

  local nic="subnet-name=$subnet"
  # публичный адрес только у веб-серверов; сервер приложения — без nat-ip-version
  [[ "$access" == public ]] && nic="$nic,nat-ip-version=ipv4"

  yc compute instance create \
    --name "$name" --hostname "$name" --zone "$zone" \
    --platform standard-v3 --cores "$VM_CORES" --memory "$VM_MEMORY" \
    --core-fraction "$VM_CORE_FRACTION" \
    --create-boot-disk "name=$name-disk,image-folder-id=standard-images,image-family=$IMAGE_FAMILY,size=$VM_DISK_SIZE,type=network-hdd,auto-delete=true" \
    --network-interface "$nic" \
    --metadata-from-file "user-data=$user_data" \
    --labels "$LABELS,role=$role" "${extra[@]}" >/dev/null
}

# Машины создаются параллельно, но каждая — только если её ещё нет
declare -A PIDS=()
for i in $(seq 1 "$WEB_COUNT"); do
  name=$(web_name "$i")
  if exists instance "$name"; then
    skip "машина $name"
  else
    log "  … создаю $name ($(web_zone "$i"), публичный адрес)"
    create_vm "$name" "$(web_zone "$i")" "$(web_subnet "$i")" web public &
    PIDS[$name]=$!
  fi
done
if exists instance "$APP_VM"; then
  skip "машина $APP_VM"
else
  log "  … создаю $APP_VM ($ZONE_A, без публичного адреса)"
  create_vm "$APP_VM" "$ZONE_A" "$SUBNET_A" app private &
  PIDS[$APP_VM]=$!
fi

FAILED_VMS=()
for name in "${!PIDS[@]}"; do
  if wait "${PIDS[$name]}"; then created "машина $name"; else FAILED_VMS+=("$name"); fi
done
(( ${#FAILED_VMS[@]} == 0 )) || die "не создались машины: ${FAILED_VMS[*]}"

# ---------------------------------------------------------------------------
step "5/7 Целевая группа"
# ---------------------------------------------------------------------------
TARGET_ARGS=()
WEB_IPS=()
for i in $(seq 1 "$WEB_COUNT"); do
  ip=$(internal_ip "$(web_name "$i")")
  WEB_IPS+=("$ip")
  TARGET_ARGS+=(--target "subnet-name=$(web_subnet "$i"),address=$ip")
done

if exists tg "$TG"; then
  skip "целевая группа $TG"
  # недостающие цели добавляем, лишние скрипт не убирает
  CUR_TARGETS=$(yc load-balancer target-group get "$TG" --format json | jq -r '.targets[]?.address')
  for i in $(seq 1 "$WEB_COUNT"); do
    ip="${WEB_IPS[$((i-1))]}"
    if ! grep -qxF "$ip" <<<"$CUR_TARGETS"; then
      yc load-balancer target-group add-targets "$TG" \
        --target "subnet-name=$(web_subnet "$i"),address=$ip" >/dev/null
      created "цель $(web_name "$i") ($ip) в $TG"
    fi
  done
else
  yc load-balancer target-group create --name "$TG" --region-id ru-central1 \
    "${TARGET_ARGS[@]}" --labels "$LABELS" >/dev/null
  created "целевая группа $TG (${WEB_IPS[*]})"
fi
TG_ID=$(get_id load-balancer target-group get "$TG")

# ---------------------------------------------------------------------------
step "6/7 Сетевой балансировщик"
# ---------------------------------------------------------------------------
HEALTHCHECK="target-group-id=$TG_ID,healthcheck-name=http,healthcheck-interval=2s,healthcheck-timeout=1s,healthcheck-unhealthythreshold=2,healthcheck-healthythreshold=2,healthcheck-http-port=$PORT,healthcheck-http-path=/"

if exists nlb "$NLB"; then
  skip "балансировщик $NLB"
  if ! yc load-balancer network-load-balancer get "$NLB" --format json \
       | jq -e --arg tg "$TG_ID" '[.attached_target_groups[]?.target_group_id] | index($tg)' >/dev/null; then
    yc load-balancer network-load-balancer attach-target-group "$NLB" --target-group "$HEALTHCHECK" >/dev/null
    created "подключение $TG к $NLB"
  fi
else
  yc load-balancer network-load-balancer create --name "$NLB" --region-id ru-central1 \
    --listener "name=http,port=80,target-port=$PORT,protocol=tcp,external-ip-version=ipv4" \
    --target-group "$HEALTHCHECK" \
    --labels "$LABELS" >/dev/null
  created "балансировщик $NLB (80 -> $PORT, проверка HTTP :$PORT/)"
fi
LB_IP=$(yc load-balancer network-load-balancer get "$NLB" --format json | jq -r '.listeners[0].address')

# ---------------------------------------------------------------------------
step "7/7 Ожидание готовности"
# ---------------------------------------------------------------------------
# Команды create возвращают управление раньше, чем cloud-init поставил nginx.
# Готовым стенд считается, когда check.sh вернул 0.
if [[ "$NO_WAIT" == 1 ]]; then
  log "  пропущено (--no-wait). Проверка: bash $HERE/check.sh"
else
  export PREFIX ZONE_A ZONE_B SUBNET_A_CIDR SUBNET_B_CIDR PORT WORD WEB_COUNT ENV_NAME SSH_USER SSH_KEY
  deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
  until bash "$HERE/check.sh" >/dev/null 2>&1; do
    if (( $(date +%s) >= deadline )); then
      log "  стенд не пришёл в норму за ${WAIT_TIMEOUT} с. Последний вывод check.sh:"
      bash "$HERE/check.sh" || true
      exit 1
    fi
    log "  ждём… $(( $(date +%s) - START_TS )) с от старта"
    sleep 15
  done
  log "  check.sh вернул 0 — стенд готов"
fi

log ""
log "Готово за $(( $(date +%s) - START_TS )) с. Стенд: http://$LB_IP/"
