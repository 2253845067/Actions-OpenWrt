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

# Fix Cyber 3588 AIB fan PWM settings. The stock DTS marks pwm1 as inverted
# and uses a 10000 ns period; this board behaves correctly with normal polarity
# and a 50000 ns period, matching the tested manual sysfs control values.
DTS_FILE="target/linux/rockchip/files/arch/arm64/boot/dts/rockchip/rk3588-cyber3588-aib.dts"
[ -f "$DTS_FILE" ] && sed -i 's|<&pwm1 0 10000 PWM_POLARITY_INVERTED>|<\&pwm1 0 50000 0>|' "$DTS_FILE"

# Add the local Cyber 3588 AIB LuCI fan plugin to the ImmortalWrt package tree.
SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAN_PACKAGE_SRC="${GITHUB_WORKSPACE:-$SCRIPT_ROOT}/luci-app-fan"
FAN_PACKAGE_DST="package/luci-app-fan"
if [ -d "$FAN_PACKAGE_SRC" ]; then
    rm -rf "$FAN_PACKAGE_DST"
    cp -a "$FAN_PACKAGE_SRC" "$FAN_PACKAGE_DST"
fi

# qmodem强制安装以覆盖现有的驱动程序/应用
./scripts/feeds install -a -f -p qmodem
