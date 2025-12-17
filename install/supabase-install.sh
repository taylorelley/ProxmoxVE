#!/usr/bin/env bash

# Copyright (c) 2021-2025 community-scripts ORG
# Author: taylorelley
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://supabase.com/

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt-get install -y \
  curl \
  sudo \
  mc \
  git \
  gpg
msg_ok "Installed Dependencies"

msg_info "Setting up Node.js Repository"
mkdir -p /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" >/etc/apt/sources.list.d/nodesource.list
$STD apt-get update
msg_ok "Set up Node.js Repository"

msg_info "Installing Node.js"
$STD apt-get install -y nodejs
msg_ok "Installed Node.js"

msg_info "Setting up Docker Repository"
setup_deb822_repo \
  "docker" \
  "https://download.docker.com/linux/$(get_os_info id)/gpg" \
  "https://download.docker.com/linux/$(get_os_info id)" \
  "$(get_os_info codename)" \
  "stable" \
  "$(dpkg --print-architecture)"
msg_ok "Set up Docker Repository"

msg_info "Installing Docker"
$STD apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin
msg_ok "Installed Docker"

msg_info "Downloading Supabase"
mkdir -p /opt/supabase
cd /opt/supabase
git clone --depth 1 https://github.com/supabase/supabase.git /tmp/supabase
cp -r /tmp/supabase/docker/* /opt/supabase/
rm -rf /tmp/supabase
msg_ok "Downloaded Supabase"

msg_info "Generating Secure Credentials"
POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c32)
JWT_SECRET=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c48)
DASHBOARD_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c16)
VAULT_ENC_KEY=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c32)
SECRET_KEY_BASE=$(openssl rand -base64 64 | tr -dc 'a-zA-Z0-9' | head -c64)
LOGFLARE_API_KEY=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c32)
LOGFLARE_PUBLIC_TOKEN=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c32)
LOGFLARE_PRIVATE_TOKEN=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c32)
PG_META_CRYPTO_KEY=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c32)
LOCAL_IP=$(hostname -I | awk '{print $1}')

ANON_KEY=$(node -e "
const crypto = require('crypto');
const header = Buffer.from(JSON.stringify({alg:'HS256',typ:'JWT'})).toString('base64url');
const payload = Buffer.from(JSON.stringify({
  role: 'anon',
  iss: 'supabase',
  iat: Math.floor(Date.now()/1000),
  exp: Math.floor(Date.now()/1000) + 157680000
})).toString('base64url');
const signature = crypto.createHmac('sha256', '${JWT_SECRET}').update(header+'.'+payload).digest('base64url');
console.log(header+'.'+payload+'.'+signature);
")

SERVICE_ROLE_KEY=$(node -e "
const crypto = require('crypto');
const header = Buffer.from(JSON.stringify({alg:'HS256',typ:'JWT'})).toString('base64url');
const payload = Buffer.from(JSON.stringify({
  role: 'service_role',
  iss: 'supabase',
  iat: Math.floor(Date.now()/1000),
  exp: Math.floor(Date.now()/1000) + 157680000
})).toString('base64url');
const signature = crypto.createHmac('sha256', '${JWT_SECRET}').update(header+'.'+payload).digest('base64url');
console.log(header+'.'+payload+'.'+signature);
")
msg_ok "Generated Secure Credentials"

msg_info "Configuring Supabase Environment"
cp /opt/supabase/.env.example /opt/supabase/.env

sed -i "s|POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${POSTGRES_PASSWORD}|" /opt/supabase/.env
sed -i "s|JWT_SECRET=.*|JWT_SECRET=${JWT_SECRET}|" /opt/supabase/.env
sed -i "s|ANON_KEY=.*|ANON_KEY=${ANON_KEY}|" /opt/supabase/.env
sed -i "s|SERVICE_ROLE_KEY=.*|SERVICE_ROLE_KEY=${SERVICE_ROLE_KEY}|" /opt/supabase/.env
sed -i "s|DASHBOARD_USERNAME=.*|DASHBOARD_USERNAME=admin|" /opt/supabase/.env
sed -i "s|DASHBOARD_PASSWORD=.*|DASHBOARD_PASSWORD=${DASHBOARD_PASSWORD}|" /opt/supabase/.env
sed -i "s|VAULT_ENC_KEY=.*|VAULT_ENC_KEY=${VAULT_ENC_KEY}|" /opt/supabase/.env
sed -i "s|SECRET_KEY_BASE=.*|SECRET_KEY_BASE=${SECRET_KEY_BASE}|" /opt/supabase/.env
sed -i "s|LOGFLARE_API_KEY=.*|LOGFLARE_API_KEY=${LOGFLARE_API_KEY}|" /opt/supabase/.env
sed -i "s|LOGFLARE_PUBLIC_ACCESS_TOKEN=.*|LOGFLARE_PUBLIC_ACCESS_TOKEN=${LOGFLARE_PUBLIC_TOKEN}|" /opt/supabase/.env
sed -i "s|LOGFLARE_PRIVATE_ACCESS_TOKEN=.*|LOGFLARE_PRIVATE_ACCESS_TOKEN=${LOGFLARE_PRIVATE_TOKEN}|" /opt/supabase/.env
sed -i "s|PG_META_CRYPTO_KEY=.*|PG_META_CRYPTO_KEY=${PG_META_CRYPTO_KEY}|" /opt/supabase/.env
sed -i "s|SUPABASE_PUBLIC_URL=.*|SUPABASE_PUBLIC_URL=http://${LOCAL_IP}:8000|" /opt/supabase/.env
sed -i "s|API_EXTERNAL_URL=.*|API_EXTERNAL_URL=http://${LOCAL_IP}:8000|" /opt/supabase/.env
sed -i "s|SITE_URL=.*|SITE_URL=http://${LOCAL_IP}:3000|" /opt/supabase/.env
msg_ok "Configured Supabase Environment"

msg_info "Starting Supabase Services"
cd /opt/supabase
$STD docker compose pull
$STD docker compose up -d
msg_ok "Started Supabase Services"

msg_info "Waiting for Services to Initialize"
sleep 30
msg_ok "Services Initialized"

{
  echo "Supabase Credentials"
  echo ""
  echo "Dashboard URL      : http://${LOCAL_IP}:8000"
  echo "Dashboard Username : admin"
  echo "Dashboard Password : ${DASHBOARD_PASSWORD}"
  echo ""
  echo "API URL            : http://${LOCAL_IP}:8000"
  echo "Anon Key           : ${ANON_KEY}"
  echo "Service Role Key   : ${SERVICE_ROLE_KEY}"
  echo ""
  echo "PostgreSQL"
  echo "  Host             : localhost"
  echo "  Port             : 5432"
  echo "  Database         : postgres"
  echo "  User             : postgres"
  echo "  Password         : ${POSTGRES_PASSWORD}"
  echo ""
  echo "JWT Secret         : ${JWT_SECRET}"
} >>~/supabase.creds

motd_ssh
customize
cleanup_lxc
