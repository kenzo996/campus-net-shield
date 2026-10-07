#!/bin/sh
# ============================================================================
#  campus-net-shield  ·  install.sh  v1.6.0
#  OpenWrt 校园网「多终端检测」绕过 + eportal 自动登录 一键装机脚本
# ----------------------------------------------------------------------------
#  ⚠ 风险声明（务必先读）
#    本脚本通过统一 TTL / User-Agent / NTP 特征，让校园网网关无法区分
#    路由器后面的多台设备。该行为可能违反你与学校 / 运营商之间的网络接入
#    协议。由此导致的账号封禁、限速、断网或校纪处分，由使用者自行承担。
#    请仅在你自己拥有合法使用权的账号与网络上使用。
#
#  ⚠ 性能代价
#    为保证 UA2F 能抓到明文 HTTP 包，本脚本会关闭路由器的 NAT 流量卸载
#    (flow offloading)，转发性能会下降。宽带跑满千兆的设备会明显感知。
#
#  在 OpenWrt 路由器上以 root 执行：
#     wget -O /tmp/cns.sh https://raw.githubusercontent.com/<用户名>/<仓库>/main/install.sh
#     sh /tmp/cns.sh
#
#  如果 raw.githubusercontent.com 被重置（wget 报 "Unable to establish SSL
#  connection"），换加速通道拉取，任选一条：
#     wget -O /tmp/cns.sh https://gh-proxy.com/https://raw.githubusercontent.com/<用户名>/<仓库>/main/install.sh
#     wget -O /tmp/cns.sh https://ghproxy.net/https://raw.githubusercontent.com/<用户名>/<仓库>/main/install.sh
#     wget -O /tmp/cns.sh https://cdn.jsdelivr.net/gh/<用户名>/<仓库>@main/install.sh
# ============================================================================

set -u

SCRIPT_VER="1.6.0"

CONF_FILE="/etc/campus-net.conf"
AUTH_BIN="/usr/bin/campus-auth"
INIT_SCRIPT="/etc/init.d/campus-auth"
NFT_DIR="/etc/nftables.d"
NFT_TTL_FILE="$NFT_DIR/12-campus-ttl.nft"
NFT_NTP_FILE="$NFT_DIR/13-campus-ntp.nft"
FW_USER="/etc/firewall.user"
UA2F_REPO="Zxilly/UA2F"
MMTLS_SH="/etc/campus-mmtls.sh"
MMTLS_INIT="/etc/init.d/campus-mmtls"
CRON_FILE="/etc/crontabs/root"
TMP_DIR="/tmp/campus-net-shield.$$"
MACSH_FILE="/etc/campus-mac.sh"

# ---------------------------------------------------------------- 输出工具 --
if [ -t 1 ]; then
    C_R='\033[1;31m'; C_G='\033[1;32m'; C_Y='\033[1;33m'; C_B='\033[1;36m'; C_N='\033[0m'
else
    C_R=''; C_G=''; C_Y=''; C_B=''; C_N=''
fi
info() { printf '%b[*]%b %s\n' "$C_B" "$C_N" "$*"; }
ok()   { printf '%b[+]%b %s\n' "$C_G" "$C_N" "$*"; }
warn() { printf '%b[!]%b %s\n' "$C_Y" "$C_N" "$*"; }
err()  { printf '%b[x]%b %s\n' "$C_R" "$C_N" "$*" >&2; }
die()  { err "$*"; cleanup_tmp; exit 1; }
step() { printf '\n%b==>%b %s\n' "$C_B" "$C_N" "$*"; }

cleanup_tmp() { [ -n "${TMP_DIR:-}" ] && rm -rf "$TMP_DIR" 2>/dev/null; }
trap 'cleanup_tmp' EXIT INT TERM

# ---------------------------------------------------------------- 交互工具 --
TTY=/dev/tty
have_tty() { [ -r "$TTY" ] && [ -w "$TTY" ]; }

ask() {
    # ask "提示" "默认值"  ->  结果输出到 stdout
    _p="$1"; _d="${2:-}"; _v=""
    if have_tty; then
        if [ -n "$_d" ]; then
            printf '%s %b[%s]%b: ' "$_p" "$C_Y" "$_d" "$C_N" >"$TTY"
        else
            printf '%s: ' "$_p" >"$TTY"
        fi
        IFS= read -r _v <"$TTY" || _v=""
    fi
    [ -n "$_v" ] || _v="$_d"
    printf '%s' "$_v"
}

ask_secret() {
    # ask_secret "提示"  ->  静默输入，结果输出到 stdout
    _p="$1"; _v=""
    if have_tty; then
        printf '%s: ' "$_p" >"$TTY"
        stty -echo <"$TTY" 2>/dev/null
        IFS= read -r _v <"$TTY" || _v=""
        stty echo <"$TTY" 2>/dev/null
        printf '\n' >"$TTY"
    fi
    printf '%s' "$_v"
}

ask_choice() {
    # ask_choice "提示" "默认" "选项1|选项2|..."  ->  结果输出到 stdout
    _p="$1"; _d="$2"; _opts="$3"
    while :; do
        _v="$(ask "$_p  ($_opts)" "$_d")"
        case "$_v" in
            cmcc|unicom|telecom|none) printf '%s' "$_v"; return 0 ;;
            *) warn "只能填：$_opts"; have_tty || { printf '%s' "$_d"; return 0; } ;;
        esac
    done
}

confirm() {
    _p="$1"; _d="${2:-y}"
    _a="$(ask "$_p (y/n)" "$_d")"
    case "$_a" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# ------------------------------------------------------------ 环境探测 ----
step "环境探测"

[ "$(id -u)" = "0" ] || die "请以 root 身份运行（ssh root@<路由器IP>）"
[ -f /etc/openwrt_release ] || die "未检测到 OpenWrt（缺少 /etc/openwrt_release），本脚本仅支持 OpenWrt"

# shellcheck disable=SC1091
. /etc/openwrt_release
OWRT_VER="${DISTRIB_RELEASE:-unknown}"
OWRT_ARCH="${DISTRIB_ARCH:-}"
OWRT_TARGET="${DISTRIB_TARGET:-unknown}"
OWRT_DESC="${DISTRIB_DESCRIPTION:-OpenWrt}"

if command -v opkg >/dev/null 2>&1; then
    PKG_MGR="opkg"
elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
else
    die "系统里既没有 opkg 也没有 apk，无法安装依赖"
fi

if command -v fw4 >/dev/null 2>&1; then
    FW_STACK="fw4"
elif command -v fw3 >/dev/null 2>&1; then
    FW_STACK="fw3"
else
    FW_STACK="unknown"
fi

detect_wan_if() {
    _i=""
    _i=$(ip route show default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n1)
    [ -n "$_i" ] || _i=$(uci -q get network.wan.device 2>/dev/null || true)
    [ -n "$_i" ] || _i=$(uci -q get network.wan.ifname 2>/dev/null || true)
    [ -n "$_i" ] || _i="wan"
    printf '%s' "$_i"
}

# 探测内网接口（NTP 劫持要按实际名字写，不能硬编码 br-lan）
# 返回空格分隔的接口列表；探测不到就退回 br-lan
detect_lan_ifs() {
    _list=""
    for _n in $(uci -q get network.lan.device 2>/dev/null || true) \
              $(uci -q get network.lan.ifname 2>/dev/null || true); do
        # uci 里可能是 "br-lan eth1" 这种列表，逐个取
        for _x in $_n; do
            case " $_list " in *" $_x "*) ;; *) _list="$_list $_x" ;; esac
        done
    done
    # 兜底：扫一遍网络命名空间里的网桥设备。
    # ⚠ 只认「真的承载了内网地址」的网桥 —— 否则会把 WAN 侧的上行网桥
    #   （部分固件把 WAN 也桥接，如 br-wan）一起当成内网接口写进 NTP 规则，
    #   结果是内网 NTP 劫持没做全、反而劫持了 WAN 进来的 NTP。
    #   判定方法：网桥自身有私网 IPv4 地址，且不是 WAN 口。
    if [ -z "$_list" ]; then
        _wan="$(detect_wan_if)"
        for _d in $(ls /sys/class/net 2>/dev/null); do
            [ "$_d" = "$_wan" ] && continue
            [ "$_d" = "lo" ] && continue
            [ -d "/sys/class/net/$_d/bridge" ] || continue
            # 该网桥必须持有 10/8、172.16/12、192.168/16 任一网段的地址
            if ip -4 addr show dev "$_d" 2>/dev/null \
               | grep -qE 'inet (10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)'; then
                _list="$_list $_d"
            fi
        done
    fi
    [ -n "$_list" ] || _list=" br-lan"
    printf '%s' "$_list"
}

WAN_IF_DETECTED="$(detect_wan_if)"
LAN_IF_LIST="$(detect_lan_ifs)"

case "${DISTRIB_ID:-OpenWrt}" in
    OpenWrt) FW_VENDOR="OpenWrt 官方" ;;
    *)       FW_VENDOR="${DISTRIB_ID}（第三方固件，依赖与内核模块来自其自建源）" ;;
