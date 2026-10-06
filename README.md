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
| 24.10.x | opkg | fw4 (nftables) | `24.10.0` 构建 | **推荐，已实测路径** |
| 25.12+ | apk | fw4 (nftables) | 无官方 apk 包，脚本走「解包二进制」兼容模式 | 实验性 |
| 21.02 及更早 | opkg | fw3 (iptables) | 无 | 不保证 |

架构方面，脚本直接读取 OpenWrt 的 `DISTRIB_ARCH`（如 `aarch64_cortex-a53`、`mipsel_24kc`、`x86_64`）去匹配 UA2F 的 release 资源，**无需手动选择**。

> OpenWrt 25.12 起包管理器从 opkg 换成了 apk，`.ipk` 无法直接安装。脚本会自动识别并改用解包提取二进制的方式，但仍可能出现依赖不匹配，遇到问题见下面的 FAQ。

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

**Q：下载 UA2F 卡住或超时？**

脚本会先走 GitHub 直链，失败后自动改用 GitHub API 解析真实地址。如果两条都不通，
可以设置加速前缀后再跑安装（自行选择可信的加速服务）：

```
export CNS_GH_MIRROR=https://ghfast.top && sh /tmp/cns.sh
```

也可以在任何能上网的机器上下载对应的 `.ipk`，`scp` 到路由器后手动装：

```
opkg install /tmp/ua2f_xxx.ipk
```

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
