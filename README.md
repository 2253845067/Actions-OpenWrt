# Openwrt For 3588AIB定制固件

[![最新固件下载](https://img.shields.io/github/v/release/2253845067/Actions-OpenWrt?style=flat-square&label=最新固件下载)](../../releases)

![支持设备](https://img.shields.io/badge/支持设备:-blueviolet.svg?style=flat-square) ![3588AIB](https://img.shields.io/badge/3588AIB-blue.svg?style=flat-square)

# 一、简介

该项目从[P3TERX/Actions-OpenWrt](https://github.com/P3TERX/Actions-OpenWrt)进行定制，添加5G模块官方支持和一些常用插件

# 二、源代码地址

- immorlinwrt：https://github.com/immortalwrt/immortalwrt

# 三、固件

## 功能特性

- 添加5G模块管理插件（QWRT模组管理）
- 添加以下主要插件
  - OpenClash
  - Docker
  - ZeroTier
- 添加风扇控制安装脚本

```bash
sh /bin/install_fan_control.sh
```

## 默认配置

- IP: `http://192.168.1.1`
- 用户名: `root`
- 密码: `password`
- 北京时间每天 `2:00` 定时编译

# 四、展示

![](/img/Snipaste_2026-07-14_12-11-52.png)
![](/img/Snipaste_2026-07-14_12-12-14.png)
![](/img/Snipaste_2026-07-14_12-12-23.png)
![](/img/Snipaste_2026-07-14_12-13-23.png)
![](/img/Snipaste_2026-07-14_12-13-33.png)
![](/img/Snipaste_2026-07-14_12-13-41.png)

# 五、鸣谢

- [immorlinwrt](https://github.com/immortalwrt/immortalwrt)
- [QModem](https://github.com/FUjr/QModem)
- [P3TERX/Actions-OpenWrt](https://github.com/P3TERX/Actions-OpenWrt)
- [istoreos](https://github.com/istoreos/istoreos)
- [Microsoft Azure](https://azure.microsoft.com)
- [GitHub Actions](https://github.com/features/actions)
- [OpenWrt](https://github.com/openwrt/openwrt)
- [tmate](https://github.com/tmate-io/tmate)
- [mxschmitt/action-tmate](https://github.com/mxschmitt/action-tmate)
- [csexton/debugger-action](https://github.com/csexton/debugger-action)
- [Cowtransfer](https://cowtransfer.com)
- [WeTransfer](https://wetransfer.com/)
- [Mikubill/transfer](https://github.com/Mikubill/transfer)
- [softprops/action-gh-release](https://github.com/softprops/action-gh-release)
- [Mattraks/delete-workflow-runs](https://github.com/Mattraks/delete-workflow-runs)
- [actions/github-script](https://github.com/actions/github-script)
- [jlumbroso/free-disk-space](https://github.com/jlumbroso/free-disk-space)