esac
KERNEL_VER="$(uname -r 2>/dev/null || echo unknown)"

info "固件      : $OWRT_DESC"
info "固件来源  : $FW_VENDOR"
info "版本      : $OWRT_VER"
info "内核      : $KERNEL_VER"
info "架构      : ${OWRT_ARCH:-未知}"
info "目标平台  : $OWRT_TARGET"
info "包管理器  : $PKG_MGR"
info "防火墙栈  : $FW_STACK"
info "WAN 接口  : $WAN_IF_DETECTED"
info "LAN 接口  :$LAN_IF_LIST"

if [ -z "$OWRT_ARCH" ]; then
    warn "读不到 DISTRIB_ARCH，UA2F 二进制可能无法自动匹配"
fi

# 联网自检
if command -v curl >/dev/null 2>&1; then
    if curl -s -m 6 -o /dev/null http://connect.rom.miui.com/generate_204 2>/dev/null; then
        ok "外网连通正常"
    else
        warn "外网似乎不通。若路由器尚未认证上网，请先手动认证一次再继续"
    fi
fi

# ------------------------------------------------------------ 收集配置 ----
step "配置采集"

printf '%s\n' "下面填校园网认证信息。账号密码来自登录页 F12 抓到的 eportal 请求。"
printf '%s\n' "对应关系：user_account=%2C0%2C<账号>%40<运营商>"

PORTAL_DEF="192.168.241.1:801"
PORTAL="$(ask '认证服务器地址（IP:端口）' "$PORTAL_DEF")"
# 归一化：去掉协议头、路径、空白，只留 host:port
PORTAL="$(printf '%s' "$PORTAL" | sed 's#^https\?://##; s#/.*##' | tr -d '[:space:]')"
# 拆分 host / port（校园网 portal 均为 IPv4，不处理 IPv6 字面量）
case "$PORTAL" in
    *:*) PORTAL_HOST="${PORTAL%%:*}"; PORTAL_PORT="${PORTAL##*:}" ;;
    *)   PORTAL_HOST="$PORTAL";        PORTAL_PORT="801" ;;
esac
[ -n "$PORTAL_HOST" ] || die "认证服务器地址不能为空"
case "$PORTAL_PORT" in ''|*[!0-9]*) die "端口不合法：$PORTAL_PORT" ;; esac

USERNAME="$(ask '上网账号（不含 @运营商）' '')"
[ -n "$USERNAME" ] || die "账号不能为空"

ISP_DEF="cmcc"
ISP="$(ask_choice '运营商' "$ISP_DEF" 'cmcc|unicom|telecom|none')"

PASSWORD="$(ask_secret '上网密码')"
[ -n "$PASSWORD" ] || die "密码不能为空"

# WAN 接口：直接回车 = 用探测结果；也可以填 auto 或真实接口名。
# ⚠ 必须把字面量 "auto" 翻译成探测结果。之前直接把提示语里的「填 auto 自动识别」
#   当成了占位说明，用户真填 auto 就会被原样写进 nft 规则：
#       oifname "auto" ip ttl set 128
#   这条规则不会报错、不会被删、自检里「链存在」也照过，但一条包都不匹配 ——
#   TTL 完全没归一，属于最难查的假成功。
_wan_in="$(ask 'WAN 接口名（回车=自动识别，也可直接填接口名）' "$WAN_IF_DETECTED")"
case "$_wan_in" in
    ''|auto|AUTO|Auto) WAN_IF="$WAN_IF_DETECTED" ;;
    *)                  WAN_IF="$_wan_in" ;;
esac
# 再兜一层：接口不存在就退回探测值
if [ -n "$WAN_IF" ] && [ ! -e "/sys/class/net/$WAN_IF" ]; then
    case "$WAN_IF" in
        *.*) ;;   # VLAN 子接口（如 wan.10）不一定有 sysfs 目录，放过
        *)
            warn "接口 '$WAN_IF' 不存在，改用自动探测结果：$WAN_IF_DETECTED"
            WAN_IF="$WAN_IF_DETECTED" ;;
    esac
fi
[ -n "$WAN_IF" ] || die "无法确定 WAN 接口名，请手动指定"

PROBE_URL="$(ask '保活探测地址' 'http://connect.rom.miui.com/generate_204')"
UA_DEF='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36'
USER_AGENT="$(ask '统一后的 User-Agent' "$UA_DEF")"

TTL_SET="$(ask '统一 TTL 值（128=Windows / 64=Linux）' '128')"
case "$TTL_SET" in ''|*[!0-9]*) TTL_SET=128 ;; esac

# ---- MAC 克隆 ----
# 说明（务必理解，别抱错期望）：
#   网关在路由器上游，它看到的是 WAN 口那一个 MAC，无论内网挂几台设备，
#   出口 MAC 永远只有一个。所以「克隆 MAC」不会让 2 台设备变成 1 台。
#   真正起作用的是 TTL 归一 + 关 IPv6（本脚本都做了）。
#   但克隆本身无害，且某些按「首次认证的 MAC」绑定会话的网关需要它保持稳定，
#   因此保留这个选项，默认关闭。
printf '\n'
printf '%s\n' "MAC 克隆（选填）。"
printf '%s\n' "  注意：网关在内网协议栈之外，克隆 MAC 无法把多台设备伪装成一台，"
printf '%s\n' "  真正起作用的是 TTL 归一。此选项仅为保持出口 MAC 稳定，可选。"
ENABLE_MAC="n"
MAC_CLONE=""
if confirm '是否克隆 WAN 口 MAC？' 'n'; then
    MAC_CLONE="$(ask '要克隆的 MAC（格式 aa:bb:cc:dd:ee:ff）' '')"
    # 归一化：转小写、去掉冒号/连字符/点/空白，只留十六进制字符。
    # ⚠ 不能写成 `tr -d '[:space:]-'`：busybox 的 tr 会把末尾的 `-`
    #   当成范围符号解析，行为不可预期（实测会把冒号删不干净，导致合法 MAC 被判非法）。
    #   拆成两步最稳。
    MAC_CLONE="$(printf '%s' "$MAC_CLONE" | tr 'A-Z' 'a-z' | tr -d ' ' | tr -d '\t' | tr -d ':' | tr -d '-' | tr -d '.')"
    # 校验：12 位十六进制
    if printf '%s' "$MAC_CLONE" | grep -qE '^[0-9a-f]{12}$'; then
        # 重新格式化成 aa:bb:cc:dd:ee:ff
        MAC_CLONE="$(printf '%s' "$MAC_CLONE" \
            | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1:\2:\3:\4:\5:\6/')"
        ENABLE_MAC="y"
    else
        warn "MAC 格式不合法（'$MAC_CLONE'），已跳过 MAC 克隆"
        MAC_CLONE=""
    fi
fi

# ---- 定时重启 / 自动保活：默认全部关闭 ----
# 用户要求：这两项默认关闭，需要时手动改配置 / 手动执行命令。
ENABLE_NTP="y"
confirm '是否启用 NTP 请求劫持（推荐）' 'y' || ENABLE_NTP="n"

ENABLE_AUTOSTART="n"
printf '\n'
printf '%s\n' "开机自启："
printf '%s\n' "  开启后，路由器重启会自动拉起认证保活进程（推荐，但默认关闭）。"
printf '%s\n' "  关闭时也会写入脚本和配置，需要时手动执行即可。"
confirm '是否启用「认证保活」开机自启？' 'n' && ENABLE_AUTOSTART="y"

ENABLE_REBOOT="n"
printf '\n'
printf '%s\n' "定时重启："
printf '%s\n' "  每天凌晨 3 点自动重启路由器（部分校园网靠这个重置会话）。默认关闭。"
confirm '是否启用「每天凌晨 3 点自动重启」？' 'n' && ENABLE_REBOOT="y"

printf '\n'
info "认证服务器 : $PORTAL_HOST:$PORTAL_PORT"
info "账号       : $USERNAME@$ISP"
info "WAN 接口   : $WAN_IF"
info "统一 TTL   : $TTL_SET"
info "NTP 劫持   : $ENABLE_NTP"
info "MAC 克隆   : ${ENABLE_MAC}${MAC_CLONE:+ ($MAC_CLONE)}"
info "开机自启   : $ENABLE_AUTOSTART"
info "凌晨重启   : $ENABLE_REBOOT"
printf '\n'
confirm '确认按以上配置安装？' 'y' || die "已取消"

mkdir -p "$TMP_DIR" || die "无法创建临时目录"

# ------------------------------------------------------------ 依赖准备 ----
step "准备依赖"

pkg_install() {
    if [ "$PKG_MGR" = "opkg" ]; then
        opkg install "$@" >/dev/null 2>&1
    else
        apk add "$@" >/dev/null 2>&1
    fi
}

if ! command -v curl >/dev/null 2>&1; then
    info "安装 curl ..."
    pkg_install curl || warn "curl 安装失败，请手动执行：$PKG_MGR update && $PKG_MGR install curl"
fi
command -v curl >/dev/null 2>&1 || die "缺少 curl，认证与保活无法工作"

