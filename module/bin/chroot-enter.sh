#!/system/bin/sh
###############################################################################
# chroot-enter.sh — 容器进入 helper（在 unshare -m 私有 mount 命名空间内执行）
#
# 由 chroot-mgr 通过以下方式调用：
#   unshare -m $MODDIR/bin/chroot-enter.sh <rootfs> [cmd...]
#
# 职责：
#   1. 在私有 mount ns 内补足容器所需挂载（proc/sys/dev/pts/shm/tmp）
#      —— 因为是私有 ns，这些挂载在会话结束后随 ns 自动消失，宿主零残留
#   2. 准备环境变量（USER/HOME/TERM/PS1/PATH）
#   3. exec chroot 进入（不 fork，保持 PID 与会话语义，便于台账追踪）
###############################################################################

ROOTFS="$1"
[ -n "${ROOTFS}" ] || { echo "E: 用法: chroot-enter.sh <rootfs> [cmd...]" >&2; exit 1; }
shift

[ -d "${ROOTFS}" ] || { echo "E: rootfs 不存在: ${ROOTFS}" >&2; exit 1; }

# --- 0. stdin tty 恢复 ----------------------------------------------------------
# v0.1.13: mksh/POSIX 非交互 shell 的异步列表（cmd &）默认把 stdin 接到 /dev/null。
# 本 helper 常被 chroot-mgr 后台化调用，若上游漏了 </dev/tty，exec 链末端的
# bash -l 会因 stdin 非 tty 进入非交互模式 → 读 EOF 静默秒退（v0.1.12 实机根因）。
# 此处兜底恢复控制终端；用一次性子 shell 预检（打开失败只伤子 shell 不退外层）。
if [ ! -t 0 ]; then
    if ( exec 0</dev/tty ) 2>/dev/null; then
        exec 0</dev/tty
    fi
fi

# --- 1. 工具探测 -----------------------------------------------------------------
# v0.1.2: 模块自带 busybox 优先（aarch64 静态 musl，含 unshare/chroot/mount/tar）
BB=""
for cand in "${CM_BINDIR}/busybox" \
            /data/adb/ksu/bin/busybox /data/adb/magisk/busybox \
            /system/bin/busybox; do
    [ -x "${cand}" ] && { BB="${cand}"; break; }
done
MOUNT="mount"; UMOUNT="umount"; CHROOT="chroot"
[ -n "${BB}" ] && { MOUNT="${BB} mount"; UMOUNT="${BB} umount"; CHROOT="${BB} chroot"; }

ismnt() { grep -q " ${1%/} " /proc/mounts 2>/dev/null; }

# --- 1. 补足挂载（幂等）--------------------------------------------------------
for d in proc sys dev dev/pts dev/shm tmp; do
    [ -d "${ROOTFS}/${d}" ] || mkdir -p "${ROOTFS}/${d}" 2>/dev/null
done

ismnt "${ROOTFS}/proc"  || ${MOUNT} -t proc proc "${ROOTFS}/proc" 2>/dev/null
ismnt "${ROOTFS}/sys"   || ${MOUNT} -t sysfs sys "${ROOTFS}/sys" 2>/dev/null
ismnt "${ROOTFS}/dev"   || ${MOUNT} -o bind /dev "${ROOTFS}/dev" 2>/dev/null

[ -d /dev/pts ] || mkdir -p /dev/pts 2>/dev/null
ismnt /dev/pts || ${MOUNT} -t devpts devpts /dev/pts -o rw,nosuid,noexec,mode=620,ptmxmode=000 2>/dev/null
ismnt "${ROOTFS}/dev/pts" || ${MOUNT} -o bind /dev/pts "${ROOTFS}/dev/pts" 2>/dev/null

[ -d /dev/shm ] || mkdir -p /dev/shm 2>/dev/null
ismnt /dev/shm || ${MOUNT} -t tmpfs tmpfs /dev/shm -o rw,nosuid,nodev,mode=1777 2>/dev/null
ismnt "${ROOTFS}/dev/shm" || ${MOUNT} -o bind /dev/shm "${ROOTFS}/dev/shm" 2>/dev/null

ismnt "${ROOTFS}/tmp" || ${MOUNT} -t tmpfs tmpfs "${ROOTFS}/tmp" -o rw,nosuid,nodev,mode=1777 2>/dev/null

