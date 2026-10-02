#!/bin/bash
# Практика 1. Журнал команд аудиторной части (вариант 05)
# Только команды, которыми создавались и удалялись ресурсы.

# --- Сервисный аккаунт, роль editor и ключ ---
yc iam service-account create --name pak-05-sa

export FOLDER_ID=$(yc config get folder-id)
export SA_ID=$(yc iam service-account get --name pak-05-sa --format json | jq -r .id)

yc resource-manager folder add-access-binding "$FOLDER_ID" \
  --role editor \
  --subject "serviceAccount:$SA_ID"

mkdir -p ~/.yc-keys
yc iam key create --service-account-name pak-05-sa \
  --output ~/.yc-keys/pak-05-key.json

# --- Своя сеть, подсеть и машина ---
export PREFIX=pak-05
export ZONE=ru-central1-b
export CIDR=10.15.1.0/24
export DISK_SIZE=20

yc vpc network create --name "$PREFIX-net"

yc vpc subnet create \
  --name "$PREFIX-subnet" \
  --network-name "$PREFIX-net" \
  --zone "$ZONE" \
  --range "$CIDR"

yc compute instance create \
  --name "$PREFIX-web-1" \
  --zone "$ZONE" \
  --platform standard-v3 \
  --cores=2 \
  --core-fraction=20 \
  --memory=2 \
  --preemptible \
  --create-boot-disk image-folder-id=standard-images,image-family=ubuntu-2404-lts,type=network-hdd,size="$DISK_SIZE" \
  --network-interface subnet-name="$PREFIX-subnet",nat-ip-version=ipv4 \
  --hostname "$PREFIX-web-1" \
  --ssh-key ~/.ssh/id_ed25519.pub \
  --labels created-by=cli

# --- Какие машины остановлены (прерываемую облако может выключить) ---
yc compute instance list --format json | jq -r '.[] | select(.status != "RUNNING") | .name'

# --- Уборка: сначала то, что использует сеть, потом сама сеть ---
yc compute instance delete "$PREFIX-web-1"
yc compute instance delete "$PREFIX-web-manual"

yc vpc subnet delete "$PREFIX-subnet"
yc vpc network delete "$PREFIX-net"
