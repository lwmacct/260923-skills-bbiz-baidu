# node-baidu-pop 故障排查手册

本手册沉淀 Kuaicdn 裸金属节点上的非显而易见路径和故障特征。使用时替换 SSH 目标、接口后缀、IP 和时间窗口。除 Docker 明确输出 UTC 外，业务日志和示例均按宿主机本地时间理解。

## 基本约束

- 这是生产业务排查：先收集只读证据，再请求授权执行时间修改、容器重启、版本切换等变更。
- 不要因为容器 `Up`、进程存在、网卡有 IP，就判断业务已恢复；必须看到注册成功和流量恢复信号。
- 不要整文件读取 `pop_machine.log*`，这些日志可能达到 GB 级。始终限定时间窗口并使用 `grep`/`tail`。
- 日志里的原始错误标识保持英文原文；不要翻译这些标识，否则会破坏搜索和匹配。

## 路径和进程事实

宿主机元数据路径：

```text
/data/kuaicdn/bbiz/pop/meta/meta
```

`node-baidu-pop` 容器内等价路径：

```text
/storage/0/meta
```

常用文件：

```text
/data/kuaicdn/bbiz/pop/meta/meta/dump_flow
/data/kuaicdn/bbiz/pop/meta/meta/log/pop_machine.log
/data/kuaicdn/bbiz/pop/meta/meta/log/pop_machine.log.wf
/data/kuaicdn/bbiz/pop/meta/meta/log/pop_machine.log.YYYYMMDDHH
/data/kuaicdn/bbiz/pop/meta/meta/config/online_conf.toml

容器内:/P2P/crash.log
容器内:/P2P/peer.version
容器内:/P2P/log/update.log
容器内:/P2P/log/update.log.wf
```

正常业务进程参数：

```text
./pop_machine -product=18 -supplier=bendian -netnames=m-ss- \
  -n-max-bw=10000 -write-flow=2 -upnp-control=5 \
  -congestion-control=bbr -bind-port=18501
```

接口名有动态后缀，例如 `m-ss-e3fa469d3c`。应按 `m-ss-` 前缀匹配，不要假设后缀固定。

## 初始只读取证

将 `:ipmi-<device-id>` 替换为用户提供的 SSH 目标：

```bash
ssh -o BatchMode=yes ':ipmi-<device-id>' '
  date "+%F %T %z epoch=%s"
  uptime
  hostname
  journalctl --list-boots --no-pager | tail -n 5
  docker ps -a --filter name=node-baidu-pop --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
  docker inspect node-baidu-pop --format "Started={{.State.StartedAt}} Status={{.State.Status}} OOM={{.State.OOMKilled}} RestartCount={{.RestartCount}} Memory={{.HostConfig.Memory}} Network={{.HostConfig.NetworkMode}}"
  docker top node-baidu-pop -eo pid,ppid,stat,pcpu,pmem,nlwp,etime,args
'
```

定位流量归零边界：

```bash
ssh -o BatchMode=yes ':ipmi-<device-id>' '
  _meta_dir=/data/kuaicdn/bbiz/pop/meta/meta
  echo "=== nearby traffic records ==="
  cut -d: -f1,4,5 "$_meta_dir/dump_flow" | tail -n 30
  echo "=== latest nonzero ==="
  tac "$_meta_dir/dump_flow" | awk -F: "\$4+0 > 0 {print; exit}"
'
```

字段解释：

```text
时间:设备UUID:peer_id:bytes:ratio:hash
```

判定：

- 长时间 `bytes=0` 的起点就是流量归零边界；上一条非零记录用于限定故障发生时间。
- 如果 journal boot 缺口覆盖该边界，说明整机曾宕机、断电或卡死。普通容器重启不会产生 boot 缺口。
- 宿主机重启后即使容器自动拉起，也可能因时钟偏差无法注册，仍会维持 0 流量。

## 注册失败与时钟分支

查看当前 PoP 注册和调度状态：

