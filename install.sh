#!/usr/bin/env bash
set -euo pipefail

ENV_FILE=".env"
ENV_TEMPLATE_URL="https://raw.githubusercontent.com/TMA-Cloud/setup/main/.env.example"
COMPOSE_FILE="docker-compose.yml"
COMPOSE_URL="https://raw.githubusercontent.com/TMA-Cloud/setup/main/docker-compose.yml"

# --- Branding Banner ---
command -v figlet >/dev/null 2>&1 && HAS_FIGLET=1 || HAS_FIGLET=0
command -v lolcat >/dev/null 2>&1 && HAS_LOLCAT=1 || HAS_LOLCAT=0

BOLD=$(tput bold 2>/dev/null || echo "")
RESET=$(tput sgr0 2>/dev/null || echo "")
CYBER=(34 36 37)

print_cyber() {
  local s=$1
  for ((i=0;i<${#s};i++)); do
    c=${CYBER[i%${#CYBER[@]}]}
    printf "\033[1;%sm%s\033[0m" "$c" "${s:i:1}"
  done
  echo
}

clear
printf "\n%.0s" {1..2}

if (( HAS_FIGLET && HAS_LOLCAT )); then
  figlet -f small "Private Cloud" | lolcat -S 80
  figlet -f small "Platform"      | lolcat -S 80
else
  art=(
"████████╗███╗   ███╗ █████╗      ██████╗██╗      ██████╗ ██╗   ██╗██████╗"
"╚══██╔══╝████╗ ████║██╔══██╗    ██╔════╝██║     ██╔═══██╗██║   ██║██╔══██╗"
"   ██║   ██╔████╔██║███████║    ██║     ██║     ██║   ██║██║   ██║██║  ██║"
"   ██║   ██║╚██╔╝██║██╔══██║    ██║     ██║     ██║   ██║██║   ██║██║  ██║"
"   ██║   ██║ ╚═╝ ██║██║  ██║    ╚██████╗███████╗╚██████╔╝╚██████╔╝╚█████╔╝"
"   ╚═╝   ╚═╝     ╚═╝╚═╝  ╚═╝     ╚═════╝╚══════╝ ╚═════╝  ╚═════╝  ╚════╝"
  )
  for l in "${art[@]}"; do print_cyber "$l"; done
fi

echo -e "\n${BOLD}\033[1;36m☁️  Lightning-Fast Private Cloud Platform ☁️${RESET}\n"
echo "🛠  Starting Setup..."

# --- Require sudo access upfront ---
if ! sudo -v >/dev/null 2>&1; then
  echo "❌ This script needs sudo privileges. Please run with a user that has sudo access."
  exit 1
fi

# --- Prompt for user input ---
read -rp "👤 Enter username: " INIT_USERNAME
while [[ -z "$INIT_USERNAME" ]]; do
  read -rp "❗ Username cannot be empty. Enter username: " INIT_USERNAME
done

read -rp "🪪 Enter full name: " INIT_NAME
while [[ -z "$INIT_NAME" ]]; do
  read -rp "❗ Name cannot be empty. Enter full name: " INIT_NAME
done

read -rsp "🔐 Enter password: " INIT_PASSWORD
echo
while [[ -z "$INIT_PASSWORD" ]]; do
  read -rsp "❗ Password cannot be empty. Enter password: " INIT_PASSWORD
  echo
done

# --- Check Docker & Compose ---
if ! command -v docker &>/dev/null; then
  echo "❌ Docker is not installed. Please install Docker first."
  exit 1
fi
if ! docker compose version &>/dev/null; then
  echo "❌ Docker Compose V2 is not installed. Please use 'docker compose'."
  exit 1
fi

# --- IP Detection ---
echo "🔍 Detecting server IP..."
get_ip() {
  ip -4 addr show scope global | awk '/inet / {print $2}' | cut -d/ -f1 | grep -vE '^(127|0)\.' | head -n1
}
SERVER_IP=$(get_ip || true)
if [[ -z "$SERVER_IP" ]]; then
  echo "❌ Could not detect valid server IP address."
  exit 1
fi
echo "🌐 Detected server IP: $SERVER_IP"

# --- Timezone Detection ---
TZ_VALUE=$(timedatectl 2>/dev/null | grep "Time zone" | awk '{print $3}') || TZ_VALUE="UTC"
[[ -z "$TZ_VALUE" ]] && TZ_VALUE="UTC" && echo "⚠️ Defaulting to UTC timezone."
echo "🕒 Timezone: $TZ_VALUE"

# --- Download .env and docker-compose.yml ---
if [[ ! -f "$ENV_FILE" ]]; then
  echo "📄 .env file not found. Downloading..."
  curl -fsSL "$ENV_TEMPLATE_URL" -o "$ENV_FILE" || {
    echo "❌ Failed to fetch .env.example from GitHub."
    exit 1
  }
fi

# --- Ensure docker-compose.yml exists ---
if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "📄 docker-compose.yml not found. Downloading..."
  curl -fsSL "$COMPOSE_URL" -o "$COMPOSE_FILE" || {
    echo "❌ Failed to fetch docker-compose.yml from GitHub."
    exit 1
  }
fi

# --- Inject Environment Variables ---
echo "🔧 Configuring environment..."
sed -i "s|^BACKEND_HOST=.*|BACKEND_HOST=${SERVER_IP}|g" "$ENV_FILE"
sed -i -E "s|(API_BASE_URL=.*://)[^:]+(:[0-9]+)|\1${SERVER_IP}\2|g" "$ENV_FILE"
sed -i -E "s|(ONLYOFFICE_JS_URL=.*://)[^:/]+|\1${SERVER_IP}|g" "$ENV_FILE"
sed -i -E "s|(CORS_ORIGINS=.*://)[^:]+(:[0-9]+)|\1${SERVER_IP}\2|g" "$ENV_FILE"
sed -i "s|^TZ=.*|TZ=${TZ_VALUE}|g" "$ENV_FILE"

gen_secret() {
  command -v openssl &>/dev/null && openssl rand -hex 32 || head -c 32 /dev/urandom | sha256sum | cut -d' ' -f1
}

replace_secret_if_blank() {
  local var=$1
  local fallback=$2
  grep -qE "^$var=($|$fallback)" "$ENV_FILE" && sed -i "s|^$var=.*|$var=$(gen_secret)|g" "$ENV_FILE"
}

replace_secret_if_blank "JWT_SECRET" "Your_Best_JWT_Secret"
replace_secret_if_blank "ONLYOFFICE_JWT_SECRET" "Your_Best_ONLYOFFICE_JWT_Secret"
replace_secret_if_blank "DB_PASSWORD" "Your_Best_Password"
replace_secret_if_blank "REDIS_PASSWORD" "Your_Best_Password"
replace_secret_if_blank "MEILI_API_KEY" "Your_Best_Api_Key"

# --- UID / GID ---
CURRENT_UID=$(id -u)
CURRENT_GID=$(id -g)
echo "👤 UID: $CURRENT_UID | 👥 GID: $CURRENT_GID"
sed -i "s|^UID=.*|UID=${CURRENT_UID}|g" "$ENV_FILE"
sed -i "s|^GID=.*|GID=${CURRENT_GID}|g" "$ENV_FILE"

# --- Upload Folders ---
DEFAULT_UPLOAD_DIR="./tma-uploads"
DEFAULT_THUMB_DIR="./tma-thumbs"
mkdir -p "$DEFAULT_UPLOAD_DIR" "$DEFAULT_THUMB_DIR"
chmod 700 "$DEFAULT_UPLOAD_DIR" "$DEFAULT_THUMB_DIR"
sed -i "s|^UPLOAD_DIR=.*|UPLOAD_DIR=${DEFAULT_UPLOAD_DIR}|g" "$ENV_FILE"
sed -i "s|^THUMB_DIR=.*|THUMB_DIR=${DEFAULT_THUMB_DIR}|g" "$ENV_FILE"
echo "📁 Upload folders set."

# --- Docker Compose Up ---
echo "🚀 Starting containers..."
docker compose up -d || {
  echo "❌ Docker containers failed to start."
  exit 1
}
echo "☑️ All services started."

# --- Initial User Creation ---
echo "⏳ Creating initial user..."
sleep 2
if docker exec cloud_storage_backend /app/createuser -username "$INIT_USERNAME" -name "$INIT_NAME" -password "$INIT_PASSWORD"; then
  echo "✅ User '$INIT_USERNAME' created."
else
  echo "❌ Failed to create initial user."
  exit 1
fi

# --- Done ---
FRONTEND_PORT=$(grep "^FRONTEND_PORT=" "$ENV_FILE" | cut -d '=' -f2)
echo ""
echo "🎉 Setup Complete!"
echo "-----------------------------"
echo "👤 Username:     $INIT_USERNAME"
echo "🪪 Name:         $INIT_NAME"
echo "🔐 Password:     $INIT_PASSWORD"
echo "-----------------------------"
echo "🌐 Your TMA CLOUD is running at: http://${SERVER_IP}:${FRONTEND_PORT}"
echo ""

echo "📌 Common User Management Commands:"
echo ""
echo "🔹 Create a new user:"
echo "    docker exec cloud_storage_backend /app/createuser"
echo ""
echo "🔹 Delete a user:"
echo "    docker exec cloud_storage_backend /app/deleteuser"
echo ""
echo "🔹 List all users:"
echo "    docker exec cloud_storage_backend /app/showusers"
