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

# 3. 询问对外端口
echo ""
read -r -p "请输入对外访问端口（默认 9321）: " INPUT_PORT
HOST_PORT=${INPUT_PORT:-9321}
echo "将使用端口：${HOST_PORT}"
echo ""

# 4. 创建目录
mkdir -p "${APP_DIR}/config" "${APP_DIR}/.cache"
cd "${APP_DIR}"
APP_PATH="$(pwd)"

# 5. 生成/询问配置
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

  # 询问是否自动写入推荐默认变量
  echo ""
  read -r -p "是否自动写入推荐的默认环境变量（SOURCE_ORDER、VOD_SERVERS 等）？[Y/n]: " AUTO_DEFAULT
  AUTO_DEFAULT=${AUTO_DEFAULT:-Y}

  if [[ "$AUTO_DEFAULT" =~ ^[Yy]$ ]]; then
    cat >> config/.env <<'EOF'

# ===== 以下为推荐默认配置，可在 Web 后台修改 =====

# 源配置
SOURCE_ORDER=360,vod,renren,hanjutv
OTHER_SERVER=https://api.danmu.icu
VOD_SERVERS=金蟾@https://zy.jinchancajii.com,789@https://www.caiji.cyou,听风@https://gctf.tfdh.top
VOD_RETURN_MODE=fastest
VOD_REQUEST_TIMEOUT=10000
YOUKU_CONCURRENCY=8

# 弹幕配置
BLOCKED_WORDS=
GROUP_MINUTE=1
DANMU_LIMIT=0
DANMU_SIMPLIFIED=false
DANMU_PUSH_URL=
CONVERT_TOP_BOTTOM_TO_SCROLL=false
CONVERT_COLOR=

# 缓存配置
UPSTASH_REDIS_REST_URL=
UPSTASH_REDIS_REST_TOKEN=
SEARCH_CACHE_MINUTES=1
COMMENT_CACHE_MINUTES=1
REMEMBER_LAST_SELECT=true
MAX_LAST_SELECT_MAP=200

# 系统配置
PROXY_URL=
TMDB_API_KEY=
LOG_LEVEL=info
CONVERT_COLOR_TO_WHITE=
DEPLOY_PLATFROM_ACCOUNT=
DEPLOY_PLATFROM_PROJECT=
DEPLOY_PLATFROM_TOKEN=
EOF
    echo "已写入一批推荐的默认配置（可在后台界面查看/修改）。"
  else
    echo "已跳过自动写入默认环境变量，你可以稍后在 Web 后台手动添加。"
  fi

  echo "已生成 config/.env 配置文件。"
else
  echo "检测到已有 config/.env，保留你原来的配置。"
fi

# 6. 生成 docker-compose.yml（如果还没有）
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

# 7. 生成更新脚本
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

# 7.1 是否启用每天 4 点自动更新
echo ""
read -r -p "是否启用每天凌晨 4 点自动更新镜像并重启容器？[Y/n]: " ENABLE_AUTO_UPDATE
ENABLE_AUTO_UPDATE=${ENABLE_AUTO_UPDATE:-Y}

if [[ "$ENABLE_AUTO_UPDATE" =~ ^[Yy]$ ]]; then
  CRON_LINE="0 4 * * * /bin/bash ${APP_PATH}/update_danmu.sh >/dev/null 2>&1"
  ( crontab -l 2>/dev/null | grep -v "${APP_PATH}/update_danmu.sh" || true; echo "${CRON_LINE}" ) | crontab -
  echo "已设置每天凌晨 4 点自动更新任务。"
else
  echo "已跳过自动更新，如需启用可手动将以下行加入 crontab："
  echo "0 4 * * * /bin/bash ${APP_PATH}/update_danmu.sh >/dev/null 2>&1"
fi

# 8. 首次拉取镜像并启动（拉最新）
${COMPOSE} pull
${COMPOSE} up -d

# 9. 读取 TOKEN / IP 信息
USER_TOKEN=$(grep '^TOKEN=' config/.env | head -n1 | cut -d= -f2-)
ADMIN_TOKEN_REAL=$(grep '^ADMIN_TOKEN=' config/.env | head -n1 | cut -d= -f2-)

SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
if [ -z "$SERVER_IP" ]; then
  SERVER_IP="你的服务器IP或域名"
fi

ADMIN_PATH="admini_${ADMIN_TOKEN_REAL}"

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
echo "管理后台（UI）：   http://${SERVER_IP}:${HOST_PORT}/${ADMIN_PATH}"
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
