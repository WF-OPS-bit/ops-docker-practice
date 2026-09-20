# 项目三：MySQL GTID 一主两从 + Redis 一主两从三哨兵

用 Docker Compose 编排 **MySQL 8 GTID 主从集群**与 **Redis 7 哨兵高可用集群**，并验证数据同步、从库只读、哨兵自动故障转移。

---

## 1. 这个项目解决什么问题

| 要解决的 | 做法 |
|---|---|
| 单库挂了数据就没了 | MySQL 一主两从，binlog + GTID 做异步复制 |
| 复制位点难维护 | 用 GTID：`SOURCE_AUTO_POSITION=1` 让从库自动定位同步点 |
| 缓存层单点 | Redis 一主两从，三个哨兵监控主节点 |
| 主节点宕机要人工介入 | 哨兵自动完成选主与切换（**仅 Redis，MySQL 不支持**） |

---

## 2. 架构图

```
         ┌──────────────────────────────────────────────┐
         │            MySQL 8：GTID 一主两从              │
         └──────────────────────────────────────────────┘

                      ┌───────────────────┐
                      │   mysql-master    │
                      │   server-id = 1   │
                      │   binlog (ROW)    │
                      │   gtid_mode = ON  │
                      └─────────┬─────────┘
                                │ GTID 异步复制
                     ┌──────────┴──────────┐
                     │                     │
            ┌────────▼────────┐   ┌────────▼────────┐
            │  mysql-slave1   │   │  mysql-slave2   │
            │  server-id = 2  │   │  server-id = 3  │
            │  read_only = ON │   │  read_only = ON │
            └─────────────────┘   └─────────────────┘

         ┌──────────────────────────────────────────────┐
         │      Redis 7：一主两从 + 三节点哨兵            │
         └──────────────────────────────────────────────┘

                      ┌───────────────────┐
                      │   redis-master    │◀──── 监控 ────┐
                      │      :6379        │               │
                      └─────────┬─────────┘               │
                                │ 主从复制                 │
                     ┌──────────┴──────────┐              │
                     │                     │              │
            ┌────────▼────────┐   ┌────────▼────────┐     │
            │  redis-slave1   │   │  redis-slave2   │     │
            │ replicaof master│   │ replicaof master│     │
            └─────────────────┘   └─────────────────┘     │
                                                           │
        ┌─────────────────────────────────────────────────┴┐
        │  sentinel1    sentinel2    sentinel3   (:26379)  │
        │  quorum = 2：单个哨兵判定主观下线后，需再获 1 票   │
        │  才判定客观下线并触发故障转移                      │
        └──────────────────────────────────────────────────┘
```

**两套集群的可靠性边界不一样**——MySQL 这套只是"数据有副本"，故障转移要人工；Redis 这套哨兵会自动切主。这点在"已知局限"里展开。

---

## 3. 环境

| 组件 | 版本 |
|---|---|
| OS | CentOS 7 Core（与项目二同一台机器） |
| Docker Engine | 26.1.4 |
| Docker Compose | v2.27.1 |
| MySQL | 8.0 |
| Redis | 7-alpine |

---

## 4. 目录结构

```
project3-mysql-redis-ha/
├── README.md
├── .env.example
├── .gitignore
├── docker-compose.yml
├── mysql/
│   ├── master.cnf          # server-id = 1
│   ├── slave1.cnf          # server-id = 2
│   └── slave2.cnf          # server-id = 3  ← 必须用独立文件，原因见踩坑 7.1
├── redis/
│   ├── redis-master.conf   # 不含密码，密码走启动参数
│   ├── redis-slave.conf    # 同上，多一行 replicaof
│   └── sentinel.conf       # 模板，运行时复制到容器可写层
└── scripts/
    ├── init-replication.sh   # 一键建立 MySQL 主从
    ├── check-replication.sh  # 检查复制状态
    └── check-sentinel.sh     # 检查哨兵与拓扑
```

---

## 5. 快速开始

### ⚠️ 先停掉项目二

本项目要起 **9 个容器**，其中 3 个是 MySQL。你的机器是 3.7G 内存，两套项目同时跑会 OOM。

```bash
cd /root/ops-docker-practice/project2-compose-nginx
docker compose stop
```

（如果还想再省 470MB，可以停掉系统里那个原生安装的 MySQL：`systemctl stop mysqld`。）

### 启动项目三

```bash
cd /root/ops-docker-practice/project3-mysql-redis-ha

cp .env.example .env
cat > .env <<'EOF'
MYSQL_ROOT_PASSWORD=RootPwd2026abc
REPL_PASSWORD=ReplPwd2026abc
REDIS_PASSWORD=RedisPwd2026abc
EOF

docker compose config --quiet && echo "配置 OK"    # 不应有任何 WARN
docker compose up -d
docker compose ps
```

