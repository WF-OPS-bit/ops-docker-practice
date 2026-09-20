#!/usr/bin/env bash
# 一键建立 MySQL GTID 主从关系
set -euo pipefail

cd "$(dirname "$0")/.."

# 让脚本内部能直接用到 .env 里定义的密码
# （docker compose 自己会读 .env 做变量替换，但 shell 变量需要手动 source）
if [ -f .env ]; then
  set -a; . ./.env; set +a
fi

ROOT_PW="${MYSQL_ROOT_PASSWORD:?请在 .env 中设置 MYSQL_ROOT_PASSWORD}"
REPL_USER=repl
REPL_PW="${REPL_PASSWORD:?请在 .env 中设置 REPL_PASSWORD}"
MASTER=mysql-master

q() { docker compose exec -T "$1" mysql -uroot -p"$ROOT_PW" -N -B -e "$2"; }

echo "==> 1/3 在主库创建复制账号"
echo "    必须显式指定 mysql_native_password —— MySQL 8 默认的 caching_sha2_password"
echo "    在非加密连接下会让从库 IO 线程报 Authentication requires secure connection"
q "$MASTER" "CREATE USER IF NOT EXISTS '${REPL_USER}'@'%'
             IDENTIFIED WITH mysql_native_password BY '${REPL_PW}';"
q "$MASTER" "GRANT REPLICATION SLAVE ON *.* TO '${REPL_USER}'@'%';"
q "$MASTER" "FLUSH PRIVILEGES;"

for s in mysql-slave1 mysql-slave2; do
  echo "==> 2/3 配置 ${s}：指向主库，启用 GTID 自动定位"
  q "$s" "STOP REPLICA;"
  # SOURCE_AUTO_POSITION=1 是关键：开启后由 GTID 集合自动计算同步点，
  # 不需要手工指定 binlog 文件名和偏移量
  q "$s" "CHANGE REPLICATION SOURCE TO
          SOURCE_HOST='${MASTER}',
          SOURCE_PORT=3306,
          SOURCE_USER='${REPL_USER}',
          SOURCE_PASSWORD='${REPL_PW}',
          SOURCE_AUTO_POSITION=1;"
  q "$s" "START REPLICA;"
done

echo "==> 3/3 等待复制链路建立"
sleep 5
bash scripts/check-replication.sh
