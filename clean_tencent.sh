#!/bin/bash
# ============================================================
# 腾讯云监控组件 完整清理脚本
# 适配: OpenCloudOS 9 (RHEL系) / Debian 12
# ============================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[-]${NC} $1"; }

# 检测系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            debian|ubuntu) OS_TYPE="debian" ;;
            opencloudos|centos|rhel|tencentos|rocky|alma) OS_TYPE="rhel" ;;
            *) OS_TYPE="unknown" ;;
        esac
    else
        OS_TYPE="unknown"
    fi
    log "检测到系统: $PRETTY_NAME (类型: $OS_TYPE)"
}

# ============================================================
# 第一步: 清理 /etc/ld.so.preload (必须最先做!)
# ============================================================
clean_ld_preload() {
    log "清理 /etc/ld.so.preload ..."
    if [ -f /etc/ld.so.preload ]; then
        cat /etc/ld.so.preload
        # 移除 libonion 和 libsgmon 相关行
        sed -i '/libonion/d' /etc/ld.so.preload
        sed -i '/libsgmon/d' /etc/ld.so.preload
        # 如果文件为空则删除
        if [ ! -s /etc/ld.so.preload ]; then
            rm -f /etc/ld.so.preload
            log "ld.so.preload 已删除(已为空)"
        else
            warn "ld.so.preload 仍有其他内容:"
            cat /etc/ld.so.preload
        fi
    else
        log "ld.so.preload 不存在, 跳过"
    fi
}

# ============================================================
# 第二步: 删除注入的 .so 文件
# ============================================================
clean_so_files() {
    log "清理 libonion / libsgmon .so 文件 ..."
    local files=(
        /lib64/libonion.so
        /lib64/libonion_security.so*
        /usr/lib64/libonion.so
        /usr/lib64/libonion_security.so*
        /lib/x86_64-linux-gnu/libonion.so
        /lib/x86_64-linux-gnu/libonion_security.so*
        /lib64/libsgmon.so
        /lib64/libsgmon.so.*
        /usr/lib64/libsgmon.so
        /usr/lib64/libsgmon.so.*
    )
    for f in "${files[@]}"; do
        # 使用通配符展开
        for ff in $f; do
            if [ -e "$ff" ] || [ -L "$ff" ]; then
                rm -f "$ff"
                log "  删除: $ff"
            fi
        done
    done
    ldconfig 2>/dev/null || true
}

# ============================================================
# 第三步: 停止所有腾讯云进程
# ============================================================
stop_processes() {
    log "停止腾讯云相关进程 ..."

    # 不调用任何官方脚本(uninst.sh要验证码, stopYDCore.sh内部调YDService -kill也可能卡住)
    # 全部直接 pkill -9 强杀
    local procs="sgagent barad_agent YDService YDLive YDEdr tat_agent cosfs"
    for p in $procs; do
        if pgrep -x "$p" > /dev/null 2>&1; then
            log "  杀死进程: $p"
            pkill -9 -x "$p" 2>/dev/null || true
        fi
    done

    # 杀死 YunJing 守护的 sleep 进程
    ps aux | grep '/bin/sh -c sleep' | grep -v grep | awk '{print $2}' | xargs -r kill -9 2>/dev/null || true

    # 卸载 cosfs 挂载
    if mount | grep -q cosfs; then
        log "  卸载 cosfs 挂载点"
        umount -l /lhcos-data 2>/dev/null || true
    fi
}

