#!/usr/bin/env bash
# check.sh — проверяет, что стенд ДЗ 1 работает.
# По строке на проверку; код возврата 0 — все проверки прошли, 1 — хотя бы одна нет.
# Пишется для раннера: смотреть нужно на код возврата, а не на текст.
#
#   ./check.sh; echo "код возврата: $?"

set -uo pipefail   # без -e: упавшая проверка не должна обрывать остальные

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=params.sh
source "$HERE/params.sh"
parse_args "$@"
require_tools yc jq curl ssh

FAILED=0
pass() { printf '✓ %s\n' "$*"; }
fail() { printf '✗ %s\n' "$*"; FAILED=$((FAILED + 1)); }

SSH_OPTS=(-i "${SSH_KEY%.pub}" -o BatchMode=yes -o ConnectTimeout=5
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

# --- Исходные данные: адрес балансировщика, адреса машин ---------------------
LB_IP=""
if LB_JSON=$(yc load-balancer network-load-balancer get "$NLB" --format json 2>/dev/null); then
  LB_IP=$(jq -r '.listeners[0].address // empty' <<<"$LB_JSON")
fi

WEB1="$(web_name 1)"
WEB1_IP=""
if WEB1_JSON=$(yc compute instance get "$WEB1" --format json 2>/dev/null); then
  WEB1_IP=$(jq -r '.network_interfaces[0].primary_v4_address.one_to_one_nat.address // empty' <<<"$WEB1_JSON")
fi

APP_IP=""
APP_PUBLIC=""
if APP_JSON=$(yc compute instance get "$APP_VM" --format json 2>/dev/null); then
  APP_IP=$(jq -r '.network_interfaces[0].primary_v4_address.address // empty' <<<"$APP_JSON")
  APP_PUBLIC=$(jq -r '.network_interfaces[0].primary_v4_address.one_to_one_nat.address // empty' <<<"$APP_JSON")
fi

# --- 1. Балансировщик отвечает кодом 200 -------------------------------------
if [[ -z "$LB_IP" ]]; then
  fail "балансировщик $NLB не найден"
else
  CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://$LB_IP/")
  if [[ "$CODE" == 200 ]]; then
    pass "балансировщик отвечает: 200 (http://$LB_IP/)"
  else
    fail "балансировщик http://$LB_IP/ отвечает кодом $CODE, ожидался 200"
  fi
fi

# --- 2. Ответы приходят больше чем с одной машины ----------------------------
# Каждый запрос curl — новое соединение с новым портом источника,
# балансировщик хеширует их по разным машинам.
if [[ -z "$LB_IP" ]]; then
  fail "распределение не проверить: нет балансировщика"
else
  HOSTS=$(for _ in $(seq 1 20); do
            curl -s -m 3 "http://$LB_IP/" | sed -n 's/.*host: \([a-z0-9-]*\).*/\1/p'
          done | sort -u)
  N_HOSTS=$(grep -c . <<<"$HOSTS")
  HOST_LIST=$(paste -sd, <<<"$HOSTS" | sed 's/,/, /g')
  if (( N_HOSTS > 1 )); then
    pass "ответили машины: $HOST_LIST"
  elif (( N_HOSTS == 1 )); then
    fail "отвечает только одна машина: $HOST_LIST"
  else
    fail "ни одна машина не ответила через балансировщик"
  fi
fi

# --- 3. Сервер приложения доступен с веб-сервера по внутреннему адресу -------
if [[ -z "$APP_IP" ]]; then
  fail "сервер приложения $APP_VM не найден"
elif [[ -z "$WEB1_IP" ]]; then
  fail "сервер приложения не проверить: нет $WEB1 с публичным адресом"
else
  # shellcheck disable=SC2029  # адрес и порт подставляются на нашей стороне — так и задумано
  APP_CODE=$(ssh "${SSH_OPTS[@]}" "$SSH_USER@$WEB1_IP" \
               "curl -s -o /dev/null -w '%{http_code}' -m 5 http://$APP_IP:$PORT/" 2>/dev/null)
  if [[ "$APP_CODE" == 200 ]]; then
    pass "сервер приложения $APP_IP:$PORT отвечает с $WEB1: 200"
  else
    fail "сервер приложения $APP_IP:$PORT недоступен с $WEB1 (код: ${APP_CODE:-нет ответа})"
  fi
fi

# --- 4. У сервера приложения нет публичного адреса ---------------------------
if [[ -z "$APP_IP" ]]; then
  fail "публичный адрес не проверить: нет $APP_VM"
elif [[ -n "$APP_PUBLIC" ]]; then
  fail "у $APP_VM есть публичный адрес $APP_PUBLIC — сервис смотрит наружу"
else
  pass "у $APP_VM нет публичного адреса"
fi

# Код возврата задаётся явно: иначе он был бы кодом последней команды
if (( FAILED == 0 )); then
  exit 0
else
  exit 1
fi
