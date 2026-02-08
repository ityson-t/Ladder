#!/usr/bin/env bash
# 一键：安装 sing-box（官方 deb 安装脚本）+ 生成 hysteria2 配置 + 安装证书并绑定自动重启 + 启动/自启
# 适用：Ubuntu/Debian（systemd）
# 用法：保存为 setup_singbox_hy2.sh，然后：chmod +x setup_singbox_hy2.sh && sudo ./setup_singbox_hy2.sh

set -u
export LC_ALL=C

ok_list=()
fail_list=()

log_ok()   { ok_list+=("$1"); }
log_fail() { fail_list+=("$1 => $2"); }

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "错误：请使用 root 执行（例如 sudo ./setup_singbox_hy2.sh）。"
    exit 1
  fi
}

run_step_capture() {
  # run_step_capture "步骤名" cmd args...
  local name="$1"; shift
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ $rc -eq 0 ]; then
    log_ok "$name"
    return 0
  else
    log_fail "$name" "$out"
    return $rc
  fi
}

run_step_shell_capture() {
  # run_step_shell_capture "步骤名" 'shell command...'
  local name="$1"; shift
  local cmd="$1"
  local out rc
  out="$(bash -lc "$cmd" 2>&1)"; rc=$?
  if [ $rc -eq 0 ]; then
    log_ok "$name"
    return 0
  else
    log_fail "$name" "$out"
    return $rc
  fi
}

print_line() { printf '%s\n' "------------------------------------------------------------"; }

detect_acme_sh() {
  if [ -x "/root/.acme.sh/acme.sh" ]; then
    echo "/root/.acme.sh/acme.sh"
  elif [ -x "${HOME}/.acme.sh/acme.sh" ]; then
    echo "${HOME}/.acme.sh/acme.sh"
  elif command -v acme.sh >/dev/null 2>&1; then
    command -v acme.sh
  else
    echo ""
  fi
}

is_number() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

# ---------------- 交互输入 ----------------
require_root

print_line
echo "将执行以下动作："
echo "1) 安装 sing-box 官方内核（deb-install.sh）"
echo "2) 写入 /etc/sing-box/config.json（Hysteria2 入站）"
echo "3) 使用 acme.sh 安装证书到 /usr/local/etc/xray/ 并绑定证书更新后重启 sing-box"
echo "4) systemctl enable --now sing-box"
print_line

read -r -p "请输入要用于证书的域名（例如 cc.itmanser.xyz）： " DOMAIN
while [ -z "${DOMAIN}" ]; do
  read -r -p "域名不能为空，请重新输入： " DOMAIN
done

read -r -p "请输入 Hysteria2 监听端口（UDP，例如 51618）： " PORT
while ! is_number "${PORT}" || [ "${PORT}" -lt 1 ] || [ "${PORT}" -gt 65535 ]; do
  read -r -p "端口不合法，请输入 1-65535 的数字： " PORT
done

read -r -p "请输入 Hysteria2 连接密码（password）： " HY2_PASSWORD
while [ -z "${HY2_PASSWORD}" ]; do
  read -r -p "密码不能为空，请重新输入： " HY2_PASSWORD
done

CERT_DIR="/usr/local/etc/xray"
CERT_KEY="${CERT_DIR}/hysteria.key"
CERT_CRT="${CERT_DIR}/hysteria.crt"

echo "证书将写入："
echo "  Key : ${CERT_KEY}"
echo "  CRT : ${CERT_CRT}"

read -r -p "确认开始执行？输入 y 继续： " CONFIRM
if [ "${CONFIRM}" != "y" ] && [ "${CONFIRM}" != "Y" ]; then
  echo "已取消。"
  exit 0
fi

print_line
echo "开始执行..."
print_line

# ---------------- 1) 安装 sing-box ----------------
# 官方安装脚本：bash <(curl -fsSL https://sing-box.app/deb-install.sh)
run_step_shell_capture "安装 sing-box（官方 deb-install.sh）" \
  'bash <(curl -fsSL https://sing-box.app/deb-install.sh)' || true

# 保险起见：确认二进制存在
if command -v sing-box >/dev/null 2>&1; then
  log_ok "验证 sing-box 命令可用"
else
  log_fail "验证 sing-box 命令可用" "未找到 sing-box，可尝试：apt update && apt install sing-box（若仓库已添加）或检查安装脚本输出"
fi

# ---------------- 2) 写入配置 /etc/sing-box/config.json ----------------
run_step_capture "创建配置目录 /etc/sing-box" mkdir -p /etc/sing-box || true

# 注意：JSON 不支持注释，这里不要写 // 注释
CONFIG_PATH="/etc/sing-box/config.json"
cat > "${CONFIG_PATH}" <<EOF
{
  "log": { "level": "warn" },
  "inbounds": [
    {
      "type": "hysteria2",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [
        { "password": "${HY2_PASSWORD}" }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "${CERT_CRT}",
        "key_path": "${CERT_KEY}"
      }
    }
  ],
  "outbounds": [
    { "type": "direct" }
  ]
}
EOF

if [ $? -eq 0 ]; then
  log_ok "写入配置 ${CONFIG_PATH}"
else
  log_fail "写入配置 ${CONFIG_PATH}" "写文件失败"
fi

# ---------------- 3) 安装证书并绑定自动重启 ----------------
# 需要 acme.sh 已经存在（你前一个脚本已安装的话一般在 /root/.acme.sh/acme.sh）
ACME_SH="$(detect_acme_sh)"
if [ -z "${ACME_SH}" ]; then
  log_fail "定位 acme.sh" "未找到 acme.sh。请先安装并签发证书（或先运行你的证书脚本）。"
else
  log_ok "定位 acme.sh：${ACME_SH}"
  run_step_capture "创建证书目录 ${CERT_DIR}" mkdir -p "${CERT_DIR}" || true

  # install-cert 会把证书拷贝到指定路径，并在续期后执行 reloadcmd
  run_step_capture "安装证书并绑定重启 sing-box（acme.sh --install-cert）" \
    "${ACME_SH}" --install-cert -d "${DOMAIN}" \
      --key-file "${CERT_KEY}" \
      --fullchain-file "${CERT_CRT}" \
      --reloadcmd "systemctl restart sing-box" || true
fi

# ---------------- 4) 启动并设置开机自启 ----------------
run_step_capture "systemctl enable --now sing-box" systemctl enable --now sing-box || true

# 验证服务状态
out="$(systemctl is-active sing-box 2>&1)"; rc=$?
if [ $rc -eq 0 ] && [ "$out" = "active" ]; then
  log_ok "验证 sing-box 服务为 active"
else
  log_fail "验证 sing-box 服务为 active" "$out"
fi

# ---------------- 输出结果 ----------------
print_line
echo "执行完成。结果清单："
print_line

echo "成功项（${#ok_list[@]}）："
for i in "${ok_list[@]}"; do
  echo "  ✅ $i"
done

print_line
echo "失败项（${#fail_list[@]}）："
if [ "${#fail_list[@]}" -eq 0 ]; then
  echo "  无"
else
  for i in "${fail_list[@]}"; do
    echo "  ❌ $i"
  done
fi

print_line
echo "重要提示：Hysteria2 使用 UDP 端口 ${PORT}，请在云厂商安全组/防火墙放行 UDP ${PORT}。"
echo "配置文件：${CONFIG_PATH}"
echo "证书文件：${CERT_CRT} / ${CERT_KEY}"
print_line

if [ "${#fail_list[@]}" -ne 0 ]; then
  exit 1
fi
exit 0
