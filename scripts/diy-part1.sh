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

# 添加5G
git clone --depth=1 https://github.com/Siriling/5G-Modem-Support package/Modem-Support

# 注释掉+modemmanager，+luci-proto-modemmanager，+kmod-pcie_mhi
# sed -i 's/+modemmanager//g; s/+luci-proto-modemmanager//g; s/+kmod-pcie_mhi//g' package/Modem-Support/luci-app-modem/Makefile

# 添加风扇
git clone --depth=1 https://github.com/2253845067/h69k-fanctrl package/h69k-fanctrl

# small大佬常用OpenWrt软件包源码合集处理
./scripts/feeds update -a && rm -rf feeds/luci/applications/luci-app-mosdns
rm -rf feeds/packages/net/{alist,adguardhome,xray*,v2ray*,v2ray*,sing*,smartdns}
rm -rf feeds/smpackage/{base-files,dnsmasq,firewall*,fullconenat,libnftnl,nftables,ppp,opkg,ucl,upx,vsftpd-alt,miniupnpd-iptables,wireless-regdb,sms-tool,luci-app-sms-tool}

# 下载openclash内核
mkdir -p feeds/smpackage/luci-app-openclash/root/etc/openclash/core/
wget -qO- https://raw.githubusercontent.com/vernesong/OpenClash/core/master/dev/clash-linux-arm64.tar.gz | tar xOvz > feeds/smpackage/luci-app-openclash/root/etc/openclash/core/clash
wget -qO- https://raw.githubusercontent.com/vernesong/OpenClash/core/master/premium/clash-linux-arm64-2023.08.17-13-gdcc8d87.gz | gunzip -c > feeds/smpackage/luci-app-openclash/root/etc/openclash/core/clash_tun
wget -qO- https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-arm64.tar.gz | tar xOvz > feeds/smpackage/luci-app-openclash/root/etc/openclash/core/clash_meta
wget -qO- https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat > feeds/smpackage/luci-app-openclash/root/etc/openclash/GeoIP.dat
wget -qO- https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat > feeds/smpackage/luci-app-openclash/root/etc/openclash/GeoSite.dat

# 加入OpenClash核心
#chmod -R a+x $GITHUB_WORKSPACE/scripts/preset-clash-core.sh
#if [ 1 = 1 ]; then
#    $GITHUB_WORKSPACE/preset-clash-core.sh arm64
#fi

# MT7916 160mhz修复
rm -rf package/kernel/mt76
git clone --depth=1 https://github.com/2253845067/mt76 package/kernel/mt76
