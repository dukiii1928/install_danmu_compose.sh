#!/usr/bin/env bash
# danmu-api · Docker Compose 一键部署脚本 2.0++
# 用法：
#   安装/更新：bash install_compose.sh
#   卸载：    bash install_compose.sh uninstall
#   状态：    bash install_compose.sh status
#
# 特点：
#   - 自动安装 Docker + Docker Compose（仅 Debian/Ubuntu）
#   - 安装前如果检测到旧部署，会先完整卸载（容器 + 配置）再重装
#   - 生成 /root/danmu-config/.env 配置文件
#   - 生成 /root/danmu-compose/docker-compose.yml 并通过 docker compose 启动
#   - 支持自定义镜像 TAG
#   - 支持可选 watchtower 自动更新
#   - 支持可选自动放行防火墙端口（ufw/firewalld）
#   - 安装结束自动打印访问地址与常用命令

set -e

#################### 基本路径配置 ####################

DANMU_ENV_DIR="/root/danmu-config"
DANMU_ENV_FILE="${DANMU_ENV_DIR}/.env"

COMPOSE_DIR="/root/danmu-compose"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"

IMAGE_REPO="logvar/danmu-api"

# 这里写死你的远程脚本地址，方便在结尾打印命令给你复制
SCRIPT_URL="https://raw.githubusercontent.com/dukiii1928/install_danmu_compose.sh/main/install_compose.sh"

#################### 日志函数 ####################

info()    { echo -e "\033[1;34m[信息]\033[0m $*"; }
warn()    { echo -e "\033[1;33m[警告]\033[0m $*"; }
success() { echo -e "\033[1;32m[成功]\033[0m $*"; }
error()   { echo -e "\033[1;31m[错误]\033[0m $*"; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    error "请使用 root 运行本脚本，例如：sudo bash $0"
    exit 1
  fi
}

#################### 系统检测与依赖安装 ####################

detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt-get"
  else
    error "当前脚本仅支持 Debian/Ubuntu 系（需要 apt-get），其他系统请手动安装 Docker。"
    exit 1
  fi
}

install_docker_and_compose() {
  if command -v docker >/dev/null 2>&1; then
    info "检测到 Docker 已安装，跳过安装。"
  else
    info "未检测到 Docker，开始安装..."
    local pkg_mgr
    pkg_mgr=$(detect_pkg_mgr)

    ${pkg_mgr} update
    ${pkg_mgr} install -y docker.io
    systemctl enable --now docker
    success "Docker 安装完成。"
  fi

  if docker compose version >/dev/null 2>&1; then
    info "检测到 Docker Compose 插件已安装。"
  else
    info "未检测到 docker compose 插件，开始安装..."
    local pkg_mgr
    pkg_mgr=$(detect_pkg_mgr)

    ${pkg_mgr} update
    ${pkg_mgr} install -y docker-compose-plugin
    success "Docker Compose 插件安装完成。"
  fi
}

#################### 检测是否已有安装 ####################

has_previous_install() {
  if [ -f "${COMPOSE_FILE}" ]; then
    return 0
  fi
  if docker ps -a --format '{{.Names}}' | grep -wq "danmu-api"; then
    return 0
  fi
  if docker ps -a --format '{{.Names}}' | grep -wq "watchtower-danmu-api"; then
    return 0
  fi
  return 1
}

#################### 卸载逻辑（可复用） ####################

_do_uninstall() {
  info "开始卸载 danmu-api（容器 + 配置）..."

  if [ -f "${COMPOSE_FILE}" ]; then
    docker compose -f "${COMPOSE_FILE}" down --remove-orphans >/dev/null 2>&1 || true
  fi

  for name in danmu-api watchtower-danmu-api; do
    if docker ps -a --format '{{.Names}}' | grep -wq "${name}"; then
      docker stop "${name}" >/dev/null 2>&1 || true
      docker rm "${name}" >/dev/null 2>&1 || true
    fi
  done

  rm -rf "${COMPOSE_DIR}" "${DANMU_ENV_DIR}"

  success "卸载完成，相关容器与配置文件已全部删除。"
}

uninstall_all() {
  require_root
  _do_uninstall
  exit 0
}

#################### 配置文件处理 ####################

random_string() {
  # 生成 24 位随机字符串
  tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 24
}

