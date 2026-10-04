#!/usr/bin/env bash
# params.sh — общие параметры стенда ДЗ 1 и разбор аргументов.
# Подключается из create.sh, check.sh и destroy.sh командой `source`,
# поэтому все три скрипта принимают одни и те же аргументы.
#
# Приоритет значений:
#   аргумент командной строки  >  переменная окружения  >  умолчание варианта

# ---------------------------------------------------------------------------
# 1. Умолчания из таблицы вариантов: вариант 05 (фамилия на П–Р), префикс pak-05
# ---------------------------------------------------------------------------
DEFAULT_PREFIX="pak-05"
DEFAULT_ZONE_A="ru-central1-b"
DEFAULT_ZONE_B="ru-central1-d"
DEFAULT_SUBNET_A="10.15.1.0/24"
DEFAULT_SUBNET_B="10.15.2.0/24"
DEFAULT_PORT="8015"
DEFAULT_WORD="vmlab"
DEFAULT_WEB_COUNT="2"
DEFAULT_ENV_NAME="lab"
DEFAULT_SSH_USER="yc-user"
DEFAULT_SSH_KEY="$HOME/.ssh/id_ed25519.pub"

# ---------------------------------------------------------------------------
# 2. Переменные окружения перекрывают умолчания
# ---------------------------------------------------------------------------
PREFIX="${PREFIX:-$DEFAULT_PREFIX}"
ZONE_A="${ZONE_A:-$DEFAULT_ZONE_A}"
ZONE_B="${ZONE_B:-$DEFAULT_ZONE_B}"
SUBNET_A_CIDR="${SUBNET_A_CIDR:-$DEFAULT_SUBNET_A}"
SUBNET_B_CIDR="${SUBNET_B_CIDR:-$DEFAULT_SUBNET_B}"
PORT="${PORT:-$DEFAULT_PORT}"
WORD="${WORD:-$DEFAULT_WORD}"
WEB_COUNT="${WEB_COUNT:-$DEFAULT_WEB_COUNT}"
ENV_NAME="${ENV_NAME:-$DEFAULT_ENV_NAME}"
SSH_USER="${SSH_USER:-$DEFAULT_SSH_USER}"
SSH_KEY="${SSH_KEY:-$DEFAULT_SSH_KEY}"

# Параметры машин — только через окружение, в варианте их нет
VM_CORES="${VM_CORES:-2}"
VM_MEMORY="${VM_MEMORY:-1}"            # ГБ на всю машину
VM_CORE_FRACTION="${VM_CORE_FRACTION:-20}"
VM_DISK_SIZE="${VM_DISK_SIZE:-20}"     # ГБ, HDD — как в практике 1
IMAGE_FAMILY="${IMAGE_FAMILY:-ubuntu-2404-lts}"
# Прерываемые машины вдвое дешевле, но облако может остановить их в любой момент,
# в том числе посреди показа клиенту. По умолчанию выключено.
VM_PREEMPTIBLE="${VM_PREEMPTIBLE:-0}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-900}"    # сколько секунд create.sh ждёт готовности стенда

# Флаги отдельных скриптов
NO_WAIT="${NO_WAIT:-0}"                # create.sh: не ждать готовности
BY_LABEL="${BY_LABEL:-0}"              # destroy.sh: искать своё по метке, а не по префиксу

# ---------------------------------------------------------------------------
# Вспомогательные функции вывода
# ---------------------------------------------------------------------------
log()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die()  { printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Использование: $(basename "$0") [параметры]

  --prefix NAME      префикс имён ресурсов            (сейчас: $PREFIX)
  --zone-a ZONE      зона A                           (сейчас: $ZONE_A)
  --zone-b ZONE      зона B                           (сейчас: $ZONE_B)
  --subnet-a CIDR    диапазон подсети в зоне A        (сейчас: $SUBNET_A_CIDR)
  --subnet-b CIDR    диапазон подсети в зоне B        (сейчас: $SUBNET_B_CIDR)
  --port N           порт сервиса на машинах          (сейчас: $PORT)
  --word WORD        слово на странице                (сейчас: $WORD)
  --web-count N      число веб-серверов, не меньше 2  (сейчас: $WEB_COUNT)
  --env NAME         имя окружения для меток          (сейчас: $ENV_NAME)
  --ssh-user NAME    пользователь на машинах          (сейчас: $SSH_USER)
  --ssh-key FILE     публичный SSH-ключ               (сейчас: $SSH_KEY)
  --no-wait          create.sh: не ждать готовности стенда
  --by-label         destroy.sh: искать ресурсы по метке owner=<префикс>
  -h, --help         эта справка

Приоритет: аргумент > переменная окружения (PREFIX, ZONE_A, ZONE_B,
SUBNET_A_CIDR, SUBNET_B_CIDR, PORT, WORD, WEB_COUNT, ENV_NAME, SSH_USER,
SSH_KEY) > умолчание варианта 05.
EOF
}

