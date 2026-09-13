#!/system/bin/sh
# SudoBox hook — Arch Linux ARM: pacman-key 初始化
#
# 首次必做（发行版支持设计 §6）：否则一切 pacman GPG 校验失败。
# 注意：pacman-key 必须在容器内执行，故这里只落"待执行"标记与说明，
#       由 chroot-mgr install 完成后提示用户首次进入时执行。
hook_run()
{
    if [ ! -d "${CHROOT_DIR}/etc/pacman.d" ]; then
        echo "    (非 Arch 系统，跳过)"
        return 0
    fi
    # 若容器内已有 keyring 则跳过
    if [ -d "${CHROOT_DIR}/etc/pacman.d/gnupg" ] && \
       [ -n "$(ls -A "${CHROOT_DIR}/etc/pacman.d/gnupg" 2>/dev/null)" ]; then
        echo "    pacman keyring 已存在，跳过"
        return 0
    fi
    mkdir -p "${CHROOT_DIR}/etc/profile.d" 2>/dev/null
    cat > "${CHROOT_DIR}/etc/profile.d/98-sudobox-arch-init.sh" <<'EOS'
# SudoBox: Arch Linux ARM 首次初始化（执行一次后自动删除本文件）
if [ ! -f /etc/pacman.d/gnupg/.sudobox-init-done ]; then
    echo "[SudoBox] 首次使用，正在初始化 pacman keyring ..."
    pacman-key --init 2>&1 | tail -3
    pacman-key --populate archlinuxarm 2>&1 | tail -3
    touch /etc/pacman.d/gnupg/.sudobox-init-done 2>/dev/null
    rm -f /etc/profile.d/98-sudobox-arch-init.sh
    echo "[SudoBox] 完成。现在可用: pacman -Syu"
fi
EOS
    chmod 0644 "${CHROOT_DIR}/etc/profile.d/98-sudobox-arch-init.sh" 2>/dev/null
    echo "    已注入 pacman-key 首次初始化脚本（首次进入容器时自动执行）"
    return 0
}
