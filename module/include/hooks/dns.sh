#!/system/bin/sh
# SudoBox hook — DNS 兜底（复用 bin/net.sh）
hook_run()
{
    local net_sh="/data/adb/modules/chroot-mgr/bin/net.sh"
    [ -f "${net_sh}" ] || net_sh="/data/adb/ksu/modules/chroot-mgr/bin/net.sh"
    if [ -f "${net_sh}" ]; then
        sh "${net_sh}" "${CHROOT_DIR}" 2>&1 | sed 's/^/    /'
    else
        echo "    (net.sh 缺失，跳过)"
    fi
    return 0
}
