# campus-net-shield

在 OpenWrt 路由器上绕过校园网「多终端检测」，并让路由器自己完成 eportal 认证与保活。

适用于 Dr.COM / 深澜 系的 `eportal/portal/login` 接口（URL 里带 `callback=dr1004` 的那种）。

---

## ⚠️ 先读这一段

**这个项目做的事情，可能违反你与学校/运营商之间的网络接入协议。**

- 校园网检测多终端共享，是学校网络管理规定的一部分。绕过它属于规避网络接入控制。
- 可预期的后果：账号被**临时封禁**、**限速**、**强制下线**，情节严重时按**校纪**处理。
- 本方案只能骗过基于 **TTL / User-Agent / NTP** 这几类浅层特征的检测。
  如果学校上了时钟偏移分析、TLS 指纹（JA3/JA4）或流量行为分析，**依然会被抓**，本方案无法覆盖。
- 账号是实名的。请自行评估风险后再决定是否使用。

作者不对任何后果负责。代码开源，你可以在路由器上先完整阅读再执行。

---

## 支持的 OpenWrt 版本

| OpenWrt | 包管理器 | 防火墙 | UA2F | 状态 |
|---|---|---|---|---|
| 22.03 – 23.05 | opkg | fw4 (nftables) | `23.05.5` 构建 | 可用 |
| 24.10.x | opkg | fw4 (nftables) | `24.10.0` 构建；Kwrt 源自带 `4.10.2-r8` | **推荐，已实测路径** |
| 25.12+ | apk | fw4 (nftables) | 无官方 apk 包，脚本走「解包二进制」兼容模式 | 实验性 |
| 21.02 及更早 | opkg | fw3 (iptables) | 无 | 不保证 |

架构方面，脚本直接读取 OpenWrt 的 `DISTRIB_ARCH`（如 `aarch64_cortex-a53`、`mipsel_24kc`、`x86_64`）去匹配 UA2F 的 release 资源，**无需手动选择**。

> OpenWrt 25.12 起包管理器从 opkg 换成了 apk，`.ipk` 无法直接安装。脚本会自动识别并改用解包提取二进制的方式，但仍可能出现依赖不匹配，遇到问题见下面的 FAQ。

### 第三方固件（Kwrt / ImmortalWrt / LEDE 等）

这类固件的 opkg 源是自建的，内核也是自行编译的，**官方 UA2F ipk 的依赖不一定能直接满足**。
脚本按下面三级顺序尝试安装：

1. 直接从固件自建源装 `ua2f` —— 最稳，依赖与内核模块版本天然匹配
2. 下载官方 ipk，逐个补齐依赖后再装
3. 仍失败则用 `opkg install --force-depends` 强制安装，并提示缺库风险

**`mips` / `mipsel` 平台（如 `ramips/mt7621`）额外需要 `libatomic`**，脚本会根据
`DISTRIB_ARCH` 自动加入依赖清单。UA2F 在 fw4 环境下还需要 `kmod-nft-queue`，
这类内核模块必须与内核版本匹配，第三方固件务必走自己的源。

> **实测记录（Kwrt 24.10-SNAPSHOT / `ramips/mt7621` / `mipsel_24kc`）**
>
> 该固件的自建 `kiddin9` 源里**自带 `ua2f` 4.10.2-r8 与 `luci-app-ua2f`**。其四个依赖
> `libuci20250120`、`libnetfilter-conntrack3`、`libnetfilter-queue1`、`kmod-nft-queue`
> 分别能在 base / packages / core 源中找到，**依赖完全可满足**。
> 也就是说在这类固件上 `opkg install ua2f` 一步到位，压根用不到官方 ipk。
> 脚本的「三级降级」里第一级就会命中，后面两级只是保险。
>
> 另外，该包的 `/etc/config/ua2f` 里 `enabled` 默认是 `0`，装完**不会自动启用**，
> 包会打印 `UA2F disabled. You should enable it manually.`。初始化脚本
> 在 `enabled != 1` 时直接 `return 1`，连 `table inet ua2f` 都不会创建。
> 这是上游设计，不是安装失败。脚本会自动写入 `enabled=1` 并重启服务。

---

## 原理

校园网网关判断「你有多台设备」靠的是流量特征，逐个抹掉即可：

