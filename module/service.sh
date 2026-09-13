#!/system/bin/sh
###############################################################################
# SudoBox / chroot-mgr — KernelSU module: service.sh (late_start)
#
# 行为：读取 .enabled flag → 若用户显式开启了"随开机恢复"，则重新挂载容器。
# 默认：开机不自动恢复（尊重"临时"语义，设计方案 §4.4）。
#
# 注意：KSU 的 service.sh 默认 blocking 运行（开机等待其返回），
#       因此实际工作一律后台化并立即 exit 0，绝不阻塞开机。
###############################################################################

MODDIR="${0%/*}"
DATA_ROOT="/data/adb/chroot-mgr/data"
STATE_FILE="${DATA_ROOT}/.state"
BOOT_FLAG="${DATA_ROOT}/config/boot-restore"
LOG="${DATA_ROOT}/service.log"

# 开机自启默认关闭（设计方案 §4.4 / 无系统改动清单）
[ -f "${BOOT_FLAG}" ] || exit 0

# 后台执行，立即返回，避免阻塞 late_start
(
    echo "[$(date '+%F %T')] service.sh: boot-restore enabled" >> "${LOG}"

    # v0.1.24: daemon-mode 门控——用户启用全局监督 daemon 时，开机恢复职责
    # 移交 chroot-mgr daemon start --boot（--boot 由 daemon 循环体执行 enable，
    # 之后的状态对账/事件日志统一在 daemon tick 里做）。
    # 未启用 daemon-mode 时走下方 legacy 一次性恢复（行为与 v0.1.23 一致）。
    if [ -f "${DATA_ROOT}/config/daemon-mode" ]; then
        echo "[$(date '+%F %T')] daemon mode: handing boot-restore to supervisor" >> "${LOG}"
        "${MODDIR}/bin/chroot-mgr" daemon start --boot >> "${LOG}" 2>&1
        echo "[$(date '+%F %T')] daemon start rc=$?" >> "${LOG}"
        exit 0
    fi

    # legacy：逐个恢复被标记的 profile（读 profile 的 .enabled）
    for prof_dir in "${DATA_ROOT}"/profiles/*; do
        [ -d "${prof_dir}" ] || continue
        [ -f "${prof_dir}/.enabled" ] || continue
        id="${prof_dir##*/}"
        echo "[$(date '+%F %T')] restoring ${id}" >> "${LOG}"
        "${MODDIR}/bin/chroot-mgr" enable "${id}" >> "${LOG}" 2>&1
        echo "[$(date '+%F %T')] enable ${id} rc=$?" >> "${LOG}"
    done
) >/dev/null 2>&1 &

exit 0
