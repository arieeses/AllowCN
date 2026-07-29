# AllowCN

> 一键部署「仅允许中国大陆访问」的防火墙规则。基于 [P3TERX/GeoLite.mmdb](https://github.com/P3TERX/GeoLite.mmdb) 的 GeoLite2 数据，用 `iptables` + `ipset` 在网络层放行大陆 IP、丢弃其它来源，并通过 cron 定期自动更新。

## 特性

- **精准大陆**:只放行 ISO 国家码 `CN`,自动排除香港(HK)、澳门(MO)、台湾(TW)。
- **网络层拦截**:`ipset` 存放数千条大陆网段,`iptables` 单条规则匹配,性能高。
- **原子更新**:用 `ipset swap` 热切换,更新期间不断流、不留空窗。
- **IPv4 + IPv6**:同时处理 `iptables` 与 `ip6tables`。
- **自动定期更新**:cron 每天拉取最新 mmdb;`@reboot` 重启后自动重建规则(规则/ipset 默认不持久,靠此保证重启仍生效)。
- **防自锁**:整机仅大陆的同时,**SSH 端口始终对所有来源开放**(`ALWAYS_OPEN_TCP_PORTS`,默认 22,安装时自动探测你的实际端口);安装器还会**自动把当前来源 IP 加入白名单**;`ALLOW_EXTRA` 可永久放行任意管理 IP;更新前有网段数量下限校验,mmdb 异常时拒绝应用。

## 工作原理

```
cron ──> allowcn.sh
           │  1. 下载最新 GeoLite2-Country.mmdb (P3TERX download 分支)
           │  2. mmdb_to_cidr.py 提取 iso_code==CN 的网段 -> cn_ipv4.txt / cn_ipv6.txt
           │  3. ipset restore 原子灌入 allowcn4 / allowcn6
           └> 4. iptables 全量拦截入站: 命中集合 ACCEPT, 否则 DROP
```

`iptables` 链 `ALLOWCN` 的判定顺序:`lo 回环放行` → `已建立连接放行` → `无条件放行端口(默认 22/SSH)ACCEPT` → `源 IP 在大陆集合内 ACCEPT` → `其余 DROP`。**所有入站流量、所有端口**都过此链,只放行中国大陆;唯独 `ALWAYS_OPEN_TCP_PORTS`(默认 22/SSH)对任何来源始终放行,因此永不会因规则把 SSH 锁死。

## 快速开始(交互式菜单)

需要 root 的 Linux 服务器(Debian/Ubuntu、RHEL/CentOS/Rocky、Alpine 均可)。一条命令拉起菜单,自动装依赖(`ipset`、`iptables`、`python3`、`maxminddb`):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/arieeses/AllowCN/main/menu.sh)
```

菜单长这样:

```
╔══════════════════════════════════════════════╗
║   AllowCN — 仅允许中国大陆访问的防火墙        ║
║   数据源: P3TERX/GeoLite.mmdb · iptables+ipset ║
╚══════════════════════════════════════════════╝
   状态: 未安装    配置: /etc/allowcn/allowcn.conf

   1) 安装 / 重装
   2) 立即更新 IP 数据并应用规则
   3) 修改配置(端口 / 白名单 / 拦截动作)
   4) 更改自动更新周期
   5) 查看运行状态
   6) 暂停规则(保留安装)
   7) 网络内核优化(BBR/调优/多队列,一键全开)
   8) 卸载
   0) 退出
