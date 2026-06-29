#!/bin/bash
#=============================================================================
# Xray VLESS-Reality 一键安装 v4
#   默认 443 · 单文件配置 · 重装保留密钥 · 安装前校验 · 链接持久化
#
# 用法: bash xray-reality.sh [-p PORT] [-d DEST] [-s SNI] [-v VER] [--no-bbr]
#=============================================================================
set -e
RD='\033[31m'; GN='\033[32m'; YL='\033[33m'; CY='\033[36m'; MG='\033[35m'; NC='\033[0m'
BOLD='\033[1m'
_ok()   { echo -e "  ${GN}[✓]${NC} $*"; }
_info() { echo -e "  ${CY}[•]${NC} $*"; }
_warn() { echo -e "  ${YL}[!]${NC} $*"; }
_err()  { echo -e "\n${RD}[✗]${NC} $*\n" >&2; exit 1; }
_step() { echo -e "\n${MG}${BOLD}── $* ──${NC}"; }

# ─── 参数 ───
PORT=""; DEST=""; SNI=""; VER=""; PROXY=""; NO_BBR=0
SNI_LIST=("www.apple.com" "www.amazon.com" "www.cloudflare.com" "www.google.com")
while [[ $# -gt 0 ]]; do
    case $1 in
        -p) PORT="$2"; shift 2 ;;  -d) DEST="$2"; shift 2 ;;
        -s) SNI="$2"; SNI_LIST=("$2"); shift 2 ;;  -v) VER="$2";  shift 2 ;;
        --proxy) PROXY="$2"; shift 2 ;;
        --no-bbr) NO_BBR=1; shift ;;
        -h|--help) sed -n '4,7p' "$0"; exit 0 ;;
        *) _err "未知参数: $1" ;;
    esac
done
[[ $EUID != 0 ]] && _err "需要 ROOT 权限"
# 随机选一个 SNI 作为本次 dest，所有 SNI 加入 serverNames
RAND_IDX=$(( RANDOM % ${#SNI_LIST[@]} ))
DEST="${SNI_LIST[$RAND_IDX]}"
[[ -z "$SNI" ]] && SNI="$DEST"
# 构建 serverNames JSON 数组
SNI_JSON=$(printf '"%s",' "${SNI_LIST[@]}"); SNI_JSON="[${SNI_JSON%,}]"

# ─── 环境检测 ───
_step "环境检测"
IS_REINSTALL=0
if [[ -f /etc/xray/config.json ]]; then
    IS_REINSTALL=1
    _info "检测到已有安装 — 将保留密钥，仅更新二进制"
    cp /etc/xray/config.json    /tmp/xray-config-bak.json
    cp /etc/xray/vless-link.txt /tmp/xray-link-bak.txt 2>/dev/null || true
    systemctl stop xray 2>/dev/null; systemctl disable xray 2>/dev/null
    rm -f /etc/systemd/system/xray.service
    pkill -f '/etc/xray/bin/xray' 2>/dev/null || true; sleep 1
    rm -f /etc/xray/bin/xray /etc/xray/bin/geoip.dat /etc/xray/bin/geosite.dat
fi

# 发行版
if   grep -qi 'ubuntu\|debian' /etc/os-release 2>/dev/null; then OS=debian; PKG=apt-get
elif grep -qi 'centos\|rhel\|fedora\|rocky\|alma' /etc/os-release 2>/dev/null; then OS=rhel; PKG=yum
elif grep -qi 'alpine' /etc/os-release 2>/dev/null; then OS=alpine; PKG=apk; IS_ALPINE=1
elif command -v apt-get &>/dev/null; then OS=debian; PKG=apt-get
elif command -v yum &>/dev/null;     then OS=rhel; PKG=yum
elif command -v apk &>/dev/null;     then OS=alpine; PKG=apk; IS_ALPINE=1
fi
_ok "系统: ${OS:-unknown}"

# 架构
case $(uname -m) in
    x86_64|amd64)  XARCH=64 ;;       aarch64|arm64) XARCH=arm64-v8a ;;
    armv7l)        XARCH=arm32-v7a ;; armv6l)        XARCH=arm32-v6 ;;
    *) _err "不支持的架构" ;;
