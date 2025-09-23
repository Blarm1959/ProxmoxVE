#!/usr/bin/env bash

# Copyright (c) 2021-2025 community-scripts ORG
# Author: Blarm1959
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/Dispatcharr/Dispatcharr

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# Setup App
msg_info "Setup ${APPLICATION}"
RELEASE=$(curl -fsSL https://api.github.com/repos/[REPO]/releases/latest | grep "tag_name" | awk '{print substr($2, 2, length($2)-3) }')
curl -fsSL -o "${RELEASE}.zip" "https://github.com/[REPO]/archive/refs/tags/${RELEASE}.zip"
unzip -q "${RELEASE}.zip"
mv "${APPLICATION}-${RELEASE}/" "/opt/${APPLICATION}"
#
#
#
echo "${RELEASE}" >/opt/"${APPLICATION}"_version.txt
msg_ok "Setup ${APPLICATION}"

motd_ssh
customize

# Cleanup
msg_info "Cleaning up"
rm -f "${RELEASE}".zip
$STD apt-get -y autoremove
$STD apt-get -y autoclean
msg_ok "Cleaned"