# ============================================================
# 第四步: 清理 systemd 服务
# ============================================================
clean_systemd() {
    log "清理 systemd 服务 ..."

    local services=(
        tat_agent.service
        tat_install.service
        nv_gpu_shutdown_pm.service
        cloud-init.service
        cloud-init-local.service
        cloud-config.service
        cloud-final.service
    )

    for svc in "${services[@]}"; do
        if systemctl list-unit-files "$svc" &>/dev/null; then
            log "  停止并禁用: $svc"
            systemctl stop "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
        fi
    done

    # 清理 cloud-init target
    systemctl disable cloud-init.target 2>/dev/null || true

    # 删除 tat 相关 service 文件
    rm -f /etc/systemd/system/tat_agent.service
    rm -f /etc/systemd/system/tat_install.service
    rm -f /etc/systemd/system/multi-user.target.wants/tat_agent.service
    rm -f /etc/systemd/system/multi-user.target.wants/tat_install.service

    # 删除腾讯云 GPU 关机服务
    rm -f /etc/systemd/system/shutdown.target.wants/nv_gpu_shutdown_pm.service

    systemctl daemon-reload
}

# ============================================================
# 第五步: 清理定时任务
# ============================================================
clean_crontab() {
    log "清理定时任务 ..."

    # 清理 /etc/cron.d/
    rm -f /etc/cron.d/sgagenttask
    rm -f /etc/cron.d/yunjing
    log "  已删除 /etc/cron.d/sgagenttask, yunjing"

    # 清理 root crontab
    if crontab -l 2>/dev/null | grep -qE '(qcloud|stargate|barad|yunjing)'; then
        crontab -l 2>/dev/null | grep -vE '(qcloud|stargate|barad|yunjing)' | crontab -
        log "  已清理 root crontab 中的腾讯云条目"
    fi
}

# ============================================================
# 第六步: 删除文件和目录
# ============================================================
clean_files() {
    log "删除腾讯云文件和目录 ..."

    # 主目录
    rm -rf /usr/local/qcloud
    rm -rf /usr/local/sa
    rm -rf /usr/local/agenttools

    # cosfs 二进制
    rm -f /usr/local/bin/cosfs

    # cosfs 挂载点
    rm -rf /lhcos-data

    # 配置文件
    rm -f /etc/qcloudzone
    rm -f /etc/tencentcloud_ipv6_base.sh

    # 临时文件
    rm -f /tmp/stargate.lock
    rm -f /tmp/sgdaemon.log

    # cloud-init 数据
    rm -rf /var/lib/cloud

    log "  文件清理完成"
}

# ============================================================
# 第七步: 替换 DNS
# ============================================================
fix_dns() {
    log "替换 DNS 为公共 DNS ..."

    if [ "$OS_TYPE" = "rhel" ]; then
        # OpenCloudOS 使用 NetworkManager, 写入 resolv.conf 并防止覆盖
        cat > /etc/resolv.conf <<DNSEOF
nameserver 223.5.5.5
nameserver 119.29.29.29
nameserver 8.8.8.8
DNSEOF
        # 在 NetworkManager 中禁止覆盖 resolv.conf
        if [ -d /etc/NetworkManager/conf.d ]; then
            cat > /etc/NetworkManager/conf.d/no-dns.conf <<NMEOF
[main]
dns=none
NMEOF
            systemctl restart NetworkManager 2>/dev/null || true
        fi
    else
        # Debian
        cat > /etc/resolv.conf <<DNSEOF
nameserver 223.5.5.5
nameserver 119.29.29.29
nameserver 8.8.8.8
DNSEOF
    fi

    log "  DNS: 阿里(223.5.5.5) + DNSPod(119.29.29.29) + Google(8.8.8.8)"
}

