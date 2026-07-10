#!/bin/bash
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#
# Copyright (c) 2019-2024 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

# Modify default IP
#sed -i 's/192.168.1.1/192.168.50.5/g' package/base-files/files/bin/config_generate

# Modify default theme
#sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci/Makefile

# Modify hostname
#sed -i 's/OpenWrt/P3TERX-Router/g' package/base-files/files/bin/config_generate

# Embed install_fan_control.sh into the firmware's /bin directory.
# After flashing, just run: sh /bin/install_fan_control.sh
FAN_SCRIPT="${GITHUB_WORKSPACE}/install_fan_control.sh"
if [ -f "$FAN_SCRIPT" ]; then
    mkdir -p files/bin
    cp "$FAN_SCRIPT" files/bin/install_fan_control.sh
    chmod +x files/bin/install_fan_control.sh
fi

# qmodem强制安装以覆盖现有的驱动程序/应用
./scripts/feeds install -a -f -p qmodem