| 特征 | 网关看到什么 | 本方案怎么处理 |
|---|---|---|
| **TTL** | Windows 初始 128、Linux/Android 64、 iOS 255；每过一跳减 1。混着出现 = 多设备 | 出口 `postrouting` 强制写死 TTL（默认 128），消除跳数与系统差异 |
| **User-Agent** | 明文 HTTP 请求头里同时出现 Windows / Android / iOS 的 UA | 装 **UA2F**，把所有未加密 HTTP 的 UA 统一成一个固定值 |
| **NTP 请求** | 各系统默认对时服务器不同（苹果、小米、安卓各不一样） | nftables 把内网发往外部 123/UDP 的包重定向到路由器，统一由路由器对时 |
| **IPID** | IP 标识符的递增规律能区分设备数 | 需要 `kmod-rkp-ipid` 内核模块，**本方案不含**（见 FAQ） |

登录部分就是把你抓到的那个 `eportal/portal/login` 请求搬到路由器上跑：自动取 WAN 口当前 IP、定时探活、掉线自动重登。

---

## ⚠️ UA2F 会弄坏微信（nftables 固件必看）

如果你用的是 22.03+ 的 OpenWrt 或第三方固件（**fw4 + nftables**），UA2F 会让
**手机微信提示「网络连接异常」，而其他 App 一切正常**。

**原因**：UA2F 生成的 nftables 规则最后一条是「所有非 22 / 443 端口的 TCP 全部送进 NFQUEUE」。
而微信的 mmtls 长连接是**伪装成 HTTP 请求**跑在 80 端口上的：

```
POST /mmtls/7ae571b3 HTTP/1.1
Accept: */*
Content-Type: application/octet-stream
Host: dns.weixin.qq.com
Upgrade: mmtls
User-Agent: MicroMessenger Client
```

UA2F 会把它当成普通 HTTP，改写里面的 `User-Agent`，mmtls 握手随即失败。

**上游有 `handle_mmtls` 选项，但在 nftables 下无效。** UA2F 作者在 README 里写得很明确：

> `handle_mmtls` —— 是否处理微信 mmtls 流量。**该规则仅在 iptables NFQUEUE 分支中生效，nftables 分支无效。**

也就是说，所有 fw4 固件的用户都吃不到这个绕过。

### 网上流传的修法是错的

搜这个问题会看到一种说法：「在 `PREROUTING` 里给 mmtls 打 `connmark 43` 就行，因为
UA2F 里有一条 `ct mark 43 → return` 的逃生口」。**这条是错的。** 把 UA2F 的链 dump
出来看顺序就明白了（下面是真机输出，顺序即执行顺序）：

```
chain postrouting {
    type filter hook postrouting priority mangle - 5; policy accept;
    ip daddr @localaddr_v4 ... return
    tcp dport 22 ... return comment "!ua2f: bypass SSH"
    tcp dport 443 ... return comment "!ua2f: bypass HTTPS"
    tcp dport 80 ... ct mark set 0x0000002c          ← ① 先把 80 端口的包无脑打成 connmark 44
    ct mark 0x0000002b ... return comment "!ua2f: bypass non-http stream"   ← ② 才判断「43 就放行」
    meta l4proto tcp ct direction original ... queue flags bypass to 10010  ← ③ 剩下的进 NFQUEUE
}
```

① 在 ② 前面，而且是无条件执行。你在 `PREROUTING` 打的 43，进了这条链先被 ① 覆盖成 44，
到 ② 时已经匹配不上了，包照样落到 ③。**光打 connmark 是没用的**（`PREROUTING` 钩子确实
早于 `postrouting` 钩子，但问题不在先后，在于标记被覆盖）。

### 正确做法：把放行判断插到 UA2F 链条最前面

必须插到 ① 之前，才轮不到它覆盖。所以本项目做两件事，缺一不可：

1. `iptables mangle PREROUTING`：用 `xt_string` 认出 mmtls（匹配请求行里的 `/mmtls/`），
   给这条**连接**打上 `connmark 43`
2. `nft insert`：把 `ct mark 0x2b return` 插进 `table inet ua2f` 队列链的**首位**

第 2 步是能生效的关键。插入后链首变成：

