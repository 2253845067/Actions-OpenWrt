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
sed -i 's/192.168.1.1/192.168.10.1/g' package/base-files/files/bin/config_generate

# Modify default theme
#sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci/Makefile

# Modify hostname
#sed -i 's/OpenWrt/P3TERX-Router/g' package/base-files/files/bin/config_generate

# Fix Cyber 3588 AIB thermal zone registration on newer kernels.
# Linux rejects thermal zones when passive_delay is greater than polling_delay,
# which makes rockchip-thermal fail with -EINVAL and removes CPU temp sysfs nodes.
CYBER_DTS="target/linux/rockchip/files/arch/arm64/boot/dts/rockchip/rk3588-cyber3588-aib.dts"
if [ -f "$CYBER_DTS" ]; then
    sed -i '/&package_thermal {/,/};/s/polling-delay-passive = <2000>;/polling-delay-passive = <1000>;/' "$CYBER_DTS"
fi

# Embed install_fan_control.sh into the firmware's /bin directory.
# After flashing, just run: sh /bin/install_fan_control.sh
FAN_SCRIPT="${GITHUB_WORKSPACE}/install_fan_control.sh"
if [ -f "$FAN_SCRIPT" ]; then
    mkdir -p files/bin
    cp "$FAN_SCRIPT" files/bin/install_fan_control.sh
    chmod +x files/bin/install_fan_control.sh
fi

# 修复 QModem 内置 ndisc6 的源码地址。
# 上游 remlab.net 已删除 ndisc6 1.0.2（返回 410 Gone），而 OpenWrt/ImmortalWrt
# 的源码镜像里也没有这个文件，于是 make download 与编译阶段都会下载失败，
# 导致整次构建中断。这里升级到上游仍在提供的 1.0.8，并同步校验值。
NDISC6_DIR="feeds/qmodem/application/ndisc6"
if [ -f "$NDISC6_DIR/Makefile" ]; then
    if grep -q '^PKG_VERSION:=1\.0\.2$' "$NDISC6_DIR/Makefile"; then
        sed -i \
            -e 's|^PKG_VERSION:=1\.0\.2$|PKG_VERSION:=1.0.8|' \
            -e 's|^PKG_SOURCE_URL:=http://www\.remlab\.net/files/ndisc6$|PKG_SOURCE_URL:=https://www.remlab.net/files/ndisc6/|' \
            -e 's|^PKG_MD5SUM:=50cb4c19606cf6ff2b7388e71832f579$|PKG_HASH:=1f2fb2dc1172770aa5a09d39738a44d8b753cc5e2e25e306ca78682f9fea0b4f|' \
            "$NDISC6_DIR/Makefile"
        # 1.0.8 用 C11 的 alignas()（src/trace-*.c），而 QModem 的 Makefile
        # 强制 -std=c99：musl 的 <stdalign.h> 在 C99 下把 alignas 展开成
        # __attribute__((aligned(struct tcphdr)))，报
        # "expected expression before 'struct'"，因此改用 gnu11。
        sed -i 's|^TARGET_CFLAGS += -std=c99$|TARGET_CFLAGS += -std=gnu11|' "$NDISC6_DIR/Makefile"
        # 这两个补丁只适用于 1.0.2：1.0.8 已重写 traceroute 代码，
        # 且 rdnssd/ 目录改名为 rdnss/，补丁无法应用。
        rm -f "$NDISC6_DIR/patches/100-favor_bsd.patch" \
              "$NDISC6_DIR/patches/110-strverscmp.patch"
        echo "qmodem: ndisc6 已升级到 1.0.8（上游已删除 1.0.2 源码包）"
    fi

    # 关闭 NLS，避免依赖 target 侧的 gettext/intl 支持
    if ! grep -q '^CONFIGURE_ARGS += --disable-nls$' "$NDISC6_DIR/Makefile"; then
        # Makefile 末尾可能没有换行符，先补齐再追加，避免与最后一行粘连
        if [ -n "$(tail -c 1 "$NDISC6_DIR/Makefile")" ]; then
            echo >> "$NDISC6_DIR/Makefile"
        fi
        echo 'CONFIGURE_ARGS += --disable-nls' >> "$NDISC6_DIR/Makefile"
    fi
fi

# qmodem强制安装以覆盖现有的驱动程序/应用
./scripts/feeds install -a -f -p qmodem
