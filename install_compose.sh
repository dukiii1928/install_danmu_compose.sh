#!/usr/bin/env bash
# LogVar 弹幕 API · Docker Compose 一键部署脚本
#
# 用法：
#   安装/更新：bash install_compose.sh
#   卸载：    bash install_compose.sh uninstall
#   状态：    bash install_compose.sh status
#
# 特点：
#   - 自动安装 Docker + Docker Compose（Debian/Ubuntu）
#   - 生成 /root/danmu-config/.env（容器挂载到 /app/config/.env，兼容 v1.9.2+）
#   - 生成 /root/danmu-compose/docker-compose.yml 并启动
#   - 可选开启 watchtower 自动更新
#   - 可选安装时填写 BILIBILI_COOKIE
#   - 自动生成 /root/README_danmu-api_compose.txt 使用说明
#
# 注意：
#   - 本脚本不包含任何真实 TOKEN，适合上传 GitHub
#   - 真正的配置在 /root/danmu-config 目录，请勿提交到公共仓库

set -e

#################### 路径与常量 ####################

DANMU_ENV_DIR="/root/danmu-config"
DANMU_ENV_FILE="${DANMU_ENV_DIR}/.env"

COMPOSE_DIR="/root/danmu-compose"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"

README_FILE="/root/README_danmu-api_compose.txt"

IMAGE_REPO="logvar/danmu-api"

# 这里写你 GitHub 上脚本的 raw 地址，方便 README 里展示
SCRIPT_URL="https://raw.githubusercontent.com/dukiii1928/install_danmu_compose.sh/main/install_compose.sh"

#################### 日志函数 ####################

info()    { echo -e "\033[1;34m[信息]\033[0m $*"; }
warn()    { echo -e "\033[1;33m[警告]\033[0m $*"; }
success() { echo -e "\033[1;32m[成功]\033[0m $*"; }
error()   { echo -e "\033[1;31m[错误]\033[0m $*"; }

require_root() {
  if [ "$(id -u)" != "0" ]; then
    error "请使用 root 用户运行本脚本（或在前面加 sudo）。"
    exit 1
  fi
}

#################### 系统与 Docker ####################

check_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
  else
    OS=$(uname -s)
  fi

  case "$OS" in
    debian|ubuntu)
      info "检测到系统：$PRETTY_NAME"
      ;;
    *)
      warn "当前系统不是 Debian/Ubuntu，脚本不会自动安装 Docker，请确保已安装 docker 和 docker compose。"
      ;;
  esac
}

install_docker_if_needed() {
  if command -v docker >/dev/null 2>&1; then
    info "Docker 已安装。"
  else
    case "$OS" in
      debian|ubuntu)
        info "开始安装 Docker..."
        apt-get update
        apt-get install -y ca-certificates curl gnupg lsb-release

        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/$ID/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg

        echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$ID \
$(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list >/dev/null

        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

        systemctl enable docker
        systemctl start docker
        success "Docker 安装完成。"
        ;;
      *)
        warn "非 Debian/Ubuntu 系统，请手动安装 Docker 和 Docker Compose。"
        ;;
    esac
  fi

  if docker compose version >/dev/null 2>&1; then
    info "docker compose 插件已安装。"
  else
    if command -v docker-compose >/dev/null 2>&1; then
      info "检测到 docker-compose 二进制，将使用 docker-compose。"
    else
      error "未检测到 docker compose，请安装后重试。"
      exit 1
    fi
  fi
}

compose_cmd() {
  if command -v docker compose >/dev/null 2>&1; then
    echo "docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
  else
    error "未找到 docker compose 或 docker-compose 命令。"
    exit 1
  fi
}

#################### 端口与防火墙 ####################

ask_port() {
  local default_port=8080
  read -rp "请输入对外访问端口 [默认 ${default_port}]：" PORT
  PORT=${PORT:-$default_port}

  if ! [[ $PORT =~ ^[0-9]+$ ]] || [ "$PORT" -le 0 ] || [ "$PORT" -gt 65535 ]; then
    error "端口格式不正确，请重新运行脚本。"
    exit 1
  fi
  info "将使用端口：$PORT"
}

open_firewall_port() {
  local port=$1

  if command -v ufw >/dev/null 2>&1; then
    if ufw status | grep -q "Status: active"; then
      info "检测到 ufw 已启用，尝试放行端口 ${port}..."
      ufw allow "$port"/tcp || warn "ufw 放行端口失败，请手动检查。"
    fi
  fi

  if command -v firewall-cmd >/dev/null 2>&1; then
    if systemctl is-active firewalld >/dev/null 2>&1; then
      info "检测到 firewalld 正在运行，尝试放行端口 ${port}..."
      firewall-cmd --permanent --add-port="${port}"/tcp || warn "firewalld 放行端口失败，请手动检查。"
      firewall-cmd --reload || true
    fi
  fi
}