# ------------------------------------------------------------ 安装 UA2F ---
step "安装 UA2F（统一 User-Agent）"

ua2f_asset_for() {
    # $1=OpenWrt 版本  $2=DISTRIB_ARCH  ->  release 资源文件名
    case "$1" in
        23.05*) _base="23.05.5"; _rev="4.10.2-1" ;;
        24.10*) _base="24.10.0"; _rev="4.10.2-r1" ;;
        *) return 1 ;;
    esac
    printf 'ua2f_%s_%s-%s.ipk' "$_rev" "$2" "$_base"
}

# GitHub 在国内经常被连接重置（表现为 wget 报 "Unable to establish SSL connection"）。
# 这里准备一组加速通道，按顺序轮试；任一通道成功即停。
# 可用 CNS_GH_MIRROR 指定自己的前缀（会排在最前面试）：
#     CNS_GH_MIRROR=https://ghfast.top/ sh install.sh
GH_MIRROR_LIST="https://gh-proxy.com/ https://ghproxy.net/ https://ghfast.top/"

# $1=原始 https://... 地址 -> 输出所有候选（自定义前缀 > 直连 > 内置通道），空格分隔
gh_candidates() {
    if [ -n "${CNS_GH_MIRROR:-}" ]; then
        printf '%s ' "${CNS_GH_MIRROR}${1}"
    fi
    printf '%s ' "$1"
    for _m in $GH_MIRROR_LIST; do
        printf '%s ' "${_m}${1}"
    done
    printf '\n'
}

# $1=原始地址  $2=输出文件；任一通道成功返回 0
gh_download() {
    for _u in $(gh_candidates "$1"); do
        if curl -fL -k --connect-timeout 12 -m 180 -o "$2" "$_u" 2>/dev/null \
           && [ -s "$2" ]; then
            _via="${_u%"$1"}"
            [ -n "$_via" ] && info "下载通道: $_via"
            return 0
        fi
    done
    return 1
}

# $1=API 地址 -> 打印 JSON 正文（同样走通道轮试）
gh_api_json() {
    for _u in $(gh_candidates "$1"); do
        _j=$(curl -fsL -k --connect-timeout 12 -m 60 "$_u" 2>/dev/null)
        if [ -n "$_j" ]; then printf '%s' "$_j"; return 0; fi
    done
    return 1
}

ua2f_download() {
    # $1=asset 名  $2=输出路径
    _asset="$1"; _out="$2"
    if gh_download "https://github.com/${UA2F_REPO}/releases/latest/download/${_asset}" "$_out"; then
        return 0
    fi
    info "各下载通道均失败，改用 GitHub API 解析真实地址 ..."
    _json="$(gh_api_json "https://api.github.com/repos/${UA2F_REPO}/releases/latest")" || return 1
    _url=$(printf '%s' "$_json" | grep -o "https://[^\"]*${_asset}" | head -n1)
    [ -n "$_url" ] || return 1
    gh_download "$_url" "$_out"
}

UA2F_OK=0
UA2F_ASSET=""

# 第一步：优先从固件自身的软件源安装。
# 第三方固件（Kwrt / ImmortalWrt / LEDE 等）自带自建源，若源里已有 ua2f，
# 其依赖与内核模块版本天然匹配，比用官方 ipk 可靠得多。
if [ "$PKG_MGR" = "opkg" ]; then
    info "更新软件源索引（可能较慢）..."
    opkg update >/dev/null 2>&1 || warn "opkg update 失败，第三方固件请确认自建源可用"
    info "尝试从固件源安装 ua2f ..."
    if opkg install ua2f >/dev/null 2>&1; then
        UA2F_OK=1
        ok "UA2F 已从固件软件源安装（依赖自动匹配，这是最稳的路径）"
        # 可选：源里若带 LuCI 界面则一并装上。默认不装，设 CNS_WITH_LUCI=1 开启。
        if [ "${CNS_WITH_LUCI:-0}" = "1" ] && opkg install luci-app-ua2f >/dev/null 2>&1; then
            ok "已附带安装 luci-app-ua2f（可在「服务 → UA2F」查看运行状态）"
        fi
    else
        info "固件源里没有 ua2f，改为下载官方 ipk"
    fi
fi

# 注意：函数在版本不匹配时不输出任何内容，用「输出是否为空」判断
UA2F_ASSET="$(ua2f_asset_for "$OWRT_VER" "$OWRT_ARCH" 2>/dev/null)"

if [ "$UA2F_OK" != "1" ] && [ -n "$UA2F_ASSET" ]; then
    info "下载 $UA2F_ASSET ..."
    if ua2f_download "$UA2F_ASSET" "/tmp/ua2f.ipk"; then
        ok "下载完成"

        if [ "$PKG_MGR" = "opkg" ]; then
            # 依赖清单取自 UA2F 的 OpenWrt 包定义。
            # 关键点：mips / mipsel 平台额外需要 libatomic，缺它必然装不上。
            UA2F_DEPS="libnetfilter-queue libnetfilter-conntrack kmod-nfnetlink-queue libpthread libuci ip-full"
            case "$OWRT_ARCH" in
                # libatomic 是官方包的依赖名；第三方固件（如 Kwrt）里叫 libatomic1。
                # 两个都试，装不上的那个会被忽略，不影响后续流程。
                *mips*) UA2F_DEPS="$UA2F_DEPS libatomic libatomic1" ;;
            esac
            if [ "$FW_STACK" = "fw4" ]; then
                UA2F_DEPS="$UA2F_DEPS kmod-nft-queue"
            else
                UA2F_DEPS="$UA2F_DEPS iptables-mod-nfqueue iptables-mod-filter iptables-mod-conntrack-extra"
            fi

            info "补齐 UA2F 依赖（逐个安装，源里没有的自动跳过）..."
            for _d in $UA2F_DEPS; do
                opkg install "$_d" >/dev/null 2>&1 || true
            done

            if opkg install /tmp/ua2f.ipk >/dev/null 2>&1; then
                UA2F_OK=1
                ok "UA2F 安装成功"
            else
                warn "常规安装失败，改用 --force-depends 强制安装 ..."
                if opkg install --force-depends /tmp/ua2f.ipk >/dev/null 2>&1; then
                    UA2F_OK=1
                    warn "已强制安装。若 UA2F 启动异常，多半是缺库，请核对上面的依赖清单"
                else
                    warn "UA2F 安装失败"
                fi
            fi
        else
            # OpenWrt 25.12+ 使用 apk，.ipk 不能直装，改为解包提取二进制
            warn "本机使用 apk（OpenWrt 25.12+），改用「解包二进制」方式安装"
            mkdir -p "$TMP_DIR/x" && (cd "$TMP_DIR/x" && tar -xzf /tmp/ua2f.ipk 2>/dev/null)
            if [ -f "$TMP_DIR/x/data.tar.gz" ]; then
                mkdir -p "$TMP_DIR/x/data" && (cd "$TMP_DIR/x/data" && tar -xzf "$TMP_DIR/x/data.tar.gz" 2>/dev/null)
            fi
            if [ -f "$TMP_DIR/x/data/usr/bin/ua2f" ]; then
                pkg_install libnetfilter-queue libmnl libnfnetlink kmod-nfnetlink-queue
                cp "$TMP_DIR/x/data/usr/bin/ua2f" /usr/bin/ua2f
                chmod 755 /usr/bin/ua2f
                if [ -f "$TMP_DIR/x/data/etc/init.d/ua2f" ]; then
                    cp "$TMP_DIR/x/data/etc/init.d/ua2f" /etc/init.d/ua2f
                    chmod 755 /etc/init.d/ua2f
                fi
                if [ -d "$TMP_DIR/x/data/usr/share/ua2f" ]; then
                    mkdir -p /usr/share/ua2f
                    cp -r "$TMP_DIR/x/data/usr/share/ua2f/." /usr/share/ua2f/ 2>/dev/null
                fi
                if [ -d "$TMP_DIR/x/data/etc/config" ] && [ -f "$TMP_DIR/x/data/etc/config/ua2f" ]; then
                    cp "$TMP_DIR/x/data/etc/config/ua2f" /etc/config/ua2f
                fi
                UA2F_OK=1
                ok "UA2F 二进制已就位（apk 兼容模式）"
            else
                warn "解包失败，UA2F 未安装"
            fi
        fi
    else
        warn "从 GitHub 下载失败（可能是网络问题）"
    fi
else
    warn "OpenWrt $OWRT_VER 没有对应的官方 UA2F 包（官方仅提供 23.05 / 24.10 构建）"
fi

if [ "$UA2F_OK" != "1" ]; then
    warn "跳过 UA2F。TTL 归一仍然生效，但明文 HTTP 的 UA 特征不会被抹除"
    warn "补救：把 $UA2F_ASSET 手动下载后 scp 到路由器，再执行 opkg install <文件>"
fi