MySQL 首次初始化较慢，等 1~2 分钟再看状态。9 个容器里，6 个定义了健康检查（3 个 MySQL + 1 个 redis-master），哨兵和 Redis 从节点没有配置 healthcheck（它们的可用性由哨兵机制本身保证）。

### 建立 MySQL 主从

**容器起来 ≠ 主从已建立**。复制关系要用脚本显式建立：

```bash
bash scripts/init-replication.sh
```

---

## 6. 验证

### 6.1 MySQL 复制状态

```bash
bash scripts/check-replication.sh
```

期望两个从库都显示：

```
Replica_IO_Running:  Yes
Replica_SQL_Running: Yes
Retrieved_Gtid_Set:  <非空>
Executed_Gtid_Set:   <非空>
```

<!-- TODO(实机跑完后补)：把真实的 SHOW REPLICA STATUS 输出贴到这里 -->

### 6.2 数据同步

```bash
# 主库写入
docker compose exec -T mysql-master mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e \
  "CREATE DATABASE IF NOT EXISTS ha_demo;
   CREATE TABLE IF NOT EXISTS ha_demo.t(id INT PRIMARY KEY, v VARCHAR(20));
   INSERT INTO ha_demo.t VALUES(1,'hello-gtid') ON DUPLICATE KEY UPDATE v='hello-gtid';"

# 两个从库分别查询
for s in mysql-slave1 mysql-slave2; do
  echo "--- $s ---"
  docker compose exec -T "$s" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B -e "SELECT * FROM ha_demo.t;"
done
```

两个从库都能查到 `hello-gtid` 即 GTID 复制通了。

<!-- TODO(实机跑完后补)：贴主库写入 + 两个从库查询的完整输出 -->

### 6.3 从库只读

```bash
docker compose exec -T mysql-slave1 mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e \
  "SELECT @@read_only, @@super_read_only;"
```

期望 `read_only = 1`。注意 **root 有 SUPER 权限，仍然能写**——这是刻意保留的，方便验证；生产环境应再加 `super_read_only = ON`。

### 6.4 Redis 哨兵与故障转移

先看当前状态：

```bash
bash scripts/check-sentinel.sh
```

然后模拟主节点宕机：

```bash
# 1) 记录当前主节点
docker compose exec -T redis-sentinel1 redis-cli -p 26379 \
  sentinel get-master-addr-by-name mymaster
# 期望输出：redis-master  172.x.x.x  6379

# 2) 暂停主节点（比 stop 更接近"进程卡死"的场景）
docker compose pause redis-master

# 3) 等 10 秒让哨兵完成判定与切换
sleep 10

# 4) 再查主节点
docker compose exec -T redis-sentinel1 redis-cli -p 26379 \
  sentinel get-master-addr-by-name mymaster
# 期望：地址变成某个从节点的 IP → 自动故障转移成功

# 5) 看哨兵日志
docker compose logs redis-sentinel1 --tail 40

# 6) 恢复
docker compose unpause redis-master
```

恢复后原来的主节点会以**从节点**身份重新加入，不会抢占主角色。

<!-- TODO(实机跑完后补)：贴 failover 前后 get-master-addr-by-name 的对比 + 哨兵日志关键行 -->

---

## 7. 踩坑记录

### 7.1 两个从库不能共用一个配置文件（server-id 会重复）

很多教程让从库共用一个 `slave.cnf`，然后注释一句"slave2 改成 3"。但容器挂载是同一份文件，**两个从库会拿到相同的 `server-id`**，复制直接失败：

```
Fatal error: The slave I/O thread stops because master and slave have equal MySQL server ids
```

这个报错指向性很强，但如果你没意识到"两个容器挂的是同一个文件"，就会一直盯着配置内容看，看不出问题。

**本仓库的做法**：拆成 `slave1.cnf`（server-id=2）和 `slave2.cnf`（server-id=3），两个容器各挂各的。

### 7.2 Redis 配置文件里写 `${REDIS_PASSWORD}` 是无效的

Redis **不会展开 shell 或 Docker 的变量**，写进 conf 的 `${REDIS_PASSWORD}` 会被当成**字面量密码**——表现是客户端认证一直失败，而配置文件看起来完全正确。

常见但不完美的解法：用 `envsubst` 在启动时替换。但 `redis:7-alpine` 镜像里**没有 `envsubst`**（它来自 gettext 包），这个方案在 alpine 上直接跑不通。

**本仓库的做法**：conf 文件保持无密钥状态，密码通过 `docker compose` 的 `command` 以启动参数传入：