# --- 2. 环境变量 ---------------------------------------------------------------
# v0.1.9: SUDOBOX_USER_NAME 由 chroot-mgr cm_enter_session 通过 env 传入，
# 对应容器内已配置的非 root 用户（cm_user_setup_if_needed 创建）。
# v0.1.14: SUDOBOX_FORCE_ROOT=1（chroot-mgr root）→ 忽略已配置用户，强制 root。
# - 未设置 / 空 / 用户不存在 → 保持原行为（root 登录）
# - 设置且 /bin/su 存在 → exec chroot rootfs /bin/su -l <name>（落到非 root shell）
# - 设置但 /bin/su 缺失 → 回退到 bash/sh（fallback）
if [ "${SUDOBOX_FORCE_ROOT:-0}" = "1" ]; then
    SUDOBOX_USER_NAME=""
fi
if [ -n "${SUDOBOX_USER_NAME:-}" ]; then
    USER="${SUDOBOX_USER_NAME}"
    LOGNAME="${SUDOBOX_USER_NAME}"
    # home 在 useradd 时已 -m 创建，默认 /home/<name>（Alpine busybox adduser 也一样）
    HOME="/home/${SUDOBOX_USER_NAME}"
    [ -d "${ROOTFS}${HOME}" ] || HOME="/root"
else
    USER=root
    LOGNAME=root
    HOME=/root
fi
SHELL=/bin/bash
[ -x "${ROOTFS}/bin/bash" ] || SHELL=/bin/sh
[ -n "${TERM}" ] || TERM=xterm-256color
PS1='[\u@\h:\w]\$ '
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# 容器内不使用宿主 LD_PRELOAD/TMPDIR（避免 Android 侧变量污染）
unset LD_PRELOAD LD_LIBRARY_PATH TMPDIR TEMP TMP ANDROID_ROOT ANDROID_DATA ANDROID_STORAGE

export USER LOGNAME HOME SHELL TERM PS1 PATH

# motd
if [ -r "${ROOTFS}/etc/motd" ]; then
    cat "${ROOTFS}/etc/motd"
fi

