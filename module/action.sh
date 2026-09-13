#!/system/bin/sh
###############################################################################
# SudoBox / chroot-mgr — KernelSU module: action.sh
#
# 在 KSU 管理器中点模块右下角"操作"按钮触发。
# 提供无 App 时的最小控制面：status / enable / disable / switch / diagnose
###############################################################################

MODDIR="${0%/*}"
MGR="${MODDIR}/bin/chroot-mgr"

if [ ! -x "${MGR}" ]; then
    echo "chroot-mgr 未找到或不可执行: ${MGR}"
    exit 1
fi

ACTIVE="$("${MGR}" status --field active 2>/dev/null)"
STATE="$("${MGR}" status --field state 2>/dev/null)"

echo "=== SudoBox / chroot-mgr ==="
echo "state : ${STATE:-unknown}"
echo "active: ${ACTIVE:-none}"
echo
echo "1) 查看完整状态"
echo "2) 启用容器 (enable)"
echo "3) 进入容器 (enter)"
echo "4) 停止容器 (disable)"
echo "5) 能力诊断 (diagnose)"
echo "6) 挂载残留检查"
echo "0) 取消"
echo
printf "选择 [0-6]: "
read -r choice || exit 0

case "${choice}" in
    1) "${MGR}" status ;;
    2)
        printf "profile id: "
        read -r id || exit 0
        [ -n "${id}" ] && "${MGR}" enable "${id}"
        ;;
    3)
        printf "profile id [${ACTIVE}]: "
        read -r id || exit 0
        "${MGR}" enter "${id:-${ACTIVE}}"
        ;;
    4) "${MGR}" disable ;;
    5) "${MGR}" diagnose ;;
    6) "${MGR}" status --mounts ;;
    0) exit 0 ;;
    *) echo "无效选择" ;;
esac
