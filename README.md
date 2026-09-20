# ops-docker-practice

> 在 Linux 服务器上从零搭建的运维实践记录：完整配置、可复现的验证命令，以及一份写得很具体的踩坑记录。

仓库现阶段包含「项目二」，「项目三」待补充。

---

## 仓库导航

| 目录 | 内容 | 状态 |
|---|---|---|
| [`project2-compose-nginx/`](project2-compose-nginx/) | Docker Compose 编排 Nginx + 双实例应用 + MySQL + Redis，含动静分离、两级缓存、数据持久化验证 | ✅ **已实机验证** |
| [`project3-mysql-redis-ha/`](project3-mysql-redis-ha/) | MySQL GTID 一主两从 + Redis 一主两从三哨兵，含故障转移验证 | 🔧 配置完成，待实机验证 |
| `docs/images/` | 终端验证截图 | ⏳ 待补充 |

---

## 项目二：Docker Compose 编排 + Nginx 集群

入口：[`project2-compose-nginx/README.md`](project2-compose-nginx/README.md)

```
                             ┌────────────────────────┐
      客户端  ──── :80 ─────▶ │   Nginx 1.27-alpine    │
                             │  动静分离 / 反代 / 缓存 │
                             └───────────┬────────────┘
                                         │ upstream weight = 2 : 1
                          ┌──────────────┴──────────────┐
                   ┌──────▼───────┐             ┌───────▼──────┐
                   │   web1:8080  │             │   web2:8080  │
                   │  Spring Boot │             │  Spring Boot │
                   └──────┬───────┘             └───────┬──────┘
                          └──────────────┬──────────────┘
                          ┌──────────────┴──────────────┐
                   ┌──────▼───────┐             ┌───────▼──────┐
                   │  MySQL 8.0   │             │  Redis 7     │
                   │  volume 持久化 │             │  AOF 持久化   │
                   └──────────────┘             └──────────────┘
```

**三条命令跑起来：**

```bash
cd project2-compose-nginx
cp .env.example .env && vim .env   # 改掉三组默认密码
./scripts/up.sh                    # 校验配置 -> 构建镜像 -> 启动
./scripts/check.sh                 # 跑完整验证套件（负载均衡/缓存/持久化）
```

**这个项目具体做了什么：**

- 多阶段 Docker 构建：最终镜像不含 Maven 和源码，以非 root 用户运行
- `depends_on` 配合 `condition: service_healthy` 控制启动顺序，避免应用先于数据库就绪
- Nginx 加权负载均衡（2:1）+ 动静分离
- 两级缓存：静态资源 `expires 30d` 给浏览器，动态接口 `proxy_cache` 给 Nginx，用 `X-Cache-Status` 响应头验证
- MySQL / Redis 数据落在命名卷上，容器重启后数据不丢

**踩坑记录**（完整版见 [README 第 7 节](project2-compose-nginx/README.md#7-踩坑记录)）：

| 坑 | 现象 | 根因 |
|---|---|---|
| JRE 镜像没有 `curl` | Nginx 永远起不来 | healthcheck 失败 → `condition: service_healthy` 永不满足 |
| `proxy_cache` 吃掉负载均衡 | 六次请求全打到同一实例 | 命中缓存后 Nginx 不再回源 |
| compose 变量作用域 | Redis 容器永远 unhealthy | `${VAR}` 是宿主机解析时替换，`$VAR` 是容器内 shell 展开 |
| `depends_on` 缺 condition | 应用连不上数据库 | 容器创建 ≠ 服务就绪 |
| MySQL 8 认证插件 | `Authentication requires secure connection` | 默认是 `caching_sha2_password` |

---

## 运行环境

| 组件 | 版本 |
|---|---|
| OS | **CentOS 7 Core**（实际验证环境，2 核 / 3.7G） |
| Docker Engine | **26.1.4** |
| Docker Compose | **v2.27.1**（命令是 `docker compose`，不是 `docker-compose`） |
| Spring Boot | 3.1.12 |
| JDK | Eclipse Temurin 17 |
| MySQL | 8.0.46 |
| Redis | 7-alpine |

> CentOS 7 已于 2024-06 EOL，这里是沿用现有虚拟机。**换新环境建议用 Rocky Linux 9 / AlmaLinux 9**——用法几乎一致，二进制兼容 RHEL，也不会被问"怎么还在用 EOL 系统"。
>
> 服务器系统准备、Docker 安装、镜像加速配置不在本仓库范围内。

---

## 关于验证状态

**项目二已在实机跑通全部五项验证**（负载均衡 / 两层缓存 / 数据层连通 / 卷持久化），原始终端输出见 [项目二 README 第 6.0 节](project2-compose-nginx/README.md#60-实测输出)。

应用层源码另外在 Windows（JDK 21 + Maven 3.6.0）下独立构建通过，产出 `target/app.jar`。

README 中所有标注为"实测输出"的内容都来自真实运行，**没有写任何未经实际验证的结论**；尚未完成的部分统一列在各自的「已知局限」中。

---

## 安全提示

- `.env` 已在 `.gitignore` 中排除，**请不要用 `git add -f` 强制提交**
- `.env.example` 里的密码只是占位符，部署前必须替换
- `docker` 组约等于 root 权限，生产环境不要随意把用户加进去