```bash
ssh -o BatchMode=yes ':ipmi-<device-id>' '
  _meta_dir=/data/kuaicdn/bbiz/pop/meta/meta
  echo "=== current net info ==="
  grep -F "add net info succ" "$_meta_dir/log/pop_machine.log" | tail -n 12
  echo "=== rejected registrations ==="
  grep -E "register status not ok|check sign error|errno.:3104" \
    "$_meta_dir/log/pop_machine.log.wf" | tail -n 30
  echo "=== updater result ==="
  docker exec node-baidu-pop sh -c \
    "tail -n 30 /P2P/log/update.log; echo ---wf---; tail -n 30 /P2P/log/update.log.wf"
'
```

时钟异常特征：

```text
[msg:register status not ok] [status:400]
[body:{"errno":3104, ... "show_msg":"check sign error"}]

request URL: ...time=1789444150...
response body: ...server_time":1789444123...
```

上述示例中，请求时间比百度服务端时间快 27 秒。同一偏差通常也会体现在百度 HTTP `Date` 头。伴随状态：

```text
[appbw:0.00] [net_bw:0.0x] [max_bw:0.00] [service_count:0] [status:3]
```

检查 NTP 和独立服务端时间：

```bash
ssh -o BatchMode=yes ':ipmi-<device-id>' '
  echo "=== timedatectl ==="
  timedatectl
  timedatectl show -p NTP -p NTPSynchronized -p TimeUTC
  journalctl -u systemd-timesyncd --since "-6 hours" --no-pager | tail -n 100

  echo "=== compare with Baidu HTTP Date ==="
  _header=$(curl -sS -I --max-time 5 http://p2p.pcsnetwork.netdisk.baidu.com/ |
    tr -d "\r" |
    awk -F": " "tolower(\$1)==\"date\" {print \$2}")
  _remote_epoch=$(date -u -d "$_header" +%s)
  _local_epoch=$(date +%s)
  echo "remote=$_remote_epoch local=$_local_epoch skew_seconds=$(( _local_epoch - _remote_epoch )) header=$_header"
'
```

不要只看 `date`，也不要把 `NTP service: active` 等同于时钟正确。`active` 只说明服务在运行；必须结合 `NTPSynchronized=yes` 和独立服务端时间比对。

## 授权后的时钟修复

优先使用 NTP，不要直接 `date -s`。仅在用户明确授权变更后执行：

```bash
ssh -o BatchMode=yes ':ipmi-<device-id>' '
  install -d -m 0755 /etc/systemd/timesyncd.conf.d
  cat > /etc/systemd/timesyncd.conf.d/99-baidu-pop-ntp.conf <<EOF
[Time]
NTP=ntp.aliyun.com ntp1.aliyun.com ntp.tencent.com
FallbackNTP=cn.pool.ntp.org time.google.com
EOF
  chmod 0644 /etc/systemd/timesyncd.conf.d/99-baidu-pop-ntp.conf
  systemctl restart systemd-timesyncd.service
  sleep 20
  timedatectl show -p NTP -p NTPSynchronized -p TimeUTC
  journalctl -u systemd-timesyncd --since "-2 min" --no-pager
'
```

如果站点有指定 NTP，必须替换为站点指定服务器。重启业务前再次验证时间偏差已经消失。

## 授权后的业务重启

只有在时钟已同步后，才经授权重启业务：

```bash
ssh -o BatchMode=yes ':ipmi-<device-id>' '
  docker restart --time 30 node-baidu-pop
  docker ps --filter name=node-baidu-pop --format "{{.Names}} {{.Status}}"
'
```

恢复标识通常按以下顺序出现：

```text
getversion succ ... [errno:0]
msg:start pop machine ... version:...
msg:start server succ ... [server_status:2]
msg:add net info succ ... [appbw:>0] [max_bw:10000.00] [service_count:1] [status:2]
```

随后必须确认新的 `dump_flow` 记录 byte 字段非零。参考事故中，`appbw` 在数分钟内从 696 升至 4000+ Mbps，`dump_flow` 出现数百亿级别非零字节记录。

## OOM 与重启循环分支

检索内核和 systemd 日志：