# 配置 UA2F
if [ "$UA2F_OK" = "1" ]; then
    info "写入 UA2F 配置 ..."
    uci -q set ua2f.enabled.enabled=1 2>/dev/null
    uci -q set ua2f.firewall.handle_fw=1 2>/dev/null
    uci -q set ua2f.firewall.handle_intranet=1 2>/dev/null
    # 443 是加密流量，UA 在里面看不到，处理它纯属浪费 CPU
    uci -q set ua2f.firewall.handle_tls=0 2>/dev/null
    uci -q set ua2f.main.custom_ua="$USER_AGENT" 2>/dev/null
    uci -q commit ua2f 2>/dev/null
    if [ -x /etc/init.d/ua2f ]; then
        /etc/init.d/ua2f enable 2>/dev/null
        /etc/init.d/ua2f restart 2>/dev/null || /etc/init.d/ua2f start 2>/dev/null
    fi
    ok "UA2F 已启用"
fi

# ------------------------------------------------- 放过微信 mmtls ---------
# 为什么必须做这一步：
#   UA2F 的 nftables 规则最后一条是「所有非 22 / 443 的 TCP 全部送入 NFQUEUE」，
#   而微信的 mmtls 长连接**伪装成 80 端口的 HTTP 请求**：
#       POST /mmtls/7ae571b3 HTTP/1.1
#       Host: dns.weixin.qq.com
#       Upgrade: mmtls
#       User-Agent: MicroMessenger Client
#   UA2F 会把它当普通 HTTP 改写 User-Agent，握手随即失败 —— 症状就是
#   「手机微信提示网络连接异常，但其他 App 都正常」。
#
# 上游有 handle_mmtls 选项，但作者在 README 里明确写了：
#   「该规则仅在 iptables NFQUEUE 分支中生效，nftables 分支无效」
# 而 22.03+ 的 OpenWrt / 第三方固件走的就是 fw4+nftables，等于没有这个绕过。
#
# ⚠ 关键（真机 dump 出来的规则链，顺序即执行顺序）：
#     tcp dport 80 ... ct mark set 0x0000002c   <- 先把 80 端口的包无脑打成 connmark 44
#     ct mark 0x0000002b ... return             <- 再来判断「43 就放行」
#     meta l4proto tcp ... queue ... to 10010   <- 剩下的全送进 NFQUEUE
#   也就是说，网上常见的说法「在 PREROUTING 里打 connmark 43 就能绕过」是**错的**：
#   43 会被上面那句 set 0x2c 覆盖掉，包照样进 NFQUEUE，微信照样坏。
#
# 唯一有效的做法：把放行判断插到 UA2F 链条的**最前面**，早于那句 set 0x2c。
# 所以这里必须做两件事，缺一不可：
#   1) iptables mangle PREROUTING：用 xt_string 认出 mmtls，给这条连接打 connmark 43
#   2) nft insert：把 `ct mark 0x2b return` 插到 table inet ua2f 队列链的首位
#
# 代价（明确写清楚，不藏着）：UA2F 不再改写 80 端口明文 HTTP 的 User-Agent。
# 为什么可以接受：
#   1) 全互联网绝大多数流量已经是 443，443 本来就是 UA2F 直接放行的（见上 dump），
#      也就是说「能改写 UA 的流量」本来就只有很小一部分；
#   2) 真正需要统一的那部分反而不在 80 上 —— 而这个方案保住了 TTL 归一；
#   3) 80 端口明文 HTTP 的 UA 差异巨大（同一个人的 Chrome 和微信 UA 都不同），
#      拿它做「多终端」判据本身就不靠谱，网关更看重 TTL / 连接数。
# ---------------------------------------------------------------------------
MMTLS_OK=0

if [ "$UA2F_OK" = "1" ] && [ "${CNS_NO_MMTLS:-0}" != "1" ]; then
    step "放行 80 端口明文 HTTP（否则微信会提示网络连接异常）"

    # 说明：本方案只操作 table inet ua2f，不再依赖 iptables / xt_string，
    # 所以这里不再安装 iptables-mod-filter / iptables-mod-conntrack-extra。

    cat > "$MMTLS_SH" <<'MMTLS_EOF'
#!/bin/sh
# campus-net-shield: 让 UA2F 跳过「明文 HTTP（80 端口）」，避免微信「网络连接异常」。
# 由 install.sh 生成。会被 firewall include / init 脚本 / 计划任务反复调用，
# 所以必须写成幂等的。
#
#   campus-mmtls.sh apply    写入放行规则（默认，无参数时也是它）
#   campus-mmtls.sh remove   清除放行规则
#   campus-mmtls.sh status   打印状态，全部到位时返回 0
#
# 无论成功失败都必须 exit 0：fw4 用 `. path`（source）方式执行 script include，
# 退出码会被 fw4 检查，非零可能让整个防火墙重载报错 —— 那时候连网都上不了。
# 同理这里刻意不用 set -u / set -e，避免污染被 source 进去的那个 shell。
#
# ---------------------------------------------------------------------------
# 为什么从「匹配 /mmtls/ 字符串」改成「放行整个 80 端口」
#
# 真机 dump 证据（`nft -a list table inet ua2f`）：
#     tcp dport 80 ... ct mark set 0x0000002c      counter packets 1086
#     ct mark 0x2b ... return                      counter packets 15   <- 我们插的
#     ct mark 0x2b ... return comment "!ua2f:..."  counter packets 0    <- UA2F 自带
#
# 八十端口的包有一千出头，被打上 connmark 43 的只有 15 个 ——
# 说明 `-m string --string /mmtls/` 在新版微信上几乎匹配不到东西。
# 原因：新版 mmtls 的握手包不再明文携带 `/mmtls/` 字样（改走 TLS 伪装 / 加密载荷），
# 而真正走 443 的那部分流量 UA2F 本来就不碰。
# 结论：靠特征串识别这条路已经失效，继续打补丁只会打不完。
#
# 现在改为「整个 80 端口从 UA2F 队列里放行」，一次解决所有走明文 HTTP 的 App。
#
# 代价（明确写清楚，不藏着）：UA2F 不再改写 80 端口 HTTP 的 User-Agent。
# 为什么可以接受：
#   1) 全互联网绝大多数流量已经是 443，443 本来就是 UA2F 直接放行的（见上 dump），
#      也就是说「能改写 UA 的流量」本来就只有很小一部分；
#   2) 真正需要统一的那部分反而不在 80 上 —— 而这个方案保住了 TTL 归一；
#   3) 80 端口明文 HTTP 的 UA 差异巨大（同一个人的 Chrome 和微信 UA 都不同），
#      拿它做「多终端」判据本身就不靠谱，网关更看重 TTL / 连接数。
# ---------------------------------------------------------------------------

NFT="$(command -v nft 2>/dev/null || true)"

# UA2F 约定的 connmark：「非 HTTP 流，跳过」。43 = 0x2b
UA2F_MARK=0x2b
u2f_table="inet ua2f"

# 找出 ua2f 表里带 queue 的那条链（正常叫 postrouting）
# 注意 nft 渲染出来是 `queue flags bypass to 10010`，没有 num 字样，别按 queue num 匹配
u2f_chain() {
    [ -n "$NFT" ] || return 1
    "$NFT" list table $u2f_table 2>/dev/null \
        | awk '/^[[:space:]]*chain[[:space:]]/{c=$2} /[[:space:]]queue[[:space:]]/{if(c){print c; exit}}'
}

# 删掉所有「我们插进去的」规则，返回删除条数。
# 判据：带 counter + 结尾 return + 不带 comment。
#   - UA2F 自带的规则一定带 comment "!ua2f: ..."，绝不会被误删
#   - 我们插的有两种形态：
#       v1.4.0 及更早：ct mark 0x0000002b counter ... return
#       v1.5.0 起    ：tcp dport 80 counter return / tcp sport 80 counter return
#     两种都要能认出来，否则重复执行 apply 会不断累积规则。
u2f_drop_ours() {
    _n=0
    _out="$("$NFT" -a list chain $u2f_table "$1" 2>/dev/null \
            | awk '/hook /{f=1; next} f && NF {print}')"
    # 逐行处理。用 here-string 而不是管道，避免 while 在子壳里跑、_n 计不到数。
    while IFS= read -r _l; do
        [ -n "$_l" ] || continue
        case "$_l" in *comment*) continue ;; esac
        case "$_l" in
            *"ct mark 0x0000002b"*counter*return*) ;;
            *"tcp dport 80"*counter*return*) ;;
            *"tcp sport 80"*counter*return*) ;;
            *) continue ;;
        esac
        _h="$(printf '%s' "$_l" | sed -n 's/.*handle \([0-9][0-9]*\).*/\1/p')"
        if [ -n "$_h" ] && "$NFT" delete rule $u2f_table "$1" handle "$_h" 2>/dev/null; then
            _n=$((_n + 1))
        fi
    done <<EOF
$_out
EOF
    printf '%s' "$_n"
}

