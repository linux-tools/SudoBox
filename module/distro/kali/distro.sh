#!/system/bin/sh
# SudoBox distro resolver — Kali NetHunter rootfs
# 由 chroot-mgr 在部署时 source 后调用：distro_resolve_url <suite> <arch> <mirror>
# 输出最终下载 URL（stdout）。
#
# v0.1.17: 官方文件名历史上已变更过一次（kalifs-arm64-full.tar.xz →
# kali-nethunter-rootfs-full-arm64.tar.xz，旧名 2026-09-07 实测 404），
# 改为从 current/rootfs 目录列表动态解析，避免再次硬编码失效。

distro_resolve_url()
{
    local suite="$1" arch="$2" mirror="$3"

    case "${mirror}" in
        ""|official) : ;;
        *) echo "W: NetHunter rootfs 无国内镜像同步，忽略 --mirror ${mirror}，走官方源" >&2 ;;
    esac

    local base="https://kali.download/nethunter-images/current/rootfs/"
    local fname
    fname="$(wget -q -O - "${base}" 2>/dev/null \
        | grep -oE "kali-nethunter-rootfs-full-${arch}\.tar\.xz" \
        | tail -1)"

    if [ -z "${fname}" ]; then
        echo "E: 未在 ${base} 解析到 ${arch} rootfs（文件命名可能再次变更）" >&2
        return 1
    fi

    echo "${base}${fname}"
}