#################### 配置生成 ####################

random_string() {
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32
}

create_env_fresh() {
  info "生成环境配置文件：${DANMU_ENV_FILE}"
  mkdir -p "$DANMU_ENV_DIR"

  local default_token default_admin_token
  default_token=$(random_string)
  default_admin_token=$(random_string)

  read -rp "请输入 API TOKEN（留空随机生成）：" TOKEN
  TOKEN=${TOKEN:-$default_token}

  read -rp "请输入管理后台 ADMIN_TOKEN（留空随机生成）：" ADMIN_TOKEN
  ADMIN_TOKEN=${ADMIN_TOKEN:-$default_admin_token}

  read -rp "请输入镜像 TAG（默认 latest）：" IMAGE_TAG
  IMAGE_TAG=${IMAGE_TAG:-latest}

  read -rp "是否启用 watchtower 自动更新？[y/N]：" enable_watchtower
  if [[ "$enable_watchtower" =~ ^[Yy]$ ]]; then
    ENABLE_WATCHTOWER="true"
  else
    ENABLE_WATCHTOWER="false"
  fi

  read -rp "是否现在设置 B 站 Cookie（BILIBILI_COOKIE）？[y/N]：" set_bili
  if [[ "$set_bili" =~ ^[Yy]$ ]]; then
    echo "请粘贴你的 B 站 Cookie（整串或关键字段，注意不要在公共场合泄露）："
    read -r BILIBILI_COOKIE
  else
    BILIBILI_COOKIE=""
  fi

  cat > "${DANMU_ENV_FILE}" <<EOF
# danmu-api 环境配置（自动生成）
# 端口仅用于记录，真实映射写在 docker-compose.yml 中
PORT=${PORT}

# 基本认证
TOKEN=${TOKEN}
ADMIN_TOKEN=${ADMIN_TOKEN}

# 镜像版本记录（compose 文件中已写死为同一值）
IMAGE_TAG=${IMAGE_TAG}

# 是否启用 watchtower 自动更新（true/false）
ENABLE_WATCHTOWER=${ENABLE_WATCHTOWER}

# B 站 Cookie，如需使用请填写，否则留空。
BILIBILI_COOKIE=${BILIBILI_COOKIE}

# 其他可选环境变量建议在网页「环境变量配置」中维护，
# 程序会将配置持久化到 /app/config/.env 或 config.yaml。
EOF

  success "环境配置文件已生成：${DANMU_ENV_FILE}"
}

#################### docker-compose.yml 生成 ####################

create_compose_file() {
  info "生成 docker-compose.yml：${COMPOSE_FILE}"
  mkdir -p "$COMPOSE_DIR"

  cat > "${COMPOSE_FILE}" <<EOF
services:
  danmu-api:
    image: ${IMAGE_REPO}:${IMAGE_TAG}
    container_name: danmu-api
    restart: unless-stopped
    ports:
      - "${PORT}:9321"
    environment:
      - TZ=Asia/Shanghai
    # 挂载配置目录到 /app/config（v1.9.2+ 从该目录读取 .env / config.yaml）
    volumes:
      - "${DANMU_ENV_DIR}:/app/config"
EOF

  if [ "${ENABLE_WATCHTOWER}" = "true" ]; then
    cat >> "${COMPOSE_FILE}" <<'EOF'

  watchtower:
    image: containrrr/watchtower
    container_name: watchtower
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    command: --cleanup --schedule "0 0 4 * * *" danmu-api
EOF
  fi

  success "docker-compose.yml 已生成。"
}

#################### 运行 / 停止 / 卸载 ####################

start_compose() {
  local cc
  cc=$(compose_cmd)
  info "使用 ${cc} 启动服务..."
  (cd "$COMPOSE_DIR" && $cc up -d)
  success "danmu-api 已启动。"
}

stop_compose() {
  if [ ! -f "$COMPOSE_FILE" ]; then
    warn "未找到 ${COMPOSE_FILE}，可能尚未安装。"
    return
  fi
  local cc
  cc=$(compose_cmd)
  info "使用 ${cc} 停止服务..."
  (cd "$COMPOSE_DIR" && $cc down) || true
  success "服务已停止。"
}