u2f_apply() {
    _ch="$(u2f_chain)"
    if [ -z "$_ch" ]; then
        # ua2f 还没起来 / nftables 分支没生成 queue 链。此时不能假装成功：
        # 调用方（fw4 include / cron）拿不到链，插了也是白插，微信照样坏。
        echo "  [!!] nft: 找不到 UA2F 的 queue 链（ua2f 未运行或为 iptables 分支）" >&2
        return 1
    fi
    # 先清掉旧的（幂等的关键），再重新插
    u2f_drop_ours "$_ch" >/dev/null
    # 把 80 端口整体从 NFQUEUE 里放行。两条都要插，且都必须早于
    # UA2F 那句 `tcp dport 80 ... ct mark set 0x0000002c`：
    #   ① 出方向（本机或转发出去的 80 请求）
    #   ② 入方向（服务器回来的 80 响应）
    # 只放行一个方向的话，TCP 三次握手能过、数据传不动，症状还是「连不上」。
    # 用 insert 逐条插到链首；nft insert 是「一次一条」，所以插两条后顺序是
    # 反的（第二条在最前），但两条互不覆盖，顺序无所谓。
    "$NFT" insert rule $u2f_table "$_ch" tcp dport 80 counter return 2>/dev/null
    "$NFT" insert rule $u2f_table "$_ch" tcp sport 80 counter return 2>/dev/null
    # 回读断言：链首前三条里必须能找到这两条放行规则，
    # 否则说明插失败了（比如权限/表被重建），此时必须报错而不是假装成功。
    _chk="$("$NFT" -a list chain $u2f_table "$_ch" 2>/dev/null \
           | awk '/hook /{f=1; next} f && NF {print}' | head -n3)"
    case "$_chk" in
        *"tcp dport 80"*return*)
            case "$_chk" in
                *"tcp sport 80"*return*) return 0 ;;
            esac
            echo "  [!!] nft: 只插入了出方向放行规则，入方向没插上" >&2
            return 1 ;;
        *)
            echo "  [!!] nft: 80 端口放行规则未生效（链首前三条里找不到）" >&2
            return 1 ;;
    esac
}

u2f_remove() {
    _ch="$(u2f_chain)" || return 0
    [ -n "$_ch" ] || return 0
    u2f_drop_ours "$_ch" >/dev/null
}

# 检查「80 端口放行」是否已生效：链首前三条里必须同时有 dport/sport 两条
u2f_check_ours() {
    _ch="$(u2f_chain)" || return 1
    [ -n "$_ch" ] || return 1
    _chk="$("$NFT" -a list chain $u2f_table "$_ch" 2>/dev/null \
           | awk '/hook /{f=1; next} f && NF {print}' | head -n3)"
    case "$_chk" in
        *"tcp dport 80"*return*) ;; *) return 1 ;;
    esac
    case "$_chk" in
        *"tcp sport 80"*return*) ;; *) return 1 ;;
    esac
    return 0
}

case "${1:-apply}" in
    remove)
        u2f_remove
        ;;
    status|check)
        _bad=0
        if u2f_check_ours; then
            echo "  [OK] nft: 80 端口已整体从 UA2F 队列放行（出入双向）"
        else
            echo "  [!!] nft: 80 端口放行规则不完整，微信仍可能异常"
            _bad=1
        fi
        exit $_bad
        ;;
    *)
        # apply 的返回值必须传出去。否则无论插成功还是插失败，
        # 最后那句 `exit 0` 都会把它抹成「成功」—— 又是一次静默失败：
        # ua2f 没起来时 fw4 include / cron 拿到 0，以为都好了，微信其实照样坏。
        u2f_apply || exit 1
        ;;
esac

exit 0
MMTLS_EOF
    chmod 755 "$MMTLS_SH"

    # 立刻生效一次
    sh "$MMTLS_SH" apply >/dev/null 2>&1

    # ① 注册成 fw4 的 include：每次防火墙 start / reload / restart 后重新应用。
    #    依据 fw4 源码（openwrt/firewall4 · root/sbin/fw4）：
    #      start() 里先 ACTION=start 生成并加载 ruleset，紧接着 ACTION=includes 执行脚本 include，
    #      三条路径都会走到，所以规则不会被漏掉。
    #      ruleset 模板只做 `flush table inet fw4`，不会动 iptables 建的 ip mangle 表。
    #      include 脚本是被 `. path`（source）执行的，所以里面不能 return、也必须 exit 0。
    if [ "$FW_STACK" = "fw4" ]; then
        while uci -q delete firewall.cns_mmtls; do :; done
        uci -q set firewall.cns_mmtls=include
        uci -q set firewall.cns_mmtls.type='script'
        uci -q set firewall.cns_mmtls.path="$MMTLS_SH"
        # fw4 已把 reload 标记为 UNSUPPORTED（写了只会换来一句警告，且不影响执行）
        # fw4_compatible 对非 /etc/firewall.user 的路径默认为真，这里写明确
        uci -q set firewall.cns_mmtls.fw4_compatible='1'
        uci -q commit firewall 2>/dev/null
    fi

    # ② 独立 init 脚本。ua2f 每次启动都会重建 table inet ua2f，我们插进链首的那条
    #    放行规则随之消失，所以必须有一个「晚于 ua2f」的时机把它补回来。
    #    START=99 就是干这个的：开机时一定排在 ua2f（通常 19 左右）之后。
    cat > "$MMTLS_INIT" <<'MMTLS_INIT_EOF'
#!/bin/sh /etc/rc.common
# campus-net-shield: 开机后把「放行 80 端口」的规则补上。
# ua2f 启动时会重建 table inet ua2f，所以本服务必须晚于它，START 取 99。
START=99
STOP=10

start()  { [ -x /etc/campus-mmtls.sh ] && /etc/campus-mmtls.sh apply; }
stop()   { [ -x /etc/campus-mmtls.sh ] && /etc/campus-mmtls.sh remove; }
reload() { [ -x /etc/campus-mmtls.sh ] && /etc/campus-mmtls.sh apply; }
MMTLS_INIT_EOF
    chmod 755 "$MMTLS_INIT"
    "$MMTLS_INIT" enable >/dev/null 2>&1
    "$MMTLS_INIT" start  >/dev/null 2>&1

    # ③ 计划任务兜底。上面两条覆盖不了「运行期手动重启 ua2f」——
    #    在 LuCI 上点一下、改个配置、进程崩溃被 procd 重拉，规则都会丢。
    #    每分钟补一次，成本可忽略（一次 nft list，必要时才插一条）。
    if [ -d /etc/crontabs ]; then
        touch "$CRON_FILE" 2>/dev/null
        grep -v 'campus-mmtls' "$CRON_FILE" > "$CRON_FILE.cns" 2>/dev/null
        mv "$CRON_FILE.cns" "$CRON_FILE" 2>/dev/null
        printf '* * * * * %s apply >/dev/null 2>&1\n' "$MMTLS_SH" >> "$CRON_FILE"
        /etc/init.d/cron restart >/dev/null 2>&1 || /etc/init.d/crond restart >/dev/null 2>&1
    fi

    if sh "$MMTLS_SH" status >/dev/null 2>&1; then
        MMTLS_OK=1
        ok "已让 UA2F 跳过微信 mmtls（iptables 打标记 + nft 链首放行）"
    else
        sh "$MMTLS_SH" status 2>&1 | sed 's/^/    /'
        warn "mmtls 放行规则没写全：固件可能缺 iptables-nft / xt_string，或 ua2f 未在运行"
        warn "  微信可能仍会提示网络连接异常。排查见 README 的 FAQ。"
    fi
fi

# --------------------------------------------------- 关闭 IPv6 ------------
# 校园网普遍只发 IPv4，但路由器默认会向内网通告 IPv6，设备于是同时持有
# IPv6 地址。一旦有 IPv6 流量出口，它就是一条**绕过所有 IPv4 规则**的通道：
# TTL 重写（在 ip6 表里另做，但很多固件没配）、NTP 劫持、UA 处理全都管不到，
# 还会额外暴露一个设备可被计数的维度。
# 既然网络本身不支持 IPv6，最干净的做法就是整体关掉。
step "关闭 IPv6（该网络只有 IPv4）"

IPV6_DISABLED="n"
# ① uci 层：不向内网分配 IPv6 地址 / 前缀
uci -q set network.lan.ipv6='0' 2>/dev/null
uci -q set network.wan.ipv6='0' 2>/dev/null
# DHCP 不再下发 IPv6 相关项
uci -q set dhcp.lan.dhcpv6='disabled' 2>/dev/null
uci -q set dhcp.lan.ra='disabled' 2>/dev/null
uci -q delete dhcp.lan.ra_slaac 2>/dev/null
uci -q delete dhcp.lan.ra_flags 2>/dev/null
# ② 网络层：关闭 IPv6 转发（内核开关）
uci -q set network.globals.ula_prefix='' 2>/dev/null
uci -q commit network 2>/dev/null
uci -q commit dhcp 2>/dev/null

# ③ sysctl：立即生效 + 开机保持
cat > /etc/sysctl.d/99-campus-noipv6.conf <<'SYSCTL_EOF'
# campus-net-shield: 该网络只有 IPv4，关闭全部 IPv6 转发与自动配置
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
SYSCTL_EOF
sysctl -p /etc/sysctl.d/99-campus-noipv6.conf >/dev/null 2>&1

