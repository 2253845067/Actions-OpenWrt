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
#echo 'src-git helloworld https://github.com/fw876/helloworld' >>feeds.conf.default
#echo 'src-git passwall https://github.com/xiaorouji/openwrt-passwall' >>feeds.conf.default

# 切换5.15内核编译
sed -i 's/6.1/5.15/g' target/linux/rockchip/Makefile

# 添加5G
git clone --depth=1 https://github.com/Siriling/5G-Modem-Support package/Modem-Support

# 删除部分插件
rm -rf package/Modem-Support/{rooter,luci-app-sms-tool,sms-tool}

# 添加风扇
git clone --depth=1 https://github.com/2253845067/h69k-fanctrl package/h69k-fanctrl

# 添加fm350专用拨号插件
# git clone -b lede https://github.com/2253845067/modemfeed
# cp -r modemfeed/packages/net/fm350-modem/. package/Modem-Support/fm350-modem
# cp -r modemfeed/packages/net/fm350-usb-net/. package/Modem-Support/fm350-usb-net
# cp -r modemfeed/luci/protocols/luci-proto-fm350/. package/Modem-Support/luci-proto-fm350

# 下载openclash内核
mkdir -p feeds/smpackage/luci-app-openclash/root/etc/openclash/core/
wget -qO- https://raw.githubusercontent.com/vernesong/OpenClash/core/master/dev/clash-linux-arm64.tar.gz | tar xOvz > feeds/smpackage/luci-app-openclash/root/etc/openclash/core/clash
wget -qO- https://raw.githubusercontent.com/vernesong/OpenClash/core/master/premium/clash-linux-arm64-2023.08.17-13-gdcc8d87.gz | gunzip -c > feeds/smpackage/luci-app-openclash/root/etc/openclash/core/clash_tun
wget -qO- https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-arm64.tar.gz | tar xOvz > feeds/smpackage/luci-app-openclash/root/etc/openclash/core/clash_meta
wget -qO- https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat > feeds/smpackage/luci-app-openclash/root/etc/openclash/GeoIP.dat
wget -qO- https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat > feeds/smpackage/luci-app-openclash/root/etc/openclash/GeoSite.dat
chmod +x feeds/smpackage/luci-app-openclash/root/etc/openclash/core/clash*

# MT7916 160mhz修复 （6.1内核下才需要使用）
# rm -rf package/kernel/mt76
# git clone --depth=1 https://github.com/2253845067/mt76 package/kernel/mt76