```bash
ssh -o BatchMode=yes ':ipmi-<device-id>' '
  journalctl --since "YYYY-MM-DD 00:00:00" --no-pager |
    grep -E "Out of memory: Killed process .*pop_machine|task=pop_machine|A process of this unit has been killed by the OOM killer" |
    tail -n 100
'
```

已观察到的 OOM 特征：

```text
Out of memory: Killed process ... (pop_machine)
total-vm: 80-104 GB
anon-rss: approximately 56-59 GB
```

参考主机约 62 GiB RAM、无 swap、容器无内存限制。同一时期 `/P2P/crash.log` 每 6–10 分钟出现一次新的 `msg:start pop machine`。

按小时统计进程启动次数：

```bash
ssh -o BatchMode=yes ':ipmi-<device-id>' '
  docker exec node-baidu-pop sh -c \
    "grep \"msg:start pop machine\" /P2P/crash.log" |
  awk "{print \$1, substr(\$2,1,2)}" | uniq -c
'
```

核对实际运行版本与镜像版本：

```bash
ssh -o BatchMode=yes ':ipmi-<device-id>' '
  docker image inspect 250218-bbiz-baidu-pop:v4.2.3.1-t2605180 --format "{{.Id}}" 2>/dev/null || true
  docker exec node-baidu-pop sh -c "cat /P2P/peer.version; ls -l /P2P/pop_machine"
'
```

镜像 tag 可能是 `4.2.3.1`，而 `/P2P/peer.version` 实际为 `4.2.4.4`。降级或升级必须使用运营方批准的包和更新机制，不要手工替换生产二进制。

缓解选项：

1. 业务版本修复/降级，或直接升级给供应商和业务负责人。
2. 降低 `n-max-bw`、存储实例数或调度负载。
3. 在 RSS 达到主机危险阈值前增加受控重启和监控。
4. 仅为了保护宿主机时增加容器内存限制；进程达到较低限制后仍会被杀死，这不是根治方案。

## 主机、网络与次要错误检查

主机可用性：

```bash
journalctl --list-boots --no-pager
journalctl -b -1 --since "YYYY-MM-DD HH:MM" --no-pager | tail -n 200
```

上一轮 boot 没有正常 systemd shutdown 记录就突然结束，数小时后才有新 boot，表示硬宕机、断电或系统卡死。`ipmitool sel list` 可能为空，或只显示 `Event Logging Disabled`；不能因为缺少 SEL 事件就推断硬件正常。

网络与路由：

```bash
ip -br addr
ip rule
ip route show table all
ss -s
ss -tunp | grep "pop_machine" | head -n 30
```

预期路由应经过 `m-ss-*` 接口。本地端口 `18501` 出现 established 连接是正常现象；没有 `LISTEN 18501` 本身不能判定为故障。

注册失败后出现过的次要告警：

```text
open /sys/class/net//statistics/rx_bytes: no such file or directory
open /sys/class/net//statistics/tx_bytes: no such file or directory
seed srv is not running
```

这些告警在注册失败前未出现，失败后随状态异常大量出现。时钟修复且注册成功后再复查；如果它们与 `service_count:1`、真实流量同时持续存在，再单独排查。

## 修复后观察与结论

至少观察 15 分钟，每隔数分钟确认：

```text
timedatectl: NTPSynchronized=yes
container: still running, no new pop_machine OOM
pop_machine.log: service_count:1 status:2 and nonzero appbw
dump_flow: new nonzero bytes
```

进程存活超过历史 7–8 分钟 OOM 间隔是有价值的证据，但不能证明内存泄漏已根治。继续在高峰流量下观察 RSS 和版本行为，并保留相关 `crash.log`、`pop_machine.log.wf*`、`update.log.wf*` 和 journal 片段，供业务方或供应商分析。

结论必须区分三类状态：

1. **时钟/注册已恢复**：`errno:0`、`server_status:2`、`status:2`。
2. **业务流量已恢复**：非零 `appbw`，且新的 `dump_flow` bytes 非零。
3. **仍有稳定性风险**：时间与注册正常，但 `pop_machine` RSS 持续异常增长或再次 OOM。