# ============================================================
# 第八步: 替换 NTP 时间源
# ============================================================
fix_ntp() {
    log "替换 NTP 时间源 ..."

    if [ "$OS_TYPE" = "rhel" ]; then
        # OpenCloudOS 使用 chrony
        if [ -f /etc/chrony.conf ]; then
            # 移除腾讯云 NTP 服务器
            sed -i '/tencentyun\.com/d' /etc/chrony.conf
            # 检查是否已有公共 NTP
            if ! grep -q 'ntp.aliyun.com' /etc/chrony.conf; then
                sed -i '1i server ntp.aliyun.com iburst\nserver ntp.tencent.com iburst\nserver cn.ntp.org.cn iburst\nserver ntp.ntsc.ac.cn iburst' /etc/chrony.conf
            fi
            systemctl restart chronyd 2>/dev/null || true
            log "  chrony: 阿里云NTP + 腾讯公共NTP + 国家授时中心"
        fi
    else
        # Debian 可能用 ntpsec 或 chrony
        if [ -f /etc/ntpsec/ntp.conf ]; then
            sed -i '/tencentyun\.com/d' /etc/ntpsec/ntp.conf
            if ! grep -q 'ntp.aliyun.com' /etc/ntpsec/ntp.conf; then
                sed -i '/^restrict ::1/a\\nserver ntp.aliyun.com iburst\nserver ntp.tencent.com iburst\nserver cn.ntp.org.cn iburst\nserver ntp.ntsc.ac.cn iburst' /etc/ntpsec/ntp.conf
            fi
            systemctl restart ntpsec 2>/dev/null || true
            log "  ntpsec: 阿里云NTP + 腾讯公共NTP + 国家授时中心"
        elif [ -f /etc/chrony/chrony.conf ]; then
            sed -i '/tencentyun\.com/d' /etc/chrony/chrony.conf
            if ! grep -q 'ntp.aliyun.com' /etc/chrony/chrony.conf; then
                sed -i '1i server ntp.aliyun.com iburst\nserver ntp.tencent.com iburst\nserver cn.ntp.org.cn iburst\nserver ntp.ntsc.ac.cn iburst' /etc/chrony/chrony.conf
            fi
            systemctl restart chronyd 2>/dev/null || true
            log "  chrony: 阿里云NTP + 腾讯公共NTP + 国家授时中心"
        fi
    fi
}

# ============================================================
# 第九步: 替换软件源
# ============================================================
fix_repos() {
    log "替换软件源为清华源 ..."

    if [ "$OS_TYPE" = "rhel" ]; then
        # OpenCloudOS 9 -> 清华源
        if [ -f /etc/yum.repos.d/OpenCloudOS.repo ]; then
            cp /etc/yum.repos.d/OpenCloudOS.repo /etc/yum.repos.d/OpenCloudOS.repo.bak
            sed -i 's|mirrors\.tencentyun\.com/opencloudos|mirrors.tuna.tsinghua.edu.cn/opencloudos|g' /etc/yum.repos.d/OpenCloudOS.repo
            log "  OpenCloudOS.repo -> 清华源"
        fi
        if [ -f /etc/yum.repos.d/epol.repo ]; then
            cp /etc/yum.repos.d/epol.repo /etc/yum.repos.d/epol.repo.bak
            sed -i 's|mirrors\.tencentyun\.com|mirrors.tuna.tsinghua.edu.cn|g' /etc/yum.repos.d/epol.repo
            log "  epol.repo -> 清华源"
        fi
        # 处理 .rpmnew 文件
        if [ -f /etc/yum.repos.d/epol.repo.rpmnew ]; then
            rm -f /etc/yum.repos.d/epol.repo.rpmnew
        fi
        dnf clean all 2>/dev/null || yum clean all 2>/dev/null || true
    else
        # Debian 12 -> 清华源
        if [ -f /etc/apt/sources.list ]; then
            cp /etc/apt/sources.list /etc/apt/sources.list.bak
            cat > /etc/apt/sources.list <<APTEOF
deb https://mirrors.tuna.tsinghua.edu.cn/debian bookworm main contrib non-free non-free-firmware
deb https://mirrors.tuna.tsinghua.edu.cn/debian bookworm-updates main contrib non-free non-free-firmware
deb https://mirrors.tuna.tsinghua.edu.cn/debian-security/ bookworm-security main contrib non-free-firmware
APTEOF
            log "  sources.list -> 清华源"
        fi
        # 清理 sources.list.d 中可能的腾讯源
        find /etc/apt/sources.list.d/ -name '*.list' -exec grep -l 'tencentyun' {} \; 2>/dev/null | while read f; do
            sed -i 's|mirrors\.tencentyun\.com|mirrors.tuna.tsinghua.edu.cn|g' "$f"
            log "  $f -> 清华源"
        done
        apt-get update 2>/dev/null || true
    fi
}

