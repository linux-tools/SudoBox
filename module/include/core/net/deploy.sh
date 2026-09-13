#!/system/bin/sh
# SudoBox Component — 网络 / DNS
# (adapted from Linux Deploy core/net, GPLv3)
#
# 策略：默认共享宿主网络命名空间（apt/ssh 直通；PD2338 有 NET_NS 但无需隔离）
# DNS：getprop net.dns1/2 → /etc/resolv.conf → 8.8.8.8（硬规则 §3.3-4）

do_configure()
{
    msg ":: 配置 ${COMPONENT} ... "
    local dns dns_list=""
    local gp=""
    command -v getprop >/dev/null 2>&1 && gp="getprop"
    [ -z "${gp}" ] && [ -x /system/bin/getprop ] && gp=/system/bin/getprop

    if [ -z "${DNS}" ] || [ "${DNS}" = "auto" ]; then
        if [ -n "${gp}" ]; then
            dns="$(${gp} net.dns1 2>/dev/null)"
            [ -n "${dns}" ] && dns_list="${dns}"
            dns="$(${gp} net.dns2 2>/dev/null)"
            [ -n "${dns}" ] && dns_list="${dns_list} ${dns}"
        fi
        if [ -z "${dns_list}" ] && [ -e /etc/resolv.conf ]; then
            dns_list="$(grep '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}')"
        fi
        [ -z "${dns_list}" ] && dns_list="8.8.8.8"
    else
        dns_list="${DNS}"
    fi

    mkdir -p "${CHROOT_DIR}/etc" 2>/dev/null
    : > "${CHROOT_DIR}/etc/resolv.conf"
    for dns in ${dns_list}; do
        echo "nameserver ${dns}" >> "${CHROOT_DIR}/etc/resolv.conf"
    done
    chmod 0644 "${CHROOT_DIR}/etc/resolv.conf" 2>/dev/null

    # nsswitch: 移除 systemd resolver（无 PID_NS 环境下 getaddrinfo 可能阻塞）
    if [ -e "${CHROOT_DIR}/etc/nsswitch.conf" ]; then
        sed -i 's/systemd//g' "${CHROOT_DIR}/etc/nsswitch.conf" 2>/dev/null
    fi

    msg "nameserver: ${dns_list}"
    return 0
}

do_start()
{
    do_configure
}

do_status()
{
    local ns
    ns="$(grep '^nameserver' "${CHROOT_DIR}/etc/resolv.conf" 2>/dev/null | awk '{print $2}' | tr '\n' ' ')"
    echo "   ${COMPONENT}: DNS=${ns:-未配置}"
    return 0
}