```
chain postrouting {
    type filter hook postrouting priority mangle - 5; policy accept;
    ct mark 0x0000002b counter packets 0 bytes 0 return    ← 我们插的，排在最前
    ip daddr @localaddr_v4 ... return
    ...
```

**为什么这样做零代价**：微信的 UA 在所有设备上都是同一串 `MicroMessenger Client`，
不携带任何设备差异，绕过它对「统一 UA」这个目标毫无损失。

**唯一冲突点**：这个绕过依赖 `ua2f.main.disable_connmark=0`。如果你因为 mwan3 / QoS 的
connmark 冲突把它改成了 `1`，UA2F 就不再生成「跳过 connmark 43」的规则，本绕过随之失效
——两者只能二选一。安装脚本检测到这种组合会自动改回 0 并提示你。

不想多装这几个包，或固件里没有，可以跳过这一步（代价：微信不可用）：

```
export CNS_NO_MMTLS=1 && sh /tmp/cns.sh
```

### 规则是怎么存活下来的

UA2F 每次启动都会**删掉并重建** `table inet ua2f`，插在它链首的那条规则会随之消失。
所以脚本用三个时机兜底（`/etc/campus-mmtls.sh` 是唯一的执行体，`apply` / `remove` / `status`）：

| 时机 | 覆盖场景 | 实现 |
|---|---|---|
| 防火墙重载 | 开机、`/etc/init.d/firewall reload` | 注册为 fw4 的 script include |
| 开机启动 | 冷启动后第一次补齐 | 独立 init 脚本 `campus-mmtls`，`START=99`（晚于 ua2f） |
| 每分钟检查 | **运行期手动重启 ua2f**（LuCI 点一下、改配置、崩溃重拉） | `/etc/crontabs/root` 里一条 `* * * * *` |

第三条看起来笨，但这是唯一能覆盖「ua2f 被重启但防火墙没重载」的手段。成本可以忽略：
一次 `nft list`，规则在的话什么都不做。

关于 include：依据 fw4 源码（`openwrt/firewall4` · `root/sbin/fw4`），
`fw4 start` / `reload` / `restart` 都会先加载 ruleset、紧接着执行一遍 script include；
ruleset 模板只做 `flush table inet fw4`，**不会** `flush ruleset`，所以 iptables
建的 `ip mangle` 表不会被冲掉。include 脚本是被 `. path`（source）执行的，
因此脚本内部不能 `return`，且必须 `exit 0`。

不管在哪个时机被调用，`apply` 都是幂等的：先按 handle 删掉自己插过的规则
（靠有没有 `comment` 区分，绝不误删 UA2F 自带的那条），再重新插到链首。

---

## 安装

### 第零步：30 秒预检（强烈建议）

在路由器上先跑这一条，把三行输出看清楚：

```
opkg update && opkg list | grep -i ua2f
```

- **有输出**（例如 `ua2f - 4.10.2-r8`）→ 你的固件源里自带 UA2F，后面一切顺利。
- **没输出** → 固件源里没有，脚本会退回下载官方 ipk，此时务必确认 `uname -r` 与
  源里 `kmod-nft-queue` 的版本匹配。

顺手记录一下环境，出问题时有用：

```
opkg print-architecture && uname -r && cat /etc/opkg/distfeeds.conf
```

### 第一步：把项目传到你的 GitHub

在本地项目目录执行下面三条命令（一次复制一条）。

先初始化仓库：

```
git init && git add -A && git commit -m "init: campus-net-shield v1.0.0"
```

关联你的远程仓库（把 `<你的用户名>` 和 `<仓库名>` 换成实际值）：

```
git remote add origin https://github.com/<你的用户名>/<仓库名>.git
```

推送：

```
git branch -M main && git push -u origin main
```

> 上传前请确认仓库是 **Public**。私有仓库在路由器上拉取需要配置 token，会增加操作步骤。

### 第二步：在路由器上一键安装

SSH 登录路由器后执行（把 `<你的用户名>/<仓库名>` 换成实际值）：

```
wget -O /tmp/cns.sh https://raw.githubusercontent.com/<你的用户名>/<仓库名>/main/install.sh && sh /tmp/cns.sh
```

