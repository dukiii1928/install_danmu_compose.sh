#!/usr/bin/env bash
set -e

# ========== 基本配置，可按需修改 ==========
APP_DIR="danmu"                 # 程序目录名：会自动创建 danmu 目录
IMAGE="logvar/danmu-api:latest" # 使用的镜像版本（默认 latest）
HOST_PORT=9321                  # 对外访问端口：默认 9321
# ======================================

echo "=== LogVar 弹幕 Docker 一键安装脚本 ==="

# 1. 检查 docker
if ! command -v docker >/dev/null 2>&1; then
  echo "未检测到 Docker，请先安装 Docker 再运行本脚本。"
  echo "例如 Ubuntu：sudo apt install docker.io"
  exit 1
fi

# 2. 检查 docker compose
if command -v docker compose >/dev/null 2>&1; then
  COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE="docker-compose"
else
  echo "未检测到 docker compose，请先安装 docker compose 再运行本脚本。"
  echo "例如：sudo apt install docker-compose-plugin 或 docker-compose"
  exit 1
fi

# 3. 创建目录
mkdir -p "${APP_DIR}/config" "${APP_DIR}/.cache"
cd "${APP_DIR}"
APP_PATH="$(pwd)"

# 4. 生成/询问配置
if [ ! -f config/.env ]; then
  echo "开始生成 config/.env 配置文件..."

  # 默认随机 TOKEN
  DEFAULT_TOKEN=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 8)
  DEFAULT_ADMIN_TOKEN=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12)

  echo ""
  read -r -p "请输入普通后台 TOKEN（留空自动使用随机值: ${DEFAULT_TOKEN}）: " INPUT_TOKEN
  read -r -p "请输入管理后台 ADMIN_TOKEN（留空自动使用随机值: ${DEFAULT_ADMIN_TOKEN}）: " INPUT_ADMIN_TOKEN
  echo ""
  echo "提示：B 站 Cookie 可选，用来抓完整弹幕。"
  echo "示例：SESSDATA=xxxx; buvid3=xxxx; ... （按你浏览器里复制的为准）"
  read -r -p "请输入 B 站 Cookie（可选，留空则不配置）: " INPUT_BILIBILI_COOKIE
  echo ""

  TOKEN=${INPUT_TOKEN:-$DEFAULT_TOKEN}
  ADMIN_TOKEN=${INPUT_ADMIN_TOKEN:-$DEFAULT_ADMIN_TOKEN}

  cat > config/.env <<EOF
# 普通后台的路径
TOKEN=${TOKEN}

# 管理后台的路径（权限更高，注意保密）
ADMIN_TOKEN=${ADMIN_TOKEN}

# 这里可以继续加别的环境变量，例如：
# PLATFORM_ORDER=bilibili1,qq
EOF

  if [ -n "$INPUT_BILIBILI_COOKIE" ]; then
    {
      echo ""
      echo "# b 站 Cookie，用于获取完整弹幕"
      echo "BILIBILI_COOKIE=${INPUT_BILIBILI_COOKIE}"
    } >> config/.env
  else
    {
      echo ""
      echo "# BILIBILI_COOKIE=在这里填入你的 b 站 Cookie（可选）"
    } >> config/.env
  fi

  echo "已生成 config/.env 配置文件。"
else
  echo "检测到已有 config/.env，保留你原来的配置。"
fi

# 5. 生成 docker-compose.yml（如果还没有）
if [ ! -f docker-compose.yml ]; then
  cat > docker-compose.yml <<EOF
services:
  danmu-api:
    image: ${IMAGE}
    container_name: danmu-api
    restart: unless-stopped
    ports:
      - "${HOST_PORT}:9321"
    volumes:
      - ./config:/app/config
      - ./.cache:/app/.cache
    env_file:
      - ./config/.env
EOF

  echo "已生成 docker-compose.yml。"
else
  echo "检测到已有 docker-compose.yml，保留你原来的文件。"
fi

# 6. 生成每日 4 点自动更新脚本
cat > "${APP_PATH}/update_danmu.sh" <<'EOF'
#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"

if command -v docker compose >/dev/null 2>&1; then
  COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE="docker-compose"
else
  echo "未找到 docker compose，请先安装。"
  exit 1
fi

${COMPOSE} pull
${COMPOSE} up -d
EOF

chmod +x "${APP_PATH}/update_danmu.sh"

# 写入 crontab，每天 4:00 自动更新（先删除旧的同名任务，避免重复）
CRON_LINE="0 4 * * * /bin/bash ${APP_PATH}/update_danmu.sh >/dev/null 2>&1"
( crontab -l 2>/dev/null | grep -v "${APP_PATH}/update_danmu.sh" || true; echo "${CRON_LINE}" ) | crontab -
echo "已设置每天凌晨 4 点自动更新任务。"

# 7. 首次拉取镜像并启动（拉最新）
${COMPOSE} pull
${COMPOSE} up -d

# 8. 读取 TOKEN / IP 信息
USER_TOKEN=$(grep '^TOKEN=' config/.env | head -n1 | cut -d= -f2-)
ADMIN_TOKEN_REAL=$(grep '^ADMIN_TOKEN=' config/.env | head -n1 | cut -d= -f2-)

SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
if [ -z "$SERVER_IP" ]; then
  SERVER_IP="你的服务器IP或域名"
fi

echo ""
echo "=== 安装完成！==="
echo "容器名：danmu-api"
echo "程序目录：${APP_PATH}"
echo "对外端口：${HOST_PORT}"
echo ""

echo "【重要】TOKEN 信息："
echo "普通后台 TOKEN：      ${USER_TOKEN}"
echo "管理后台 ADMIN_TOKEN：${ADMIN_TOKEN_REAL}"
echo ""

echo "【后台访问地址】"
echo "普通后台（UI）：   http://${SERVER_IP}:${HOST_PORT}/${USER_TOKEN}"
echo "管理后台（UI）：   http://${SERVER_IP}:${HOST_PORT}/${ADMIN_TOKEN_REAL}"
echo ""
echo "如果 IP 检测不对，请把上面地址里的 IP 部分换成你服务器的真实 IP 或域名。"
echo ""

echo "=== 常用维护命令（在 ${APP_PATH} 目录下执行） ==="
echo "1）更新到最新镜像（除了自动更新外，手动立即更新）："
echo "   cd ${APP_PATH} && ${COMPOSE} pull && ${COMPOSE} up -d"
echo ""
echo "2）重启容器："
echo "   cd ${APP_PATH} && ${COMPOSE} restart"
echo ""
echo "3）查看日志："
echo "   cd ${APP_PATH} && ${COMPOSE} logs -f"
echo ""
echo "4）停止并卸载容器（保留配置）："
echo "   cd ${APP_PATH} && ${COMPOSE} down"
echo ""
echo "5）完全卸载（删除目录和数据）："
echo "   cd ${APP_PATH}/.. && ${COMPOSE} down && rm -rf ${APP_DIR}"
echo ""
echo "6）自动更新脚本位置："
echo "   ${APP_PATH}/update_danmu.sh"
echo ""
echo "脚本到此结束，祝使用愉快～"
