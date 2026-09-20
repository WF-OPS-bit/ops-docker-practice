#!/usr/bin/env bash
# 检查 Redis 哨兵状态与主从拓扑
set -uo pipefail

cd "$(dirname "$0")/.."

if [ -f .env ]; then
  set -a; . ./.env; set +a
fi
REDIS_PW="${REDIS_PASSWORD:?}"

echo "===== 1. 各哨兵认定的主节点 ====="
for s in redis-sentinel1 redis-sentinel2 redis-sentinel3; do
  addr=$(docker compose exec -T "$s" redis-cli -p 26379 \
         sentinel get-master-addr-by-name mymaster 2>/dev/null | tr '\n' ' ')
  echo "  [$s] ${addr:-（无响应）}"
done

echo
echo "===== 2. 主节点视角的复制拓扑 ====="
docker compose exec -T redis-master redis-cli -a "$REDIS_PW" --no-auth-warning \
  info replication 2>/dev/null | grep -E '^(role|connected_slaves|slave[0-9]+)' \
  || echo "  （读取失败）"

echo
echo "===== 3. 哨兵监控的主节点元数据 ====="
# redis-cli 输出是 key/value 交替的两列，用 paste 两两配对便于阅读
docker compose exec -T redis-sentinel1 redis-cli -p 26379 \
  sentinel master mymaster 2>/dev/null | paste - - 2>/dev/null \
  | grep -iE 'name|ip$|"port"|flags|num-slaves|num-other-sentinels|quorum|down-after' \
  || echo "  （读取失败）"

echo
echo "===== 4. 从节点角色确认 ====="
for s in redis-slave1 redis-slave2; do
  role=$(docker compose exec -T "$s" redis-cli -a "$REDIS_PW" --no-auth-warning \
         info replication 2>/dev/null | grep -E '^role:' | tr -d '\r')
  echo "  [$s] ${role:-（无响应）}"
done

echo
echo "故障转移验证是破坏性操作，未包含在本脚本内 —— 步骤见 README 第 6.4 节。"