**但国内这条大概率拉不动。** `raw.githubusercontent.com` 经常被连接重置，wget 会报
`Unable to establish SSL connection`。这不是证书问题，是链路被掐。换下面任意一条
加速通道即可（均实测可返回正确内容）：

```
wget -O /tmp/cns.sh https://gh-proxy.com/https://raw.githubusercontent.com/<你的用户名>/<仓库名>/main/install.sh && sh /tmp/cns.sh
```

```
wget -O /tmp/cns.sh https://ghproxy.net/https://raw.githubusercontent.com/<你的用户名>/<仓库名>/main/install.sh && sh /tmp/cns.sh
```

```
wget -O /tmp/cns.sh https://cdn.jsdelivr.net/gh/<你的用户名>/<仓库名>@main/install.sh && sh /tmp/cns.sh
```

> 前两条是实时代理，推送后立刻能拿到最新代码。jsdelivr 是 CDN，分支内容有缓存
> （最长 12 小时），更新后想立刻生效，把 `@main` 换成具体 commit 哈希。

脚本会依次询问：认证服务器地址（格式 `IP:端口`，默认 `192.168.241.1:801`）、上网账号、
运营商、密码、WAN 接口。除账号密码外都有默认值，直接回车即可。

> 认证服务器地址一定要带端口。端口从你抓到的登录请求里看，形如
> `http://192.168.241.1:801/eportal/...` 中的 `801`。漏掉端口会登录失败。

装完后用内网任意设备验证：

- **TTL**：`ping 223.5.5.5`，回显 TTL 应该恒为设定值（默认 128）
- **UA**：浏览器打开 <http://ua-check.stagoh.com/>，应显示统一后的 UA
- **实测**：手机 + 电脑 + 平板同时上网，观察 24 小时是否掉线

---

## 常用命令

查看在线状态：

```
/usr/bin/campus-auth status
```

手动登录一次：

```
/usr/bin/campus-auth login
```

看日志（登录成功/失败都记在这里）：

```
logread -e campus-auth | tail -n 30
```

检查 UA2F 是否真的在跑（进程 + 防火墙规则，两个都要有输出）：

```
pgrep -f /usr/bin/ua2f && nft list table inet ua2f
```

检查微信 mmtls 放行规则是否在位（两项都要 [OK]）：

```
/etc/campus-mmtls.sh status
```

手动补一次放行规则（规则被 ua2f 重启冲掉时可以这样救急）：

```
/etc/campus-mmtls.sh apply
```

重启保活服务：

```
/etc/init.d/campus-auth restart
```

改配置（账号密码、认证服务器地址等）：

```
vi /etc/campus-net.conf
```

改完重启服务生效。

---

## 卸载

把仓库里的 `uninstall.sh` 拉到路由器执行：

```
wget -O /tmp/cns-uninstall.sh https://raw.githubusercontent.com/<你的用户名>/<仓库名>/main/uninstall.sh && sh /tmp/cns-uninstall.sh
```

拉不动就换通道：

```
wget -O /tmp/cns-uninstall.sh https://gh-proxy.com/https://raw.githubusercontent.com/<你的用户名>/<仓库名>/main/uninstall.sh && sh /tmp/cns-uninstall.sh
```

会移除服务、规则、配置，并恢复流量卸载和 NTP 设置。

---

## FAQ

**Q：手机微信提示「网络连接异常」，其他 App 都正常？**

先做这个判定，30 秒出结果 —— 临时停掉 UA2F：

```
/etc/init.d/ua2f stop
```

然后杀掉微信进程重开，测一下：

- **微信恢复正常** → 就是 UA2F 改坏了 mmtls，见上面的「UA2F 会弄坏微信」一节。
  重装一次脚本即可自动修复；想手动修就执行下面四条（**一次复制一条**）：

```
opkg update && opkg install iptables-nft iptables-mod-filter iptables-mod-conntrack-extra
```

```
/usr/sbin/iptables -t mangle -A PREROUTING -p tcp --dport 80 -m string --string /mmtls/ --algo bm -j CONNMARK --set-mark 43
```

```
nft insert rule inet ua2f postrouting ct mark 0x2b counter return
```

```
/etc/init.d/ua2f start
```

