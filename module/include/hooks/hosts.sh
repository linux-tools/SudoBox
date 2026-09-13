#!/system/bin/sh
# SudoBox hook — /etc/hosts 与 hostname
# chroot 环境下若无 hosts，大量工具（sudo、hostname 解析）会阻塞或报异常
hook_run()
{
    local hn="${SUDOBOX_HOSTNAME:-localhost}"
    [ -n "${DISTRO}" ] && hn="${DISTRO}"

    mkdir -p "${CHROOT_DIR}/etc" 2>/dev/null
    cat > "${CHROOT_DIR}/etc/hosts" <<HOSTS
127.0.0.1       localhost
127.0.0.1       ${hn}
::1             localhost ip6-localhost ip6-loopback
fe00::0         ip6-localnet
ff00::0         ip6-mcastprefix
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
HOSTS
    chmod 0644 "${CHROOT_DIR}/etc/hosts" 2>/dev/null

    echo "${hn}" > "${CHROOT_DIR}/etc/hostname" 2>/dev/null
    chmod 0644 "${CHROOT_DIR}/etc/hostname" 2>/dev/null
    echo "    /etc/hosts + hostname=${hn}"
    return 0
}
