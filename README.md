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

**Q：装完还是被检测到多设备？**

按顺序排查：

1. 确认流量卸载真的关了。`uci get firewall.@defaults[0].flow_offloading` 应该返回 `0`。
   卸载会绕过防火墙和 CPU，UA2F 直接抓不到包。
2. 确认没有代理软件抢 80/443 端口。OpenClash / PassWall / ShellCrash 之类会劫持流量导致 UA2F 失效，
   测试时先停掉，或在代理规则里放行校园网内网网段。
3. 用 `nft list ruleset | grep -A 4 campus_ttl` 确认 TTL 规则真的加载了。
4. 如果以上都对还是掉线，说明学校用了更深的检测（时钟偏移 / 行为分析），本方案无法覆盖。

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
| `install.sh` | 一键装机：探测环境 → 装 UA2F → 写 TTL/NTP 规则 → 生成认证脚本 → 注册开机自启 |
| `uninstall.sh` | 一键还原，恢复到安装前状态 |
| `/etc/campus-net.conf` | 安装后生成的配置（含账号密码） |
| `/usr/bin/campus-auth` | 安装后生成的认证/保活脚本 |
| `/etc/init.d/campus-auth` | 安装后生成的开机自启服务 |

---

## 致谢

- [Zxilly/UA2F](https://github.com/Zxilly/UA2F) — User-Agent 统一的核心实现

## License

MIT