> ⚠️ 第三条不能省。只做前两条是**没用的** —— 见「网上流传的修法是错的」。
> 而且第三条会被「重启 ua2f」冲掉，正式安装脚本用计划任务每分钟补回来；
> 手动敲的这一条重启 ua2f 后就没了。

- **微信还是不正常** → 不是 UA2F 的问题，往下看。

**Q：停掉 UA2F 之后微信仍然异常？**

那说明是校园网侧的限制或本机环境问题，不是本方案引入的。按顺序排查：

1. **关掉 WiFi 用手机流量试**。正常 → 确认是校园网侧的事。
2. **检查路由器时间**：`date`。时间偏差过大会导致 TLS 证书校验失败，而微信对证书
   校验比大多数 App 严格。若路由器 NTP 没同步（本方案会劫持内网 NTP 到路由器自身），
   先把路由器的时间修对。
3. 确认没有代理软件劫持了 80 / 443。
4. 部分校园网会对微信长连接单独限速或阻断。这种情况本方案无法解决，
   只能换手机流量或找网管。

**Q：怎么确认 mmtls 绕过规则真的生效了？**

```
/etc/campus-mmtls.sh status
```

两项都是 `[OK]` 才算生效：

```
  [OK] iptables: mmtls 连接会被打上 connmark 43
  [OK] nft: UA2F 链首已插入放行规则
```

想看得更实在一点，直接看链首那一条的位置：

```
nft list chain inet ua2f postrouting | head -4
```

第一行规则必须是 `ct mark 0x0000002b ... return`，**排在 `tcp dport 80 ... ct mark set 0x2c` 前面**，
否则就是没生效。安装脚本结束时打印的自检里也有一项专门检查它。

**Q：微信好了，但过一阵又坏了 / 重启 ua2f 之后又坏了？**

说明补偿机制没跑起来。三类原因：

1. **计划任务没注册**：`crontab -l | grep campus-mmtls`，没有就重装脚本。
2. **UA2F 换了队列链的名字**：`nft list table inet ua2f` 里如果那条带 `queue` 的链不叫
   `postrouting`，脚本会自动识别，但如果你改过 UA2F 的配置（比如切了 REDIRECT / TPROXY
   模式），可能有别的链在队列，需要看 `status` 的输出。
3. **有别的组件在抢 connmark**：跑 `status` 各项都 OK 但微信仍坏，见下面那条 FAQ。

**Q：装完还是被检测到多设备？**

安装结束时脚本会打印一段「安装结果自检」，**先看那里**，它会直接告诉你哪一环没通，
并自动检测代理组件冲突。要人工核对的话按这个顺序：

**① UA2F 到底跑起来没有** —— 这是最常出问题的一环：

```
pgrep -f /usr/bin/ua2f ; nft list table inet ua2f
```

前者没输出 = 进程没在运行；后者报错 = 防火墙规则没加载。

> 注意：`opkg install ua2f` 装完**默认是停用状态**，包会提示
> `UA2F disabled. You should enable it manually.` —— 上游设计如此，不是装坏了。
> 它的 `/etc/config/ua2f` 里 `enabled` 默认是 `0`，初始化脚本检测到就立刻 `return 1`，
> 连防火墙规则都不会建。脚本会替你打开它。手工修复：

```
uci set ua2f.enabled.enabled=1 && uci commit ua2f && /etc/init.d/ua2f enable && /etc/init.d/ua2f restart
```

**② 确认流量卸载真的关了。** `uci get firewall.@defaults[0].flow_offloading` 应该返回 `0`。
卸载会绕过防火墙和 CPU，UA2F 直接抓不到包。

**③ 确认没有代理软件抢 80/443 端口。** OpenClash / PassWall / ShellCrash 之类会劫持流量
导致 UA2F 失效，测试时先停掉，或在代理规则里放行校园网内网网段。

**④ 检查 connmark 冲突。** UA2F 会给 80 端口打 `connmark 44`、并跳过 `connmark 43` 的流。
如果路由器上跑着 mwan3、QoS 或多线路分流，可能占用相同的连接标记，导致 UA2F 抓不到包。
关掉它的 connmark 逻辑（代价：所有 TCP 都进 NFQUEUE，性能略降但更干净）：

```
uci set ua2f.main.disable_connmark=1 && uci commit ua2f && /etc/init.d/ua2f restart
```

