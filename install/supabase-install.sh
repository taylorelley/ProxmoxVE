#!/usr/bin/env bash

# Copyright (c) 2021-2025 community-scripts ORG
# Author: taylorelley
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://supabase.com/

# Source framework functions if available, otherwise use fallbacks
if [ -n "$FUNCTIONS_FILE_PATH" ]; then
  source "$FUNCTIONS_FILE_PATH"
  color
  verb_ip6
  catch_errors
  setting_up_container
  network_check
  update_os
else
  # Fallback functions for standalone execution
  msg_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
  msg_ok() { echo -e "\e[32m[OK]\e[0m $1"; }
  msg_error() { echo -e "\e[31m[ERROR]\e[0m $1"; }
  color() { :; }
  verb_ip6() { :; }
  catch_errors() { set -euo pipefail; }
  setting_up_container() { :; }
  network_check() { :; }
  update_os() {
    msg_info "Updating System Packages"
    apt-get update && apt-get upgrade -y
    msg_ok "Updated System Packages"
  }
  motd_ssh() { :; }
  customize() { :; }
  cleanup_lxc() { :; }
  STD=""

  # Initialize
  catch_errors
fi

msg_info "Installing Dependencies"
$STD apt-get install -y \
  ca-certificates \
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

# Check if Docker is already installed
if command -v docker &> /dev/null; then
  msg_ok "Docker is already installed ($(docker --version))"
