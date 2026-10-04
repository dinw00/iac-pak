#!/usr/bin/env bash
# ДЗ 1. Поднимает стенд для показа продукта целиком с нуля.
# Повторный запуск не падает и не создаёт дубликатов: перед каждым созданием
# проверяется, что ресурса ещё нет. В конце скрипт ждёт, пока check.sh вернёт 0.
#
#   bash create.sh                  # значения варианта 05
#   bash create.sh --web-count 3    # аргумент важнее переменной окружения и умолчания
#   bash create.sh --help           # все параметры
set -euo pipefail # стоп на первой ошибке и на пустой переменной

# ---- параметры варианта ----
# приоритет: аргумент командной строки > переменная окружения > умолчание из варианта
PREFIX="${PREFIX:-pak-05}"                      # префикс имён ресурсов
ZONE_A="${ZONE_A:-ru-central1-b}"               # зона A
ZONE_B="${ZONE_B:-ru-central1-d}"               # зона B
CIDR_A="${CIDR_A:-10.15.1.0/24}"                # подсеть в зоне A
CIDR_B="${CIDR_B:-10.15.2.0/24}"                # подсеть в зоне B
APP_PORT="${APP_PORT:-8015}"                    # порт, на котором отвечает nginx
GREETING="${GREETING:-vmlab}"                   # слово из варианта, оно же на странице
WEB_COUNT="${WEB_COUNT:-2}"                     # число веб-серверов
ENV_NAME="${ENV_NAME:-lab}"                     # имя окружения — для меток
BOOT_SIZE="${BOOT_SIZE:-20}"                    # загрузочный диск, ГБ — как в практике 2
IMAGE_FAMILY="${IMAGE_FAMILY:-ubuntu-2404-lts}" # образ машин, как в практиках
WAIT_LIMIT="${WAIT_LIMIT:-900}"                 # сколько секунд ждать готовности стенда
NO_WAIT=0                                       # 1 — не ждать готовности

usage() {
  cat <<EOF
Параметры (в скобках — текущее значение):
  --prefix NAME     префикс имён ресурсов      ($PREFIX)       env: PREFIX
  --zone-a ZONE     зона A                     ($ZONE_A)       env: ZONE_A
  --zone-b ZONE     зона B                     ($ZONE_B)       env: ZONE_B
  --cidr-a CIDR     подсеть в зоне A           ($CIDR_A)       env: CIDR_A
  --cidr-b CIDR     подсеть в зоне B           ($CIDR_B)       env: CIDR_B
  --port N          порт сервиса               ($APP_PORT)     env: APP_PORT
  --greeting WORD   слово на странице          ($GREETING)     env: GREETING
  --web-count N     веб-серверов, не меньше 2  ($WEB_COUNT)    env: WEB_COUNT
  --env NAME        имя окружения для меток    ($ENV_NAME)     env: ENV_NAME
  --boot-size N     загрузочный диск, ГБ       ($BOOT_SIZE)    env: BOOT_SIZE
  --no-wait         не ждать, пока check.sh вернёт 0
Приоритет: аргумент > переменная окружения > умолчание варианта 05.
EOF
}

# ---- аргументы командной строки ----
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)    PREFIX="${2:?у $1 нет значения}";    shift 2 ;;
    --zone-a)    ZONE_A="${2:?у $1 нет значения}";    shift 2 ;;
    --zone-b)    ZONE_B="${2:?у $1 нет значения}";    shift 2 ;;
    --cidr-a)    CIDR_A="${2:?у $1 нет значения}";    shift 2 ;;
    --cidr-b)    CIDR_B="${2:?у $1 нет значения}";    shift 2 ;;
    --port)      APP_PORT="${2:?у $1 нет значения}";  shift 2 ;;
    --greeting)  GREETING="${2:?у $1 нет значения}";  shift 2 ;;
    --web-count) WEB_COUNT="${2:?у $1 нет значения}"; shift 2 ;;
    --env)       ENV_NAME="${2:?у $1 нет значения}";  shift 2 ;;
    --boot-size) BOOT_SIZE="${2:?у $1 нет значения}"; shift 2 ;;
    --no-wait)   NO_WAIT=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           echo "неизвестный аргумент: $1 (список: --help)" >&2; exit 1 ;;
  esac
done

if ! [ "$WEB_COUNT" -ge 2 ] 2>/dev/null; then
  echo "веб-серверов должно быть не меньше двух, иначе стенд не переживёт отказ машины" >&2
  exit 1
fi

DIR="$(cd "$(dirname "$0")" && pwd)"   # каталог hw-01: запускать можно откуда угодно
LABELS="env=$ENV_NAME,owner=$PREFIX"    # метки на всё, что создаём (задача со звёздочкой 1)
ZONES=("$ZONE_A" "$ZONE_B")
SUBNETS=("$PREFIX-subnet-a" "$PREFIX-subnet-b")
CIDRS=("$CIDR_A" "$CIDR_B")