create_env_fresh() {
  mkdir -p "${DANMU_ENV_DIR}"

  local PORT TOKEN ADMIN_TOKEN BILIBILI_COOKIE IMAGE_TAG ENABLE_WATCHTOWER AUTO_OPEN_FIREWALL

  info "未检测到配置文件，将为你创建新的配置。"

  read -rp "请输入对外访问端口 [默认 8080]: " input_port
  PORT="${input_port:-8080}"

  local rand_token rand_admin
  rand_token="$(random_string)"
  rand_admin="admin_$(random_string)"

  read -rp "请输入 TOKEN [默认随机: ${rand_token}]: " input_token
  TOKEN="${input_token:-$rand_token}"

  read -rp "请输入 ADMIN_TOKEN（管理专用）[默认随机: ${rand_admin}]: " input_admin
  ADMIN_TOKEN="${input_admin:-$rand_admin}"

  read -rp "镜像 TAG [默认 latest，例如 latest 或具体版本号]: " input_tag
  IMAGE_TAG="${input_tag:-latest}"

  read -rp "是否启用 watchtower 自动更新? (y/N): " input_wt
  case "${input_wt}" in
    y|Y) ENABLE_WATCHTOWER="true" ;;
    *)   ENABLE_WATCHTOWER="false" ;;
  esac

  read -rp "是否尝试自动放行防火墙端口 ${PORT}? (y/N): " input_fw
  case "${input_fw}" in
    y|Y) AUTO_OPEN_FIREWALL="true" ;;
    *)   AUTO_OPEN_FIREWALL="false" ;;
  esac

  read -rp "请输入 BILIBILI_COOKIE（可留空）: " BILIBILI_COOKIE

  cat > "${DANMU_ENV_FILE}" <<EOF
# danmu-api 配置文件（由 install_compose.sh 生成/更新）

# 对外访问端口（仅用于生成说明，不直接被程序读取）
PORT=${PORT}

# 访问令牌（URL 路径的一部分）
TOKEN=${TOKEN}

# 管理后台令牌（URL 路径的一部分，务必保密）
ADMIN_TOKEN=${ADMIN_TOKEN}

# 弹幕颜色处理：default / white / color
CONVERT_COLOR=default

# 源优先级
SOURCE_ORDER=default

# 其他弹幕服务器
OTHER_SERVER=

# VOD 服务器相关
VOD_SERVERS=
VOD_RETURN_MODE=merge
VOD_REQUEST_TIMEOUT=8000
YOUKU_CONCURRENCY=4

# B 站 Cookie（可选）
BILIBILI_COOKIE=${BILIBILI_COOKIE}

# 镜像 TAG，如 latest 或具体版本号
IMAGE_TAG=${IMAGE_TAG}

# 是否启用 watchtower 自动更新（true/false）
ENABLE_WATCHTOWER=${ENABLE_WATCHTOWER}

# 是否自动放行防火墙端口（true/false）
AUTO_OPEN_FIREWALL=${AUTO_OPEN_FIREWALL}
EOF

  success "配置文件已写入：${DANMU_ENV_FILE}"

  export PORT TOKEN ADMIN_TOKEN BILIBILI_COOKIE IMAGE_TAG ENABLE_WATCHTOWER AUTO_OPEN_FIREWALL
}

#################### 生成 docker-compose.yml ####################

create_compose_file() {
  mkdir -p "${COMPOSE_DIR}"

  cat > "${COMPOSE_FILE}" <<EOF
services:
  danmu-api:
    image: ${IMAGE_REPO}:${IMAGE_TAG:-latest}
    container_name: danmu-api
    restart: unless-stopped

    ports:
      - "${PORT:-8080}:9321"

    environment:
      - TZ=Asia/Shanghai

    volumes:
      - "${DANMU_ENV_FILE}:/app/.env"
EOF

  success "docker-compose 配置已写入：${COMPOSE_FILE}"
}

#################### 防火墙放行 ####################

open_firewall_port() {
  if [ "${AUTO_OPEN_FIREWALL}" != "true" ]; then
    return 0
  fi

  local port="${PORT:-8080}"

  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -q "Status: active"; then
      info "检测到 ufw，尝试放行端口 ${port}/tcp ..."
      ufw allow "${port}/tcp" >/dev/null 2>&1 || warn "ufw 放行端口失败，请手动检查。"
    fi
  elif command -v firewall-cmd >/dev/null 2>&1; then
    info "检测到 firewalld，尝试放行端口 ${port}/tcp ..."
    firewall-cmd --add-port="${port}/tcp" --permanent >/dev/null 2>&1 || warn "firewalld 放行端口失败。"
    firewall-cmd --reload >/dev/null 2>&1 || true
  else
    warn "未检测到 ufw 或 firewalld，跳过自动放行防火墙端口，请按需手动配置。"
  fi
}

#################### watchtower 自动更新 ####################

setup_watchtower() {
  if [ "${ENABLE_WATCHTOWER}" != "true" ]; then
    info "未启用 watchtower 自动更新。"
    return 0
  fi

  info "配置 watchtower 自动更新 danmu-api 容器..."

  if docker ps -a --format '{{.Names}}' | grep -wq "watchtower-danmu-api"; then
    docker stop watchtower-danmu-api >/dev/null 2>&1 || true
    docker rm watchtower-danmu-api >/dev/null 2>&1 || true
  fi

  docker run -d \
    --name watchtower-danmu-api \
    -v /var/run/docker.sock:/var/run/docker.sock \
    --restart always \
    -e TZ=Asia/Shanghai \
    -e WATCHTOWER_SCHEDULE="0 0 4 * * *" \
    containrrr/watchtower \
    danmu-api >/dev/null 2>&1 || warn "watchtower 启动失败，请手动检查。"

  success "watchtower 已配置（每日凌晨 4 点检查 danmu-api 更新）。"
}

