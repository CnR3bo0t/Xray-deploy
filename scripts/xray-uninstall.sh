#!/bin/bash
#===========================================================================
# Xray 卸载脚本 v1.0 — 一键清理所有安装痕迹
# 用法:
#   bash xray-uninstall.sh          # 卸载 Xray (保留 Caddy)
#   bash xray-uninstall.sh --all    # 同时卸载 Xray + Caddy
#   bash xray-uninstall.sh --force  # 跳过确认提示
#===========================================================================

red='\e[31m'; yellow='\e[33m'; green='\e[92m'; cyan='\e[96m'; none='\e[0m'
_red()    { echo -e "${red}$@${none}"; }
_green()  { echo -e "${green}$@${none}"; }
_yellow() { echo -e "${yellow}$@${none}"; }
_cyan()   { echo -e "${cyan}$@${none}"; }

is_all=""; is_force=""
for arg in "$@"; do
    case $arg in --all) is_all=1 ;; --force) is_force=1 ;; -h|--help)
        echo "用法: $0 [--all] [--force]"
        echo "  --all    同时卸载 Caddy"
        echo "  --force  跳过确认提示"
        exit 0 ;; esac
done

[[ $EUID != 0 ]] && { _red "请用 root 用户运行."; exit 1; }

# ---- 路径定义 ----
is_core=xray
is_core_dir=/etc/$is_core
is_log_dir=/var/log/$is_core
is_sh_bin=/usr/local/bin/$is_core
is_caddy_bin=/usr/local/bin/caddy
is_caddy_dir=/etc/caddy
is_caddy_log=/var/log/caddy
[[ -f /etc/alpine-release ]] && is_alpine=1

# ---- 确认 ----
echo
echo "============================================"
echo "  Xray 卸载脚本"
echo "============================================"
echo
echo " 将删除:"
echo "   - Xray 服务 & 配置: $is_core_dir"
echo "   - Xray 日志:        $is_log_dir"
echo "   - Xray 命令:        $is_sh_bin"
[[ $is_all ]] && echo "   - Caddy 服务 & 配置: $is_caddy_dir"
[[ $is_all ]] && echo "   - Caddy 日志:        $is_caddy_log"
[[ $is_all ]] && echo "   - Caddy 命令:        $is_caddy_bin"
echo

if [[ ! $is_force ]]; then
    read -p "确认卸载? [y/N]: " yn
    [[ ! $yn =~ ^[Yy]$ ]] && { echo "已取消."; exit 0; }
fi

# ---- 1. 停止服务 ----
echo; _yellow "[1/6] 停止服务..."

_stop() {
    local name=$1
    if [[ $is_alpine ]]; then
        rc-service "$name" stop 2>/dev/null || true
        rc-update del "$name" default 2>/dev/null || true
    else
        systemctl stop "$name" 2>/dev/null || true
        systemctl disable "$name" 2>/dev/null || true
    fi
    rm -f "/lib/systemd/system/${name}.service" "/etc/init.d/${name}"
}

_stop $is_core
[[ $is_all ]] && _stop caddy
[[ ! $is_alpine ]] && systemctl daemon-reload 2>/dev/null || true
_green "  OK"

# ---- 2. 终止进程 ----
echo; _yellow "[2/6] 终止残留进程..."

_kill() {
    local pids=$(pgrep -f "$1" 2>/dev/null || true)
    if [[ $pids ]]; then
        for pid in $pids; do kill "$pid" 2>/dev/null || true; done
        sleep 1
        pids=$(pgrep -f "$1" 2>/dev/null || true)
        [[ $pids ]] && kill -9 $pids 2>/dev/null || true
        echo "  已终止: $1"
    fi
}

_kill "$is_core_dir/bin/$is_core"
[[ $is_all ]] && _kill "$is_caddy_bin"
_green "  OK"

# ---- 3. 删除文件 ----
echo; _yellow "[3/6] 删除文件..."

rm -rf "$is_core_dir" "$is_log_dir" "$is_sh_bin"
# also clean any symlink in /usr/bin
rm -f "/usr/bin/$is_core" "/usr/local/sbin/$is_core"

if [[ $is_all ]]; then
    rm -rf "$is_caddy_dir" "$is_caddy_log" "$is_caddy_bin"
fi
_green "  OK"

# ---- 4. 清理 shell 配置 ----
echo; _yellow "[4/6] 清理 shell 配置..."

for f in /root/.bashrc /root/.profile /root/.bash_profile /etc/skel/.bashrc; do
    [[ -f $f ]] && sed -i "/alias $is_core=/d" "$f" 2>/dev/null || true
done
_green "  OK"

# ---- 5. 清理 Caddy 用户(如有) ----
echo; _yellow "[5/6] 清理 Caddy 相关..."

if [[ $is_all ]]; then
    # Caddy on debian sometimes creates a caddy user
    if id caddy &>/dev/null 2>&1; then
        userdel caddy 2>/dev/null && echo "  已删除 caddy 用户" || true
    fi
    # Caddy system group
    if getent group caddy &>/dev/null 2>&1; then
        groupdel caddy 2>/dev/null || true
    fi
fi

# Remove any lingering Caddy directories
if [[ $is_all ]]; then
    rm -rf /var/lib/caddy /etc/ssl/caddy 2>/dev/null || true
fi
_green "  OK"

# ---- 6. 残留检查 ----
echo; _yellow "[6/6] 检查残留..."

is_clean=1
_check() {
    if [[ -e $1 ]]; then _red "  ! 残留: $1"; is_clean=""; fi
}

_check "$is_core_dir"
_check "$is_log_dir"
_check "$is_sh_bin"
_check "/lib/systemd/system/${is_core}.service"
_check "/etc/init.d/${is_core}"

if [[ $is_all ]]; then
    _check "$is_caddy_dir"
    _check "$is_caddy_bin"
    _check "/lib/systemd/system/caddy.service"
    _check "/etc/init.d/caddy"
fi

if ! pgrep -f "$is_core_dir/bin/$is_core" &>/dev/null; then :; else
    _red "  ! Xray 进程仍在运行"; is_clean=""
fi

if [[ $is_clean ]]; then
    _green "  无残留, 清理干净."
fi

# ---- 完成 ----
echo
echo "============================================"
_green "  卸载完成."
echo "============================================"
echo