esac

# 依赖
for cmd in curl unzip; do
    command -v $cmd &>/dev/null || MISSING="$MISSING $cmd"
done
if [[ -n "$MISSING" ]]; then
    _info "安装依赖:${MISSING} ..."
    case $OS in
        debian) apt-get update -qq 2>/dev/null; apt-get install -y -qq curl unzip xxd 2>/dev/null || apt-get install -y -qq curl unzip vim-common ;;
        rhel)   yum install -y -q curl unzip vim-common 2>/dev/null ;;
        alpine) apk add -q curl unzip xxd 2>/dev/null ;;
    esac
fi
_ok "依赖完整"

# init
if [[ $IS_ALPINE ]]; then
    command -v rc-service &>/dev/null || _err "Alpine 需要 openrc: apk add openrc"
    USE_INIT=openrc
else
    command -v systemctl &>/dev/null || _err "需要 systemd"
    USE_INIT=systemd
fi

# 时间
if command -v timedatectl &>/dev/null; then
    timedatectl show 2>/dev/null | grep -q 'NTPSynchronized=yes' || { timedatectl set-ntp true 2>/dev/null; _warn "时间可能未同步，Reality 要求误差<30秒"; }
fi

# BBR
[[ $NO_BBR -eq 0 ]] && [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" != "bbr" ]] && {
    modprobe tcp_bbr 2>/dev/null; sysctl -w net.core.default_qdisc=fq net.ipv4.tcp_congestion_control=bbr 2>/dev/null
}

# 端口
[[ -z "$PORT" ]] && PORT=443
if command -v ss &>/dev/null && ss -tlnp 2>/dev/null | grep -q ":${PORT} "; then
    _warn "端口 ${PORT} 被占用，尝试切换..."
    for try in 8443 $(( RANDOM % 55536 + 10000 )) $(( RANDOM % 55536 + 10000 )); do
        ss -tlnp 2>/dev/null | grep -q ":${try} " || { PORT=$try; break; }
    done
fi
_ok "端口: ${YL}${PORT}${NC}"

# ─── 下载 ───
_step "下载 (并行)"
REPO="https://github.com/XTLS/Xray-core"
if [[ -z "$VER" ]]; then
    VER=$(curl -sI --max-time 10 "${REPO}/releases/latest" 2>/dev/null | grep -i '^location:' | tr -d '\r' | grep -oP 'tag/\K[^/\r\n]+' || echo "")
    [[ -z "$VER" ]] && VER=$(curl -s --max-time 10 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null | grep '"tag_name"' | head -1 | tr -d '\r\n ",v' || true)
    [[ -z "$VER" ]] && _err "无法获取版本号，请用 -v 指定"
fi
_info "版本: ${YL}${VER}${NC}  架构: linux-${XARCH}"

TMP=$(mktemp -d); trap "rm -rf $TMP" EXIT; cd "$TMP"

_dl() {
    local u="$1" o="$2"
    for i in 1 2 3; do
        [[ -n "$PROXY" ]] && curl -f --socks5 "$PROXY" -sSL --connect-timeout 15 --max-time 120 "$u" -o "$o" 2>/dev/null && return 0
        curl -f -sSL --connect-timeout 15 --max-time 120 "$u" -o "$o" 2>/dev/null && return 0
        [[ $i -lt 3 ]] && sleep 2
    done
    return 1
}