# Вывод команд create убираем в /dev/null, чтобы лог читался; ошибки идут в stderr и видны.
# Проверка существования — по КОДУ ВОЗВРАТА yc ... get, а не по выводу и не через || true.

echo "==> сеть"
if yc vpc network get --name "$PREFIX-net" >/dev/null 2>&1; then
  echo "сеть $PREFIX-net уже есть, пропускаю"
else
  yc vpc network create --name "$PREFIX-net" --labels "$LABELS" >/dev/null
  echo "сеть $PREFIX-net создана"
fi

echo "==> NAT-шлюз и таблица маршрутизации"
if yc vpc gateway get --name "$PREFIX-nat" >/dev/null 2>&1; then
  echo "NAT-шлюз $PREFIX-nat уже есть, пропускаю"
else
  yc vpc gateway create --name "$PREFIX-nat" --labels "$LABELS" >/dev/null
  echo "NAT-шлюз $PREFIX-nat создан"
fi
GW_ID=$(yc vpc gateway get --name "$PREFIX-nat" --format json | jq -r .id)

if yc vpc route-table get --name "$PREFIX-rt" >/dev/null 2>&1; then
  echo "таблица маршрутизации $PREFIX-rt уже есть, пропускаю"
else
  yc vpc route-table create --name "$PREFIX-rt" --network-name "$PREFIX-net" \
    --route "destination=0.0.0.0/0,gateway-id=$GW_ID" \
    --labels "$LABELS" >/dev/null
  echo "таблица маршрутизации $PREFIX-rt создана: 0.0.0.0/0 -> $PREFIX-nat"
fi

echo "==> подсети"
for idx in 0 1; do
  if yc vpc subnet get --name "${SUBNETS[$idx]}" >/dev/null 2>&1; then
    echo "подсеть ${SUBNETS[$idx]} уже есть, пропускаю"
  else
    yc vpc subnet create --name "${SUBNETS[$idx]}" --network-name "$PREFIX-net" \
      --zone "${ZONES[$idx]}" --range "${CIDRS[$idx]}" \
      --labels "$LABELS" >/dev/null
    echo "подсеть ${SUBNETS[$idx]} создана: ${ZONES[$idx]}, ${CIDRS[$idx]}"
  fi
done

# Закрытому серверу приложения нужен выход в интернет, иначе cloud-init не скачает nginx.
# Подсеть ссылается на таблицу, таблица — на шлюз. Привязку тоже проверяем:
# подсеть могла остаться от прерванного запуска без таблицы.
RT_ID=$(yc vpc route-table get --name "$PREFIX-rt" --format json | jq -r .id)
CUR_RT=$(yc vpc subnet get --name "$PREFIX-subnet-a" --format json | jq -r '.route_table_id // ""')
if [ "$CUR_RT" = "$RT_ID" ]; then
  echo "таблица $PREFIX-rt уже привязана к $PREFIX-subnet-a, пропускаю"
else
  yc vpc subnet update --name "$PREFIX-subnet-a" --route-table-name "$PREFIX-rt" >/dev/null
  echo "таблица $PREFIX-rt привязана к $PREFIX-subnet-a"
fi

echo "==> файл настройки из шаблона"
SSH_KEY=$(cat ~/.ssh/id_ed25519.pub)
export APP_PORT GREETING SSH_KEY
# shellcheck disable=SC2016  # список переменных для envsubst — именно текст, без подстановки
envsubst '${APP_PORT} ${GREETING} ${SSH_KEY}' \
  < "$DIR/cloud-init.tpl.yaml" > "$DIR/cloud-init.yaml"
# yc при --metadata-from-file сам подставляет переменные окружения на место $ИМЯ.
# Так у нас nginx-овский $uri однажды превратился в пустую строку. $(hostname) он не трогает.
if grep -nE '\$[A-Za-z0-9_{*#$@!?-]' "$DIR/cloud-init.yaml"; then
  echo "в cloud-init.yaml остался знак доллара перед именем — yc заменит его пустой строкой" >&2
  exit 1
fi