# ============================================================
# 第十步: 清理 /etc/hosts 中的腾讯云条目 (如有)
# ============================================================
clean_hosts() {
    if grep -qiE '(tencentyun|qcloud)' /etc/hosts 2>/dev/null; then
        log "清理 /etc/hosts 中的腾讯云条目 ..."
        sed -i '/tencentyun/d;/qcloud/d' /etc/hosts
    fi
}

# ============================================================
# 验证
# ============================================================
verify() {
    echo ""
    echo "========================================"
    log "清理完成! 验证结果:"
    echo "========================================"

    echo ""
    echo "--- 残留进程检查 ---"
    local remain=$(ps aux | grep -E '(barad|sgagent|YDService|YDLive|tat_agent|cosfs)' | grep -v grep)
    if [ -z "$remain" ]; then
        log "无腾讯云残留进程 ✓"
    else
        err "仍有残留进程:"
        echo "$remain"
    fi

    echo ""
    echo "--- ld.so.preload 检查 ---"
    if [ -f /etc/ld.so.preload ] && grep -qE '(libonion|libsgmon)' /etc/ld.so.preload; then
        err "ld.so.preload 仍有腾讯云注入"
    else
        log "ld.so.preload 干净 ✓"
    fi

    echo ""
    echo "--- 定时任务检查 ---"
    local cron_remain=$(crontab -l 2>/dev/null | grep -E '(qcloud|stargate|yunjing)')
    if [ -z "$cron_remain" ] && [ ! -f /etc/cron.d/sgagenttask ] && [ ! -f /etc/cron.d/yunjing ]; then
        log "定时任务干净 ✓"
    else
        err "仍有腾讯云定时任务"
    fi

    echo ""
    echo "--- /usr/local/qcloud 检查 ---"
    if [ -d /usr/local/qcloud ]; then
        err "/usr/local/qcloud 仍存在"
    else
        log "/usr/local/qcloud 已删除 ✓"
    fi

    echo ""
    echo "--- DNS 检查 ---"
    cat /etc/resolv.conf

    echo ""
    echo "--- NTP 检查 ---"
    if [ "$OS_TYPE" = "rhel" ]; then
        grep '^server' /etc/chrony.conf 2>/dev/null
    else
        grep '^server' /etc/ntpsec/ntp.conf /etc/chrony/chrony.conf 2>/dev/null
    fi

    echo ""
    echo "--- nginx 状态 ---"
    if systemctl is-active nginx &>/dev/null; then
        log "nginx 运行正常 ✓"
        ss -tlnp | grep nginx | head -3
    else
        err "nginx 未运行!"
    fi

    echo ""
    echo "--- 对外连接检查(应只剩 nginx 和 sshd) ---"
    ss -tnp state established | grep -v -E '(nginx|sshd)' | grep -v 'Local' || log "无异常外连 ✓"

    echo ""
    echo "========================================"
}

# ============================================================
# 主流程
# ============================================================
main() {
    echo "========================================"
    echo "  腾讯云监控组件 完整清理脚本"
    echo "========================================"
    echo ""

    detect_os

    if [ "$OS_TYPE" = "unknown" ]; then
        err "未识别的系统类型, 退出"
        exit 1
    fi

    clean_ld_preload   # 1. 最先清理 ld.so.preload
    clean_so_files     # 2. 删除 .so 文件
    stop_processes     # 3. 停止进程
    clean_systemd      # 4. 清理 systemd
    clean_crontab      # 5. 清理定时任务
    clean_files        # 6. 删除文件目录
    fix_dns            # 7. 替换 DNS
    fix_ntp            # 8. 替换 NTP
    fix_repos          # 9. 替换软件源
    clean_hosts        # 10. 清理 hosts
    verify             # 验证
}

main "$@"
