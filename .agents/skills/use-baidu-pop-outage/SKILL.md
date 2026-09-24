---
name: use-baidu-pop-outage
description: 排查 Kuaicdn node-baidu-pop 流量归零、百度 PoP 注册/签名失败、pop_machine OOM 重启以及关联的主机和网络故障。适用于使用 host network 且挂载 /P2P 与 /storage/0/meta 日志的 Docker 业务容器。
---

# Baidu PoP 故障排查

先诊断，后变更。这类生产节点上，系统时间、百度注册、`pop_machine` 内存和主机可用性相互关联；容器状态为 `Up` 只能说明容器在运行，不能证明业务已注册或已恢复流量。

## 快速路径

1. 先确定流量边界和主机边界：
   - 宿主机 `/data/kuaicdn/bbiz/pop/meta/meta/dump_flow` 与容器内 `/storage/0/meta/dump_flow` 是同一份文件。找出最后一个第 4 个冒号字段非零的记录。
   - 将该时间与 `journalctl --list-boots` 对齐。journal 存在缺口时，说明整机曾不可用，而不只是 Docker 容器异常。
2. 在排查网络前，先检查注册状态和时钟有效性：
   - 在 `pop_machine.log.wf*` 中搜索 `register status not ok`、`check sign error`、`errno":3104`。
   - 将本地 epoch 与百度 HTTP `Date` 头、以及拒绝响应里的 `server_time` 比较；同时查看 `timedatectl show -p NTP -p NTPSynchronized`。
   - 请求中的 `time` 比 `server_time` 快数十秒，且 `NTPSynchronized=no` 时，强烈指向时钟偏差导致签名失败。
3. 检查反复 OOM 模式：
   - 在 journal 中搜索 `Out of memory: Killed process ... (pop_machine)` 和 `task=pop_machine`。
   - 高峰期 `/P2P/crash.log` 中每约 6–10 分钟出现一次 `msg:start pop machine`，与已观察到的 OOM/重启循环一致。
4. 核实网络状态，但不要把所有 socket 现象都当成根因：
   - 确认 `m-ss-*` 接口仍有预期 IP 和默认路由。
   - 本地端口 `18501` 常见形态是 established 连接，不要求一定出现 `LISTEN`。
   - `open /sys/class/net//statistics/...` 和 `seed srv is not running` 可能是注册/状态失败后的伴随错误。时钟和注册问题解决前，先将其视为次要线索。

## 关键日志标识

注册/时钟异常状态：

```text
register status not ok
check sign error
{"errno":3104 ...}
appbw:0.00 ... max_bw:0.00 ... service_count:0 ... status:3
```

恢复/健康状态：

```text
getversion succ ... errno:0
start server succ ... server_status:2
add net info succ ... max_bw:10000.00 ... service_count:1 ... status:2
```

`dump_flow` 重新出现非零 byte count 是流量恢复的直接信号。`add net info` 中的 `appbw`/`net_bw` 可以作为更快的中间观测指标。

## 时间修复与重启

只有在用户明确授权变更后，才修改系统时间或重启业务容器。NTP 可纠正时，不要手动设置任意时间。

1. 在 `/etc/systemd/timesyncd.conf.d/99-baidu-pop-ntp.conf` 配置可达 NTP。站点有指定 NTP 时必须优先使用站点指定值；没有时的参考配置：

   ```ini
   [Time]
   NTP=ntp.aliyun.com ntp1.aliyun.com ntp.tencent.com
   FallbackNTP=cn.pool.ntp.org time.google.com
   ```

2. 重启 `systemd-timesyncd`，要求 `NTPSynchronized=yes`，并验证本地 epoch 与百度 HTTP `Date` 一致。
3. 时间稳定后，才使用优雅超时重启 `node-baidu-pop`。
4. 依次观察 `errno:0`、`server_status:2`、非零 `appbw` 和新的非零 `dump_flow` 记录。至少继续观察 15 分钟，因为历史 OOM 循环约 7–8 分钟就可能杀死 `pop_machine`。

## OOM 缓解

Docker 内存限制可以保护宿主机，但不能治愈业务进程泄漏。若 `pop_machine` 在 62 GiB 主机上反复达到约 57–59 GiB anonymous RSS，应升级给业务负责人，或执行运营方批准的修复：升级/降级实际运行二进制、降低负载（`n-max-bw` 或实例数）、引入受控重启和监控。务必记录 `/P2P/peer.version`；更新器可能替换二进制，实际版本可能与镜像 tag 不同。

详细命令、路径、日志格式、判定标准和修复后观察要求见 `references/runbook.md`。不要对多 GB 的 PoP 日志做宽泛 `cat`；使用精确 `grep`、`tail` 和时间窗口。