# --- 3. exec chroot ------------------------------------------------------------
if [ $# -gt 0 ]; then
    # 用户显式传了命令（如 'chroot-mgr enter ubuntu -- /bin/bash'），优先按命令；
    # 不强切到 SUDOBOX_USER_NAME（保留手动以 root 跑的逃生通道）。
    exec ${CHROOT} "${ROOTFS}" "$@"
else
    # v0.1.9: 配置了非 root 用户 → su 落到该用户。
    # v0.1.10/0.1.11: su 失败打提示 / 预检 shell 可登录性。
    # v0.1.12: 入口彻底去 su/PAM 依赖。实机结论：distro su 对 root 走 pam_rootok
    #          短路所以 v0.1.8 时代一直正常，但 `su -l <user>` 走完整 PAM 栈，
    #          在 chroot + KernelSU（Android 内核无 auditd/systemd）环境里某个
    #          PAM 模块静默失败 → rc=0 零输出退出（截图复现两次，无任何诊断线索）。
    #          改为 setpriv 直接降权（纯 syscall，无 PAM/shadow/su 语义依赖）：
    #          优先容器内 /usr/bin/setpriv（GNU util-linux），否则模块 busybox
    #          复制进 rootfs/tmp（tmpfs，会话结束随挂载消失，零残留）。
    #          exec 前先探测降权链路可用，不可用才回落 su 兜底。
    # v0.1.14: SUDOBOX_FORCE_ROOT=1（chroot-mgr root 子命令）→ 整段跳过，
    #          直接落 root fallback（bash -l，不经 setpriv/su/PAM）。
    if [ -n "${SUDOBOX_USER_NAME:-}" ] && [ "${SUDOBOX_FORCE_ROOT:-0}" != "1" ]; then
        _upw="$(grep "^${SUDOBOX_USER_NAME}:" "${ROOTFS}/etc/passwd" 2>/dev/null | head -n1)"
        if [ -n "${_upw}" ]; then
            _uuid="$(printf '%s\n' "${_upw}" | cut -d: -f3)"
            _ugid="$(printf '%s\n' "${_upw}" | cut -d: -f4)"
            _uhom="$(printf '%s\n' "${_upw}" | cut -d: -f6)"
            _ush="$(printf '%s\n' "${_upw}" | cut -d: -f7)"
            [ -n "${_ush}" ] || _ush="/bin/bash"
            case "${_ush}" in
                /bin/false|/usr/sbin/nologin|/sbin/nologin|/bin/sync|"")
                    echo "" >&2
                    echo "W: 用户 '${SUDOBOX_USER_NAME}' 的 shell '${_ush:-空}' 不可登录——回退 root。" >&2
                    echo "   修复: 宿主执行 chroot-mgr user-config --reset 后重新 enter" >&2 ;;
                *)
                    if [ -x "${ROOTFS}${_ush}" ] && [ -d "${ROOTFS}${_uhom:-/nonexistent}" ]; then
                        HOME="${_uhom}"; export HOME
                        _sesp=""; _spargs=""
                        if [ -x "${ROOTFS}/usr/bin/setpriv" ]; then
                            _sesp="/usr/bin/setpriv"
                            # GNU util-linux 语法；--init-groups 按 passwd 补全附加组
                            _spargs="--reuid=${_uuid} --regid=${_ugid} --init-groups"
                        elif [ -n "${BB}" ]; then
                            # 模块 busybox 拷入 rootfs/tmp（tmpfs → 会话结束零残留）
                            mkdir -p "${ROOTFS}/tmp" 2>/dev/null
                            cp "${BB}" "${ROOTFS}/tmp/.sb-bb" 2>/dev/null \
                                && chmod 0755 "${ROOTFS}/tmp/.sb-bb" 2>/dev/null \
                                && { _sesp="/tmp/.sb-bb setpriv";
                                     # busybox setpriv 语法与 GNU 不同
                                     _spargs="--ruid=${_uuid} --rgid=${_ugid} --clear-groups"; }
                        fi
                        if [ -n "${_sesp}" ] && ${CHROOT} "${ROOTFS}" ${_sesp} ${_spargs} /bin/sh -c ':' >/dev/null 2>&1; then
                            echo "== 以 ${SUDOBOX_USER_NAME} (uid=${_uuid}) 进入 (setpriv 直降权，不经 PAM) =="
                            exec ${CHROOT} "${ROOTFS}" ${_sesp} ${_spargs} "${_ush}" -l
                        fi
                        # setpriv 不可用（缺二进制/flag 不支持）→ su 兜底。
                        # su 可能在 PAM 处静默退出 rc=0（v0.1.12 前的死法），故先打标记
                        if [ -x "${ROOTFS}/bin/su" ]; then
                            echo "== 以 ${SUDOBOX_USER_NAME} 进入 (setpriv 不可用，su 兜底) =="
                            echo "   （若下行无 shell 提示符即退出，说明容器 PAM 栈异常，请截图反馈）"
                            ${CHROOT} "${ROOTFS}" /bin/su -l "${SUDOBOX_USER_NAME}"
                            _su_rc=$?
                            if [ ${_su_rc} -eq 0 ]; then exit 0; fi
                            echo "" >&2
                            echo "提示: su 进入失败 (rc=${_su_rc})——回退 root 便于排查。" >&2
                        else
                            echo "W: 容器内无 setpriv 也无 su——回退 root shell" >&2
                        fi
                    else
                        echo "" >&2
                        echo "W: 用户 '${SUDOBOX_USER_NAME}' 的 shell(${_ush:-?})/home(${_uhom:-?}) 不可用——回退 root。" >&2
                        echo "   修复: 宿主执行 chroot-mgr user-config --reset 后重新 enter" >&2
                    fi
                    ;;
            esac
        else
            echo "" >&2
            echo "W: 容器内无用户 '${SUDOBOX_USER_NAME}'（配置标志遗留）——回退 root。" >&2
            echo "   修复: 宿主执行 chroot-mgr user-config --reset 后重新 enter" >&2
        fi
    fi
    # root fallback（含上面非 root 入口失败的回退）。
    # v0.1.12: root 不再走 su —— root 无需降权，bash -l 直接给 login shell，
    #          绕开 PAM（su - root 虽有 pam_rootok 短路，但没有理由多绕一层）。
    if [ -x "${ROOTFS}/bin/bash" ]; then
        exec ${CHROOT} "${ROOTFS}" /bin/bash -l
    elif [ -x "${ROOTFS}/bin/su" ]; then
        exec ${CHROOT} "${ROOTFS}" /bin/su - root
    else
        exec ${CHROOT} "${ROOTFS}" /bin/sh -l
    fi
fi