```yaml
command: >
  sh -c "redis-server /usr/local/etc/redis/redis.conf
         --requirepass ${REDIS_PASSWORD}
         --masterauth ${REDIS_PASSWORD}"
```

`${REDIS_PASSWORD}` 是 **compose 在宿主机解析时**替换的，Redis 拿到的已经是明文参数。配置文件因此可以直接提交到仓库，不泄露任何密钥。

### 7.3 Sentinel 会重写自己的配置文件

Redis Sentinel 启动后会把运行时状态（已知从库列表、纪元、当前主库地址）**回写**到自己的配置文件。这会带来两个问题：

1. 仓库里提交的那份文件会被写脏，下次 `git status` 全是改动；
2. 三个哨兵如果挂载同一个文件，会互相覆盖，状态错乱。

**本仓库的做法**：`sentinel.conf` 只作为**只读模板**挂载，启动时复制到容器可写层再运行：

```yaml
command: >
  sh -c "cp /usr/local/etc/redis/sentinel.conf /tmp/sentinel.conf
         && echo 'sentinel auth-pass mymaster ${REDIS_PASSWORD}' >> /tmp/sentinel.conf
         && redis-sentinel /tmp/sentinel.conf"
```

每个哨兵容器有自己独立的 `/tmp/sentinel.conf`，互不干扰；仓库里的模板永远干净。

> 副作用：容器重建后运行时状态会丢失，哨兵重新发现拓扑。对练习环境无影响。

另外 `sentinel auth-pass` 必须写在 `sentinel monitor` **之后**，所以用 `>>` 追加到文件末尾，顺序正好正确。

### 7.4 MySQL 8 复制账号必须用 mysql_native_password

这是整个项目**最容易卡住**的地方。MySQL 8 默认认证插件改为 `caching_sha2_password`，在非加密连接下做复制会报：

```
Authentication requires secure connection
```

而 `SHOW REPLICA STATUS` 里显示的是 `Replica_IO_Running: Connecting`——**看起来像网络不通**，很容易往防火墙、容器网络方向排查，白费时间。

修法（已在 `init-replication.sh` 中）：

```sql
CREATE USER 'repl'@'%' IDENTIFIED WITH mysql_native_password BY '...';
```

同时 MySQL 容器启动参数也要加 `--default-authentication-plugin=mysql_native_password`。

### 7.5 术语变更：SLAVE → REPLICA

MySQL 8.0.22 起，`SHOW SLAVE STATUS` / `START SLAVE` 改叫 `SHOW REPLICA STATUS` / `START REPLICA`，字段名也从 `Slave_IO_Running` 变成 `Replica_IO_Running`。8.4 起 `SHOW MASTER STATUS` 也改叫 `SHOW BINARY LOG STATUS`。

**用错术语会直接报错**，而网上大量教程用的还是老写法。看文档时务必确认版本。

---

## 8. 已知局限

如实交代，这几件事本仓库**没有**做：

1. **MySQL 这套没有自动故障转移。** 哨兵只管 Redis。

   主库宕机后，要人工挑一个从库、执行 `STOP REPLICA` + `RESET REPLICA ALL`、把它提升为主库、再改写其余从库的指向。自动切换需要引入 **Orchestrator** 或 **MHA**，它们负责探活、选主、改写复制指向、处理脑裂——比这套练习项目复杂一个量级。

   面试被问"MySQL 主库挂了怎么办"，正确的说法是：

   > 这套做到的是**数据不丢、故障可查、可人工切换**；自动故障转移要引入 Orchestrator / MHA，我了解它的选主逻辑，但没有在生产环境跑过。

   **这句话照实说，可信度远高于吹牛。**

2. **异步复制，存在数据丢失窗口。** 主库提交后不等从库确认就返回，主库宕机时未同步的 binlog 会丢。要强一致需要半同步复制（`rpl_semi_sync`）或 MySQL Group Replication。

3. **所有容器在同一台机器。** 这是单机模拟，机器挂了整个集群都没了，不具备真正的机房级高可用。

4. **哨兵数量为 3、quorum 为 2** 是最小可用配置。生产环境哨兵应该跨机器部署，否则机器宕机时哨兵也一起没了。

5. **`read_only` 对 SUPER 权限账号无效**（root 仍能写从库），生产环境需要 `super_read_only = ON`。

6. **没有资源限制**，compose 里没设 `mem_limit`。3 个 MySQL 实例已把 `innodb_buffer_pool_size` 压到 64M 以适应 3.7G 内存的机器。

7. **尚未实机验证**。本套配置已按项目二趟平的坑做了对应处理（DNS、镜像源、SELinux），但项目三的验证输出和截图仍待补充（README 中标记 `TODO` 的位置）。
