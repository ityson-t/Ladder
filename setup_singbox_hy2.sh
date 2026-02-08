#!/usr/bin/env bash
# 一键：安装 sing-box（官方 deb 安装脚本）+ 申请/安装域名证书（Cloudflare DNS, acme.sh）并绑定自动重启 + 生成 hysteria2 配置 + 启动/自启
# 适用：Ubuntu/Debian（systemd）
# 用法：
#   保存为 setup_singbox_hy2_cf.sh
#   chmod +x setup_singbox_hy2_cf.sh
#   sudo ./setup_singbox_hy2_cf.sh

set -u
export LC_ALL=C

ok_list=()
fail_list=()

log_ok()   { ok_list+=("$1"); }
log_fail() { fail_list+=("$1 => $2"); }

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "错误：请使用 root 执行（例如 sudo ./setup_singbox_hy2_cf.sh）。"
    exit 1
  fi
}

print_line() { printf '%s\n' "------------------------------------------------------------"; }

is_number() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

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

acme_has_cert() {
  # acme_has_cert "/path/to/acme.sh" "domain"
  local acme="$1"
  local domain="$2"
  "${acme}" --list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "${domain}"
}

# ---------------- 交互输入 ----------------
require_root

print_line
echo "将执行以下动作："
echo "1) 安装 sing-box 官方内核（deb-install.sh）"
echo "2) 确保 acme.sh 存在（若不存在则安装）"
echo "3) 使用 Cloudflare DNS 自动签发证书（若该域名还没有证书）"
echo "4) 安装证书到 /usr/local/etc/xray/ 并绑定证书更新后自动重启 sing-box"
echo "5) 写入 /etc/sing-box/config.json（Hysteria2 入站）"
echo "6) systemctl enable --now sing-box"
print_line

read -r -p "请输入 ZeroSSL 注册邮箱（用于 acme.sh 账户注册）： " ZEROSSL_EMAIL
while [ -z "${ZEROSSL_EMAIL}" ]; do
  read -r -p "邮箱不能为空，请重新输入： " ZEROSSL_EMAIL
done

read -r -p "请输入 Cloudflare Global API Key（不是 Token）： " CF_Key
while [ -z "${CF_Key}" ]; do
  read -r -p "Key 不能为空，请重新输入： " CF_Key
done

read -r -p "请输入 Cloudflare 账户邮箱（对应 Global API Key 的邮箱）： " CF_Email
while [ -z "${CF_Email}" ]; do
  read -r -p "邮箱不能为空，请重新输入： " CF_Email
done

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

print_line
echo "域名：${DOMAIN}"
echo "UDP 端口：${PORT}"
echo "证书输出："
echo "  Key : ${CERT_KEY}"
echo "  CRT : ${CERT_CRT}"
echo "注意：请确保云厂商安全组/防火墙已放行 UDP ${PORT}"
print_line

read -r -p "确认开始执行？输入 y 继续： " CONFIRM
if [ "${CONFIRM}" != "y" ] && [ "${CONFIRM}" != "Y" ]; then
  echo "已取消。"
  exit 0
fi

print_line
echo "开始执行..."
print_line

# ---------------- 1) 安装 sing-box ----------------
run_step_shell_capture "安装 sing-box（官方 deb-install.sh）" \
  'bash <(curl -fsSL https://sing-box.app/deb-install.sh)' || true

if command -v sing-box >/dev/null 2>&1; then
  log_ok "验证 sing-box 命令可用"
else
  log_fail "验证 sing-box 命令可用" "未找到 sing-box，请检查安装脚本输出或网络"
fi

# ---------------- 2) 确保 acme.sh + socat ----------------
# dns_cf 不一定需要 socat，但很多场景安装它有益（并与你之前习惯一致）
if command -v socat >/dev/null 2>&1; then
  log_ok "socat 已安装（跳过）"
else
  run_step_capture "安装 socat" apt update -y || true
  run_step_capture "安装 socat（apt install -y）" apt install -y socat || true
fi

ACME_SH="$(detect_acme_sh)"
if [ -z "${ACME_SH}" ]; then
  run_step_shell_capture "安装 acme.sh" 'curl -fsSL https://get.acme.sh | sh' || true
  ACME_SH="$(detect_acme_sh)"
fi

if [ -n "${ACME_SH}" ]; then
  log_ok "定位 acme.sh：${ACME_SH}"
else
  log_fail "定位 acme.sh" "未找到 acme.sh，无法继续申请/安装证书"
fi

# 注册 ZeroSSL 账户（可重复执行，已注册会提示已存在）
if [ -n "${ACME_SH}" ]; then
  run_step_capture "注册/确认 ZeroSSL 账户" "${ACME_SH}" --register-account -m "${ZEROSSL_EMAIL}" || true
fi

# ---------------- 3) 签发证书（若不存在） ----------------
export CF_Key="${CF_Key}"
export CF_Email="${CF_Email}"

if [ -n "${ACME_SH}" ]; then
  if acme_has_cert "${ACME_SH}" "${DOMAIN}"; then
    log_ok "acme.sh 已存在该域名证书记录（跳过签发）"
  else
    run_step_capture "签发证书（dns_cf）" "${ACME_SH}" --issue --dns dns_cf -d "${DOMAIN}" || true
  fi
fi

# ---------------- 4) 安装证书并绑定自动重启 ----------------
run_step_capture "创建证书目录 ${CERT_DIR}" mkdir -p "${CERT_DIR}" || true

if [ -n "${ACME_SH}" ]; then
  run_step_capture "安装证书并绑定重启 sing-box（acme.sh --install-cert）" \
    "${ACME_SH}" --install-cert -d "${DOMAIN}" \
      --key-file "${CERT_KEY}" \
      --fullchain-file "${CERT_CRT}" \
      --reloadcmd "systemctl restart sing-box" || true
fi

# ---------------- 5) 写入 sing-box 配置 ----------------
run_step_capture "创建配置目录 /etc/sing-box" mkdir -p /etc/sing-box || true

CONFIG_PATH="/etc/sing-box/config.json"

# JSON 不能写 // 注释，避免 sing-box 解析失败
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

# 可选：配置校验（不一定所有版本都支持 check 子命令；失败不影响启动）
if sing-box help 2>/dev/null | grep -qE '\bcheck\b'; then
  run_step_capture "配置语法检查（sing-box check）" sing-box check -c "${CONFIG_PATH}" || true
else
  log_ok "跳过配置语法检查（sing-box check 不可用）"
fi

# ---------------- 6) 启动并自启 ----------------
run_step_capture "systemctl enable --now sing-box" systemctl enable --now sing-box || true

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
echo "运行要点："
echo "- 协议：Hysteria2（UDP ${PORT}）"
echo "- 配置：${CONFIG_PATH}"
echo "- 证书：${CERT_CRT} / ${CERT_KEY}"
echo "- 安全组/防火墙：请放行 UDP ${PORT}"
print_line

# 证书文件检查
echo "证书文件检查："
if [ -f "${CERT_KEY}" ] && [ -f "${CERT_CRT}" ]; then
  echo "  ✅ 证书文件已就绪"
else
  echo "  ❌ 证书文件未就绪（若签发/安装失败，请查看失败项里的错误原文）"
fi
print_line

if [ "${#fail_list[@]}" -ne 0 ]; then
  exit 1
fi
exit 0