> 注意：这么做会让微信 mmtls 的放行规则同时失效（它依赖 `connmark 43` 这条逃生口）。
> 两者只能二选一。

**⑤ 确认 TTL 规则真的加载了，而且绑对了接口。** 光看到链存在不够 ——
如果 `oifname` 写的是一个不存在的接口名，规则会一直「在」但一条包都不匹配：

```
nft list chain inet fw4 campus_ttl
```

期望输出里必须是**真实的接口名**：

```
    oifname "pppoe-wan" ip ttl set 128
```

> **已知坑：早期版本可能显示 `oifname "auto"`。**
> 那是因为安装时问「WAN 接口名」你填了 `auto`，而旧版脚本把 `auto` 当字面量
> 写进了规则。这条规则不报错、不会被删、自检里「链存在」也照过，
> **但一条包都不匹配，TTL 完全没归一。** 新版已修正（`auto` 会被翻译成探测结果）。
> 如果看到 `"auto"`，重装即可；或手工修：
>
> ```
> sed -i 's/oifname "auto"/oifname "真实WAN口"/' /etc/nftables.d/12-campus-ttl.nft && /etc/init.d/firewall reload
> ```

**⑥ 确认 NTP 劫持绑的是真实内网接口。**

```
nft list chain inet fw4 campus_ntp
```

输出里的 `iifname` 必须是你实际的内网接口（`br-lan`、`lan`、自建网桥名…）。
旧版曾硬编码 `br-lan` / `br-guest`，新版会自动探测，探测不到才退回 `br-lan`。

**⑦ 实测出口 TTL —— 这一步最能说明问题。**

在内网任意设备上：

```
ping 223.5.5.5
```

**判读方法（关键，别搞错）**：`223.5.5.5` 是阿里 DNS，它自己发出时 TTL 是 64，
到你这里经过十来跳，所以**正常会看到 50 上下浮动的值，不会等于 128**。
你要对比的是**路由器侧和内网设备侧是否一致**：

- 在路由器上执行 `ping -c 2 223.5.5.5`，记下 TTL（记为 A）
- 在内网电脑上 ping 同一目标，记下 TTL（记为 B）
- **A 与 B 应当相同**。若 B 比 A 小 1（例如 A=53、B=52），说明 TTL 规则没生效 ——
  差的那 1 就是经过路由器的那一跳

以上都正常还是掉线，说明学校用了更深的检测（时钟偏移 / 行为分析），本方案无法覆盖。

**Q：要不要克隆 MAC / 改 MAC？**

**不需要，而且可能弄坏你的网络。** 先说网关到底靠什么识别多设备：

- **TTL 递减**是最主要的特征。同一台电脑直连和经过路由器转发，报文 TTL 差 1。
  这条靠 TTL 归一解决。
- **MAC 地址在校园网侧根本看不到**。你路由器 WAN 口发出的包，源 MAC 是 WAN 口的，
  内网各设备的 MAC 早就被路由器剥掉了。所以「多设备共享」跟设备 MAC 无关。
- 真正会被用到 MAC 的地方是**认证**：有些学校的 eportal 要求 `wlan_user_mac` 与
  首次认证时一致，否则判定为「换设备」。这种情况下你只需要保证 WAN 口 MAC 稳定，
  而不是去克隆内网某台电脑的 MAC。

**什么情况下才需要考虑改 MAC**：如果学校是**绑定 MAC 认证**（一次认证锁死一个设备），
而你换了路由器，那就要把新路由器的 WAN 口 MAC 改成原来那台电脑的 MAC，让网关认为
还是同一台机器。这属于「换设备后重新绑定」，跟防多终端检测是两件事。

操作方式（在 LuCI 里改更稳：网络 → 接口 → WAN → 高级设置 → 克隆 MAC 地址）。
改之前记下原 MAC，改完 `reboot`。

**不建议照搬网上「克隆成手机 MAC」之类的说法** —— 那类做法通常是为了绕过
「PC 不能连」的限制，跟共享检测无关，反而可能让认证失败。

**Q：Kwrt / ImmortalWrt 这类第三方固件上装不上 UA2F？**

先确认自建源可用：

```
opkg update
```

再看源里有没有 ua2f：

