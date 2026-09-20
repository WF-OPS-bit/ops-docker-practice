#!/usr/bin/env bash
# 一键启动：校验配置 -> 构建镜像 -> 启动 -> 打印状态
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  echo "[i] 检测到没有 .env，已从 .env.example 复制"
  cp .env.example .env
  echo "[!] 请先用 vim .env 改掉默认密码，然后重新执行本脚本"
  exit 1
fi

echo "==> 1/3 校验 compose 配置（变量没写对会在这里报错）"
docker compose config --quiet

echo "==> 2/3 构建镜像并后台启动"
docker compose up -d --build

echo "==> 3/3 等待服务健康检查通过"
sleep 10
docker compose ps

echo
echo "全部服务状态见上表，STATUS 列应显示 (healthy)。"
echo "跑 ./scripts/check.sh 做功能验证。"
