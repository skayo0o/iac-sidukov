# Практика 1: Журнал вводимых команд, вариант 08 (sidukov-08)

# Параметры варианта
export PREFIX=sidukov-08
export ZONE=ru-central1-b
export CIDR=10.18.1.0/24
export DISK_SIZE=20

# Создание сервисного аккаунта (если не существует)
yc iam service-account get --name "$PREFIX-sa" >/dev/null 2>&1 || \
  yc iam service-account create --name "$PREFIX-sa"

export FOLDER_ID=$(yc config get folder-id)
export SA_ID=$(yc iam service-account get --name "$PREFIX-sa" --format json | jq -r .id)

# роль editor на каталог
yc resource-manager folder add-access-binding "$FOLDER_ID" \
  --role editor \
  --subject "serviceAccount:$SA_ID"

# авторизованный ключ аккаунта (хранится вне репозитория)
mkdir -p ~/.yc-keys
if [ ! -s ~/.yc-keys/"$PREFIX"-key.json ]; then
  yc iam key create --service-account-name "$PREFIX-sa" \
    --output ~/.yc-keys/"$PREFIX"-key.json
fi

# Создание собственной сети и подсети
yc vpc network create --name "$PREFIX-net"

yc vpc subnet create \
  --name "$PREFIX-subnet" \
  --network-name "$PREFIX-net" \
  --zone "$ZONE" \
  --range "$CIDR"

# Создание ВМ в сети
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

# Подключение и настройка ВМ
export VM_IP=$(yc compute instance get "$PREFIX-web-1" --format json \
  | jq -r '.network_interfaces[0].primary_v4_address.one_to_one_nat.address')
ssh yc-user@"$VM_IP"
sudo apt update
sudo apt install -y nginx
set +H
sudo sed -i "s|Welcome to nginx!|labwork on $(hostname)|g"   /var/www/html/index.nginx-debian.html
exit

# Сведения о ресурсах
yc compute instance list
yc compute instance list --format json
yc compute instance list --format json \
  | jq -r '.[] | "\(.name)\t\(.status)\t\(.network_interfaces[0].primary_v4_address.one_to_one_nat.address // "нет")"'
yc compute instance list --format json | jq -r ".[] | select(.name | startswith(\"$PREFIX\")) | .name"
yc compute instance list --format json | jq -r '.[] | select(.status != "RUNNING") | .name'

# Уборка
yc compute instance delete "$PREFIX-web-1"
yc compute instance delete "$PREFIX-web-manual"
yc vpc subnet delete "$PREFIX-subnet"
yc vpc network delete "$PREFIX-net"

# Проверка
yc compute instance list
yc vpc network list
yc compute disk list