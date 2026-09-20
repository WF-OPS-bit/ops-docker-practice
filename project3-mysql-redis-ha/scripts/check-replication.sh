#!/usr/bin/env bash
# 检查 MySQL 主从复制状态
set -uo pipefail

cd "$(dirname "$0")/.."

if [ -f .env ]; then
  set -a; . ./.env; set +a
fi
ROOT_PW="${MYSQL_ROOT_PASSWORD:?}"

for s in mysql-slave1 mysql-slave2; do
  echo "----- $s -----"
  docker compose exec -T "$s" mysql -uroot -p"$ROOT_PW" -e "SHOW REPLICA STATUS\G" 2>/dev/null \
    | grep -E 'Replica_IO_Running|Replica_SQL_Running|Seconds_Behind|Last_IO_Error|Last_SQL_Error|Retrieved_Gtid|Executed_Gtid' \
    || echo "  （读取失败：容器未就绪或复制未建立）"
  echo
done

echo "说明：Replica_IO_Running 与 Replica_SQL_Running 同时为 Yes 才算正常。"
echo "若 IO 线程卡在 Connecting 且 Last_IO_Error 提到 secure connection，"
echo "说明复制账号没用 mysql_native_password —— 详见 README 踩坑记录。"