```

规则固定为:**整机所有端口仅大陆可访问,SSH 端口对所有来源开放**。选 **1 安装** 时会自动探测你的 SSH 端口(默认 22)保持全球可达、把当前来源 IP 加入白名单,并让你设置自动更新周期——从源头避免把自己锁在门外。

也可以先克隆再运行菜单:

```bash
git clone https://github.com/arieeses/AllowCN.git
cd AllowCN && sudo ./menu.sh
```

## 网络内核优化(集成 tcp-dashboard 的调优)

菜单 **7) 网络内核优化** 提供「一键开启所有」的内核网络调优,效果等价于 [tcp-dashboard](https://github.com/666shen/tcp-dashboard) 的全部优化项,但为**原生、可审计、非交互**的实现——不在运行时从任何远端域名拉取脚本执行:

- **IPv4 优先解析**(`gai.conf`)—— 解决 IPv6 绕路导致的握手卡顿
- **BBR + FQ 拥塞控制**
- **生产级 sysctl / ulimit 调优**—— 缓冲区按内存 5% 动态分配、6w+ 并发、开启 ECN、MTU 探测、TFO、MSS Clamp 等
- **网卡多队列(RPS/RFS)**—— 把软中断平摊到所有 CPU 核心

命令行也可直接用:

```bash
sudo /usr/local/lib/allowcn/netopt.sh enable-all   # 一键全开
sudo /usr/local/lib/allowcn/netopt.sh status       # 查看状态
sudo /usr/local/lib/allowcn/netopt.sh rollback     # 一键回退到内核默认
```

> 说明:所有参数均为标准 Linux 内核项,已逐条审阅。原项目 GitHub 上的 `tcp.sh` 仅是引导器、真正逻辑运行时从第三方域名下载执行,出于安全考虑本项目改为等效的原生实现并致谢原作者。若你需要官方交互面板做精细调节,仍可自行运行 `bash <(curl -sL https://raw.githubusercontent.com/666shen/tcp-dashboard/main/tcp.sh)`。`sudo ./uninstall.sh --purge` 会连同这些内核优化一并回退。

## 无人值守 / 脚本化安装

不想走菜单、想直接一把装好并应用规则:

```bash
git clone https://github.com/arieeses/AllowCN.git
cd AllowCN
sudo ./install.sh                        # 默认:全端口仅大陆 + 每天 04:30 更新
                                         # (自动把当前 SSH 来源 IP 加入白名单兜底)
sudo ./install.sh --schedule "0 3 * * *" # 自定义 cron 周期
sudo ./install.sh --no-run               # 只安装,暂不应用
```

## 配置

配置文件在 `/etc/allowcn/allowcn.conf`,改完执行 `sudo allowcn` 立即生效:

| 变量 | 默认 | 说明 |
|------|------|------|
| `ALWAYS_OPEN_TCP_PORTS` | `22` | **无条件对所有来源开放**的 TCP 端口,豁免大陆限制。默认放行 SSH(22),永不锁死。SSH 在非标准端口就改成对应端口(如 `22,2222`);留空则无豁免(不建议)。安装器会自动把你当前的 SSH 端口并入此项。 |
| `BLOCK_ACTION` | `DROP` | 拦截动作:`DROP`(静默丢弃)或 `REJECT`(返回拒绝)。 |
| `ENABLE_IPV6` | `1` | 是否同时对 IPv6 生效。 |
| `ALLOW_EXTRA` | 空 | 无视地理位置永久放行的网段(空格分隔,v4/v6 皆可),用于保住你的管理入口。 |
| `MIN_CN_V4` | `1000` | 安全下限:提取到的大陆 IPv4 网段少于此值则中止,防止坏数据清空白名单。 |

> ⚠️ 默认 `ALWAYS_OPEN_TCP_PORTS=22` 已保证 SSH 全球可达,不会锁死。若你的 SSH 端口不是 22,安装器会自动探测并并入;手动改配置时也请确认它包含你的 SSH 端口。

## 常用命令

```bash
sudo allowcn                 # 立即完整更新(下载+提取+应用)
sudo allowcn --no-download   # 用本地已有 mmdb 重新提取并应用
sudo allowcn --reload-only   # 仅用缓存网段重建规则(最快,@reboot 用)
sudo ipset list allowcn4     # 查看当前生效的大陆 IPv4 集合
sudo iptables -L ALLOWCN -n  # 查看判定链
tail -f /var/log/allowcn.log # 看运行日志
```

## 卸载

```bash
sudo ./uninstall.sh          # 移除规则/ipset/cron/程序,保留数据
sudo ./uninstall.sh --purge  # 连缓存数据、配置和日志一并删除
```

## 注意事项

- **持久化**:`iptables`/`ipset` 规则重启后默认丢失。本项目用 cron 的 `@reboot` 自动重建,无需额外的 `netfilter-persistent`。若你已用其它持久化方案,可自行调整。
- **仅在网络层**:这是 L3/L4 的来源 IP 过滤,不解析应用层。CDN / 反代后面的真实来源会被源 IP 掩盖,此时应在最外层入口部署,或改用应用层方案。
- **GeoIP 精度**:GeoLite2 是免费库,存在少量误判;上游每天更新,本项目跟随更新。
- **数据许可**:IP 数据版权归 MaxMind,遵循 GeoLite2 EULA 与 CC BY-SA 4.0。本项目运行时从上游拉取,不再分发数据库文件。

## 许可

代码以 [MIT](LICENSE) 许可发布。
