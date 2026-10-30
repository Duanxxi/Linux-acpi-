# acpi-dump

> Linux 下导出 ACPI 表、反编译成 ASL、并在其中查找设备与关键字的单文件工具。

一个 `bash` 脚本，零基础依赖。缺 `acpica-tools` 时自动识别发行版并安装；没网时直接报"网络故障"，而不是把包管理器的一大堆报错甩给你。

---

## 功能

| 功能 | 命令 |
|---|---|
| 列出当前机器上的所有 ACPI 表 | `./acpi-dump.sh list` |
| 导出并反编译 DSDT | `./acpi-dump.sh dsdt` |
| 导出并反编译所有 SSDT | `./acpi-dump.sh ssdt` |
| 导出任意表（用表签名） | `./acpi-dump.sh facp` |
| 导出全部表 | `./acpi-dump.sh all` |
| 查找设备名 | `./acpi-dump.sh dsdt -d PCI0` |
| 关键字查找 | `./acpi-dump.sh dsdt -k ThermalZone` |

- 表签名大小写均可（`dsdt` / `DSDT` 等价）
- 反编译自动处理 DSDT 与 SSDT 的依赖关系（SSDT 带 DSDT 做外部符号表）
- 部分固件的 AML 不合规范，会自动用 `iasl -f` 强制重试一次

---

## 快速开始

```bash
git clone https://github.com/<your-name>/acpi-dump.git
cd acpi-dump
chmod +x acpi-dump.sh
sudo ./acpi-dump.sh
```

不带参数运行会进入**交互菜单**，按数字选功能，不用记命令：

```
=========================================================
  ACPI 表工具 v1.0.3
  输出目录: /home/user/Github-acpi/acpi_out
  已导出:   1 个 .dat，1 个 .dsl
=========================================================

   1) 列出所有 ACPI 表
   2) 导出 DSDT
   3) 导出所有 SSDT
   4) 导出指定表
   5) 导出全部表
   6) 查找设备名
   7) 查找关键字
   8) 帮助
   0) 退出

请选择 [0-8]:
```

- 每次操作完回到菜单，顶部状态会刷新「已导出」数量
- **选 4 会列出本机所有 ACPI 表**，输数字选，不用记签名；缺 DSDT/SSDT/FACP 会单独提醒
- **选 6/7 会先让你选查找范围**：全部表，或某一个 `.dsl`（便于定位问题在 DSDT 还是某个 SSDT 里）
- 选 6/7 前如果还没导出过任何表，会提示先执行 2 或 3
- 如果一台表都读不到，会提示常见原因（Device Tree 启动 / 权限 / 内核未启用 ACPI）

非 root 运行时会自动通过 `sudo` 提权。

---

## 使用示例（命令行模式）

带参数运行时保持原来的命令行行为，便于脚本化和 CI：

```bash
# 看看这台机器有哪些表
./acpi-dump.sh list

# 导出 DSDT 并反编译
sudo ./acpi-dump.sh dsdt

# 找 PCI0 这个设备在哪定义、在哪被引用
sudo ./acpi-dump.sh dsdt -d PCI0

# 找所有跟电源资源相关的代码（带前后 2 行上下文）
sudo ./acpi-dump.sh dsdt -k PowerResource

# 指定输出目录
sudo ./acpi-dump.sh all -o ~/acpi

# 导出后直接用 grep 二次过滤
grep -n "Method (_STA" ~/acpi/*.dsl
```

输出：

```
acpi_out/
├── dsdt.dat     # 二进制表（AML）
├── dsdt.dsl     # 反编译后的 ASL 源码，可读
├── ssdt1.dat
├── ssdt1.dsl
└── ...
```

---

## 依赖与自动安装

工具本身只用 `bash` 和 `coreutils`。真正的依赖是：

| 工具 | 来源包 | 作用 |
|---|---|---|
| `acpidump` | `acpica-tools` | 从内核 dump ACPI 表 |
| `iasl` | `acpica-tools` | 把 AML 反编译成 ASL |

缺失时的行为：

1. 先探测网络（`getent` → `curl`/`wget` → `ping`，任一通过即认为有网）
2. **有网**：识别 `apt` / `apt-get` / `dnf` / `yum` / `pacman` / `zypper` / `apk`，自动安装
3. **没网**：明确报 `网络故障`，并列出各发行版的手动安装命令，退出码 `2`

> Arch 系的包名是 `acpica`，不是 `acpica-tools`，脚本已按发行版映射。

### 国产系统（麒麟 / UOS）特别注意

这两家的商业源需要授权，`apt-get update` 常直接报 `401 Unauthorized` 和「没有数字签名」，**但 `apt install` 可以用**（`apt` 是系统封装的包装器，走的是另一套源配置）。

所以脚本把 **`apt` 排在 `apt-get` 前面**，且先直接 `install` 而不是先 `update`——`update` 反而会踩到坏源。

如果仍然失败，两个兜底方案：

```bash
# 1) 只装 iasl 也行，acpidump 可以用 cp 代替
ls /sys/firmware/acpi/tables/
sudo cp /sys/firmware/acpi/tables/DSDT ./acpi_out/dsdt.dat

# 2) 源码编译 iasl（只要 gcc / bison / flex）
wget https://github.com/acpica/acpica/archive/refs/tags/R20250404.tar.gz
tar xzf R20250404.tar.gz && cd acpica-R20250404
make iasl -j$(nproc)
sudo cp generate/unix/bin/iasl /usr/local/bin/
```

**关键：没有 `acpidump` 也能用。**
`/sys/firmware/acpi/tables/` 里的文件本身就是原始 ACPI 表，脚本检测到 `acpidump` 缺失时会直接 `cp` 出来（命名规则与 `acpidump -b` 一致），功能等价。只有 `iasl` 是不可替代的。

如果 `sysfs` 挂载点不在默认位置，可以用环境变量指定：

```bash
ACPI_SYSFS_DIR=/path/to/tables ./acpi-dump.sh dsdt
```

---

## 退出码

| 码 | 含义 |
|---|---|
| 0 | 成功 |
| 1 | 参数错误 |
| 2 | 依赖缺失且安装失败 / 无网络 |
| 3 | 无 root 权限 |
| 4 | 目标表不存在 |
| 5 | 反编译未产出任何 `.dsl` |
| 6 | 查找无匹配 |

方便在脚本里判断：

```bash
sudo ./acpi-dump.sh dsdt -k Thermal >/dev/null 2>&1
case $? in
    0) echo "找到了" ;;
    6) echo "没找到" ;;
    *) echo "出错了" ;;
esac
---

## 原理

```
内核 ACPI 表  --acpidump -b-->  xxx.dat (AML 二进制)
                                      |
                                  iasl -d
                                      |
                                      v
                                  xxx.dsl (ASL 源码)
                                      |
                              grep / 阅读 / 修改
```

ACPI 表在运行时由固件（UEFI/BIOS）交给操作系统，内核把它们暴露在 `/sys/firmware/acpi/tables/`。`acpidump` 读这些表并转成二进制文件，`iasl` 再把 AML 字节码反编译成人能读的 ASL。
