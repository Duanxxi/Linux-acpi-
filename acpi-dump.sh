#!/usr/bin/env bash
#
# acpi-dump.sh - ACPI 表导出 / 反编译 / 查找工具
#
# 用法:
#   ./acpi-dump.sh list                     列出所有 ACPI 表
#   ./acpi-dump.sh dsdt                     导出并反编译 DSDT
#   ./acpi-dump.sh ssdt                     导出并反编译所有 SSDT
#   ./acpi-dump.sh facp                     导出任意表（用表签名，大小写均可）
#   ./acpi-dump.sh all                      导出全部表
#   ./acpi-dump.sh dsdt -d PCI0             查找设备 PCI0（Device/Scope/Name/Method）
#   ./acpi-dump.sh dsdt -k ThermalZone      关键字查找（带上下文）
#   ./acpi-dump.sh -l                       等价于 list
#
# 选项:
#   -d, --device <NAME>   在反编译结果里查找设备名（ACPI 4 字符名）
#   -k, --keyword <TEXT>  在反编译结果里查找关键字
#   -o, --outdir <DIR>    输出目录，默认 ./acpi_out
#       --no-color        关闭彩色输出
#   -h, --help            显示帮助
#   -V, --version         显示版本
#
# 依赖: acpica-tools (acpidump + iasl)，缺失时会尝试自动安装
#
# License: MIT
#

set -uo pipefail

VERSION="1.0.3"
SCRIPT_NAME="$(basename "$0")"
OUTDIR="./acpi_out"
USE_COLOR="auto"
USE_SYSFS=0   # 1 = 没有 acpidump，直接从 /sys/firmware/acpi/tables 读
SYSFS_DIR="${ACPI_SYSFS_DIR:-/sys/firmware/acpi/tables}"

# ---------------------------------------------------------------------------
# 输出与错误
# ---------------------------------------------------------------------------

if [ -t 1 ] && [ "$USE_COLOR" != "never" ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
    C_BLU=$'\033[34m'; C_DIM=$'\033[2m';  C_RST=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_RST=""
fi

info()  { printf '%s[*]%s %s\n'  "$C_BLU" "$C_RST" "$*"; }
ok()    { printf '%s[+]%s %s\n'  "$C_GRN" "$C_RST" "$*"; }
warn()  { printf '%s[!]%s %s\n'  "$C_YEL" "$C_RST" "$*" >&2; }
err()   { printf '%s[x]%s %s\n'  "$C_RED" "$C_RST" "$*" >&2; }

die() { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# 依赖检测与自动安装
# ---------------------------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

# 识别包管理器
# 顺序很关键：apt 排在 apt-get 前面。麒麟/UOS 上 apt-get 常因商业源 401 失效，
# 但 apt 是系统封装的包装器，走它自己的源配置，实测可用。
detect_pm() {
    local pm
    for pm in apt dnf yum pacman zypper apk apt-get; do
        if have "$pm"; then
            echo "$pm"
            return 0
        fi
    done
    return 1
}

# 各发行版的包名（Arch 的包叫 acpica，不是 acpica-tools）
pkg_for() {
    case "$1" in
        apt|apt-get|dnf|yum) echo "acpica-tools" ;;
        pacman|zypper|apk) echo "acpica" ;;
        *) echo "acpica-tools" ;;
    esac
}

# 网络连通性：DNS -> HTTP -> ICMP 三级探测，任一通过即认为有网
check_net() {
    if have getent && getent hosts mirrors.aliyun.com >/dev/null 2>&1; then
        return 0
    fi
    if have curl; then
        curl -sI --max-time 4 https://mirrors.aliyun.com >/dev/null 2>&1 && return 0
        curl -sI --max-time 4 https://deb.debian.org     >/dev/null 2>&1 && return 0
        curl -sI --max-time 4 https://archlinux.org      >/dev/null 2>&1 && return 0
    fi
    if have wget; then
        wget -q --timeout=4 --spider https://mirrors.aliyun.com >/dev/null 2>&1 && return 0
    fi
    if have ping; then
        ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1 && return 0
    fi
    return 1
}

