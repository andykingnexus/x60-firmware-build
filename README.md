# Firmware build archive

本仓库保留多套**独立源码、内核与设备目标**的构建流程，用于兼容、对比和救援。它们不是同一种固件，镜像不可跨设备或跨分区布局混刷。

## 工作流一览

| 工作流 | 设备 / 用途 | 源码与内核 | 状态 |
| --- | --- | --- | --- |
| `Build RG-X60` | 普通 RG-X60（非 New） | RuijieNetworksCommunity/MT798X-6.6-24.10，`openwrt-24.10-6.6`，固定提交 | 保留 |
| `Build RG-X60 New` | RG-X60 New | padavanonly/immortalwrt-mt798x-6.6，24.10 / 6.6 | 保留 |
| `Build Cetron CT3003 U-BootMod` | Cetron CT3003 U-BootMod | padavanonly/immortalwrt-mt798x-6.6，24.10 / 6.6 | 保留 |
| `Build RG-X60-New NMBM Recovery FIP` | RG-X60 New 的 NMBM 应急恢复 | 固定的 U-Boot/FIP 源码与补丁 | 仅救援 |

## 使用边界

- 普通固件只刷对应设备生成的 `squashfs-sysupgrade.bin`。
- 不要把 initramfs、Factory、BL2、FIP 或不同设备的镜像当作普通 sysupgrade 固件刷入。
- `Build RG-X60-New NMBM Recovery FIP` 是处理 NMBM 只读/恢复场景的专用工具，不能替代日常固件；仅在已确认恢复流程、分区布局和文件校验无误时使用。
- 修改 `defconfig/` 或相应工作流会触发对应的 GitHub Actions 构建；README 变更不会触发固件构建。

## RG-X60 New 的其他构建仓库

- [25.12-mt798x-rebase](https://github.com/andykingnexus/25.12-mt798x-rebase)：25.12 Rebase 构建。
- [rg-x60-new-mainline-build](https://github.com/andykingnexus/rg-x60-new-mainline-build)：官方 ImmortalWrt 主线、107MiB UBI 布局的专用构建。

实验性 KDAE/Honk 分支会保留到确认不再需要其历史内容后再删除。