# ④ 兜底：逐接口关一遍（sysctl.d 在内核重启后生效，这里是立刻生效）
for _i in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
    [ -w "$_i" ] && echo 1 > "$_i" 2>/dev/null
done

/etc/init.d/network reload >/dev/null 2>&1
/etc/init.d/odhcpd restart >/dev/null 2>&1 || true

# 回读断言
_ipv6_left="$(ip -6 addr show scope global 2>/dev/null | grep -c 'inet6')"
if [ "$_ipv6_left" -eq 0 ]; then
    IPV6_DISABLED="y"
    ok "IPv6 已关闭（无全局 IPv6 地址）"
else
    warn "仍检测到 $_ipv6_left 个全局 IPv6 地址，请手动核对：ip -6 addr"
    warn "  若内网设备仍拿到 IPv6，检查 LuCI「网络 → 接口 → LAN → DHCP 服务器 → IPv6」"
fi

# ------------------------------------------------- 关闭 NAT 流量卸载 ------
step "关闭流量卸载（UA2F 生效的必要条件）"

uci -q set firewall.@defaults[0].flow_offloading='0' 2>/dev/null
uci -q set firewall.@defaults[0].flow_offloading_hw='0' 2>/dev/null
uci -q commit firewall 2>/dev/null
ok "已关闭 flow offloading"

# ------------------------------------------------------- MAC 克隆 ---------
if [ "$ENABLE_MAC" = "y" ] && [ -n "$MAC_CLONE" ]; then
    step "克隆 WAN 口 MAC 为 $MAC_CLONE"

    # 落成 uci 配置：这是持久化的正道，重启后仍生效。
    # 不要用 `ip link set dev wan address ...` 硬改 —— 那只是运行期的，
    # 网卡 up/down 或重启就丢，而且各家固件对 wan 段名字不一定叫 wan。
    _mac_applied="n"

    # 优先写 network.wan.macaddr（标准 OpenWrt 就是这么做的）
    if uci -q get network.wan >/dev/null 2>&1; then
        uci -q set network.wan.macaddr="$MAC_CLONE"
        uci -q commit network
        _mac_applied="uci:network.wan"
    fi

    # 设备段也可能需要（DSA 固件里 device 段与 interface 段分开）
    # 探测该 interface 对应的 device 名
    _dev="$(uci -q get network.wan.device 2>/dev/null || true)"
    if [ -z "$_dev" ]; then
        _dev="$WAN_IF"
    fi
    if uci -q get "network.$_dev" >/dev/null 2>&1; then
        uci -q set "network.$_dev.macaddr=$MAC_CLONE" 
        uci -q commit network
        _mac_applied="$_mac_applied + uci:network.$_dev"
    fi

    # 立刻生效（不重启网络，避免断连）
    if [ -e "/sys/class/net/$WAN_IF" ]; then
        ip link set dev "$WAN_IF" down 2>/dev/null
        ip link set dev "$WAN_IF" address "$MAC_CLONE" 2>/dev/null
        ip link set dev "$WAN_IF" up 2>/dev/null
    fi

    # 回读断言：读出来必须等于目标值
    sleep 1
    _cur="$(cat "/sys/class/net/$WAN_IF/address" 2>/dev/null | tr 'A-Z' 'a-z')"
    if [ "$_cur" = "$MAC_CLONE" ]; then
        ok "WAN 口 MAC 已改为 $MAC_CLONE（来源：$_mac_applied）"
        # 生成一个便于手动改的小脚本
        cat > "$MACSH_FILE" <<MAC_SCRIPT_EOF
#!/bin/sh
# campus-net-shield: 调整 WAN 口 MAC 克隆。安装时写入的是 $MAC_CLONE
#   campus-mac.sh show            显示当前 WAN MAC
#   campus-mac.sh set aa:bb:...   改为指定 MAC（同时写入 uci，重启保留）
#   campus-mac.sh off             取消克隆（清掉 uci 里的 macaddr）
WAN_IF="$WAN_IF"
case "\$1" in
    set)
        [ -n "\$2" ] || { echo "用法: \$0 set aa:bb:cc:dd:ee:ff"; exit 1; }
        uci set network.wan.macaddr="\$2" 2>/dev/null
        uci commit network 2>/dev/null
        ip link set dev "\$WAN_IF" down 2>/dev/null
        ip link set dev "\$WAN_IF" address "\$2" 2>/dev/null
        ip link set dev "\$WAN_IF" up 2>/dev/null
        echo "已设置 \$WAN_IF 的 MAC 为 \$2"
        ;;
    off)
        uci -q delete network.wan.macaddr 2>/dev/null
        uci commit network 2>/dev/null
        echo "已清除 uci 中的 MAC 克隆，重启后恢复硬件 MAC"
        ;;
    *)
        echo "当前 \$WAN_IF MAC: \$(cat /sys/class/net/\$WAN_IF/address 2>/dev/null)"
        ;;
esac
MAC_SCRIPT_EOF
        chmod 755 "$MACSH_FILE"
    else
        warn "MAC 未生效（当前 $_cur，目标 $MAC_CLONE）"
        warn "  已写入 uci，重启网络后应生效；也可手动执行：$MACSH_FILE set $MAC_CLONE"
    fi
fi

# -------------------------------------------------------- TTL 归一 --------
step "统一出口 TTL 为 $TTL_SET"

# ⚠ 关键：/etc/nftables.d/*.nft 确实会被 fw4 加载，但加载点是
#   templates/ruleset.uc 里的 `include "/etc/nftables.d/*.nft"`，
#   而那行位于 `table inet fw4 { ... }` 的**内部**（「User includes」注释处）。
#   所以写在这里的文件必须只包含 chain 定义，**不能带自己的 table 头**，
#   否则会嵌套出一个非法结构、整份规则加载失败。
#   这也意味着这些链属于 table inet fw4。
NFT_TTL_CHAIN="campus_ttl"

if [ "$FW_STACK" = "fw4" ]; then
    mkdir -p "$NFT_DIR"
    cat > "$NFT_TTL_FILE" <<EOF
# campus-net-shield: 统一出口 TTL，抹掉「经过路由跳数」特征
# 注意：本文件被 fw4 的 ruleset 模板以 include 方式加载，
# 位置在 table inet fw4 内部，因此这里不能再写 table 头。
chain $NFT_TTL_CHAIN {
    type filter hook postrouting priority 300; policy accept;
    oifname "$WAN_IF" ip ttl set $TTL_SET
    oifname "$WAN_IF" ip6 hoplimit set $TTL_SET
}
EOF
    info "已写入 $NFT_TTL_FILE"
elif [ "$FW_STACK" = "fw3" ]; then
    pkg_install iptables-mod-ipopt
    touch "$FW_USER"
    sed -i '/# campus-net-shield ttl begin/,/# campus-net-shield ttl end/d' "$FW_USER" 2>/dev/null
    {
        echo "# campus-net-shield ttl begin"
        echo "iptables -t mangle -A POSTROUTING -o $WAN_IF -j TTL --ttl-set $TTL_SET"
        echo "ip6tables -t mangle -A POSTROUTING -o $WAN_IF -j TTL --ttl-set $TTL_SET"
        echo "# campus-net-shield ttl end"
    } >> "$FW_USER"
    ok "已写入 $FW_USER"
else
    warn "无法识别防火墙栈，TTL 规则未写入"
fi

# -------------------------------------------------------- NTP 劫持 --------
if [ "$ENABLE_NTP" = "y" ]; then
    step "劫持 NTP 请求（统一对时特征）"

    # 让路由器自身提供 NTP 服务
    uci -q set system.ntp.enable_server='1' 2>/dev/null
    uci -q set system.ntp.server='ntp.aliyun.com' 'cn.pool.ntp.org' 2>/dev/null
    uci -q commit system 2>/dev/null
    /etc/init.d/sysntpd restart >/dev/null 2>&1 || true

    if [ "$FW_STACK" = "fw4" ]; then
        mkdir -p "$NFT_DIR"
        # 按实际探测到的内网接口生成，不硬编码 br-lan
        {
            printf '# campus-net-shield: 把内网发往外部的 NTP 请求重定向到路由器自身\n'
            printf '# 同样被 include 进 table inet fw4，故只写 chain。\n'
            printf 'chain campus_ntp {\n'
            printf '    type nat hook prerouting priority dstnat; policy accept;\n'
            for _li in $LAN_IF_LIST; do
                printf '    iifname "%s" udp dport 123 redirect\n' "$_li"
            done
            printf '}\n'
        } > "$NFT_NTP_FILE"
        info "已写入 $NFT_NTP_FILE（接口:$LAN_IF_LIST）"
    elif [ "$FW_STACK" = "fw3" ]; then
        pkg_install iptables-mod-nat-extra
        touch "$FW_USER"
        sed -i '/# campus-net-shield ntp begin/,/# campus-net-shield ntp end/d' "$FW_USER" 2>/dev/null
        {
            echo "# campus-net-shield ntp begin"
            for _li in $LAN_IF_LIST; do
                echo "iptables -t nat -A PREROUTING -i $_li -p udp --dport 123 -j REDIRECT --to-ports 123"
            done
            echo "# campus-net-shield ntp end"
        } >> "$FW_USER"
        ok "已写入 $FW_USER"
    fi