else
  msg_info "Setting up Docker Repository (Official Debian Method)"
  # Following official Docker documentation: https://docs.docker.com/engine/install/debian/

  # Determine Debian codename with fallbacks to ensure valid apt sources
  DEBIAN_CODENAME=""
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    DEBIAN_CODENAME="${VERSION_CODENAME}"
  fi

  # Fallback to lsb_release if VERSION_CODENAME is empty
  if [ -z "$DEBIAN_CODENAME" ] && command -v lsb_release &> /dev/null; then
    DEBIAN_CODENAME=$(lsb_release -cs 2>/dev/null)
  fi

  # Final fallback to bookworm (current Debian stable)
  if [ -z "$DEBIAN_CODENAME" ]; then
    DEBIAN_CODENAME="bookworm"
    msg_info "Could not detect Debian codename, using default: bookworm"
  fi

  # Download Docker's official GPG key
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  # Add Docker repository to apt sources (deb822 format)
  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${DEBIAN_CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  # Update package index
  $STD apt-get update
  msg_ok "Set up Docker Repository"

  msg_info "Installing Docker"
  $STD apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin
  msg_ok "Installed Docker"

  msg_info "Verifying Docker Installation"
  if ! docker --version &> /dev/null; then
    msg_error "Docker installation failed"
    exit 1
  fi
  msg_ok "Docker installation verified ($(docker --version))"
fi

msg_info "Downloading Supabase"
mkdir -p /opt/supabase
if ! cd /opt/supabase; then
  msg_error "Failed to change directory to /opt/supabase"
  exit 1
fi

# Clone Supabase repository
if ! git clone --depth 1 https://github.com/supabase/supabase.git /tmp/supabase; then
  msg_error "Failed to clone Supabase repository"
  exit 1
fi

# Copy docker files and verify .env.example exists
if [ ! -d /tmp/supabase/docker ]; then
  msg_error "Docker directory not found in Supabase repository"
  rm -rf /tmp/supabase
  exit 1
fi

cp -r /tmp/supabase/docker/* /opt/supabase/

# Check for .env.example in multiple possible locations
if [ -f /opt/supabase/.env.example ]; then
  msg_ok "Found .env.example in /opt/supabase/"
elif [ -f /tmp/supabase/.env.example ]; then
  cp /tmp/supabase/.env.example /opt/supabase/
  msg_ok "Copied .env.example from repository root"
elif [ -f /tmp/supabase/docker/.env.example ]; then
  cp /tmp/supabase/docker/.env.example /opt/supabase/
  msg_ok "Copied .env.example from docker directory"
elif [ -f /opt/supabase/volumes/api/.env.example ]; then
  cp /opt/supabase/volumes/api/.env.example /opt/supabase/
  msg_ok "Found .env.example in volumes/api/"
else
  # Try to download official .env.example directly from GitHub
  msg_info "Downloading official .env.example from Supabase repository"
  if curl -fsSL https://raw.githubusercontent.com/supabase/supabase/master/docker/.env.example -o /opt/supabase/.env.example; then
    msg_ok "Downloaded official .env.example"
  else
    msg_info ".env.example not available, will create comprehensive configuration"
    # Don't create an empty file - let the configuration section handle this
    rm -f /opt/supabase/.env.example
  fi
fi

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

# Generate JWT tokens with 5-year expiration (157680000 seconds)
ANON_KEY=$(node -e "
const crypto = require('crypto');
const header = Buffer.from(JSON.stringify({alg:'HS256',typ:'JWT'})).toString('base64url');
const payload = Buffer.from(JSON.stringify({
  role: 'anon',
  iss: 'supabase',
  iat: Math.floor(Date.now()/1000),
  exp: Math.floor(Date.now()/1000) + 157680000  // 5 years
})).toString('base64url');
const signature = crypto.createHmac('sha256', '${JWT_SECRET}').update(header+'.'+payload).digest('base64url');
console.log(header+'.'+payload+'.'+signature);
") || { msg_error "Failed to generate ANON_KEY"; exit 1; }

SERVICE_ROLE_KEY=$(node -e "
const crypto = require('crypto');
const header = Buffer.from(JSON.stringify({alg:'HS256',typ:'JWT'})).toString('base64url');
const payload = Buffer.from(JSON.stringify({
  role: 'service_role',
  iss: 'supabase',
  iat: Math.floor(Date.now()/1000),
  exp: Math.floor(Date.now()/1000) + 157680000  // 5 years
})).toString('base64url');
const signature = crypto.createHmac('sha256', '${JWT_SECRET}').update(header+'.'+payload).digest('base64url');
console.log(header+'.'+payload+'.'+signature);
") || { msg_error "Failed to generate SERVICE_ROLE_KEY"; exit 1; }
msg_ok "Generated Secure Credentials"

msg_info "Configuring Supabase Environment"

# Copy .env.example to .env if it exists and has content
if [ -f /opt/supabase/.env.example ] && [ -s /opt/supabase/.env.example ]; then
  cp /opt/supabase/.env.example /opt/supabase/.env

  # Update configuration using sed (will only replace if pattern exists)
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

  # Ensure critical variables exist (append if not found in file)
  grep -q "^POSTGRES_PASSWORD=" /opt/supabase/.env || echo "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}" >> /opt/supabase/.env
  grep -q "^JWT_SECRET=" /opt/supabase/.env || echo "JWT_SECRET=${JWT_SECRET}" >> /opt/supabase/.env
  grep -q "^ANON_KEY=" /opt/supabase/.env || echo "ANON_KEY=${ANON_KEY}" >> /opt/supabase/.env
  grep -q "^SERVICE_ROLE_KEY=" /opt/supabase/.env || echo "SERVICE_ROLE_KEY=${SERVICE_ROLE_KEY}" >> /opt/supabase/.env
else
  # Create comprehensive .env from scratch with all Supabase variables
  msg_info "Creating comprehensive .env file from scratch"
  cat > /opt/supabase/.env <<EOF
############
# Secrets
############
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
JWT_SECRET=${JWT_SECRET}
ANON_KEY=${ANON_KEY}
SERVICE_ROLE_KEY=${SERVICE_ROLE_KEY}
DASHBOARD_USERNAME=admin
DASHBOARD_PASSWORD=${DASHBOARD_PASSWORD}

############
# Database
############
POSTGRES_HOST=db
POSTGRES_DB=postgres
POSTGRES_PORT=5432
# Default to "postgres" user; can be changed to "supabase_admin"
POSTGRES_USER=postgres

############
# API Proxy - Kong
############
KONG_HTTP_PORT=8000
KONG_HTTPS_PORT=8443

############
# API - PostgREST
############
PGRST_DB_SCHEMAS=public,storage,graphql_public

############
# Auth - GoTrue
############
# General
SITE_URL=http://${LOCAL_IP}:3000
ADDITIONAL_REDIRECT_URLS=
JWT_EXPIRY=3600
DISABLE_SIGNUP=false
API_EXTERNAL_URL=http://${LOCAL_IP}:8000

# Mailer Config
MAILER_URLPATHS_CONFIRMATION="/auth/v1/verify"
MAILER_URLPATHS_INVITE="/auth/v1/verify"
MAILER_URLPATHS_RECOVERY="/auth/v1/verify"
MAILER_URLPATHS_EMAIL_CHANGE="/auth/v1/verify"

# Email auth
ENABLE_EMAIL_SIGNUP=true
ENABLE_EMAIL_AUTOCONFIRM=false
SMTP_ADMIN_EMAIL=admin@example.com
SMTP_HOST=supabase-mail
SMTP_PORT=2500
SMTP_USER=fake_mail_user
SMTP_PASS=fake_mail_password
SMTP_SENDER_NAME=fake_sender

# Phone auth
ENABLE_PHONE_SIGNUP=true
ENABLE_PHONE_AUTOCONFIRM=true

############
# Studio - Dashboard
############
STUDIO_DEFAULT_ORGANIZATION=Default Organization
STUDIO_DEFAULT_PROJECT=Default Project
STUDIO_PORT=3000
SUPABASE_PUBLIC_URL=http://${LOCAL_IP}:8000

# Deprecated: Use STUDIO_PORT instead
PUBLIC_REST_URL=http://${LOCAL_IP}:8000/rest/v1/

############
# Functions - Edge Runtime
############
FUNCTIONS_VERIFY_JWT=false

############
# Logs - Logflare
############
LOGFLARE_LOGGER_BACKEND_API_KEY=${LOGFLARE_API_KEY}
LOGFLARE_API_KEY=${LOGFLARE_API_KEY}

# Change vector.schema to vector if you are using Postgres 13 or lower
VECTOR_DB_SCHEMA=extensions

############
# Metrics - Prometheus
############
METRICS_ENABLED=true

############
# Analytics - BigQuery
############
BIGQUERY_PROJECT_ID=your-project

############
# Storage
############
STORAGE_BACKEND=file
FILE_SIZE_LIMIT=52428800
STORAGE_S3_REGION=local

# Deprecated: Use FILE_SIZE_LIMIT instead
FILE_STORAGE_BACKEND_PATH=/var/lib/storage
GLOBAL_S3_BUCKET=supabase-storage-local

############
# Realtime
############
REALTIME_IP_VERSION=ipv4

############
# Image Transformation
############
IMGPROXY_ENABLE_WEBP_DETECTION=true

############
# PostgreSQL Vault
############
VAULT_ENC_KEY=${VAULT_ENC_KEY}

############
# Meta
############
PG_META_CRYPTO_KEY=${PG_META_CRYPTO_KEY}

############
# Auth - Secret Key Base
############
SECRET_KEY_BASE=${SECRET_KEY_BASE}

############
# Pooler
############
DEFAULT_POOL_SIZE=20
MAX_CLIENT_CONN=100

############
# Logflare
############
LOGFLARE_PUBLIC_ACCESS_TOKEN=${LOGFLARE_PUBLIC_TOKEN}
LOGFLARE_PRIVATE_ACCESS_TOKEN=${LOGFLARE_PRIVATE_TOKEN}
EOF
fi

msg_ok "Configured Supabase Environment"

msg_info "Starting Supabase Services"
if ! cd /opt/supabase; then
  msg_error "Failed to change directory to /opt/supabase"
  exit 1
fi
$STD docker compose pull
$STD docker compose up -d
msg_ok "Started Supabase Services"

msg_info "Waiting for Services to Initialize"
sleep 30
msg_ok "Services Initialized"

# Write credentials to temp file with restricted permissions, then move atomically
CREDS_TEMP=$(mktemp)
chmod 600 "$CREDS_TEMP"
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
} >"$CREDS_TEMP"
mv "$CREDS_TEMP" ~/supabase.creds

motd_ssh
customize
cleanup_lxc
