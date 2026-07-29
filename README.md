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

## 安装

需要 root 的 Linux 服务器(Debian/Ubuntu、RHEL/CentOS/Rocky、Alpine 均可)。安装脚本会自动装 `ipset`、`iptables`、`python3`、`maxminddb`。

```bash
git clone https://github.com/arieeses/AllowCN.git
cd AllowCN
sudo ./install.sh
```

自定义更新时间(cron 表达式,默认每天 04:30):

```bash
sudo ./install.sh --schedule "0 3 * * *"
```

只安装、暂不应用规则:

```bash
sudo ./install.sh --no-run
```

## 配置

配置文件在 `/etc/allowcn/allowcn.conf`,改完执行 `sudo allowcn` 立即生效:

| 变量 | 默认 | 说明 |
|------|------|------|
| `PROTECT_TCP_PORTS` | `80,443` | 只允许大陆访问的 TCP 端口,逗号分隔。**不要把 22 放进来**,除非你确定永远从大陆 IP 登录。 |
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