GEO="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
_dl "${REPO}/releases/download/${VER}/Xray-linux-${XARCH}.zip" xray.zip &
_dl "${GEO}/geoip.dat"   geoip.dat   &
_dl "${GEO}/geosite.dat" geosite.dat &
wait
[[ -s xray.zip && -s geoip.dat && -s geosite.dat ]] || _err "下载失败"
_ok "Xray-core ($(du -h xray.zip | cut -f1))  geoip ($(du -h geoip.dat | cut -f1))  geosite ($(du -h geosite.dat | cut -f1))"

unzip -qo xray.zip && chmod +x xray
XRAY="$(pwd)/xray"; "$XRAY" version &>/dev/null || _err "二进制损坏"

# ─── 密钥 & 配置 ───
_step "生成配置"
XDIR="/etc/xray"; XBIN="${XDIR}/bin/xray"; XLOG="/var/log/xray"

if [[ $IS_REINSTALL -eq 1 ]]; then
    _info "恢复已有配置..."
    mkdir -p "$XDIR/bin" "$XLOG"
    install -m 755 "$XRAY"        "$XBIN"
    install -m 644 geoip.dat      "$XDIR/bin/geoip.dat"
    install -m 644 geosite.dat    "$XDIR/bin/geosite.dat"
    cp /tmp/xray-config-bak.json  "${XDIR}/config.json"
    OLD_VLESS=$(cat /tmp/xray-link-bak.txt 2>/dev/null || cat "${XDIR}/vless-link.txt" 2>/dev/null || echo "")
    rm -f /tmp/xray-config-bak.json /tmp/xray-link-bak.txt
    _ok "配置已恢复，密钥不变"
else
    KEYS=$("$XRAY" x25519 2>/dev/null) || KEYS=$(echo "" | "$XRAY" x25519 2>/dev/null)
    PRIV=$(echo "$KEYS" | grep -iE '^Private[ -]?Key' | awk '{print $NF}')
    PUB=$(echo "$KEYS"  | grep -iE '(^Public[ -]?Key|^Password)' | awk '{print $NF}')
    [[ -z "$PRIV" ]] && _err "密钥生成失败"
    UUID=$("$XRAY" uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    SID=$(head -c 8 /dev/urandom 2>/dev/null | xxd -p 2>/dev/null || openssl rand -hex 8 2>/dev/null || echo "6ba85179e3f2c407")
    _ok "UUID: ${UUID:0:18}...  ShortId: ${SID}"

    mkdir -p "$XDIR/bin" "$XLOG"
    install -m 755 "$XRAY"        "$XBIN"
    install -m 644 geoip.dat      "$XDIR/bin/geoip.dat"
    install -m 644 geosite.dat    "$XDIR/bin/geosite.dat"

    cat > "${XDIR}/config.json" <<JSON
{
  "log": {"access":"${XLOG}/access.log","error":"${XLOG}/error.log","loglevel":"info"},
  "dns": {"servers":["https+local://dns.google/dns-query","localhost"]},
  "inbounds":[{
    "tag":"reality-in","listen":"0.0.0.0","port":${PORT},"protocol":"vless",
    "settings":{"clients":[{"id":"${UUID}","flow":"xtls-rprx-vision"}],"decryption":"none"},
    "streamSettings":{"network":"tcp","security":"reality","realitySettings":{
      "show":false,"dest":"${DEST}:443","xver":0,
      "serverNames":${SNI_JSON},"privateKey":"${PRIV}","shortIds":["${SID}"]
    }},
    "sniffing":{"enabled":true,"destOverride":["http","tls"]}
  }],
  "outbounds":[
    {"protocol":"freedom","tag":"direct"},
    {"protocol":"blackhole","tag":"block"}
  ],
  "routing":{"domainStrategy":"AsIs","rules":[
    {"type":"field","ip":["geoip:private"],"outboundTag":"block"},
    {"type":"field","domain":["geosite:category-ads-all"],"outboundTag":"block"}
  ]}
}
JSON
fi

# 验证
"$XRAY" run -test -config "${XDIR}/config.json" &>/dev/null || _err "配置文件无效"
_ok "配置验证通过"

# ─── 服务 ───
_step "创建服务"
if [[ $USE_INIT == openrc ]]; then
    cat > /etc/init.d/xray <<EOF
#!/sbin/openrc-run
name="Xray"; description="Xray VLESS-Reality"
command="${XBIN}"; command_args="run -config ${XDIR}/config.json"
command_background=true; pidfile="/run/\${RC_SVCNAME}.pid"
output_log="${XLOG}/openrc.log"; error_log="${XLOG}/openrc.err"; rc_ulimit="-n 1048576"
depend() { need net; use dns; after network; }
EOF
    chmod +x /etc/init.d/xray; rc-update add xray default &>/dev/null; rc-service xray restart 2>/dev/null
else
    cat > /etc/systemd/system/xray.service <<SVC
[Unit]
Description=Xray VLESS-Reality
After=network.target nss-lookup.target
[Service]
Type=simple
User=root
NoNewPrivileges=true
ExecStart=${XBIN} run -config ${XDIR}/config.json
Restart=on-failure
RestartPreventExitStatus=23
RestartSec=5s
LimitNPROC=10000
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
[Install]
WantedBy=multi-user.target
SVC
    systemctl daemon-reload; systemctl enable xray 2>/dev/null; systemctl restart xray 2>/dev/null
fi
sleep 2

if [[ $USE_INIT == openrc ]]; then
    rc-service xray status 2>/dev/null | grep -q 'started' && _ok "服务运行中 (OpenRC)" || _err "启动失败"
else
    systemctl is-active --quiet xray && _ok "服务运行中 (systemd)" || _err "启动失败: journalctl -u xray -n 20"
fi

# ─── 链接 ───
# 重装时从配置文件读取变量
if [[ $IS_REINSTALL -eq 1 ]]; then
    UUID=$(grep -oP '"id":\s*"\K[^"]+' "${XDIR}/config.json" | head -1)
    PORT=$(grep -oP '"port":\s*\K\d+' "${XDIR}/config.json" | head -1)
fi
_step "获取 IP"
IP=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null | tr -d '\r\n')
[[ -z "$IP" ]] && IP=$(curl -4 -s --max-time 5 ip.sb 2>/dev/null | tr -d '\r\n')
[[ -z "$IP" ]] && IP="YOUR_IP"

