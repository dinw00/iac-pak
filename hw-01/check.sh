#!/usr/bin/env bash
# ДЗ 1. Проверяет, что стенд работает, и печатает по строке на каждую проверку.
# Код возврата: 0 — прошли все проверки, 1 — не прошла хотя бы одна.
# Пишется для раннера: смотреть нужно на код возврата, а не на текст.
#
#   bash check.sh; echo "код возврата: $?"
set -uo pipefail # без -e: упавшая проверка не должна обрывать остальные

# ---- параметры варианта ----
# приоритет: аргумент командной строки > переменная окружения > умолчание из варианта
PREFIX="${PREFIX:-pak-05}"          # префикс имён ресурсов
APP_PORT="${APP_PORT:-8015}"        # порт, на котором отвечает nginx
GREETING="${GREETING:-vmlab}"       # слово из варианта, оно же на странице
SSH_USER="${SSH_USER:-student}"     # пользователя заводит cloud-init

# ---- аргументы командной строки ----
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)   PREFIX="${2:?у $1 нет значения}";   shift 2 ;;
    --port)     APP_PORT="${2:?у $1 нет значения}"; shift 2 ;;
    --greeting) GREETING="${2:?у $1 нет значения}"; shift 2 ;;
    -h|--help)  echo "параметры: --prefix ($PREFIX), --port ($APP_PORT), --greeting ($GREETING)"; exit 0 ;;
    *)          echo "неизвестный аргумент: $1" >&2; exit 1 ;;
  esac
done

FAILED=0
ok()   { echo "✓ $*"; }
fail() { echo "✗ $*"; FAILED=1; }

# ssh для раннера: без вопроса про ключ хоста (адреса после пересоздания стенда
# достаются другим машинам) и без зависаний, если машина не отвечает
SSH=(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
         -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR)

# ---- адреса: балансировщик, web-1 снаружи, app-1 внутри ----
LB_IP=$(yc load-balancer network-load-balancer get --name "$PREFIX-lb" --format json 2>/dev/null \
  | jq -r '.listeners[0].address // empty')
WEB1_IP=$(yc compute instance get --name "$PREFIX-web-1" --format json 2>/dev/null \
  | jq -r '.network_interfaces[0].primary_v4_address.one_to_one_nat.address // empty')
APP_JSON=$(yc compute instance get --name "$PREFIX-app-1" --format json 2>/dev/null)
APP_IP=$(echo "$APP_JSON" | jq -r '.network_interfaces[0].primary_v4_address.address // empty' 2>/dev/null)
APP_PUBLIC=$(echo "$APP_JSON" | jq -r '.network_interfaces[0].primary_v4_address.one_to_one_nat.address // empty' 2>/dev/null)

# ---- 1. балансировщик отвечает кодом 200 ----
CODE=""
if [ -z "$LB_IP" ]; then
  fail "балансировщик $PREFIX-lb не найден"
else
  CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://$LB_IP")
  if [ "$CODE" = 200 ]; then
    ok "балансировщик отвечает: 200 (http://$LB_IP)"
  else
    fail "балансировщик http://$LB_IP отвечает: $CODE, ожидался 200"
  fi
fi

# ---- 2. ответы приходят больше чем с одной машины ----
# каждый curl — новое соединение с новым портом источника, балансировщик
# раскладывает их по хешу на разные машины
if [ -z "$LB_IP" ]; then
  fail "распределение не проверить: нет балансировщика"
elif [ "$CODE" != 200 ]; then
  # не тратим 20 запросов с таймаутами на балансировщик, который и так не отвечает
  fail "распределение не проверить: балансировщик не отвечает 200"
else
  HOSTS=$(for _ in $(seq 1 20); do
            curl -s -m 3 "http://$LB_IP" | grep -m1 -o "$GREETING on [a-z0-9-]*"
          done | sed "s/^$GREETING on //" | sort -u)
  N=$(echo "$HOSTS" | grep -c .)
  LIST=$(echo "$HOSTS" | paste -sd, - | sed 's/,/, /g')
  if [ "$N" -gt 1 ]; then
    ok "ответили машины: $LIST"
  elif [ "$N" -eq 1 ]; then
    fail "отвечает только одна машина: $LIST"
  else
    fail "ни одна машина не ответила через балансировщик"
  fi
fi

# ---- 3. сервер приложения доступен с веб-сервера по внутреннему адресу ----
if [ -z "$APP_IP" ]; then
  fail "сервер приложения $PREFIX-app-1 не найден"
elif [ -z "$WEB1_IP" ]; then
  fail "сервер приложения не проверить: нет $PREFIX-web-1 с публичным адресом"
else
  ANSWER=$("${SSH[@]}" "$SSH_USER@$WEB1_IP" "curl -s -m 5 http://$APP_IP:$APP_PORT" 2>/dev/null \
    | grep -m1 -o "$GREETING on [a-z0-9-]*")
  if [ "$ANSWER" = "$GREETING on $PREFIX-app-1" ]; then
    ok "сервер приложения $APP_IP:$APP_PORT отвечает с $PREFIX-web-1: $ANSWER"
  else
    fail "сервер приложения $APP_IP:$APP_PORT недоступен с $PREFIX-web-1"
  fi
fi

# ---- 4. у сервера приложения нет публичного адреса ----
if [ -z "$APP_IP" ]; then
  fail "публичный адрес не проверить: нет $PREFIX-app-1"
elif [ -n "$APP_PUBLIC" ]; then
  fail "у $PREFIX-app-1 есть публичный адрес $APP_PUBLIC — сервис смотрит наружу"
else
  ok "у $PREFIX-app-1 нет публичного адреса"
fi

# код возврата задаём явно: иначе он был бы кодом последней команды
if [ "$FAILED" = 0 ]; then
  exit 0
else
  exit 1
fi
