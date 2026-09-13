#!/system/bin/sh
# SudoBox hook — Alpine: /etc/apk/repositories 换源
hook_run()
{
    [ -d "${CHROOT_DIR}/etc/apk" ] || { echo "    (非 Alpine 系统，跳过)"; return 0; }

    local base="https://dl-cdn.alpinelinux.org/alpine"
    case "${SUDOBOX_MIRROR}" in
        tuna)   base="https://mirrors.tuna.tsinghua.edu.cn/alpine" ;;
        aliyun) base="https://mirrors.aliyun.com/alpine" ;;
        ustc)   base="https://mirrors.ustc.edu.cn/alpine" ;;
    esac

    # suite 形如 v3.21
    local ver="${SUITE}"
    [ -n "${ver}" ] || ver="v3.21"

    cat > "${CHROOT_DIR}/etc/apk/repositories" <<EOF
${base}/${ver}/main
${base}/${ver}/community
EOF
    chmod 0644 "${CHROOT_DIR}/etc/apk/repositories" 2>/dev/null
    echo "    apk repositories -> ${base}/${ver}"
    return 0
}