fi

# 重载后必须**回读断言**，不能只看文件写成功。
# 光写文件、规则没被加载（或接口名写错导致一条不匹配）时，
# 「文件存在」「链存在」两种检查都会通过 —— 这就是之前 TTL 假成功的原因。
NTF_APPLY_OK=0
if [ -d "$NFT_DIR" ]; then
    /etc/init.d/firewall reload >/dev/null 2>&1 && ok "防火墙规则已重载"

    if [ "$FW_STACK" = "fw4" ]; then
        _bad=""
        if ! nft list chain inet fw4 campus_ttl 2>/dev/null \
             | grep -q "oifname \"$WAN_IF\""; then
            _bad="$_bad TTL接口绑定"
        fi
        if [ "$ENABLE_NTP" = "y" ]; then
            for _li in $LAN_IF_LIST; do
                nft list chain inet fw4 campus_ntp 2>/dev/null \
                    | grep -q "iifname \"$_li\"" || _bad="$_bad NTP接口($_li)"
            done
        fi
        if [ -n "$_bad" ]; then
            err "防火墙规则未按预期生效，缺：$_bad"
            err "  TTL 未生效 = 出口 TTL 没有归一，多数学校靠这个判定多设备共享。"
            err "  常见原因是接口名不对。当前 WAN=$WAN_IF  LAN=$LAN_IF_LIST"
            err "  核对命令： ip link ; nft list chain inet fw4 campus_ttl"
            NTF_APPLY_OK=0
        else
            NTF_APPLY_OK=1
        fi
    fi
fi

# ------------------------------------------------- 生成认证脚本 ----------
step "生成认证 / 保活脚本"

cat > "$CONF_FILE" <<EOF
# campus-net-shield 配置（含明文密码，权限 600）
PORTAL_HOST="$PORTAL_HOST"
PORTAL_PORT="$PORTAL_PORT"
USERNAME="$USERNAME"
PASSWORD="$PASSWORD"
ISP="$ISP"
WAN_IF="$WAN_IF"
PROBE_URL="$PROBE_URL"
USER_AGENT="$USER_AGENT"
CHECK_INTERVAL="60"
PROBE_TIMEOUT="5"
LOG_TAG="campus-auth"
EOF
chmod 600 "$CONF_FILE"
ok "配置写入 $CONF_FILE"

cat > "$AUTH_BIN" <<'AUTH_SCRIPT'
#!/bin/sh
# campus-auth — 校园网 eportal 认证 / 保活
# 由 campus-net-shield 自动生成，请勿手改（改配置请编辑 /etc/campus-net.conf）

CONF="/etc/campus-net.conf"
[ -f "$CONF" ] || { echo "campus-auth: 缺少 $CONF" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"

LOG_TAG="${LOG_TAG:-campus-auth}"

log() { logger -t "$LOG_TAG" "$*" 2>/dev/null || echo "$LOG_TAG: $*"; }

urlencode() {
    printf '%s' "$1" | sed \
        -e 's/%/%25/g' -e 's/ /%20/g' -e 's/!/%21/g' -e 's/"/%22/g' \
        -e 's/#/%23/g' -e 's/\$/%24/g' -e 's/&/%26/g' -e "s/'/%27/g" \
        -e 's/(/%28/g' -e 's/)/%29/g' -e 's/\*/%2A/g' -e 's/+/%2B/g' \
        -e 's/,/%2C/g' -e 's/\//%2F/g' -e 's/:/%3A/g' -e 's/;/%3B/g' \
        -e 's/=/%3D/g' -e 's/?/%3F/g' -e 's/@/%40/g' -e 's/\[/%5B/g' \
        -e 's/\]/%5D/g' -e 's/\^/%5E/g' -e 's/`/%60/g' -e 's/{/%7B/g' \
        -e 's/|/%7C/g' -e 's/}/%7D/g' -e 's/\\/%5C/g'
}

get_wan_ip() {
    _ip=""
    if [ "${WAN_IF:-auto}" != "auto" ] && [ -n "${WAN_IF:-}" ]; then
        _ip=$(ip -4 addr show dev "$WAN_IF" 2>/dev/null \
              | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -n1)
    fi
    [ -n "$_ip" ] || _ip=$(ip route get "$PORTAL_HOST" 2>/dev/null \
              | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1)
    printf '%s' "$_ip"
}

is_online() {
    _code=$(curl -s -m "${PROBE_TIMEOUT:-5}" -o /dev/null -w '%{http_code}' \
            "$PROBE_URL" 2>/dev/null)
    [ "$_code" = "204" ]
}

do_login() {
    _ip="$(get_wan_ip)"
    if [ -z "$_ip" ]; then
        log "取不到 WAN IP，跳过本次登录"
        return 2
    fi

    _acc=$(urlencode "$USERNAME")
    _pwd=$(urlencode "$PASSWORD")
    _isp=$(urlencode "$ISP")
    _ua=$(urlencode "$USER_AGENT")
    _v=$(date +%s | tail -c 5)

    _url="http://${PORTAL_HOST}:${PORTAL_PORT}/eportal/portal/login?callback=dr1004&login_method=1&user_account=%2C0%2C${_acc}%40${_isp}&user_password=${_pwd}&wlan_user_ip=${_ip}&wlan_user_ipv6=&wlan_user_mac=000000000000&wlan_ac_ip=&wlan_ac_name=&ua=${_ua}&terminal_type=1&lang=zh-cn&jsVersion=4.2.2&v=${_v}"

    _resp=$(curl -s -m 10 -k "$_url" 2>/dev/null)

    case "$_resp" in
        *'"result":1'*)  log "认证成功  IP=$_ip"; return 0 ;;
        *'"ret_code":2'*) log "认证成功  IP=$_ip"; return 0 ;;
        *'"result":0'*)  log "认证失败  $_resp"; return 1 ;;
        '')              log "认证无响应（网络不通或 portal 地址错误）"; return 1 ;;
        *)               log "认证响应异常  $_resp"; return 1 ;;
    esac
}

case "${1:-once}" in
    once)
        is_online && exit 0
        do_login >/dev/null 2>&1
        ;;
    login)
        do_login
        ;;
    status)
        if is_online; then echo "在线"; else echo "离线"; fi
        ;;
    daemon)
        log "守护进程启动"
        _fails=0
        while :; do
            if is_online; then
                _fails=0
            else
                do_login
                _fails=$((_fails + 1))
                # 连续 20 次失败后进入 10 分钟冷却，避免触发风控
                if [ "$_fails" -ge 20 ]; then
                    log "连续登录失败 $_fails 次，冷却 10 分钟"
                    sleep 600
                    _fails=0
                    continue
                fi
            fi
            sleep "${CHECK_INTERVAL:-60}"
        done
        ;;
    *)
        echo "用法: campus-auth {once|login|status|daemon}" >&2
        exit 64
        ;;
esac
AUTH_SCRIPT

chmod 755 "$AUTH_BIN"
ok "脚本写入 $AUTH_BIN"

# ------------------------------------------------- 注册 procd 服务 -------
step "注册认证服务"

cat > "$INIT_SCRIPT" <<'INIT_SCRIPT_EOF'
#!/bin/sh /etc/rc.common
# campus-net-shield: 校园网认证保活服务
# 说明：本服务默认不 enable、也不启动。需要时手动启用：
#     /etc/init.d/campus-auth enable && /etc/init.d/campus-auth start
# 或只跑一次登录（不进守护进程）：
#     /usr/bin/campus-auth login

START=95
STOP=10
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /usr/bin/campus-auth daemon
    procd_set_param respawn 3600 5 5
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

stop_service() { :; }
INIT_SCRIPT_EOF

chmod 755 "$INIT_SCRIPT"

# 默认关闭（用户要求）：不 enable、不 start。但 init 脚本和配置都已就位，
# 想开就一条命令。
"$INIT_SCRIPT" stop >/dev/null 2>&1
"$INIT_SCRIPT" disable >/dev/null 2>&1
if [ "$ENABLE_AUTOSTART" = "y" ]; then
    "$INIT_SCRIPT" enable >/dev/null 2>&1
    "$INIT_SCRIPT" restart >/dev/null 2>&1
    ok "认证保活服务已注册并设为开机自启"
else
    ok "认证保活服务已注册（未启用自启，按需手动开启）"
fi

# ------------------------------------------------- 定时重启（可选） ------
if [ "$ENABLE_REBOOT" = "y" ]; then
    step "设置每天凌晨 3 点自动重启"
    if [ -d /etc/crontabs ]; then
        touch "$CRON_FILE" 2>/dev/null
        grep -v 'campus-reboot' "$CRON_FILE" > "$CRON_FILE.cns" 2>/dev/null
        mv "$CRON_FILE.cns" "$CRON_FILE" 2>/dev/null
        printf '0 3 * * * /sbin/reboot # campus-reboot\n' >> "$CRON_FILE"
        /etc/init.d/cron restart >/dev/null 2>&1 || /etc/init.d/crond restart >/dev/null 2>&1
        ok "已设置：每天 03:00 自动重启"
    else
        warn "/etc/crontabs 不存在，无法设置定时重启"
    fi
