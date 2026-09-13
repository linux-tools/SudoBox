#!/system/bin/sh
# SudoBox hook — apt seccomp 豁免
#
# 硬规则（开发思路 §3.3-2）：Android 内核的 seccomp 策略会拦截 apt 的沙箱，
# 导致所有 apt 操作失败（linuxdeploy 十年踩坑结论）。
# 必须在 /etc/apt/apt.conf.d/ 写入豁免配置。
hook_run()
{
    if [ ! -d "${CHROOT_DIR}/etc/apt/apt.conf.d" ]; then
        echo "    (非 apt 系统，跳过)"
        return 0
    fi
    # seccomp 沙箱关闭（Android 内核必需）
    echo 'apt::sandbox::seccomp "false";' > "${CHROOT_DIR}/etc/apt/apt.conf.d/999seccomp-off"
    # 不降权（chroot 内 _apt 用户常因无 setgroups 权限失败）
    echo 'Debug::NoDropPrivs "true";' > "${CHROOT_DIR}/etc/apt/apt.conf.d/00no-drop-privs"
    chmod 0644 "${CHROOT_DIR}/etc/apt/apt.conf.d/999seccomp-off" \
               "${CHROOT_DIR}/etc/apt/apt.conf.d/00no-drop-privs" 2>/dev/null
    echo "    apt seccomp 豁免已写入"
    return 0
}