install_pkg() {
    local pm="$1" pkg
    pkg="$(pkg_for "$pm")"
    case "$pm" in
        apt)
            # 麒麟/UOS 上 apt install 能用，apt-get 常因源授权 401 失败，
            # 所以先直接 install，不主动 update（update 反而会踩到坏源）
            apt install -y "$pkg" && return 0
            apt update -qq >/dev/null 2>&1 || true
            apt install -y "$pkg" && return 0
            apt install -y "$pkg" \
                -o Acquire::AllowInsecureRepositories=true \
                -o Acquire::AllowDowngradeToInsecureRepositories=true
            ;;
        apt-get)
            apt-get update -qq >/dev/null 2>&1 || true
            apt-get install -y "$pkg" && return 0
            apt-get install -y "$pkg" \
                -o Acquire::AllowInsecureRepositories=true \
                -o Acquire::AllowDowngradeToInsecureRepositories=true
            ;;
        dnf)     dnf install -y "$pkg" ;;
        yum)     yum install -y "$pkg" ;;
        pacman)  pacman -Sy --noconfirm --needed "$pkg" ;;
        zypper)  zypper --non-interactive install "$pkg" ;;
        apk)     apk add --no-cache "$pkg" ;;
        *)       return 1 ;;
    esac
}

ensure_tools() {
    local missing=() pm

    # acpidump 缺失不阻断：/sys/firmware/acpi/tables 里的文件就是原始表，
    # cp 出来和 acpidump -b 等价（国产系统装不上 acpica-tools 时的救命路径）
    if ! have acpidump; then
        if [ -r "$SYSFS_DIR" ]; then
            USE_SYSFS=1
            warn "未找到 acpidump，将直接从 /sys/firmware/acpi/tables 读取（效果等价）"
        else
            missing+=(acpidump)
        fi
    fi

    # iasl 没有替代品，必须装
    have iasl || missing+=(iasl)

    if [ ${#missing[@]} -eq 0 ]; then
        return 0
    fi

    warn "缺少依赖工具: ${missing[*]}（属于 acpica-tools 包）"

    # 先判网络，再判包管理器——这样报错信息才对得上真正的原因
    if ! check_net; then
        err "网络故障：检测不到外网连接，无法自动安装依赖。"
        err ""
        err "请检查网络（或代理/DNS）后重试，也可以手动安装："
        err "  Debian / Ubuntu : sudo apt install acpica-tools"
        err "  RHEL / Fedora   : sudo dnf install acpica-tools"
        err "  Arch            : sudo pacman -S acpica"
        err "  openSUSE        : sudo zypper install acpica"
        err "  Alpine          : sudo apk add acpica"
        exit 2
    fi

    if ! pm="$(detect_pm)"; then
        err "未识别到包管理器，请手动安装 acpica-tools 后重试。"
        exit 2
    fi

    info "检测到包管理器: $pm，正在安装 $(pkg_for "$pm") ..."
    if ! install_pkg "$pm"; then
        install_help_hint
        exit 2
    fi

    have iasl || { install_help_hint; exit 2; }
    ok "依赖安装完成"
}

# 自动安装失败时的兜底提示：国产发行版（麒麟/UOS）的源常要授权，apt 直接 401
install_help_hint() {
    err ""
    err "自动安装失败。常见原因："
    err "  · 软件源需要授权（麒麟/UOS 商业源常见，apt 报 401 Unauthorized）"
    err "  · 软件源签名校验失败（'没有数字签名'）"
    err "  · 当前源里没有 acpica-tools 这个包"
    err ""
    err "三个办法，按成功率排序："
    err ""
    err "【1】直接用 apt —— 麒麟/UOS 上 apt-get 常因商业源 401 失效，但 apt 可以用"
    err "    sudo apt install -y acpica-tools"
    err ""
    err "【2】只装 iasl 也行（acpidump 可以用 cp 代替，本脚本已支持）"
    err "    ls /sys/firmware/acpi/tables/    # 有内容就说明能直接读表"
    err "    sudo cp /sys/firmware/acpi/tables/DSDT ./acpi_out/dsdt.dat"
    err ""
    err "【3】从源码编译 iasl（最可靠，只要有 gcc/bison/flex）"
    err "    which gcc bison flex make"
    err "    wget https://github.com/acpica/acpica/archive/refs/tags/R20250404.tar.gz"
    err "    tar xzf R20250404.tar.gz && cd acpica-R20250404"
    err "    make iasl -j\$(nproc)"
    err "    sudo cp generate/unix/bin/iasl /usr/local/bin/"
}

# ---------------------------------------------------------------------------
# 权限
# ---------------------------------------------------------------------------

# acpidump 需要 root；非 root 时用 sudo 重跑自己，保留原参数
require_root() {
    [ "$(id -u)" -eq 0 ] && return 0

    if have sudo; then
        info "acpidump 需要 root 权限，尝试通过 sudo 重新执行 ..."
        exec sudo -E bash "$0" "$@"
    fi

    err "需要 root 权限读取 ACPI 表，但未找到 sudo。"
    err "请用 root 用户执行，例如: su -c './$SCRIPT_NAME $*'"
    exit 3
}

# ---------------------------------------------------------------------------
# 动作
# ---------------------------------------------------------------------------

# 列出当前机器可用的 ACPI 表签名（每行一个大写签名，已去重）
# 多个 SSDT（SSDT1/SSDT2…）合并成一行 SSDT，导出时会一起导出
list_tables() {
    if [ -d "$SYSFS_DIR" ]; then
        ls -1 "$SYSFS_DIR" 2>/dev/null \
            | grep -vE '^(dynamic|data)$' \
            | sed -E 's/^(SSDT)[0-9]+$/\1/' \
            | grep -E '^[A-Za-z0-9]{4}$' \
            | sort -u
    elif have acpidump; then
        acpidump 2>/dev/null | grep -oE '^[A-Z0-9]{4}' | sort -u
    fi
}

do_list() {
    local t
    printf '%s已加载的 ACPI 表（来源 %s）:%s\n' "$C_DIM" "$SYSFS_DIR" "$C_RST"
    list_tables | while IFS= read -r t; do
        printf '  %s\n' "$t"
    done
}

# 返回反编译后 .dsl 文件列表
dsl_files() {
    find "$OUTDIR" -maxdepth 1 -name '*.dsl' 2>/dev/null | sort
}

# 若目标表还没反编译，自动补一次
ensure_decompiled() {
    local sig="$1"
    [ -n "$(dsl_files)" ] && return 0
    info "尚未反编译，先导出并反编译 $sig ..."
    do_dump "$sig"
}

# 没有 acpidump 时的替代实现：sysfs 里的文件本身就是原始 ACPI 表
# （acpidump -b 无非是把它读出来写成 <sig>.dat，命名规则保持一致）
dump_sysfs() {
    local sig="$1"
    local src="$SYSFS_DIR"
    local n=0 f base lower

    [ -d "$src" ] || return 1

    if [ "$sig" = "ALL" ]; then
        for f in "$src"/*; do
            [ -f "$f" ] || continue
            base="$(basename "$f" | tr 'A-Z' 'a-z')"
            case "$base" in dynamic|data) continue ;; esac
            cp "$f" "$OUTDIR/$base.dat" 2>/dev/null && n=$((n + 1))
        done
    else
        lower="$(printf '%s' "$sig" | tr 'A-Z' 'a-z')"
        for f in "$src"/*; do
            [ -f "$f" ] || continue
            base="$(basename "$f" | tr 'A-Z' 'a-z')"
            case "$base" in
                "$lower"*) cp "$f" "$OUTDIR/$base.dat" 2>/dev/null && n=$((n + 1)) ;;
            esac
        done
    fi

    [ "$n" -gt 0 ]
}

do_dump() {
    local raw="$1"
    local sig
    sig="$(echo "$raw" | tr '[:lower:]' '[:upper:]')"

    mkdir -p "$OUTDIR" || die "无法创建输出目录: $OUTDIR"

    if [ "$sig" = "ALL" ]; then
        info "导出全部 ACPI 表到 $OUTDIR ..."
        if [ "${USE_SYSFS:-0}" = "1" ]; then
            dump_sysfs ALL || die "读取 /sys/firmware/acpi/tables 失败（该目录为空或不可读）"
        else
            ( cd "$OUTDIR" && acpidump -b ) || die "acpidump 执行失败"
        fi
        n=$(find "$OUTDIR" -maxdepth 1 -name '*.dat' 2>/dev/null | wc -l)
    else
        info "导出 $sig 到 $OUTDIR ..."
        if [ "${USE_SYSFS:-0}" = "1" ]; then
            dump_sysfs "$sig" \
                || die "在 /sys/firmware/acpi/tables 里找不到 $sig（可运行 '$SCRIPT_NAME list' 查看）"
        else
            ( cd "$OUTDIR" && acpidump -b -n "$sig" ) \
                || die "acpidump 执行失败（该表可能不存在，可先运行 '$SCRIPT_NAME list' 查看）"
        fi
        # 只统计本次签名对应的文件，避免把目录里之前导出的表算进来
        n=$(find "$OUTDIR" -maxdepth 1 -iname "${sig}*.dat" 2>/dev/null | wc -l)
    fi

    n=$(printf '%s' "$n" | tr -d ' ')
    if [ "${n:-0}" -eq 0 ]; then
        err "没有导出任何表。可能这张表在你的机器上不存在，或固件不提供。"
        err "可运行 '$SCRIPT_NAME list' 查看当前机器有哪些表。"
        exit 4
    fi

    if [ "$sig" = "ALL" ]; then
        ok "导出完成，共 $n 个表"
    else
        ok "本次导出 $n 个 $sig 表"
    fi

    do_decompile
}

do_decompile() {
    local f base

    # 1) DSDT 先编，SSDT 反编译时要用它做外部符号表
    for f in "$OUTDIR"/dsdt*.dat; do
        [ -e "$f" ] || continue
        if ! { iasl -d "$f" >/dev/null 2>&1 || iasl -f -d "$f" >/dev/null 2>&1; }; then
            warn "反编译失败: $(basename "$f")（部分固件的 AML 不符合规范，已尝试 -f 强制模式）"
        fi
    done

    # 2) SSDT 带上 DSDT 做外部引用，避免大量 unresolved external 警告
    for f in "$OUTDIR"/ssdt*.dat; do
        [ -e "$f" ] || continue
        if [ -e "$OUTDIR/dsdt.dat" ]; then
            iasl -e "$OUTDIR/dsdt.dat" -d "$f" >/dev/null 2>&1 \
                || iasl -f -e "$OUTDIR/dsdt.dat" -d "$f" >/dev/null 2>&1 \
                || warn "反编译失败: $(basename "$f")"
        else
            iasl -d "$f" >/dev/null 2>&1 || iasl -f -d "$f" >/dev/null 2>&1 \
                || warn "反编译失败: $(basename "$f")"
        fi
    done

    # 3) 其余表（FACP/APIC/SRAT/…) 是固定结构体，不是 AML，不反编译，只保留 .dat
    local other=0
    for f in "$OUTDIR"/*.dat; do
        [ -e "$f" ] || continue
        base="$(basename "$f" .dat)"
        case "$base" in
            dsdt*|ssdt*) continue ;;
            *) other=$((other + 1)) ;;
        esac
    done

    local total
    total=$(dsl_files | wc -l)
    if [ "$total" -eq 0 ]; then
        # 只导出了非 AML 表（FACP/APIC/SRAT…）时，没有 .dsl 是正常的
        if [ "$other" -gt 0 ]; then
            ok "已导出 $other 个非 AML 表（FACP/APIC 这类是固定结构，本来就不需要反编译）"
            return 0
        fi
        err "反编译没有产出任何 .dsl 文件。"
        err "可尝试手动执行: iasl -f -d $OUTDIR/dsdt.dat 查看具体报错。"
        exit 5
    fi

    ok "反编译完成，输出目录内共 $total 个 .dsl 文件"
    local d
    for d in $(dsl_files); do
        printf '    %s\n' "$(basename "$d")"
    done
    [ "$other" -gt 0 ] && info "另有 $other 个非 AML 表只保留了 .dat（FACP/APIC 这类是固定结构，无需反编译）"
    return 0
}

# 列出已反编译的 .dsl，让用户选查找范围
# 菜单走 stderr（调用方用 $(...) 捕获时不会被吞掉），选中的路径走 stdout
pick_dsl_scope() {
    local -a ds
    local line i sel

    while IFS= read -r line; do
        [ -n "$line" ] && ds+=("$line")
    done < <(dsl_files)

    [ ${#ds[@]} -eq 0 ] && return 1

    printf '%s当前已导出的表：%s\n\n' "$C_DIM" "$C_RST" >&2
    printf '   0) 所有表（共 %d 个）\n' "${#ds[@]}" >&2
    for i in "${!ds[@]}"; do
        printf '  %2d) %s\n' "$((i + 1))" "$(basename "${ds[$i]}")" >&2
    done

    printf '\n请选择查找范围（直接回车 = 全部）: ' >&2
    read -r sel
    [ -z "$sel" ] && sel=0

    printf '%s' "$sel" | grep -qE '^[0-9]+$' || return 1
    [ "$sel" -eq 0 ] && { printf '%s\n' "${ds[@]}"; return 0; }
    [ "$sel" -ge 1 ] && [ "$sel" -le ${#ds[@]} ] \
        && { printf '%s\n' "${ds[$((sel - 1))]}"; return 0; }

    return 1
}

do_search_device() {
    local name="$1"
    local files="${2:-}"
    [ -z "$files" ] && files="$(dsl_files)"
    [ -z "$files" ] && die "没有可搜索的 .dsl 文件，请先导出（例如 '$SCRIPT_NAME dsdt'）"

    # 支持两种输入：
    #   短名    PCI0
    #   全路径  \_SB.PCI0  或  _SB.PCI0
    local short
    short="$(printf '%s' "$name" | sed 's/.*[.\\]//; s/.*_//')"
    [ -z "$short" ] && short="$name"

    local nf scope
    nf=$(printf '%s\n' $files | grep -c . || true)
    if [ "${nf:-0}" -le 1 ]; then
        scope="$(basename $files)"
    else
        scope="全部 $nf 个表"
    fi

    printf '%s查找设备: %s%s  %s(范围: %s)%s\n' \
        "$C_BLU" "$name" "$C_RST" "$C_DIM" "$scope" "$C_RST"

    local esc_def
    esc_def="$(printf '%s' "$short" | sed 's/[].[^$\\*\/+?(){}|]/\\&/g')"

    # A. 定义与引用（Device / Scope / Name / Method / External）
    local defs
    defs=$(grep -niE \
        "(Device|Scope|Name|Method|External)[[:space:]]*\([[:space:]]*\\\\?${esc_def}([^A-Za-z0-9_]|$)" \
        $files 2>/dev/null || true)

    # B. 若输入是完整路径，再全文搜一次该路径（ASL 里是嵌套结构，路径只出现在引用处）
    local refs=""
    local path
    path="$(printf '%s' "$name" | sed 's/^\\\\*//')"
    if [ "$path" != "$short" ]; then
        refs=$(grep -niF -- "$path" $files 2>/dev/null || true)
    fi

    if [ -z "$defs" ] && [ -z "$refs" ]; then
        warn "未找到设备 '$name'。"
        warn "提示：ACPI 设备名通常是 4 个字符（如 PCI0、LPCB、BAT0）；"
        warn "      也可以输完整路径（如 \\_SB.PCI0），或用 -k 搜关键字确认拼写。"
        return 6
    fi

    local total=0 cnt
    if [ -n "$defs" ]; then
        printf '%s【定义】Device / Scope / Name / Method / External%s\n' "$C_DIM" "$C_RST"
        printf '%s\n' "$defs"
        cnt=$(printf '%s\n' "$defs" | grep -c . || true)
        total=$((total + cnt))
    fi

    if [ -n "$refs" ]; then
        printf '\n%s【引用】包含路径 %s 的位置%s\n' "$C_DIM" "$path" "$C_RST"
        printf '%s\n' "$refs"
        cnt=$(printf '%s\n' "$refs" | grep -c . || true)
        total=$((total + cnt))
    fi

    printf '\n%s共 %s 处匹配%s\n' "$C_DIM" "$total" "$C_RST"
    return 0
}

do_search_keyword() {
    local kw="$1"
    local files="${2:-}"
    [ -z "$files" ] && files="$(dsl_files)"
    [ -z "$files" ] && die "没有可搜索的 .dsl 文件，请先导出（例如 '$SCRIPT_NAME dsdt'）"

    local nf scope
    nf=$(printf '%s\n' $files | grep -c . || true)
    if [ "${nf:-0}" -le 1 ]; then
        scope="$(basename $files)"
    else
        scope="全部 $nf 个表"
    fi

    printf '%s关键字查找: %s%s  %s(范围: %s)%s\n' \
        "$C_BLU" "$kw" "$C_RST" "$C_DIM" "$scope" "$C_RST"
    printf '%s显示前后各 2 行上下文，忽略大小写%s\n\n' "$C_DIM" "$C_RST"

    local out
    out=$(grep -n -A2 -B2 -i -- "$kw" $files 2>/dev/null || true)

    if [ -z "$out" ]; then
        warn "未找到关键字 '$kw'。"
        return 6
    fi

    printf '%s\n' "$out"

    # 用 -o 统计出现次数（含上下文行难以区分匹配行与上下文行，-o 最准）
    local cnt
    cnt=$(grep -o -i -- "$kw" $files 2>/dev/null | wc -l | tr -d ' ')
    printf '\n%s共 %s 处匹配%s\n' "$C_DIM" "$cnt" "$C_RST"
}

# ---------------------------------------------------------------------------
# 帮助
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
${SCRIPT_NAME} v${VERSION} - ACPI 表导出 / 反编译 / 查找

用法:
  ${SCRIPT_NAME}                            交互菜单（推荐，无参数直接运行）
  ${SCRIPT_NAME} <表名|list|all> [选项]      命令行模式

常用:
  ${SCRIPT_NAME} list                列出当前机器上的 ACPI 表
  ${SCRIPT_NAME} dsdt                导出并反编译 DSDT
  ${SCRIPT_NAME} ssdt                导出并反编译所有 SSDT
  ${SCRIPT_NAME} facp                导出任意表（用表签名，大小写均可）
  ${SCRIPT_NAME} all                 导出全部表
  ${SCRIPT_NAME} dsdt -d PCI0        查找设备 PCI0
  ${SCRIPT_NAME} dsdt -k Thermal     关键字查找（带上下文）
  ${SCRIPT_NAME} -l                  等价于 list

选项:
  -d, --device <NAME>   查找设备名（Device/Scope/Name/Method 定义与引用）
  -k, --keyword <TEXT>  查找关键字（不区分大小写，带前后 2 行）
  -o, --outdir <DIR>    输出目录，默认 ./acpi_out
      --no-color        关闭彩色
  -h, --help            显示本帮助
  -V, --version         显示版本

说明:
  - acpidump 需要 root，非 root 运行时会自动通过 sudo 提权
  - 缺少 acpica-tools 时会自动检测包管理器并安装
  - 无网络时直接报"网络故障"，不会让包管理器抛一堆看不懂的错误
  - 输出: <outdir>/<表名>.dat（二进制） + <表名>.dsl（ASL 源码）

示例:
  ${SCRIPT_NAME} dsdt -o ~/acpi -d \\_SB.PCI0
  ${SCRIPT_NAME} ssdt -k "PowerResource"
  ${SCRIPT_NAME} all -o /tmp/acpi && grep -rn "Method (_STA" /tmp/acpi/*.dsl
EOF
}

# ---------------------------------------------------------------------------
# 交互菜单（无参数运行时进入）
# ---------------------------------------------------------------------------

pause_key() {
    [ -t 0 ] || return 0
    printf '\n%s按回车回到菜单...%s' "$C_DIM" "$C_RST"
    read -r _ || true
}

report_result() {
    case "$1" in
        0) ok "完成" ;;
        4) err "没有导出任何表（该表可能不存在）" ;;
        5) err "反编译失败" ;;
        6) warn "没有匹配结果" ;;
        *) err "操作失败（退出码 $1）" ;;
    esac
}

interactive_menu() {
    local choice input rc n_dsl n_dat i must line scope
    local -a tables

    while true; do
        n_dsl=$(dsl_files 2>/dev/null | wc -l | tr -d ' ')
        n_dat=$(find "$OUTDIR" -maxdepth 1 -name '*.dat' 2>/dev/null | wc -l | tr -d ' ')

        # 真终端里清屏重绘，管道/重定向时不清（保留完整日志）
        [ -t 1 ] && clear

        printf '\n'
        printf '%s=========================================================%s\n' "$C_BLU" "$C_RST"
        printf '  %sACPI 表工具 v%s%s\n' "$C_GRN" "$VERSION" "$C_RST"
        printf '  输出目录: %s\n' "$(cd "$OUTDIR" 2>/dev/null && pwd || echo "$OUTDIR")"
        printf '  已导出:   %s 个 .dat，%s 个 .dsl\n' "${n_dat:-0}" "${n_dsl:-0}"
        printf '%s=========================================================%s\n' "$C_BLU" "$C_RST"
        printf '\n'
        printf '   1) 列出所有 ACPI 表\n'
        printf '   2) 导出 DSDT\n'
        printf '   3) 导出所有 SSDT\n'
        printf '   4) 导出指定表（列出本机所有表，按数字选）\n'
        printf '   5) 导出全部表\n'
        printf '   6) 查找设备名（可选全部或单个表）\n'
        printf '   7) 查找关键字（可选全部或单个表）\n'
        printf '   8) 帮助\n'
        printf '   0) 退出\n'
        printf '\n'
        printf '%s请选择 [0-8]:%s ' "$C_GRN" "$C_RST"

        if ! read -r choice; then
            printf '\n'
            break
        fi

        case "$choice" in
            1)
                printf '\n'
                ( do_list )
                pause_key
                ;;
            2)
                printf '\n'
                ( do_dump dsdt ); rc=$?
                report_result "$rc"
                pause_key
                ;;
            3)
                printf '\n'
                ( do_dump ssdt ); rc=$?
                report_result "$rc"
                pause_key
                ;;
            4)
                printf '\n'
                tables=()
                while IFS= read -r line; do
                    [ -n "$line" ] && tables+=("$line")
                done < <(list_tables)

                if [ ${#tables[@]} -eq 0 ]; then
                    err "读不到任何 ACPI 表。可能的原因："
                    err "  · 这台机器用 Device Tree 启动，根本没有 ACPI（RK3588 等 ARM 开发板常见）"
                    err "  · 权限不足（读 $SYSFS_DIR 需要 root）"
                    err "  · 内核未启用 ACPI 支持"
                    err ""
                    err "可以先确认: ls $SYSFS_DIR/"
                    pause_key
                    continue
                fi

                printf '当前机器可用的 ACPI 表：\n\n'
                for i in "${!tables[@]}"; do
                    printf '  %2d) %s\n' "$((i + 1))" "${tables[$i]}"
                done

                # 常见表缺失提醒
                for must in DSDT SSDT FACP; do
                    if ! printf '%s\n' "${tables[@]}" | grep -qx "$must"; then
                        warn "注意：这台机器上没有 $must 表"
                    fi
                done

                printf '\n请输入序号导出（0 取消）: '
                read -r input

                if [ -z "$input" ] || [ "$input" = "0" ]; then
                    pause_key
                    continue
                fi

                if ! printf '%s' "$input" | grep -qE '^[0-9]+$'; then
                    warn "请输入数字序号"
                    pause_key
                    continue
                fi

                if [ "$input" -lt 1 ] || [ "$input" -gt ${#tables[@]} ]; then
                    warn "序号超出范围（1-${#tables[@]}）"
                    pause_key
                    continue
                fi

                printf '\n'
                ( do_dump "${tables[$((input - 1))]}" ); rc=$?
                report_result "$rc"
                pause_key
                ;;
            5)
                printf '\n'
                ( do_dump ALL ); rc=$?
                report_result "$rc"
                pause_key
                ;;
            6)
                if [ -z "$(dsl_files)" ]; then
                    warn "还没有反编译好的表，请先执行 2) 导出 DSDT 或 3) 导出 SSDT"
                    pause_key
                    continue
                fi
                printf '\n'
                if ! scope="$(pick_dsl_scope)"; then
                    warn "无效的序号，已取消"
                    pause_key
                    continue
                fi
                printf '\n请输入设备名（4 字符如 PCI0，或全路径 \\_SB.PCI0）: '
                read -r input
                if [ -z "$input" ]; then
                    warn "输入为空，已取消"
                    pause_key
                    continue
                fi
                printf '\n'
                ( do_search_device "$input" "$scope" ); rc=$?
                report_result "$rc"
                pause_key
                ;;
            7)
                if [ -z "$(dsl_files)" ]; then
                    warn "还没有反编译好的表，请先执行 2) 导出 DSDT 或 3) 导出 SSDT"
                    pause_key
                    continue
                fi
                printf '\n'
                if ! scope="$(pick_dsl_scope)"; then
                    warn "无效的序号，已取消"
                    pause_key
                    continue
                fi
                printf '\n请输入关键字（如 ThermalZone、_STA、PowerResource）: '
                read -r input
                if [ -z "$input" ]; then
                    warn "输入为空，已取消"
                    pause_key
                    continue
                fi
                printf '\n'
                ( do_search_keyword "$input" "$scope" ); rc=$?
                report_result "$rc"
                pause_key
                ;;
            8|h|H)
                printf '\n'
                usage
                pause_key
                ;;
            0|q|Q)
                printf '\n%s再见。%s\n' "$C_DIM" "$C_RST"
                break
                ;;
            *)
                warn "无效的序号: '$choice'（输入 0-8）"
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
    local action=""

    # 无参数且是交互终端 → 进菜单；无参数但不是终端（管道/重定向）→ 显示帮助
    # ACPI_FORCE_MENU=1 可强制进菜单，便于自动化测试
    if [ $# -eq 0 ]; then
        if [ -t 0 ] || [ "${ACPI_FORCE_MENU:-0}" = "1" ]; then
            ensure_tools
            require_root "$@"
            interactive_menu
        else
            usage
        fi
        exit 0
    fi

    local kw_device="" kw_text=""

    while [ $# -gt 0 ]; do
        case "$1" in
            -d|--device)   [ $# -ge 2 ] || die "$1 需要一个参数"; kw_device="$2"; shift 2 ;;
            -k|--keyword)  [ $# -ge 2 ] || die "$1 需要一个参数"; kw_text="$2";  shift 2 ;;
            -o|--outdir)   [ $# -ge 2 ] || die "$1 需要一个参数"; OUTDIR="$2";    shift 2 ;;
            --no-color)    USE_COLOR="never"; shift ;;
            -l)            action="list"; shift ;;
            -h|--help)     usage; exit 0 ;;
            -V|--version)  echo "$SCRIPT_NAME $VERSION"; exit 0 ;;
            -*)            die "未知选项: $1（用 -h 查看帮助）" ;;
            *)             action="$1"; shift ;;
        esac
    done

    [ -n "$action" ] || { usage; exit 1; }

    # 关闭颜色时重建变量
    if [ "$USE_COLOR" = "never" ]; then
        C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_RST=""
    elif [ -t 1 ]; then
        C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
        C_BLU=$'\033[34m'; C_DIM=$'\033[2m';  C_RST=$'\033[0m'
    fi

    case "$action" in
        list|ls) do_list; exit 0 ;;
    esac

    # 以下动作需要 acpica-tools
    ensure_tools
    require_root "$@"

    local rc=0

    case "$action" in
        all|ALL)
            do_dump ALL
            ;;
        *)
            # 如果只做查找，且还没有导出过，先导出 DSDT
            if [ -n "$kw_device" ] || [ -n "$kw_text" ]; then
                ensure_decompiled "$action"
            else
                do_dump "$action"
            fi

            if [ -n "$kw_device" ]; then
                do_search_device "$kw_device" || rc=$?
            fi
            if [ -n "$kw_text" ]; then
                do_search_keyword "$kw_text" || rc=$?
            fi
            ;;
    esac

    printf '\n%s输出目录: %s%s\n' "$C_DIM" "$(cd "$OUTDIR" 2>/dev/null && pwd || echo "$OUTDIR")" "$C_RST"

    # 把查找无匹配的退出码传出去，方便在脚本里判断
    exit "$rc"
}

main "$@"
