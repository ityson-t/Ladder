#!/usr/bin/env bash
# 一键：更新系统 + 安装socat + 安装acme.sh并注册ZeroSSL + Cloudflare DNS申请证书 + 证书落盘到xray目录 + 开启BBR
# 适用：Ubuntu/Debian（apt）
# 用法：保存为 setup_ssl_bbr.sh，然后：chmod +x setup_ssl_bbr.sh && sudo ./setup_ssl_bbr.sh

set -u
export LC_ALL=C

# ---------- 工具函数 ----------
ok_list=()
fail_list=()

log_ok()   { ok_list+=("$1"); }
log_fail() { fail_list+=("$1 => $2"); }

run_step() {
  # run_step "步骤名" 命令...
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

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "错误：请使用 root 执行（例如 sudo ./setup_ssl_bbr.sh）。"
    exit 1
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

append_if_missing() {
  # append_if_missing "文件" "完整行内容"
  local file="$1"
  local line="$2"
  if grep -qsF "$line" "$file"; then
    return 0
  fi
  echo "$line" >> "$file"
}

print_line() { printf '%s\n' "------------------------------------------------------------"; }

# ---------- 交互输入 ----------
require_root

print_line
echo "将执行以下动作："
echo "1) apt update && apt upgrade"
echo "2) 安装 socat"
echo "3) 安装 acme.sh 并注册 ZeroSSL 账户"
echo "4) 使用 Cloudflare DNS API 申请证书"
echo "5) 证书输出到 /usr/local/etc/xray/"
echo "6) 开启 BBR（bbr + fq），并验证"
print_line

read -r -p "请输入 ZeroSSL 注册邮箱（用于 acme.sh --register-account）： " ZEROSSL_EMAIL
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

read -r -p "请输入要申请证书的域名（例如 sub.example.com）： " DOMAIN
while [ -z "${DOMAIN}" ]; do
  read -r -p "域名不能为空，请重新输入： " DOMAIN
done

read -r -p "确认开始执行？输入 y 继续： " CONFIRM
if [ "${CONFIRM}" != "y" ] && [ "${CONFIRM}" != "Y" ]; then
  echo "已取消。"
  exit 0
fi

print_line
echo "开始执行..."
print_line

# ---------- 1. 更新系统 ----------
run_step "apt update" apt update || true
run_step "apt upgrade -y" apt upgrade -y || true

# ---------- 2. 安装 socat ----------
run_step "安装 socat" apt install socat -y || true

# ---------- 3. 安装 acme.sh ----------
if [ -d "/root/.acme.sh" ] || [ -d "${HOME}/.acme.sh" ]; then
  log_ok "acme.sh 已存在（跳过安装）"
else
  # 这里不使用管道 set -e，收集错误输出
  out="$(curl -fsSL https://get.acme.sh 2>&1 | sh 2>&1)"
  rc=$?
  if [ $rc -eq 0 ]; then
    log_ok "安装 acme.sh"
  else
    log_fail "安装 acme.sh" "$out"
  fi
fi

# 定位 acme.sh
ACME_SH=""
if [ -x "/root/.acme.sh/acme.sh" ]; then
  ACME_SH="/root/.acme.sh/acme.sh"
elif [ -x "${HOME}/.acme.sh/acme.sh" ]; then
  ACME_SH="${HOME}/.acme.sh/acme.sh"
fi

if [ -z "${ACME_SH}" ]; then
  log_fail "定位 acme.sh" "未找到 ~/.acme.sh/acme.sh，请检查安装是否成功"
else
  log_ok "定位 acme.sh"
fi

# 注册 ZeroSSL（需要 acme.sh 存在）
if [ -n "${ACME_SH}" ]; then
  run_step "注册 ZeroSSL 账户" "${ACME_SH}" --register-account -m "${ZEROSSL_EMAIL}" || true
fi

# ---------- 4. 申请证书（Cloudflare DNS） ----------
# Cloudflare DNS 插件需要环境变量（export）
export CF_Key="${CF_Key}"
export CF_Email="${CF_Email}"

if [ -n "${ACME_SH}" ]; then
  # 注意：dns_cf 使用的是 Cloudflare Global API Key + Email
  run_step "申请证书（dns_cf）" "${ACME_SH}" --issue --dns dns_cf -d "${DOMAIN}" || true
fi

# ---------- 5. 证书目录 + 安装证书到统一路径 ----------
XRAY_DIR="/usr/local/etc/xray"
run_step "创建证书目录 ${XRAY_DIR}" mkdir -p "${XRAY_DIR}" || true

CERT_KEY_PATH="${XRAY_DIR}/${DOMAIN}.key"
CERT_CRT_PATH="${XRAY_DIR}/${DOMAIN}.crt"        # fullchain
CERT_CA_PATH="${XRAY_DIR}/${DOMAIN}.ca.crt"      # ca
CERT_PEM_PATH="${XRAY_DIR}/${DOMAIN}.pem"        # cert

if [ -n "${ACME_SH}" ]; then
  # install-cert：把证书拷贝到指定位置，并支持自动更新时执行 reloadcmd（此处不写 reloadcmd）
  run_step "安装证书到 ${XRAY_DIR}" \
    "${ACME_SH}" --install-cert -d "${DOMAIN}" \
      --key-file       "${CERT_KEY_PATH}" \
      --fullchain-file "${CERT_CRT_PATH}" \
      --ca-file        "${CERT_CA_PATH}" \
      --cert-file      "${CERT_PEM_PATH}" || true
fi

# ---------- 6. 开启 BBR ----------
# 写入 sysctl.conf（避免重复写入）
SYSCTL_FILE="/etc/sysctl.conf"
( append_if_missing "${SYSCTL_FILE}" "net.core.default_qdisc=fq" ) && log_ok "写入/确认 fq 到 ${SYSCTL_FILE}" || log_fail "写入 fq 到 ${SYSCTL_FILE}" "写入失败"
( append_if_missing "${SYSCTL_FILE}" "net.ipv4.tcp_congestion_control=bbr" ) && log_ok "写入/确认 bbr 到 ${SYSCTL_FILE}" || log_fail "写入 bbr 到 ${SYSCTL_FILE}" "写入失败"

run_step "sysctl -p 生效配置" sysctl -p || true

# 验证可用算法包含 bbr
out="$(sysctl net.ipv4.tcp_available_congestion_control 2>&1)"; rc=$?
if [ $rc -eq 0 ] && echo "$out" | grep -q "bbr"; then
  log_ok "验证可用拥塞控制包含 bbr"
else
  log_fail "验证可用拥塞控制包含 bbr" "$out"
fi

# 验证模块加载（不保证所有发行版都显示 tcp_bbr；但一般会）
out="$(lsmod 2>&1 | grep -i bbr || true)"
if [ -n "$out" ]; then
  log_ok "验证 bbr 模块已加载（lsmod）"
else
  log_fail "验证 bbr 模块已加载（lsmod）" "未在 lsmod 中看到 bbr；可能未加载或内核/发行版显示方式不同"
fi

# ---------- 输出结果 ----------
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
# 额外提示：证书文件是否存在
echo "证书文件检查："
if [ -f "${CERT_KEY_PATH}" ] && [ -f "${CERT_CRT_PATH}" ]; then
  echo "  ✅ 已生成并安装："
  echo "     Key : ${CERT_KEY_PATH}"
  echo "     CRT : ${CERT_CRT_PATH}"
else
  echo "  ❌ 证书文件未齐全："
  echo "     Key : ${CERT_KEY_PATH}"
  echo "     CRT : ${CERT_CRT_PATH}"
  echo "     可能原因：Cloudflare API Key/邮箱不匹配、域名不在该账号、DNS 解析未生效、acme.sh 申请失败等。"
fi

print_line
# 如果失败项不为空，返回非 0 便于自动化判断
if [ "${#fail_list[@]}" -ne 0 ]; then
  exit 1
fi
exit 0
