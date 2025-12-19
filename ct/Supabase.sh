#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2021-2025 community-scripts ORG
# Author: taylorelley
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://supabase.com/

APP="Supabase"
var_tags="${var_tags:-database;docker}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-50}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"
var_pw="${var_pw:-}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -d /opt/supabase ]]; then
    msg_error "No ${APP} Installation Found!"
    exit 1
  fi

  msg_info "Creating Backup"
  mkdir -p /opt/supabase-backups
  BACKUP_FILE="/opt/supabase-backups/env_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
  tar -czf "$BACKUP_FILE" -C /opt/supabase .env 2>/dev/null || true
  msg_ok "Backup Created"

  msg_info "Updating ${APP}"
  if ! cd /opt/supabase; then
    msg_error "Failed to change directory to /opt/supabase"
    exit 1
  fi
  if ! $STD docker compose pull; then
    msg_error "Failed to pull Docker images"
    exit 1
  fi
  $STD docker compose up -d
  msg_ok "Updated ${APP}"

  msg_info "Cleaning Up"
  $STD docker image prune -f
  msg_ok "Cleanup Completed"

  msg_ok "Update Successful"
  exit 0
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:8000${CL}"
