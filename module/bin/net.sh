#!/system/bin/sh
###############################################################################
# net.sh — DNS 兜底工具（独立可调用）
#
# 用法: net.sh <rootfs> [dns1 dns2 ...]
#
# 硬规则（开发思路 §3.3-4）：
#   getprop net.dns1/2 → 回退 /etc/resolv.conf → 回退 8.8.8.8
#   写入容器 /etc/resolv.conf；nsswitch.conf 去掉 systemd（无 PID_NS 时 hosts 解析会卡）
###############################################################################

ROOTFS="$1"; shift
[ -n "${ROOTFS}" ] || { echo "E: 用法: net.sh <rootfs> [dns...]" >&2; exit 1; }

GP=""
command -v getprop >/dev/null 2>&1 && GP="getprop"
[ -z "${GP}" ] && [ -x /system/bin/getprop ] && GP=/system/bin/getprop

dns_list="$*"
if [ -z "${dns_list}" ] && [ -n "${GP}" ]; then
    d="$(${GP} net.dns1 2>/dev/null)"; [ -n "${d}" ] && dns_list="${d}"
    d="$(${GP} net.dns2 2>/dev/null)"; [ -n "${d}" ] && dns_list="${dns_list} ${d}"
fi
if [ -z "${dns_list}" ] && [ -e /etc/resolv.conf ]; then
    dns_list="$(grep '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}')"
fi
[ -z "${dns_list}" ] && dns_list="8.8.8.8 1.1.1.1"

mkdir -p "${ROOTFS}/etc" 2>/dev/null
: > "${ROOTFS}/etc/resolv.conf"
for dns in ${dns_list}; do
    echo "nameserver ${dns}" >> "${ROOTFS}/etc/resolv.conf"
done
chmod 0644 "${ROOTFS}/etc/resolv.conf" 2>/dev/null

# nsswitch：去掉 systemd resolver（无 PID_NS 环境下会导致 getaddrinfo 阻塞）
if [ -e "${ROOTFS}/etc/nsswitch.conf" ]; then
    sed -i 's/systemd//g' "${ROOTFS}/etc/nsswitch.conf" 2>/dev/null
fi

echo "- resolv.conf: ${dns_list}"
exit 0