```
opkg list | grep -i ua2f
```

有的话直接装，**不要用官方 ipk** —— 自建源的包与内核模块版本是匹配的：

```
opkg install ua2f
```

源里没有才会退回官方 ipk，此时常见失败原因是缺 `libatomic`（mips/mipsel 平台）
或 `kmod-nft-queue` 与内核版本不匹配。可以先手动补依赖再装：

```
opkg install libatomic kmod-nfnetlink-queue kmod-nft-queue libnetfilter-queue
```

**Q：`opkg install ua2f.ipk` 报依赖缺失？**

手动补依赖再装：

```
opkg update && opkg install libnetfilter-queue kmod-nfnetlink-queue iptables-nft
```

**Q：OpenWrt 25.12 装不上 UA2F？**

apk 环境下脚本走的是「解包 `.ipk` 提取二进制」路径，属于兼容模式。如果失败，
可以考虑降到 24.10 固件（UA2F 有官方构建，最省事）。

**Q：为什么不处理 IPID 检测？**

需要 `kmod-rkp-ipid` 内核模块，通常只能**编译固件时**加入，运行时装不了。
只有在确认学校检测了 IPID 的情况下才值得折腾，编译固件成本较高。

**Q：会影响网速吗？**

会有影响。关闭 NAT 流量卸载后，转发全部走 CPU。百兆宽带感知不明显，
千兆宽带或高并发场景会掉速。这是 UA2F 能工作的前提条件，无法避免。

**Q：`wget` 报 `Unable to establish SSL connection`？**

不是证书问题，是 `raw.githubusercontent.com` 的连接被重置。这不是脚本的锅，任何
GitHub 直链在同样网络下都会这样。三条对策，按省事程度排：

1. **换加速通道拉脚本**（见上面的安装章节，`gh-proxy.com` / `ghproxy.net` 实测可用）
2. 如果只是脚本内部的 UA2F 下载失败：脚本自身已内置多通道轮询，会依次尝试直连、
   `gh-proxy.com`、`ghproxy.net`、`ghfast.top`，还可以指定自己的前缀：

```
export CNS_GH_MIRROR=https://你的加速前缀/ && sh /tmp/cns.sh
```

3. **绕开网络**：在任何能上网的机器上下载好 `.ipk`，`scp` 到路由器手动装：

```
opkg install /tmp/ua2f_xxx.ipk
```

> 顺带一提：如果你用的是 Kwrt / ImmortalWrt 这类固件，源里通常已经有 `ua2f`，
> 直连 GitHub 失败完全不影响安装——脚本第一级就走固件源。

**Q：`luci-app-ua2f` 要不要装？**

可装可不装。它的作用只是给一个网页开关，不装不影响任何功能。安装时加个环境变量即可：

```
export CNS_WITH_LUCI=1 && sh /tmp/cns.sh
```

装完在 LuCI 的「服务 → UA2F」看运行状态。

**Q：密码明文存在路由器上安全吗？**

`/etc/campus-net.conf` 权限是 `600`，只有 root 可读。但确实是明文。
如果路由器多人共用 root，请自行评估。

---

## 文件说明

| 文件 | 作用 |
|---|---|
| `install.sh` | 一键装机：探测环境 → 装 UA2F → 写 TTL/NTP 规则 → 生成认证脚本 → 注册开机自启 → 自检 |
| `uninstall.sh` | 一键还原，恢复到安装前状态 |
| `/etc/campus-net.conf` | 安装后生成的配置（含账号密码） |
| `/usr/bin/campus-auth` | 安装后生成的认证/保活脚本 |
| `/etc/init.d/campus-auth` | 安装后生成的开机自启服务 |
| `/etc/campus-mmtls.sh` | 微信 mmtls 放行规则的唯一执行体，`apply` / `remove` / `status` 三个子命令 |
| `/etc/init.d/campus-mmtls` | `START=99`，开机时在 ua2f 之后把放行规则补回来 |
| `/etc/crontabs/root` | 追加一条 `* * * * *`，运行期 ua2f 被重启时自动补偿放行规则 |

---

## 致谢

- [Zxilly/UA2F](https://github.com/Zxilly/UA2F) — User-Agent 统一的核心实现

## License

MIT