uninstall_all() {
  warn "即将卸载 danmu-api 及其相关配置："
  warn "  - 停止并移除容器"
  warn "  - 删除 ${COMPOSE_DIR}"
  warn "  - 删除 ${DANMU_ENV_DIR}（包含 .env 与网页配置）"
  warn "  - 删除 ${README_FILE}"
  read -rp "确认卸载？[y/N]：" confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    info "已取消卸载。"
    return
  fi

  stop_compose

  local cc
  cc=$(compose_cmd)
  (cd "$COMPOSE_DIR" && $cc rm -f) 2>/dev/null || true

  docker rm -f danmu-api watchtower 2>/dev/null || true

  rm -rf "$COMPOSE_DIR"
  rm -rf "$DANMU_ENV_DIR"
  rm -f "$README_FILE"

  success "卸载完成。"
}

check_status() {
  info "容器运行状态："
  docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" | grep -E "danmu-api|watchtower" || echo "未找到 danmu-api / watchtower 容器。"
}

#################### README 生成 ####################

generate_readme() {
  local token admin_token
  token=$(grep '^TOKEN=' "${DANMU_ENV_FILE}" | cut -d'=' -f2)
  admin_token=$(grep '^ADMIN_TOKEN=' "${DANMU_ENV_FILE}" | cut -d'=' -f2)

  cat > "${README_FILE}" <<EOF
LogVar 弹幕 API · Docker Compose 部署说明
=====================================

一、基本信息
------------

- 镜像仓库：${IMAGE_REPO}
- 配置目录（宿主机）：${DANMU_ENV_DIR}
- docker-compose 目录：${COMPOSE_DIR}
- 访问端口：${PORT}
- TOKEN：${token}
- ADMIN_TOKEN：${admin_token}

二、常用访问地址
----------------

- 管理后台（使用 ADMIN_TOKEN）：
  http://你的服务器IP:${PORT}/${admin_token}

- 普通 API 示例（使用 TOKEN）：
  http://你的服务器IP:${PORT}/${token}?url=视频地址

三、目录说明
------------

- ${DANMU_ENV_DIR}
  - .env         # 基础环境变量（由 install_compose.sh 生成，可被网页配置覆盖）
  - config.yaml  # 如通过网页端「环境变量配置」保存，程序可能生成该文件

- ${COMPOSE_DIR}
  - docker-compose.yml  # compose 配置文件

四、常用命令
------------

# 查看容器状态
docker ps

# 进入 docker-compose 目录
cd ${COMPOSE_DIR}

# 启动/更新服务
$(compose_cmd) pull
$(compose_cmd) up -d

# 停止服务
$(compose_cmd) down

五、重新安装 / 卸载
--------------------

# 重新安装（会停止旧容器并删除配置后重装）
bash install_compose.sh

# 仅卸载（停止容器 + 删除所有配置）
bash install_compose.sh uninstall

六、远程一键安装
----------------

可以在其他服务器使用下面命令一键安装（如你修改了仓库地址请同步更新）：

  bash <(curl -fsSL ${SCRIPT_URL})

EOF

  success "部署说明已生成：${README_FILE}"
}

#################### 主流程 ####################

main_install() {
  require_root
  check_os
  install_docker_if_needed
  ask_port
  open_firewall_port "$PORT"

  if [ -d "$DANMU_ENV_DIR" ] || [ -d "$COMPOSE_DIR" ]; then
    warn "检测到旧的 danmu-api 部署目录："
    [ -d "$DANMU_ENV_DIR" ] && warn "  - ${DANMU_ENV_DIR}"
    [ -d "$COMPOSE_DIR" ] && warn "  - ${COMPOSE_DIR}"
    read -rp "是否先卸载旧部署再重装？[Y/n]：" ans
    ans=${ans:-Y}
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      uninstall_all
    else
      warn "你选择保留旧部署，可能导致配置冲突，请自行确认。"
    fi
  fi

  create_env_fresh
  create_compose_file
  start_compose
  generate_readme

  local token admin_token
  token=$(grep '^TOKEN=' "${DANMU_ENV_FILE}" | cut -d'=' -f2)
  admin_token=$(grep '^ADMIN_TOKEN=' "${DANMU_ENV_FILE}" | cut -d'=' -f2)

  success "安装完成！"
  echo
  echo "================ 安装结果摘要 ================"
  echo "配置目录：${DANMU_ENV_DIR}"
  echo "compose 目录：${COMPOSE_DIR}"
  echo "访问端口：${PORT}"
  echo
  echo "管理后台示例地址（请把 你的服务器IP 换成真实 IP）："
  echo "  http://你的服务器IP:${PORT}/${admin_token}"
  echo
  echo "普通 API 示例："
  echo "  http://你的服务器IP:${PORT}/${token}?url=视频地址"
  echo
  echo "详细说明请查看：${README_FILE}"
  echo "============================================="
}

main() {
  case "$1" in
    uninstall)
      uninstall_all
      ;;
    status)
      check_status
      ;;
    *)
      main_install
      ;;
  esac
}

main "$@"
