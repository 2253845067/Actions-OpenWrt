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

# 解决编译libxlts（host）不通过
sed -i '/HOST_CONFIGURE_ARGS/ s/--disable-shared/--enable-shared/' feeds/packages/libs/libxml2/Makefile
sed -i '/HOST_CONFIGURE_ARGS/ a--with-libxml-libs-prefix=$(STAGING_DIR_HOSTPKG)/lib' feeds/packages/libs/libxslt/Makefile
sed -i '/HOST_CONFIGURE_ARGS/ a--with-libxml-include-prefix=$(STAGING_DIR_HOSTPKG)/include/libxml2/' feeds/packages/libs/libxslt/Makefile
