# AllowCN

> 一键部署「仅允许中国大陆访问」的防火墙规则。基于 [P3TERX/GeoLite.mmdb](https://github.com/P3TERX/GeoLite.mmdb) 的 GeoLite2 数据，用 `iptables` + `ipset` 在网络层放行大陆 IP、丢弃其它来源，并通过 cron 定期自动更新。

## 特性

- **精准大陆**:只放行 ISO 国家码 `CN`,自动排除香港(HK)、澳门(MO)、台湾(TW)。
- **网络层拦截**:`ipset` 存放数千条大陆网段,`iptables` 单条规则匹配,性能高。
- **原子更新**:用 `ipset swap` 热切换,更新期间不断流、不留空窗。
- **IPv4 + IPv6**:同时处理 `iptables` 与 `ip6tables`。
- **自动定期更新**:cron 每天拉取最新 mmdb;`@reboot` 重启后自动重建规则(规则/ipset 默认不持久,靠此保证重启仍生效)。
- **防自锁**:默认只保护 `80,443`,**不碰 SSH(22)**;支持 `ALLOW_EXTRA` 永久放行你的管理 IP;更新前有网段数量下限校验,mmdb 异常时拒绝应用。

## 工作原理

```
cron ──> allowcn.sh
           │  1. 下载最新 GeoLite2-Country.mmdb (P3TERX download 分支)
           │  2. mmdb_to_cidr.py 提取 iso_code==CN 的网段 -> cn_ipv4.txt / cn_ipv6.txt
           │  3. ipset restore 原子灌入 allowcn4 / allowcn6
           └> 4. iptables 在受保护端口上: 命中集合 ACCEPT, 否则 DROP
```

`iptables` 链 `ALLOWCN` 的判定顺序:`lo 回环放行` → `已建立连接放行` → `源 IP 在大陆集合内 ACCEPT` → `其余 DROP`。只有配置里 `PROTECT_*_PORTS` 指定的端口会被送进该链,其它端口(含 SSH)完全不受影响。

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

选 **1 安装** 时会引导你设置:保护端口、自动更新周期,并**自动检测你的 SSH 来源 IP 询问是否加入白名单**,从源头避免把自己锁在门外。

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
sudo ./install.sh                        # 默认每天 04:30 更新,保护 80,443
sudo ./install.sh --schedule "0 3 * * *" # 自定义 cron 周期
sudo ./install.sh --no-run               # 只安装,暂不应用
```

## 配置

配置文件在 `/etc/allowcn/allowcn.conf`,改完执行 `sudo allowcn` 立即生效:

| 变量 | 默认 | 说明 |
|------|------|------|
| `PROTECT_ALL_PORTS` | `0` | 设为 `1` 时**整机所有端口**仅放行大陆(含 SSH),覆盖下面的端口设置。⚠ 开启前务必在 `ALLOW_EXTRA` 填好你的管理 IP,否则下次登录即被锁死。 |
| `PROTECT_TCP_PORTS` | `80,443` | `PROTECT_ALL_PORTS=0` 时生效:只允许大陆访问的 TCP 端口,逗号分隔。**不要把 22 放进来**,除非你确定永远从大陆 IP 登录。 |
| `PROTECT_UDP_PORTS` | 空 | 需要保护的 UDP 端口(如 QUIC 用 `443`)。 |
| `BLOCK_ACTION` | `DROP` | 拦截动作:`DROP`(静默丢弃)或 `REJECT`(返回拒绝)。 |
| `ENABLE_IPV6` | `1` | 是否同时对 IPv6 生效。 |
| `ALLOW_EXTRA` | 空 | 无视地理位置永久放行的网段(空格分隔,v4/v6 皆可),用于保住你的管理入口。 |
| `MIN_CN_V4` | `1000` | 安全下限:提取到的大陆 IPv4 网段少于此值则中止,防止坏数据清空白名单。 |

> ⚠️ **务必先设置 `ALLOW_EXTRA` 放行你自己的出口 IP**,再考虑把管理相关端口纳入保护,避免把自己锁在外面。

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