fi

# ------------------------------------------------- 首次登录测试 ----------
step "首次登录测试"

sleep 2
if RESULT="$("$AUTH_BIN" login 2>&1)"; then
    ok "$RESULT"
else
    warn "$RESULT"
    warn "若提示「认证失败」，请核对账号 / 密码 / 运营商 / 认证服务器地址"
    warn "检查配置：cat $CONF_FILE"
fi

# --------------------------------------------------------- 自检 ----------
step "安装结果自检"

CHK_PASS=0
CHK_FAIL=0

chk() {
    # $1=说明  $2=命令
    if eval "$2" >/dev/null 2>&1; then
        ok "$1"
        CHK_PASS=$((CHK_PASS + 1))
    else
        warn "$1"
        CHK_FAIL=$((CHK_FAIL + 1))
    fi
}

if [ "$ENABLE_AUTOSTART" = "y" ]; then
    chk "认证保活服务在运行"  "pgrep -f '$AUTH_BIN'"
else
    # 默认关闭时不检查进程，只检查脚本和配置就位
    chk "认证脚本已就位（$AUTH_BIN）" "[ -x '$AUTH_BIN' ]"
    chk "认证配置已就位（$CONF_FILE）" "[ -f '$CONF_FILE' ]"
fi

if [ "$ENABLE_MAC" = "y" ] && [ -n "$MAC_CLONE" ]; then
    chk "WAN 口 MAC 已克隆为 $MAC_CLONE" \
        "[ \"\$(cat /sys/class/net/$WAN_IF/address 2>/dev/null | tr 'A-Z' 'a-z')\" = \"$MAC_CLONE\" ]"
fi

chk "IPv6 已关闭（无全局 IPv6 地址）" \
    "[ \"\$(ip -6 addr show scope global 2>/dev/null | grep -c inet6)\" = \"0\" ]"

if [ "$UA2F_OK" = "1" ]; then
    # ua2f 的 /etc/config/ua2f 里 enabled 默认是 0，start_service 会直接 return 1。
    # 所以这里必须实测进程，不能只看包装没装上。
    chk "UA2F 进程在运行（enabled=1 已生效）" "pgrep -f /usr/bin/ua2f"
    if [ "$FW_STACK" = "fw4" ]; then
        chk "UA2F nft 规则表已加载（table inet ua2f）" "nft list table inet ua2f"
    fi
fi

if [ "$UA2F_OK" = "1" ] && [ "${CNS_NO_MMTLS:-0}" != "1" ]; then
    chk "80 端口放行规则已生效（微信不再异常）" "$MMTLS_SH status"
fi

chk "流量卸载已关闭"      "[ \"\$(uci -q get firewall.@defaults[0].flow_offloading)\" != \"1\" ]"

if [ "$FW_STACK" = "fw4" ]; then
    chk "TTL 规则已加载"  "nft list ruleset | grep -q campus_ttl"
    # 断言接口名绑定 —— 接口名写错时规则照样存在，只是一条包都不匹配
    chk "TTL 规则绑定了 WAN 接口（$WAN_IF）" \
        "nft list chain inet fw4 campus_ttl | grep -q 'oifname \"$WAN_IF\"'"
    if [ "$ENABLE_NTP" = "y" ]; then
        chk "NTP 劫持已加载"  "nft list ruleset | grep -q campus_ntp"
        for _li in $LAN_IF_LIST; do
            chk "NTP 劫持绑定了内网接口（$_li）" \
                "nft list chain inet fw4 campus_ntp | grep -q 'iifname \"$_li\"'"
        done
    fi
else
    chk "TTL 规则已加载"  "iptables -t mangle -S POSTROUTING | grep -q TTL"
fi

# 实测出口 TTL：从路由器自己 ping，收包 TTL 应当已被改写。
# 这是唯一能证明「TTL 真的归一了」的检查，前面那些都只是看规则在不在。
# 注意：ping 目标不同、回程跳数不同，收到的 TTL 本来就会浮动，
# 所以这里不比绝对值，只验证「ping 通了」+ 打印实测值供人工核对。
if command -v ping >/dev/null 2>&1; then
    _pttl="$(ping -c 2 -W 3 223.5.5.5 2>/dev/null | sed -n 's/.*ttl=\([0-9]*\).*/\1/ip' | head -n1)"
    if [ -n "$_pttl" ]; then
        ok "出口连通性正常（实测收到 ttl=$_pttl，本机统一值已设为 $TTL_SET）"
        info "  ⚠ 这个 ttl 是『对端回包』的值，随目标与跳数浮动，不等于 $TTL_SET 是正常的。"
        info "  要验证改写是否生效，请在【内网设备】上 ping 同一目标，对比是否与网关侧一致。"
    else
        warn "从路由器 ping 外网无响应，无法实测 TTL（不影响规则本身）"
    fi
fi

# 代理软件会劫持 80/443，让 UA2F 抓不到明文 HTTP；mwan3 / QoS 还可能占用
# connmark，与 UA2F 的 43 / 44 标记冲突。这是「装完仍被检测」的头号原因。
for _p in clash mihomo sing-box xray hysteria mwan3 passwall shellcrash ssrplus; do
    if pgrep -f "$_p" >/dev/null 2>&1; then
        warn "检测到代理/多拨组件正在运行：$_p"
        warn "  它会劫持 80/443 并可能占用 connmark，可能导致 UA2F 失效。"
        warn "  测试时先停掉它，或在它的规则里放行校园网内网网段。"
        warn "  若确认是 connmark 冲突，可执行下面这条后重启 UA2F："
        warn "    uci set ua2f.main.disable_connmark=1 && uci commit ua2f && /etc/init.d/ua2f restart"
    fi
done

if [ "$UA2F_OK" != "1" ]; then
    warn "UA2F 未安装 —— TTL 与 NTP 仍生效，但明文 HTTP 的 UA 特征不会被抹除"
    CHK_FAIL=$((CHK_FAIL + 1))
fi

printf '\n'
if [ "$CHK_FAIL" -eq 0 ]; then
    ok "自检全部通过（共 $CHK_PASS 项）"
else
    warn "自检有 $CHK_FAIL 项未通过（通过 $CHK_PASS 项），请按上面的提示逐条排查"
fi

# ------------------------------------------------- 汇总 -----------------
printf '\n'
printf '%b============================================================%b\n' "$C_G" "$C_N"
printf '%b  campus-net-shield v%s 安装完成%b\n' "$C_G" "$SCRIPT_VER" "$C_N"
printf '%b============================================================%b\n' "$C_G" "$C_N"
cat <<INFO

 配置    : $CONF_FILE   （含明文密码，权限 600）
 脚本    : $AUTH_BIN
 服务    : $INIT_SCRIPT

 当前状态
   开机自启 : $ENABLE_AUTOSTART   $([ "$ENABLE_AUTOSTART" = "y" ] && echo "（已启用）" || echo "（已关闭，需要时手动开）")
   凌晨重启 : $ENABLE_REBOOT
   MAC 克隆 : $ENABLE_MAC${MAC_CLONE:+  ($MAC_CLONE)}
   IPv6     : $IPV6_DISABLED   $([ "$IPV6_DISABLED" = "y" ] && echo "（已关闭）" || echo "（未完全关闭，请核对）")

 常用命令
   查看在线状态 : $AUTH_BIN status
   手动登录     : $AUTH_BIN login
   查看日志     : logread -e campus-auth | tail -n 30
   微信诊断     : $MMTLS_SH status

   开启开机自启（当前关闭时）:
     $INIT_SCRIPT enable && $INIT_SCRIPT start

   开启凌晨自动重启:
     echo '0 3 * * * /sbin/reboot # campus-reboot' >> /etc/crontabs/root
     /etc/init.d/cron restart

   调整 MAC 克隆:
     $MACSH_FILE            # 查看当前 MAC
     $MACSH_FILE set aa:bb:cc:dd:ee:ff
     $MACSH_FILE off        # 取消克隆

   检查 UA2F    : pgrep -f /usr/bin/ua2f && nft list table inet ua2f

 验证是否成功（用内网任意设备）
   1) TTL  : 内网设备 ping 223.5.5.5，记 TTL；路由器上再 ping 一次
             —— 两者相同 = 生效；内网侧小 1 = 没生效
   2) IPv6 : ip -6 addr show scope global   —— 应无输出
   3) 实测 : 多台设备同时上网，观察是否掉线

 卸载    : 在仓库目录执行 sh uninstall.sh

 ⚠ 若以上都做了仍被踢，说明学校用了更深的检测（IPID / TCP 指纹 / 连接数行为分析），
   这些在路由器层难以伪造。此时请停止使用，避免账号进一步被处置。

INFO
exit 0