#################### 启动服务 ####################

start_service() {
  local full_image="${IMAGE_REPO}:${IMAGE_TAG:-latest}"

  info "拉取镜像：${full_image}"
  docker pull "${full_image}" || warn "镜像拉取失败，将尝试使用本地缓存镜像（如果有）。"

  info "使用 docker compose 启动 danmu-api..."
  docker compose -f "${COMPOSE_FILE}" up -d

  success "danmu-api 已启动。"
}

#################### 生成使用说明 ####################

generate_readme() {
  local README_FILE="/root/README_danmu-api_compose.txt"

  # shellcheck disable=SC1090
  source "${DANMU_ENV_FILE}" || true

  local SERVER_IP
  SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
  [ -z "${SERVER_IP}" ] && SERVER_IP="你的服务器IP"

  cat > "${README_FILE}" <<EOF
==================== danmu-api · Docker Compose 部署说明 ====================

一、服务访问

1. 普通访问地址（请替换成你自己的 IP / 域名）：

   http://${SERVER_IP}:${PORT}/${TOKEN}

2. 管理后台地址（包含日志查看、在线配置等，务必保密）：

   http://${SERVER_IP}:${PORT}/${ADMIN_TOKEN}

如通过 Cloudflare / 反向代理，可将上面的 IP 替换为你的域名，例如：

   https://你的域名/${TOKEN}
   https://你的域名/${ADMIN_TOKEN}


二、常用 Docker Compose 命令（需在 ${COMPOSE_DIR} 目录执行）

1. 启动 / 更新服务：

   cd ${COMPOSE_DIR}
   docker compose up -d

2. 停止服务：

   cd ${COMPOSE_DIR}
   docker compose down

3. 查看运行状态：

   cd ${COMPOSE_DIR}
   docker compose ps

4. 查看日志：

   docker logs -f danmu-api


三、修改配置

1. 编辑配置文件：

   nano ${DANMU_ENV_FILE}

2. 保存后重启服务使其生效：

   cd ${COMPOSE_DIR}
   docker compose down
   docker compose up -d


四、关于自动更新与防火墙

- 镜像仓库：${IMAGE_REPO}
- 镜像 TAG：${IMAGE_TAG}

- watchtower 自动更新：${ENABLE_WATCHTOWER}
  若为 true，则每日凌晨 4 点检查 danmu-api 是否有新镜像。

- 自动放行防火墙端口：${AUTO_OPEN_FIREWALL}


五、卸载（完全删除容器及配置）

   bash install_compose.sh uninstall

   或在你使用的 curl 命令后面加上 "uninstall" 参数。

=====================================================================
EOF

  success "使用说明已生成：${README_FILE}"
}

#################### 安装完成后在终端打印摘要 ####################

print_final_hint() {
  # shellcheck disable=SC1090
  source "${DANMU_ENV_FILE}" || true
  local SERVER_IP
  SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
  [ -z "${SERVER_IP}" ] && SERVER_IP="你的服务器IP"

  echo
  echo "==================== 安装完成 · 信息摘要 ===================="
  echo "普通访问:  http://${SERVER_IP}:${PORT}/${TOKEN}"
  echo "管理后台:  http://${SERVER_IP}:${PORT}/${ADMIN_TOKEN}"
  echo
  echo "配置说明文件: /root/README_danmu-api_compose.txt"
  echo
  echo "常用命令："
  echo "  更新/重装：bash <(curl -fsSL ${SCRIPT_URL})"
  echo "  卸载：    bash <(curl -fsSL ${SCRIPT_URL}) uninstall"
  echo "  状态：    bash <(curl -fsSL ${SCRIPT_URL}) status"
  echo "==========================================================="
}

#################### 状态查看 ####################

show_status() {
  require_root
  info "当前 Docker 容器列表（过滤 danmu）："
  docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -i 'danmu' || echo "暂无 danmu 相关容器。"

  if [ -f "${COMPOSE_FILE}" ]; then
    echo
    info "docker compose ps："
    (cd "${COMPOSE_DIR}" && docker compose ps || true)
  fi

  exit 0
}

#################### 主流程 ####################

main() {
  case "$1" in
    uninstall)
      uninstall_all
      ;;
    status)
      show_status
      ;;
    *)
      require_root
      install_docker_and_compose

      # 安装前检查是否已有安装，有的话先完整卸载
      if has_previous_install; then
        warn "检测到已有 danmu-api 部署，将先卸载旧版本后再安装。"
        _do_uninstall
      fi

      # 全新创建配置
      create_env_fresh
      create_compose_file
      open_firewall_port
      start_service
      setup_watchtower
      generate_readme
      print_final_hint

      echo
      success "全部完成！你可以查看 /root/README_danmu-api_compose.txt 获取详细使用说明。"
      ;;
  esac
}

main "$@"
