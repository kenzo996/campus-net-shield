#!/bin/sh
# ============================================================================
#  campus-net-shield  ·  uninstall.sh  v1.2.0
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
MMTLS_SH="/etc/campus-mmtls.sh"
MMTLS_INIT="/etc/init.d/campus-mmtls"
CRON_FILE="/etc/crontabs/root"

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

step "移除微信 mmtls 放行规则"

# 顺序很重要：
#   1) 先停掉定时补偿任务 —— 否则下面删完规则，一分钟内它又给装回来
#   2) 再执行 remove 清规则（iptables 的 connmark 规则 + 插进 UA2F 链首的那条）
#   3) 最后摘 firewall include
# 反过来任何一步做错，都会出现「卸载不干净」。
if [ -d /etc/crontabs ] && [ -f "$CRON_FILE" ]; then
    grep -v 'campus-mmtls' "$CRON_FILE" > "$CRON_FILE.cns" 2>/dev/null
    mv "$CRON_FILE.cns" "$CRON_FILE" 2>/dev/null
    /etc/init.d/cron restart >/dev/null 2>&1 || /etc/init.d/crond restart >/dev/null 2>&1
    ok "已移除 mmtls 定时补偿任务"
fi

if [ -x "$MMTLS_INIT" ]; then
    "$MMTLS_INIT" stop    >/dev/null 2>&1
    "$MMTLS_INIT" disable >/dev/null 2>&1
    rm -f "$MMTLS_INIT" && ok "已删除 $MMTLS_INIT"
fi

if [ -x "$MMTLS_SH" ]; then
    "$MMTLS_SH" remove >/dev/null 2>&1 && ok "已清除 mmtls 放行规则（iptables + nft）"
fi

# 先摘掉 firewall include —— 否则下一步重载防火墙时脚本会被再次调用，规则又回来了
while uci -q delete firewall.cns_mmtls; do :; done
uci -q commit firewall 2>/dev/null
ok "已移除 firewall include（firewall.cns_mmtls）"

if [ -f "$MMTLS_SH" ]; then
    rm -f "$MMTLS_SH" && ok "已删除 $MMTLS_SH"
fi

# 兜底：万一上面 remove 没跑成（脚本已被删 / 参数不认），这里再硬清一遍
IPT="$(command -v iptables 2>/dev/null || true)"
if [ -n "$IPT" ]; then
    while "$IPT" -t mangle -D PREROUTING -p tcp --dport 80 \
            -m string --string /mmtls/ --algo bm \
            -j CONNMARK --set-mark 43 2>/dev/null; do :; done
fi

# UA2F 的链如果还在，把插进去的那条规则按 handle 删掉。
# 我们插的那条渲染成 `ct mark 0x0000002b counter packets N bytes M return`，
# UA2F 自己那条带 comment，靠 comment 区分，不能误删。
NFT_BIN="$(command -v nft 2>/dev/null || true)"
if [ -n "$NFT_BIN" ]; then
    _ch="$("$NFT_BIN" list table inet ua2f 2>/dev/null \
           | awk '/^[[:space:]]*chain[[:space:]]/{c=$2} /[[:space:]]queue[[:space:]]/{if(c){print c; exit}}')"
    if [ -n "$_ch" ]; then
        "$NFT_BIN" -a list chain inet ua2f "$_ch" 2>/dev/null | while IFS= read -r _l; do
            case "$_l" in *"ct mark 0x0000002b"*counter*return*) ;; *) continue ;; esac
            case "$_l" in *comment*) continue ;; esac
            _h="$(printf '%s' "$_l" | sed -n 's/.*handle \([0-9][0-9]*\).*/\1/p')"
            [ -n "$_h" ] && "$NFT_BIN" delete rule inet ua2f "$_ch" handle "$_h" 2>/dev/null
        done
    fi
fi

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
