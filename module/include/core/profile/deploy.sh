#!/system/bin/sh
# SudoBox Component — 容器 shell 环境
# (adapted from Linux Deploy core/profile, GPLv3)
#
# 无 PID_NS 环境下不做服务自启（那是 svc 的职责），
# 本组件只保证进入容器后的基本环境可用：PATH、locale、tmp 权限。

do_configure()
{
    msg ":: 配置 ${COMPONENT} ... "

    # /etc/profile.d 注入容器环境
    mkdir -p "${CHROOT_DIR}/etc/profile.d" 2>/dev/null
    cat > "${CHROOT_DIR}/etc/profile.d/99-sudobox.sh" <<'PROFILE'
# SudoBox container environment (generated)
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export TERM="${TERM:-xterm-256color}"
# 无 PID_NS：容器内看不到宿主进程树，ps 需直接读 /proc
alias ps='ps -ef 2>/dev/null || ps'
# 提示当前运行于 SudoBox chroot（unshare -m + chroot，非完整容器）
if [ -z "${SUDOBOX_QUIET}" ]; then
    echo "SudoBox · $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME}" || echo GNU/Linux)"
    echo "引擎 unshare -m + chroot  ·  无 PID 命名空间（systemd 不可用）"
fi
PROFILE
    chmod 0644 "${CHROOT_DIR}/etc/profile.d/99-sudobox.sh" 2>/dev/null

    # motd
    cat > "${CHROOT_DIR}/etc/motd" <<'MOTD'

  ____            _         ____
 / ___| _   _  __| | ___   | __ )  _____  __
 \___ \| | | |/ _` |/ _ \  |  _ \ / _ \ \/ /
  ___) | |_| | (_| | (_) | | |_) | (_) >  <
 |____/ \__,_|\__,_|\___/  |____/ \___/_/\_\

 按需提权，即用即还  ·  Your Linux workspace, on demand.

MOTD
    chmod 0644 "${CHROOT_DIR}/etc/motd" 2>/dev/null

    # tmp 权限（chroot 内守护进程常依赖）
    [ -d "${CHROOT_DIR}/tmp" ] || mkdir -p "${CHROOT_DIR}/tmp" 2>/dev/null
    chmod 1777 "${CHROOT_DIR}/tmp" 2>/dev/null

    return 0
}

do_status()
{
    echo "   ${COMPONENT}: profile.d/99-sudobox.sh $([ -f "${CHROOT_DIR}/etc/profile.d/99-sudobox.sh" ] && echo ok || echo missing)"
    return 0
}
