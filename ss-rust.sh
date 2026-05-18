#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="0.1.5"
REPO_RAW="https://raw.githubusercontent.com/shuijiao1/SS-Rust-Manager/main"
UPDATE_URL="$REPO_RAW/ss-rust.sh"
VERSION_URL="$REPO_RAW/version.txt"
BIN="/usr/local/bin/ss-rust"
CONFIG_DIR="/etc/ss-rust"
CONFIG_FILE="$CONFIG_DIR/config.json"
SERVICE_FILE="/etc/systemd/system/ss-rust.service"
SERVICE_NAME="ss-rust"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;35m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
say(){ printf '%b\n' "$*"; }; ok(){ say "${GREEN}✓${NC} $*"; }; err(){ say "${RED}✖${NC} $*" >&2; }; info(){ say "${BLUE}▶${NC} $*"; }; warn(){ say "${YELLOW}⚠${NC} $*"; }
have(){ command -v "$1" >/dev/null 2>&1; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || { err "请用 root 运行"; exit 1; }; }
install_pkg(){ if have apt-get; then apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"; elif have dnf; then dnf install -y "$@"; elif have yum; then yum install -y "$@"; else err "未找到包管理器，请手动安装：$*"; exit 1; fi; }
ensure_deps(){ local m=(); for c in curl tar xz jq systemctl openssl; do have "$c" || m+=("$c"); done; ((${#m[@]}==0)) || install_pkg curl tar xz-utils jq systemd openssl coreutils; }
validate_port(){ [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1>=1 && 10#$1<=65535)); }
rand_port(){ echo $((RANDOM % 55536 + 10000)); }
method_key_bytes(){
  case "$1" in
    2022-blake3-aes-128-gcm) echo 16 ;;
    2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) echo 32 ;;
    *) echo 0 ;;
  esac
}
rand_pass_for_method(){
  local method="$1" bytes
  bytes="$(method_key_bytes "$method")"
  if (( bytes > 0 )); then
    openssl rand -base64 "$bytes"
  else
    openssl rand -base64 18 | tr -d '=+/' | cut -c1-20
  fi
}
rand_pass(){ rand_pass_for_method "2022-blake3-aes-128-gcm"; }
validate_password_for_method(){
  local method="$1" password="$2" bytes actual
  bytes="$(method_key_bytes "$method")"
  (( bytes == 0 )) && return 0
  actual=$(printf '%s' "$password" | openssl base64 -A -d 2>/dev/null | wc -c | tr -d ' ' || true)
  [[ "$actual" == "$bytes" ]] || { err "$method 需要 base64 后解码长度为 ${bytes} 字节的密码，当前为 ${actual:-0} 字节"; return 1; }
}
select_method(){
  local default="${1:-2022-blake3-aes-128-gcm}" c
  say "请选择加密方式（直接回车默认：$default）" >&2
  say "${GREEN}1.${NC} 2022-blake3-aes-128-gcm（推荐，16 字节 key）" >&2
  say "${GREEN}2.${NC} 2022-blake3-aes-256-gcm（32 字节 key）" >&2
  say "${GREEN}3.${NC} 2022-blake3-chacha20-poly1305（32 字节 key）" >&2
  say "${GREEN}4.${NC} aes-128-gcm" >&2
  say "${GREEN}5.${NC} aes-256-gcm" >&2
  say "${GREEN}6.${NC} chacha20-ietf-poly1305" >&2
  read -rp "请输入选项 [1-6]: " c
  case "${c:-}" in
    "" ) echo "$default" ;;
    1) echo "2022-blake3-aes-128-gcm" ;;
    2) echo "2022-blake3-aes-256-gcm" ;;
    3) echo "2022-blake3-chacha20-poly1305" ;;
    4) echo "aes-128-gcm" ;;
    5) echo "aes-256-gcm" ;;
    6) echo "chacha20-ietf-poly1305" ;;
    *) err "无效选项"; return 1 ;;
  esac
}
urlencode(){ local LC_ALL=C s="$1" o="" i c h; for ((i=0;i<${#s};i++)); do c=${s:i:1}; case "$c" in [a-zA-Z0-9.~_-]) o+="$c";; *) printf -v h '%%%02X' "'$c"; o+="$h";; esac; done; printf '%s' "$o"; }

asset_regex(){ case "$(uname -m)" in x86_64|amd64) echo 'x86_64-unknown-linux-gnu\.tar\.xz$';; *) err "暂只支持 amd64/x86_64，当前架构：$(uname -m)"; exit 1;; esac; }
latest_asset(){ local json url re; re="$(asset_regex)"; json="$(curl -fsSL https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest)"; url="$(printf '%s' "$json" | jq -r --arg re "$re" '.assets[] | select(.name|test($re)) | .browser_download_url' | head -n1)"; [[ -n "$url" && "$url" != null ]] || { err "未找到当前架构的 shadowsocks-rust Release 资产"; exit 1; }; echo "$url"; }
install_ss(){ ensure_deps; local url tmp method password; url="$(latest_asset)"; tmp="$(mktemp -d)"; info "下载 shadowsocks-rust：$url"; curl -fL --retry 3 -o "$tmp/ss.tar.xz" "$url"; tar -xf "$tmp/ss.tar.xz" -C "$tmp"; install -m 0755 "$tmp/ssserver" "$BIN"; rm -rf "$tmp"; mkdir -p "$CONFIG_DIR"; if [[ ! -s "$CONFIG_FILE" ]]; then read -rp "请输入 ss-rust 监听端口（留空随机）: " port; port=${port:-$(rand_port)}; validate_port "$port" || { err "端口无效"; exit 1; }; method="$(select_method)" || exit 1; read -rp "请输入 ss-rust 密码（留空随机）: " password; password=${password:-$(rand_pass_for_method "$method")}; validate_password_for_method "$method" "$password" || exit 1; cat > "$CONFIG_FILE" <<EOF
{
  "server": "0.0.0.0",
  "server_port": $port,
  "password": "$password",
  "method": "$method",
  "timeout": 300,
  "fast_open": false,
  "mode": "tcp_and_udp"
}
EOF
  fi; cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Shadowsocks Rust Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=$BIN -c $CONFIG_FILE
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload; systemctl enable --now "$SERVICE_NAME"; ok "ss-rust 已安装/更新并启动"; view_config; }
view_config(){ [[ -f "$CONFIG_FILE" ]] || { err "未安装/无配置"; return 1; }; ensure_deps; local port password method ip p_enc tag; port=$(jq -r .server_port "$CONFIG_FILE"); password=$(jq -r .password "$CONFIG_FILE"); method=$(jq -r .method "$CONFIG_FILE"); ip=$(curl -fsS4 https://ipv4.icanhazip.com 2>/dev/null | tr -d '\n' || true); ip=${ip:-"<服务器IP>"}; p_enc=$(urlencode "$password"); tag=$(urlencode VPS); say "------------------------------------------"; say "ss-rust 当前配置"; say "地址: ${GREEN}$ip${NC}"; say "端口: ${GREEN}$port${NC}"; say "密码: ${GREEN}$password${NC}"; say "加密: ${GREEN}$method${NC}"; say "------------------------------------------"; say "Surge:"; say "${GREEN}VPS = ss, $ip, $port, encrypt-method=$method, password=$password, udp-relay=true${NC}"; say "URI:"; say "${GREEN}ss://${method}:${p_enc}@${ip}:${port}#${tag}${NC}"; say "------------------------------------------"; }
modify_config(){ [[ -f "$CONFIG_FILE" ]] || { err "ss-rust 未安装"; return 1; }; ensure_deps; local old_method method; old_method=$(jq -r .method "$CONFIG_FILE" 2>/dev/null || echo "2022-blake3-aes-128-gcm"); read -rp "新端口（留空随机）: " port; port=${port:-$(rand_port)}; validate_port "$port" || { err "端口无效"; return 1; }; method="$(select_method "$old_method")" || return 1; read -rp "新密码（留空随机）: " password; password=${password:-$(rand_pass_for_method "$method")}; validate_password_for_method "$method" "$password" || return 1; jq --argjson port "$port" --arg password "$password" --arg method "$method" '.server_port=$port | .password=$password | .method=$method' "$CONFIG_FILE" > /tmp/ss-rust.json && mv /tmp/ss-rust.json "$CONFIG_FILE"; systemctl restart "$SERVICE_NAME"; ok "配置已更新"; view_config; }
uninstall_ss(){ read -rp "确认卸载 ss-rust？[y/N]: " y; [[ "$y" =~ ^[Yy]$ ]] || return 0; systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true; rm -f "$SERVICE_FILE" "$BIN"; rm -rf "$CONFIG_DIR"; systemctl daemon-reload; ok "已卸载 ss-rust"; }
service_ctl(){ case "$1" in start|stop|restart) systemctl "$1" "$SERVICE_NAME" && ok "服务已$1";; status) systemctl --no-pager --full status "$SERVICE_NAME" || true;; esac; }
check_update(){ local r tmp; r=$(curl -fsSL "$VERSION_URL" 2>/dev/null | head -n1 | tr -cd '0-9.' || true); [[ -n "$r" && "$r" != "$VERSION" ]] || { ok "脚本已是最新 v$VERSION"; return; }; warn "发现新版脚本 v$r"; read -rp "更新？[y/N]: " y; [[ "$y" =~ ^[Yy]$ ]] || return; tmp=$(mktemp); curl -fsSL "$UPDATE_URL" -o "$tmp"; bash -n "$tmp"; install -m 0755 "$tmp" "$0"; rm -f "$tmp"; ok "脚本已更新"; exit 0; }
install_status(){ [[ -x "$BIN" ]] && printf "${GREEN}已安装${NC}" || printf "${RED}未安装${NC}"; }
run_status(){ systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null && printf "${GREEN}运行中${NC}" || printf "${RED}未运行${NC}"; }
menu() {
  need_root
  ensure_deps
  while true; do
    clear || true
    say "${CYAN}============================================${NC}"
    say "          ${CYAN}Shadowsocks-Rust 管理脚本 v$VERSION${NC}"
    say "${CYAN}============================================${NC}"
    say "${GREEN}仓库: github.com/shuijiao1/SS-Rust-Manager${NC}"
    say "${GREEN}作者: shuijiao1${NC}"
    say "${CYAN}============================================${NC}"
    say "安装状态：$(install_status)"
    say "运行状态：$(run_status)"
    say ""
    say "${BLUE}=== 基础功能 ===${NC}"
    say "${GREEN}1.${NC} 安装/更新 ss-rust"
    say "${GREEN}2.${NC} 卸载 ss-rust"
    say "${GREEN}3.${NC} 修改配置"
    say "${GREEN}4.${NC} 查看配置"
    say "${GREEN}5.${NC} 重启服务"
    say ""
    say "${BLUE}=== 服务管理 ===${NC}"
    say "${GREEN}6.${NC} 启动服务"
    say "${GREEN}7.${NC} 停止服务"
    say "${GREEN}8.${NC} 查看服务状态"
    say ""
    say "${BLUE}=== 系统功能 ===${NC}"
    say "${GREEN}9.${NC} 检查脚本更新"
    say "${GREEN}0.${NC} 退出脚本"
    say "${CYAN}============================================${NC}"
    read -rp "请输入选项 [0-9]: " c
    case "$c" in
      1) install_ss ;;
      2) uninstall_ss ;;
      3) modify_config ;;
      4) view_config ;;
      5) service_ctl restart ;;
      6) service_ctl start ;;
      7) service_ctl stop ;;
      8) service_ctl status ;;
      9) check_update ;;
      0) exit 0 ;;
      *) err "无效选项" ;;
    esac
    say ""
    read -rp "按回车继续..." _
  done
}

case "${1:-}" in install) need_root; install_ss;; config|view) need_root; view_config;; modify) need_root; modify_config;; start|stop|restart|status) need_root; service_ctl "$1";; uninstall) need_root; uninstall_ss;; update-script) need_root; check_update;; -h|--help|help) echo "bash ss-rust.sh [install|modify|view|start|stop|restart|status|uninstall|update-script]";; *) menu;; esac