if [[ $IS_REINSTALL -eq 1 ]] && [[ -n "$OLD_VLESS" ]]; then
    VLESS="$OLD_VLESS"
else
    VLESS="vless://${UUID}@${IP}:${PORT}?encryption=none&security=reality&flow=xtls-rprx-vision&type=tcp&sni=${SNI}&pbk=${PUB}&fp=chrome&sid=${SID}#REALITY-${IP}"
fi
SUB=$(echo -n "$VLESS" | base64 -w 0 2>/dev/null || echo -n "$VLESS" | base64)
echo "$VLESS" > "${XDIR}/vless-link.txt"
echo "$SUB"   > "${XDIR}/sub-base64.txt"

clear 2>/dev/null || true
echo ""
echo -e "${GN}${BOLD} ╔════════════════════════════════════╗"
echo -e " ║   Xray VLESS-Reality  安装完成    ║"
echo -e " ╠════════════════════════════════════╣${NC}"
echo ""
echo -e "  地址: ${YL}${IP}${NC}    端口: ${YL}${PORT}${NC}"
echo -e "  UUID: ${CY}${UUID}${NC}"
echo -e "  SNI:  ${CY}${SNI}${NC}"
echo ""
echo -e "  ${VLESS}"
echo ""
echo -e "  订阅: ${SUB}"
echo ""
echo -e "  📁 cat ${XDIR}/vless-link.txt"
echo -e "  📁 ${XDIR}/config.json"
echo ""

command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active" && echo -e "  ${YL}⚠${NC} ufw allow ${PORT}/tcp"
echo ""
