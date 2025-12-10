#!/usr/bin/env bash
set -e

# ========== 基本配置，可按需修改 ==========
APP_DIR="danmu"                 # 程序目录名：会自动创建 danmu 目录
IMAGE="logvar/danmu-api:latest" # 使用的镜像版本（默认 latest）
HOST_PORT=9321                  # 对外访问端口，后面会询问覆盖
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

ROOT_DIR="$(pwd)"
OLD_APP_PATH="${ROOT_DIR}/${APP_DIR}"

# 3. 自动检测并清理旧安装
if [ -d "${APP_DIR}" ] || docker ps -a --format '{{.Names}}' | grep -q '^danmu-api$'; then
  echo ""
  echo "检测到可能存在旧的 danmu 安装，开始自动清理..."

  # 3.1 尝试通过旧目录里的 compose down
  if [ -d "${APP_DIR}" ] && [ -f "${APP_DIR}/docker-compose.yml" ]; then
    echo " - 停止旧的 docker compose 服务..."
    (cd "${APP_DIR}" && ${COMPOSE} down --remove-orphans >/dev/null 2>&1) || true
  fi

  # 3.2 尝试直接删除旧容器
  echo " - 删除旧容器 danmu-api（如果存在）..."
  docker rm -f danmu-api >/dev/null 2>&1 || true

  # 3.3 删除旧的自动更新 crontab
  echo " - 清理旧的 crontab 自动更新任务..."
  (crontab -l 2>/dev/null | grep -v "${OLD_APP_PATH}/update_danmu.sh" || true) | crontab - 2>/dev/null || true

  # 3.4 删除旧目录
  if [ -d "${APP_DIR}" ]; then
    echo " - 删除旧目录 ${OLD_APP_PATH} ..."
    rm -rf "${APP_DIR}"
  fi

  echo "旧安装已清理完成，将继续安装最新版本。"
  echo ""
fi

# 4. 询问对外端口
echo ""
read -r -p "请输入对外访问端口（默认 9321）: " INPUT_PORT
HOST_PORT=${INPUT_PORT:-9321}
echo "将使用端口：${HOST_PORT}"
echo ""

# 5. 创建目录
mkdir -p "${APP_DIR}/config" "${APP_DIR}/.cache"
cd "${APP_DIR}"
APP_PATH="$(pwd)"

# 6. 生成/询问配置（每次安装都重写 .env）
echo "开始生成 config/.env 配置文件..."

# 默认随机 TOKEN
DEFAULT_TOKEN=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 8)
DEFAULT_ADMIN_TOKEN=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12)

echo ""
read -r -p "请输入普通后台 TOKEN（留空自动使用随机值: ${DEFAULT_TOKEN}）: " INPUT_TOKEN
read -r -p "请输入管理后台 ADMIN_TOKEN（留空自动使用随机值: ${DEFAULT_ADMIN_TOKEN}）: " INPUT_ADMIN_TOKEN
echo ""

TOKEN=${INPUT_TOKEN:-$DEFAULT_TOKEN}
ADMIN_TOKEN=${INPUT_ADMIN_TOKEN:-$DEFAULT_ADMIN_TOKEN}

# 一次性重写 .env
cat > config/.env <<EOF
# API 访问令牌
TOKEN=${TOKEN}

# 系统管理访问令牌（权限更高，注意保密）
ADMIN_TOKEN=${ADMIN_TOKEN}

# 其他可选环境变量（推荐在 Web UI 里配置，例如 BILIBILI_COOKIE 等）
# BILIBILI_COOKIE=在这里填入你的 b 站 Cookie（可选）
EOF

echo "config/.env 已生成。"

# 7. 生成 docker-compose.yml（如果还没有）
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

# 8. 生成更新脚本
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

# 8.1 是否启用每天 4 点自动更新
echo ""
read -r -p "是否启用每天凌晨 4 点自动更新镜像并重启容器？[Y/n]: " ENABLE_AUTO_UPDATE
ENABLE_AUTO_UPDATE=${ENABLE_AUTO_UPDATE:-Y}

if [[ "$ENABLE_AUTO_UPDATE" =~ ^[Yy]$ ]]; then
  CRON_LINE="0 4 * * * /bin/bash ${APP_PATH}/update_danmu.sh >/dev/null 2>&1"
  (crontab -l 2>/dev/null | grep -v "${APP_PATH}/update_danmu.sh" || true; echo "${CRON_LINE}") | crontab -
  echo "已设置每天凌晨 4 点自动更新任务。"
else
  echo "已跳过自动更新，如需启用可手动将以下行加入 crontab："
  echo "0 4 * * * /bin/bash ${APP_PATH}/update_danmu.sh >/dev/null 2>&1"
fi

# 9. 首次拉取镜像并启动（拉最新）
${COMPOSE} pull
${COMPOSE} up -d

# 10. 读取 TOKEN / IP 信息
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
echo "1）立即更新到最新镜像并重启："
echo "   cd ${APP_PATH} && ./update_danmu.sh"
echo ""
echo "2）重启容器："
if command -v docker compose >/dev/null 2>&1; then
  echo "   cd ${APP_PATH} && docker compose restart"
else
  echo "   cd ${APP_PATH} && docker-compose restart"
fi
echo ""
echo "3）查看日志："
if command -v docker compose >/dev/null 2>&1; then
  echo "   cd ${APP_PATH} && docker compose logs -f"
else
  echo "   cd ${APP_PATH} && docker-compose logs -f"
fi
echo ""
echo "4）停止并卸载容器（保留配置）："
if command -v docker compose >/dev/null 2>&1; then
  echo "   cd ${APP_PATH} && docker compose down"
else
  echo "   cd ${APP_PATH} && docker-compose down"
fi
echo ""
echo "5）完全卸载（删除目录和数据）："
echo "   cd ${APP_PATH}/.. && rm -rf ${APP_DIR}"
echo ""
echo "6）自动更新脚本位置："
echo "   ${APP_PATH}/update_danmu.sh"
echo ""
echo "脚本到此结束，祝使用愉快～"
