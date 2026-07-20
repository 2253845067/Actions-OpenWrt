#!/bin/bash
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part1.sh
# Description: OpenWrt DIY script part 1 (Before Update feeds)
#
# Copyright (c) 2019-2024 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

# Uncomment a feed source
#sed -i 's/^#\(.*helloworld\)/\1/' feeds.conf.default

# Add a feed source

# 添加 QModem 软件源
echo 'src-git qmodem https://github.com/FUjr/QModem.git;main' >> feeds.conf.default

# 添加主题软件包
mkdir -p package/yuqi-package/theme
git clone --depth=1 https://github.com/eamonxg/luci-app-aurora-config.git package/yuqi-package/theme/luci-app-aurora-config
git clone --depth=1 https://github.com/eamonxg/luci-theme-aurora.git package/yuqi-package/theme/luci-theme-aurora

# 添加网络流量监控应用
mkdir -p package/yuqi-package/others
git clone --depth=1 https://github.com/timsaya/luci-app-bandix.git package/yuqi-package/others/luci-app-bandix
git clone --depth=1 https://github.com/timsaya/openwrt-bandix.git package/yuqi-package/others/openwrt-bandix

# 添加风扇控制插件
git clone --depth=1 https://github.com/2253845067/luci-app-fancontrol.git package/yuqi-package/others/luci-app-fancontrol
