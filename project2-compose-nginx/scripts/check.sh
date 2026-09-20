#!/usr/bin/env bash
# 一键验证：负载均衡 / 静态缓存 / 代理缓存 / 数据持久化 / 数据层连通
set -uo pipefail

cd "$(dirname "$0")/.."

ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; }
head1() { echo; echo "===== $* ====="; }

# ---------- 验证 1：加权负载均衡 ----------
head1 "验证 1：加权负载均衡（weight=2:1，期望约 4:2）"
echo "  连续请求 6 次 /api/hi，统计命中的实例："
# 注意两个坑：
#   1) Spring Boot 的响应体末尾没有换行符
#   2) GNU sed 处理"最后一行无换行"的输入时，输出也不补换行
# 所以必须在每次提取后自己补一个 echo，否则 6 次结果会拼成一整串，
# uniq -c 只会统计到 1 行，明明打到了两个实例也会误判成 FAIL。
counts=$(for _ in $(seq 1 6); do
  curl -s http://localhost/api/hi | sed -n 's/.*"instance":"\([^"]*\)".*/\1/p'
  echo
done)
echo "$counts" | sed '/^$/d' | sort | uniq -c | sed 's/^/    /'
distinct=$(echo "$counts" | sed '/^$/d' | sort -u | wc -l)
if [ "$distinct" -ge 2 ]; then
  ok "两个实例都被打到（权重 2:1 时 web1 应明显多于 web2）"
else
  bad "只命中了一个实例 —— 检查 Nginx upstream 和容器网络"
fi

# ---------- 验证 2：静态资源浏览器缓存 ----------
head1 "验证 2：静态资源缓存头"
hdr=$(curl -sI http://localhost/static/app.css)
echo "$hdr" | grep -iE 'cache-control|expires' | sed 's/^/  /' || true
if echo "$hdr" | grep -qi 'max-age=2592000'; then
  ok "Cache-Control: max-age=2592000（30 天）"
else
  bad "没有 30 天缓存头 —— 检查 location ~* \.css 是否匹配到"
fi

# ---------- 验证 3：Nginx 代理缓存 ----------
head1 "验证 3：proxy_cache 命中（同一 URL 两次）"
first=$(curl -sI http://localhost/api/cache-time | grep -i x-cache-status | tr -d '\r')
echo "  第一次: ${first:-（无响应头）}"
sleep 1
second=$(curl -sI http://localhost/api/cache-time | grep -i x-cache-status | tr -d '\r')
echo "  第二次: ${second:-（无响应头）}"
if echo "$second" | grep -qi 'HIT'; then
  ok "第二次请求命中缓存"
else
  bad "第二次仍是 MISS —— 注意 proxy_cache 只缓存 GET/HEAD，且源站响应不能带 Set-Cookie"
fi

# ---------- 验证 4：数据层连通 ----------
head1 "验证 4：MySQL / Redis 连通"
echo "  /api/db   -> $(curl -s http://localhost/api/db | head -c 200)"
echo "  /api/redis-> $(curl -s http://localhost/api/redis | head -c 200)"

# ---------- 验证 5：数据持久化 ----------
head1 "验证 5：MySQL 数据持久化（重启容器后数据还在）"
ROOT_PW=$(grep -E '^MYSQL_ROOT_PASSWORD=' .env | cut -d= -f2-)
docker compose exec -T mysql mysql -uroot -p"$ROOT_PW" -e \
  "CREATE TABLE IF NOT EXISTS appdb.t_demo(id INT PRIMARY KEY, v VARCHAR(20));
   INSERT INTO appdb.t_demo VALUES(1,'persist-test') ON DUPLICATE KEY UPDATE v='persist-test';" \
  2>/dev/null
docker compose restart mysql >/dev/null
echo "  等待 MySQL 重新就绪..."
sleep 15
after=$(docker compose exec -T mysql mysql -uroot -p"$ROOT_PW" -N -B -e "SELECT v FROM appdb.t_demo WHERE id=1;" 2>/dev/null)
echo "  重启后查到的数据: $after"
if [ "$after" = "persist-test" ]; then
  ok "volume 挂载生效，容器重启后数据未丢失"
else
  bad "数据丢失 —— 检查 mysql_data 卷是否正常挂载"
fi

echo
echo "验证结束。"