# ---------------------------------------------------------------------------
# 3. Аргументы командной строки перекрывают всё
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    local opt="$1"
    # форма --key=value превращается в --key value
    if [[ "$opt" == --*=* ]]; then
      set -- "${opt%%=*}" "${opt#*=}" "${@:2}"
      continue
    fi
    # флаги без значения
    case "$opt" in
      -h|--help)  usage; exit 0 ;;
      --no-wait)  NO_WAIT=1;  shift; continue ;;
      --by-label) BY_LABEL=1; shift; continue ;;
    esac
    # параметры со значением
    local val="${2-}"
    case "$opt" in
      --prefix)    PREFIX="$val" ;;
      --zone-a)    ZONE_A="$val" ;;
      --zone-b)    ZONE_B="$val" ;;
      --subnet-a)  SUBNET_A_CIDR="$val" ;;
      --subnet-b)  SUBNET_B_CIDR="$val" ;;
      --port)      PORT="$val" ;;
      --word)      WORD="$val" ;;
      --web-count) WEB_COUNT="$val" ;;
      --env)       ENV_NAME="$val" ;;
      --ssh-user)  SSH_USER="$val" ;;
      --ssh-key)   SSH_KEY="$val" ;;
      *) die "неизвестный параметр: $opt (список — $(basename "$0") --help)" ;;
    esac
    [[ -n "$val" ]] || die "у параметра $opt не задано значение"
    shift 2
  done
  validate_params
  derive_names
}

validate_params() {
  [[ "$PREFIX" =~ ^[a-z][a-z0-9-]{0,30}$ ]] \
    || die "префикс '$PREFIX': латиница в нижнем регистре, цифры и дефис, начинается с буквы"
  if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
    die "порт '$PORT' должен быть числом от 1 до 65535"
  fi
  if ! [[ "$WEB_COUNT" =~ ^[0-9]+$ ]] || (( WEB_COUNT < 2 )); then
    die "веб-серверов должно быть не меньше 2, иначе стенд не переживёт отказ машины"
  fi
  local cidr_re='^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'
  [[ "$SUBNET_A_CIDR" =~ $cidr_re ]] || die "подсеть A '$SUBNET_A_CIDR' не похожа на CIDR"
  [[ "$SUBNET_B_CIDR" =~ $cidr_re ]] || die "подсеть B '$SUBNET_B_CIDR' не похожа на CIDR"
  [[ "$ZONE_A" != "$ZONE_B" ]] || die "зоны A и B совпадают ($ZONE_A)"
  [[ "$WORD" =~ ^[A-Za-z0-9_-]+$ ]] || die "слово на странице '$WORD': только латиница, цифры, _ и -"
}

# Имена ресурсов строятся только от префикса
# shellcheck disable=SC2034  # переменные используются в скриптах, которые подключают params.sh
derive_names() {
  NET="$PREFIX-net"
  SUBNET_A="$PREFIX-subnet-a"
  SUBNET_B="$PREFIX-subnet-b"
  NAT_GW="$PREFIX-nat"
  RT="$PREFIX-rt"
  APP_VM="$PREFIX-app-1"
  TG="$PREFIX-tg"
  NLB="$PREFIX-nlb"
  LABELS="env=$ENV_NAME,owner=$PREFIX"
}

# Веб-серверы чередуются по зонам: нечётные — в зоне A, чётные — в зоне B
web_name()   { printf '%s-web-%s' "$PREFIX" "$1"; }
web_zone()   { if (( $1 % 2 == 1 )); then printf '%s' "$ZONE_A";   else printf '%s' "$ZONE_B";   fi; }
web_subnet() { if (( $1 % 2 == 1 )); then printf '%s' "$SUBNET_A"; else printf '%s' "$SUBNET_B"; fi; }

require_tools() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || die "не найдена утилита '$t'"
  done
}

# Доступ к облаку проверяется до любых проверок существования:
# иначе ошибка авторизации выглядела бы как «ресурса нет»
require_cloud() {
  [[ -n "$(yc config get folder-id 2>/dev/null)" ]] \
    || die "в профиле yc не задан folder-id (yc config set folder-id ...)"
  yc vpc network list >/dev/null 2>&1 \
    || die "yc не может обратиться к облаку: проверьте профиль и токен (yc vpc network list)"
}
