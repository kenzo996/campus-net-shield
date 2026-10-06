#!/bin/sh
# ============================================================================
#  campus-net-shield  ·  uninstall.sh  v1.0.0
#  一键还原：移除认证服务、TTL / NTP 规则，恢复流量卸载与 NTP 设置
#
#  在 OpenWrt 路由器上以 root 执行：
#     sh uninstall.sh
# ============================================================================

set -u

CONF_FILE="/etc/campus-net.conf"
AUTH_BIN="/usr/bin/campus-auth"
INIT_SCRIPT="/etc/init.d/campus-auth"
NFT_DIR="/etc/nftables.d"
NFT_TTL_FILE="$NFT_DIR/12-campus-ttl.nft"
NFT_NTP_FILE="$NFT_DIR/13-campus-ntp.nft"
FW_USER="/etc/firewall.user"

if [ -t 1 ]; then
    C_R='\033[1;31m'; C_G='\033[1;32m'; C_Y='\033[1;33m'; C_B='\033[1;36m'; C_N='\033[0m'
else
    C_R=''; C_G=''; C_Y=''; C_B=''; C_N=''
fi
info() { printf '%b[*]%b %s\n' "$C_B" "$C_N" "$*"; }
ok()   { printf '%b[+]%b %s\n' "$C_G" "$C_N" "$*"; }
warn() { printf '%b[!]%b %s\n' "$C_Y" "$C_N" "$*"; }
step() { printf '\n%b==>%b %s\n' "$C_B" "$C_N" "$*"; }

[ "$(id -u)" = "0" ] || { warn "请以 root 身份运行"; exit 1; }

if command -v opkg >/dev/null 2>&1; then PKG_MGR="opkg"
elif command -v apk >/dev/null 2>&1; then PKG_MGR="apk"
else PKG_MGR=""; fi

step "停止并移除认证服务"

if [ -x "$INIT_SCRIPT" ]; then
    "$INIT_SCRIPT" stop   >/dev/null 2>&1
    "$INIT_SCRIPT" disable >/dev/null 2>&1
    ok "服务已停止并取消自启"
fi

[ -f "$INIT_SCRIPT" ] && rm -f "$INIT_SCRIPT" && ok "已删除 $INIT_SCRIPT"
[ -f "$AUTH_BIN" ]    && rm -f "$AUTH_BIN"    && ok "已删除 $AUTH_BIN"
[ -f "$CONF_FILE" ]   && rm -f "$CONF_FILE"   && ok "已删除 $CONF_FILE"

step "移除 TTL / NTP 防火墙规则"

[ -f "$NFT_TTL_FILE" ] && rm -f "$NFT_TTL_FILE" && ok "已删除 $NFT_TTL_FILE"
[ -f "$NFT_NTP_FILE" ] && rm -f "$NFT_NTP_FILE" && ok "已删除 $NFT_NTP_FILE"

if [ -f "$FW_USER" ]; then
    sed -i '/# campus-net-shield ttl begin/,/# campus-net-shield ttl end/d' "$FW_USER" 2>/dev/null
    sed -i '/# campus-net-shield ntp begin/,/# campus-net-shield ntp end/d' "$FW_USER" 2>/dev/null
    ok "已清理 $FW_USER"
fi

step "恢复系统设置"

# 恢复流量卸载
uci -q set firewall.@defaults[0].flow_offloading='1' 2>/dev/null
uci -q set firewall.@defaults[0].flow_offloading_hw='0' 2>/dev/null
uci -q commit firewall 2>/dev/null
ok "已恢复 flow offloading（软件加速开启，硬件加速维持关闭）"

# 恢复 NTP 服务设置
uci -q set system.ntp.enable_server='0' 2>/dev/null
uci -q delete system.ntp.server 2>/dev/null
uci -q commit system 2>/dev/null
/etc/init.d/sysntpd restart >/dev/null 2>&1 || true
ok "已关闭本地 NTP 服务"

step "重载防火墙"
if [ -f /etc/init.d/firewall ]; then
    /etc/init.d/firewall reload >/dev/null 2>&1 && ok "防火墙已重载"
fi

# UA2F 是否卸载
printf '\n'
printf '是否一并卸载 UA2F 插件？(y/n) [y]: '
RESP=""
if [ -r /dev/tty ]; then
    IFS= read -r RESP </dev/tty || RESP=""
fi
case "${RESP:-y}" in
    [Nn]*) info "保留 UA2F" ;;
    *)
        if [ "$PKG_MGR" = "opkg" ]; then
            # luci-app-ua2f 依赖 ua2f（安装时用 CNS_WITH_LUCI=1 可能装过），
            # 不先卸掉它，opkg 会因为反向依赖而拒绝卸载 ua2f。
            if opkg list-installed 2>/dev/null | grep -q '^luci-app-ua2f '; then
                opkg remove luci-app-ua2f >/dev/null 2>&1 \
                    && ok "已卸载 luci-app-ua2f" \
                    || warn "luci-app-ua2f 卸载失败，忽略"
            fi
            if opkg remove ua2f >/dev/null 2>&1; then
                ok "UA2F 已卸载（opkg）"
            elif opkg remove --force-depends ua2f >/dev/null 2>&1; then
                ok "UA2F 已卸载（opkg，--force-depends）"
            else
                warn "opkg 卸载 UA2F 失败（可能仍有包依赖它）"
            fi
        elif [ "$PKG_MGR" = "apk" ]; then
            apk del ua2f >/dev/null 2>&1 && ok "UA2F 已卸载（apk）" || warn "apk 未管理 ua2f"
        fi
        # apk 兼容模式下是手动放进去的二进制
        if [ -f /usr/bin/ua2f ] && [ "$PKG_MGR" = "apk" ]; then
            rm -f /usr/bin/ua2f
            ok "已删除手动安装的 /usr/bin/ua2f"
        fi
        if [ -x /etc/init.d/ua2f ]; then
            /etc/init.d/ua2f stop >/dev/null 2>&1
            /etc/init.d/ua2f disable >/dev/null 2>&1
            rm -f /etc/init.d/ua2f
            rm -rf /usr/share/ua2f
            rm -f /etc/config/ua2f
            ok "已清理 UA2F 残留文件"
        fi
        ;;
esac

printf '\n'
printf '%b============================================================%b\n' "$C_G" "$C_N"
printf '%b  campus-net-shield 已卸载%b\n' "$C_G" "$C_N"
printf '%b============================================================%b\n' "$C_G" "$C_N"
cat <<'INFO'

 路由器已恢复原状：
   - 不再自动登录校园网（如需上网请手动认证）
   - 出口 TTL 不再被修改
   - 内网 NTP 请求不再被劫持
   - NAT 流量卸载已重新开启

 若还想彻底清理，可手动执行：
   opkg remove libnetfilter-queue kmod-nfnetlink-queue

INFO
exit 0
