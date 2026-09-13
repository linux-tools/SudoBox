#!/system/bin/sh
###############################################################################
# SudoBox / chroot-mgr — KernelSU module: uninstall.sh
#
# 卸载即全清 (D10)：
#   1. 优先用 chroot-mgr uninstall --purge（v0.1.2+）—— 走完整 disable 流程
#      + 清理数据目录
#   2. 兜底：直接 force umount + rm -rf（兼容老版本 chroot-mgr）
# 零残留，不触碰 /system。
###############################################################################

# v0.1.8: KSU/Magisk 对 uninstall.sh 可能以 `sh -e` 执行——任何隐藏失败会立刻
# 中断脚本、跳过最终 rm -rf，导致数据目录残留。显式 set +e 覆盖。
set +e

MODDIR="${0%/*}"
DATA_DIR="/data/adb/chroot-mgr"
MGR="${MODDIR}/bin/chroot-mgr"

# --- 1. graceful stop (chroot-mgr v0.1.2+ 优先) -----------------------------
# v0.1.8 修复：不得因 uninstall --purge 成功就 exit 0——
# purge 只清空 ${CM_DATA_DIR} 内容并重建空壳目录（chroot-mgr 运行期需要
# profiles/config/tmp 存在），不删 /data/adb/chroot-mgr 目录本体。
# 提前退出会导致数据目录残留（"卸载不干净"）。无论 purge/disable 成败，
# 都必须继续走到步骤 3 的 rm -rf 最终兜底。
if [ -x "${MGR}" ]; then
    "${MGR}" uninstall --purge -y >/dev/null 2>&1
    "${MGR}" disable --all >/dev/null 2>&1
fi

# --- 2. force release (best effort) ------------------------------------------
# 逆序 umount 任何仍指向 rootfs 的挂载
if [ -d "${DATA_DIR}/data/profiles" ]; then
    for i in 1 2 3; do
        MOUNTS="$(grep "${DATA_DIR}" /proc/mounts 2>/dev/null | awk '{print $2}' | sort -r)"
        [ -n "${MOUNTS}" ] || break
        for m in ${MOUNTS}; do
            umount "${m}" 2>/dev/null || umount -l "${m}" 2>/dev/null
        done
    done
fi

# --- 3. PATH 注入清理（v0.1.21 chroot-mgr path install 产物）-----------------
# 只删本模块创建的 symlink（指向 *chroot-mgr* 的链接），不动用户自己的文件。
# /data/adb/ksu/bin 是 KSU 数据目录而非系统目录，删除属模块数据清理（D10/D11）。
KSU_BIN="/data/adb/ksu/bin"
if [ -d "${KSU_BIN}" ]; then
    for n in chroot-mgr sudobox; do
        if [ -L "${KSU_BIN}/${n}" ]; then
            case "$(readlink "${KSU_BIN}/${n}" 2>/dev/null)" in
            *chroot-mgr*) rm -f "${KSU_BIN}/${n}" 2>/dev/null ;;
            esac
        fi
    done
fi

# --- 4. remove data dir ------------------------------------------------------
# 注意：只删 /data/adb/chroot-mgr（本模块专用数据目录），
#       绝不递归删除 /data/adb 或其他模块目录。
rm -rf "${DATA_DIR}"

exit 0
