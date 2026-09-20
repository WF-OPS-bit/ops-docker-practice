# 终端截图目录

存放验证过程的终端截图。所有截图均为真实终端输出，未经绘图工具重制。

| 文件 | 内容 |
|---|---|
| `01-compose-ps-and-check-sh-pass.png` | **项目二**：`docker compose ps` 服务状态 + `bash scripts/check.sh` 五项验证全 PASS |
| `02-project3-sentinels-and-topology.png` | **项目三**：三哨兵集群就绪，三个哨兵认定的主节点一致，`num-other-sentinels = 2` |
| `03-project3-failover-before-after.png` | **项目三**：故障转移前后 `get-master-addr-by-name` 对比（`172.22.0.5` → `172.22.0.10`） |
| `04-project3-failover-log.png` | **项目三**：哨兵完整故障转移日志，含 `+sdown` / `+odown #quorum 2/2` / `+switch-master` |

## 待补充

- 项目三的 `SHOW REPLICA STATUS` 双 Yes + GTID 集合截图（该输出已完整记录在项目三 README 第 6.1 节，但暂缺截图）
- 主库写入、两个从库查询的对比截图