echo "==> веб-серверы"
for i in $(seq 1 "$WEB_COUNT"); do
  idx=$(( (i - 1) % 2 ))   # 0, 1, 0, 1… — переключатель между зонами
  if yc compute instance get --name "$PREFIX-web-$i" >/dev/null 2>&1; then
    echo "машина $PREFIX-web-$i уже есть, пропускаю"
  else
    yc compute instance create \
      --name "$PREFIX-web-$i" \
      --zone "${ZONES[$idx]}" \
      --platform standard-v3 \
      --cores=2 --core-fraction=20 --memory=2 \
      --preemptible \
      --create-boot-disk image-folder-id=standard-images,image-family="$IMAGE_FAMILY",type=network-hdd,size="$BOOT_SIZE" \
      --network-interface subnet-name="${SUBNETS[$idx]}",nat-ip-version=ipv4 \
      --hostname "$PREFIX-web-$i" \
      --metadata-from-file user-data="$DIR/cloud-init.yaml" \
      --labels "$LABELS,role=web" >/dev/null
    echo "машина $PREFIX-web-$i создана: ${ZONES[$idx]}, публичный адрес"
  fi
done

echo "==> сервер приложения"
# без nat-ip-version: публичного адреса нет, наружу машина не смотрит
if yc compute instance get --name "$PREFIX-app-1" >/dev/null 2>&1; then
  echo "машина $PREFIX-app-1 уже есть, пропускаю"
else
  yc compute instance create \
    --name "$PREFIX-app-1" \
    --zone "$ZONE_A" \
    --platform standard-v3 \
    --cores=2 --core-fraction=20 --memory=2 \
    --preemptible \
    --create-boot-disk image-folder-id=standard-images,image-family="$IMAGE_FAMILY",type=network-hdd,size="$BOOT_SIZE" \
    --network-interface subnet-name="$PREFIX-subnet-a" \
    --hostname "$PREFIX-app-1" \
    --metadata-from-file user-data="$DIR/cloud-init.yaml" \
    --labels "$LABELS,role=app" >/dev/null
  echo "машина $PREFIX-app-1 создана: $ZONE_A, без публичного адреса"
fi

echo "==> целевая группа"
if yc load-balancer target-group get --name "$PREFIX-tg" >/dev/null 2>&1; then
  echo "целевая группа $PREFIX-tg уже есть, пропускаю"
else
  # собираем список веб-серверов: имя подсети и внутренний адрес каждого
  TARGETS=""
  IPS=""
  for i in $(seq 1 "$WEB_COUNT"); do
    idx=$(( (i - 1) % 2 ))
    IP=$(yc compute instance get --name "$PREFIX-web-$i" --format json \
      | jq -r '.network_interfaces[0].primary_v4_address.address')
    TARGETS="$TARGETS --target subnet-name=${SUBNETS[$idx]},address=$IP"
    IPS="$IPS $IP"
  done
  # shellcheck disable=SC2086  # TARGETS должен разбиться на отдельные аргументы
  yc load-balancer target-group create --name "$PREFIX-tg" --region-id ru-central1 \
    $TARGETS --labels "$LABELS" >/dev/null
  echo "целевая группа $PREFIX-tg создана:$IPS"
fi

echo "==> балансировщик"
TG_ID=$(yc load-balancer target-group get --name "$PREFIX-tg" --format json | jq -r .id)
if yc load-balancer network-load-balancer get --name "$PREFIX-lb" >/dev/null 2>&1; then
  echo "балансировщик $PREFIX-lb уже есть, пропускаю"
else
  yc load-balancer network-load-balancer create \
    --name "$PREFIX-lb" \
    --region-id ru-central1 \
    --listener name=http,port=80,target-port="$APP_PORT",external-ip-version=ipv4 \
    --target-group target-group-id="$TG_ID",healthcheck-name=http,healthcheck-interval=2s,healthcheck-timeout=1s,healthcheck-unhealthythreshold=2,healthcheck-healthythreshold=2,healthcheck-http-port="$APP_PORT",healthcheck-http-path=/ \
    --labels "$LABELS" >/dev/null
  echo "балансировщик $PREFIX-lb создан: 80 -> $APP_PORT, проверка HTTP :$APP_PORT/"
fi
LB_IP=$(yc load-balancer network-load-balancer get --name "$PREFIX-lb" --format json \
  | jq -r '.listeners[0].address')

echo "==> ожидание готовности"
# Команды create возвращают управление раньше, чем cloud-init поставил nginx.
# Готовым стенд считается, когда check.sh вернул 0.
if [ "$NO_WAIT" = 1 ]; then
  echo "пропущено (--no-wait), проверка: bash $DIR/check.sh"
else
  export PREFIX   # APP_PORT и GREETING уже экспортированы для envsubst
  until bash "$DIR/check.sh" >/dev/null 2>&1; do
    if [ "$SECONDS" -ge "$WAIT_LIMIT" ]; then
      echo "стенд не пришёл в норму за $WAIT_LIMIT с, последний вывод check.sh:"
      bash "$DIR/check.sh" || true
      exit 1
    fi
    echo "ждём… $SECONDS с от старта"
    sleep 10
  done
  echo "check.sh вернул 0 — стенд готов"
fi

echo "==> готово за $SECONDS с: http://$LB_IP"
