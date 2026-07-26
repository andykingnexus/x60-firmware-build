# Ruijie RG-X60 自定义固件编译工程

基于 [`RuijieNetworksCommunity/MT798X-6.6-24.10`](https://github.com/RuijieNetworksCommunity/MT798X-6.6-24.10)
（分支 `openwrt-24.10-6.6`），只编译 **RG-X60（普通版）** 一个设备。

## 目录结构

```
.
├── defconfig/
│   └── x60.config          # 基于官方 mt7986-ruijie-lite.config 裁剪出的单设备配置
├── patches/
│   └── zzz-999-mtkhnat-use-generic-nf-nat-dependency.patch
│                            # 解除 MediaTek HNAT 驱动对 legacy iptables (IP_NF_NAT) 的强制依赖
├── .github/workflows/
│   └── build-x60.yml       # GitHub Actions 编译工作流
└── README.md
```

**注意**：本仓库本身不包含 OpenWrt/ImmortalWrt 源码。workflow 运行时会实时 clone
`RuijieNetworksCommunity/MT798X-6.6-24.10` 官方仓库，把上面两个文件套进去再编译。
这样做的好处是官方仓库更新时，你只要重新跑一次 workflow 就能拿到最新源码 + 你的定制。

## 部署步骤

### 1. Fork / 新建仓库
把这个目录整体推到你自己的 GitHub 仓库（例如 `andykingnezus/x60-firmware`）。

```bash
git init
git add .
git commit -m "init: X60 custom build project"
git branch -M main
git remote add origin https://github.com/<your-account>/<your-repo>.git
git push -u origin main
```

### 2. 触发编译
- **推送触发**：修改 `defconfig/x60.config`、`patches/` 或 workflow 文件并 push 到 `main`，会自动开始编译。
- **手动触发**：在 GitHub 仓库页面 → Actions → "Build Ruijie RG-X60 Firmware" → Run workflow。
  可选打开 `ssh_debug: true`，会在下载源码后启动 tmate，方便远程排错。

### 3. 取产物
编译完成后，在该次 workflow run 页面的 Artifacts 里下载
`ruijie-rg-x60-firmware-<run_number>`，里面包含：
- `*sysupgrade.bin` —— 刷机用固件
- `x60-full.config` —— 实际生效的完整 `.config`（用于事后核对哪些选项真正落地）

### 4. 刷机
你目前用的是社区第三方 U-Boot（支持 uboot 界面选择原厂/扩容分区，且认 `sysupgrade.bin` 格式），
直接在 U-Boot 里选择你当前使用的分区类型，走 sysupgrade 方式刷入即可。
**建议先做好可从 U-Boot 界面重新刷入的手段（TFTP / 已有固件备份）再刷第一次**，
因为这是你自己 fork 定制的固件，出现问题时最快的恢复路径是 U-Boot 侧重刷，而不是等 GitHub Actions。

---

## 配置说明（相对官方 `mt7986-ruijie-lite.config` 的改动）

### 1. 只保留 RG-X60 单设备
原 `mt7986-ruijie-lite.config` 是 multi-profile，一次编译打包 X60 / X60 New / X60 Pro / EW-6000GX Pro
四款设备的固件。本仓库改为单设备 `CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_ruijie-rg-x60=y`，
去掉 `CONFIG_TARGET_MULTI_PROFILE`，编译时间显著缩短，产物也更干净。

对应设备定义在 Ruijie 源码的 `target/linux/mediatek/image/filogic.mk` 里：

```makefile
define Device/ruijie-rg-x60
  DEVICE_VENDOR := Ruijie
  DEVICE_MODEL := RG-X60
  DEVICE_DTS := mt7986a-ruijie-rg-x60-expand
  ...
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += ruijie-rg-x60
```

**重要说明**：这个仓库里普通 RG-X60（非 New/Pro）只有 `stock`（原厂分区）和这个 `expand`（扩容分区）
两个变体，**没有单独的 `-ubootmod` 后缀设备**。你说的"已刷入社区第三方 U-Boot，支持原厂/扩容分区可选"
正好对应这个 `expand` 变体——它是配合改造过分区表的社区 U-Boot 使用的固件形态，
镜像格式仍然是标准 `sysupgrade.bin`，与你现有 U-Boot 认的格式一致。

### 2. eBPF / BTF 内核选项（用于 dae 透明代理）

Kconfig 依赖链（在这棵源码树里逐一核实过，不是照抄别处的通用列表）：

```
KERNEL_DEBUG_INFO=y                    # 父依赖，必须先开
# KERNEL_DEBUG_INFO_REDUCED is not set # 必须关闭，否则 BTF 编译条件不满足
KERNEL_DEBUG_INFO_BTF=y                # 生成 BTF 类型信息（dae 的 CO-RE 依赖它）
KERNEL_DEBUG_INFO_BTF_MODULES=y
KERNEL_MODULE_ALLOW_BTF_MISMATCH=y     # 内核模块 BTF 不完全匹配时仍允许加载
KERNEL_BPF_EVENTS=y                    # BPF 挂到 kprobe/uprobe/tracepoint
KERNEL_CGROUP_BPF=y                    # cgroup 挂载点上的 eBPF（dae 的 TC hook 依赖）
KERNEL_XDP_SOCKETS=y                   # XDP socket
KERNEL_BPF_STREAM_PARSER=y             # BPF_MAP_TYPE_SOCKMAP 相关
KERNEL_NETKIT=y                        # BPF 可编程网络设备
KERNEL_KPROBE_EVENTS=y
KERNEL_PROBE_EVENTS_BTF_ARGS=y
```

`KERNEL_DEBUG_INFO_BTF` 在官方源码里默认写的是
`default y if (... TARGET_mediatek_filogic ...) && BUILDBOT`——也就是说只有 Ruijie 官方自己的
buildbot 编译才会自动带上，你自建 workflow 必须显式声明，否则会静默保持关闭。

workflow 里加了一步「校验配置是否被依赖关系丢弃」，编译前会打印这几个符号最终是否为 `=y`，
如果哪一个因为其他依赖冲突被打回默认值，日志里会有 `WARN` 提示，方便你第一时间发现，
而不是等固件刷上去之后才发现 dae 用不了 BTF CO-RE。

### 3. HNAT 与 legacy iptables 解耦（关键修复）

你提到的问题是真实存在的：MediaTek 官方 SDK 补丁
`999-2745-mtkhnat-add-mtkhnat-driver-support.patch` 里，`NET_MEDIATEK_HNAT` 的 Kconfig 依赖写死为：

```kconfig
depends on NET_MEDIATEK_SOC && NF_CONNTRACK && IP_NF_NAT
```

`IP_NF_NAT` 是 legacy iptables 的 NAT 内核符号，这会导致即便你完全走 nftables/firewall4，
只要开 HNAT 硬件加速就必须连带编译 legacy iptables 相关内核模块。

参照你给的 `chasey-dev/immortalwrt-mt798x-rebase` 那次 commit
（[d577094](https://github.com/chasey-dev/immortalwrt-mt798x-rebase/commit/d577094863e2e9c2245049e00a64d217126c1054)）
的思路，新增一个补丁把依赖改成通用的 `NF_NAT`：

```diff
 config NET_MEDIATEK_HNAT
 	tristate "MediaTek HW NAT support"
-	depends on NET_MEDIATEK_SOC && NF_CONNTRACK && IP_NF_NAT
+	depends on NET_MEDIATEK_SOC && NF_CONNTRACK && NF_NAT
```

**这个补丁只解除了「强制依赖」，没有删除 defconfig 里的 iptables legacy 包**——
你的 x60.config 里仍然保留了 `iptables-mod-*` / `kmod-ipt-*` 一整套（继承自官方 lite.config），
作为兼容后备。如果你后续确认完全不需要，可以再单独清理 defconfig，
这个改动和"删不删 iptables 包"是两件独立的事，不冲突。

补丁文件名刻意用字母前缀 `zzz-999-...`（而不是数字前缀），
是因为这棵源码树里 `patches-6.6/` 目录同时存在 `999-xxx` 和 `9999-xxx` 两种数字前缀，
字典序排序下 `999-` 系列其实排在 `9999-` 系列**之前**，光用数字前缀无法稳妥保证排在最后应用。
已核实 `9999-01-hnat.patch` 等后续补丁不会再触碰这一行 Kconfig 依赖，
但用字母前缀更保险、可读性也更好。

### 4. 移除的 LuCI 组件

按你的要求，从官方 lite.config 里去掉了以下内容（你目前完全走 sing-box/dae 命令行方案，不需要图形化面板）：

- `luci-app-eqos-mtk` / `luci-i18n-eqos-mtk-zh-cn`
- `luci-app-upnp` / `luci-i18n-upnp-zh-cn`
- `miniupnpd-nftables`
- passwall / rclone 相关的 `INCLUDE_*` 子特性声明整体清除
  （这些包本身在 lite.config 里没有被启用为主包，只是留了一堆可选特性的占位声明，一并清掉）

---

## 已知注意事项

1. **U-Boot 不是这个仓库编译的**：你现有的社区第三方 U-Boot 是单独的项目，这个仓库只负责编译
   OpenWrt/ImmortalWrt 系统本体（`sysupgrade.bin`）。两者是解耦的，正常情况下互不影响。
2. **首次编译较慢**：完整走一遍 `make download` + `make -j$(nproc)` 大概率超过 1 小时（含工具链），
   GitHub Actions 免费额度里单个 job 最长 6 小时，通常够用；如果你想加速后续编译，
   可以在 workflow 里加 ccache 持久化（当前版本没有加，先保证正确性，你需要的话我可以后续加上）。
2. **编译失败时**：workflow 会自动把 `.config` 和 `logs/` 目录打包成
   `build-logs-<run_number>` artifact，方便你直接回来看具体是哪个包挂了。
3. **eBPF 校验步骤只做静态检查**：只能确认 `.config` 里符号是否为 `y`，
   不能保证 dae 运行时 100% 正常（比如具体的 verifier 兼容性问题要实际刷机测试）。
