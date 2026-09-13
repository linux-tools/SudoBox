#!/system/bin/sh
# SudoBox Component — 挂载点配置
# (adapted from Linux Deploy core/mnt, GPLv3)

do_configure()
{
    msg ":: 配置 ${COMPONENT} ... "
    # 生成 /etc/mtab：容器内视角（去掉 rootfs 前缀）
    rm -f "${CHROOT_DIR}/etc/mtab" 2>/dev/null
    grep "${CHROOT_DIR%/}" /proc/mounts 2>/dev/null \
        | sed "s|${CHROOT_DIR%/}/*|/|g" > "${CHROOT_DIR}/etc/mtab" 2>/dev/null
    chmod 0644 "${CHROOT_DIR}/etc/mtab" 2>/dev/null
    return 0
}

do_start()
{
    # rootfs 主体挂载由 chroot-mgr 的 cm_mount_all 完成（宿主 ns，全局可见）；
    # 本组件负责用户自定义 MOUNTS（SRC:DST）与 mtab 同步。
    if [ -n "${MOUNTS}" ]; then
        msg ":: 挂载自定义路径: "
        local item src dst target
        for item in ${MOUNTS}
        do
            src="${item%%:*}"; dst="${item##*:}"
            [ -n "${src}" ] && [ -n "${dst}" ] || continue
            msg -n "   ${src} -> ${dst} ... "
            target="${CHROOT_DIR}${dst}"
            if grep -q " ${target%/} " /proc/mounts 2>/dev/null; then
                msg "skip"
                continue
            fi
            [ -d "${target}" ] || mkdir -p "${target}" 2>/dev/null
            if [ -d "${src}" ]; then
                mount -o bind "${src}" "${target}" 2>/dev/null && msg "done" || msg "fail"
            elif [ -e "${src}" ]; then
                mount -o rw,relatime "${src}" "${target}" 2>/dev/null && msg "done" || msg "fail"
            else
                [ -d "${src}" ] || mkdir -p "${src}" 2>/dev/null
                mount -o bind "${src}" "${target}" 2>/dev/null && msg "done" || msg "fail"
            fi
        done
    fi
    do_configure
}

do_status()
{
    local n
    n="$(grep -c "${CHROOT_DIR%/}" /proc/mounts 2>/dev/null)"
    echo "   ${COMPONENT}: ${n} 个挂载点"
    return 0
}
