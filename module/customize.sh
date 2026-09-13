#!/system/bin/sh
###############################################################################
# SudoBox / chroot-mgr -- KernelSU module: customize.sh (install time)
#
# 职责（幂等，升级时重复执行安全）：
#   1. 架构探测与兼容性校验
#   2. 创建数据目录 /data/adb/chroot-mgr/data/{profiles,config,tmp}   (D8)
#   3. 幂等迁移：升级模块不动数据 (D9)
#   4. 权限与 SELinux context 修正
#   5. 强制设置模块自带 busybox 可执行位（防 unzip 丢 mode bits）
#
# 硬约束：不写 /system /vendor /product，不改 init/rc，不 setprop 持久化 (D11)
#
# v0.1.4 错误处理原则（回应代码评审）：
#   - 失败处理按影响分级，绝不用 `|| true` 无声吞错（那不是防御，是掩耳盗铃）：
#     * 影响核心功能（busybox 缺失/不可执行/损坏、数据目录建不了）-> abort()，
#       带具体原因退出 1
#     * 不影响功能但应留痕（chcon context 修正失败）-> warn() 打一行可见警告，
#       继续安装
#     * 本脚本不需要 `|| true`：顶部 set +e 已保证单条命令失败不会中断脚本，
#       真正的门卫是每个关键点后的显式 rc 检查
#   - KSU/Magisk 安装器可能用 `sh -e` 执行本脚本，顶部 set +e 显式覆盖，
#     否则任何隐藏失败都会让安装器只显示"错误代码 1"而不给原因
#   - KSU 安装器 unzip 不保证保留 Unix mode bits（ZIP 内 0o755 可能变 0o644），
#     所以校验前必须先 chmod 0755 恢复
###############################################################################

set +e   # 显式关闭 errexit：错误必须走到显式检查点，由 warn()/abort() 分级处理

umask 022

DATA_DIR="/data/adb/chroot-mgr"
DATA_ROOT="${DATA_DIR}/data"

ui_print() { echo "$@"; }
warn()     { ui_print "! 警告: $*"; }
abort()    { ui_print "! 严重错误: $*"; exit 1; }

ui_print "********************************************"
ui_print " SudoBox / chroot-mgr  (Sudo=按需提权, Box=容器盒)"
ui_print " 引擎: unshare -m + chroot   ·   标语: 按需提权，即用即还"
ui_print "********************************************"

# --- 1. architecture ---------------------------------------------------------
ARCH="$(uname -m 2>/dev/null || echo unknown)"
case "${ARCH}" in
    aarch64|arm64)   DEB_ARCH="arm64"  ; PLATFORM="arm_64" ;;
    armv7l|armv8l)   DEB_ARCH="armhf"  ; PLATFORM="arm"    ;;
    x86_64|amd64)    DEB_ARCH="amd64"  ; PLATFORM="x86_64" ;;
    i686|i386|x86)   DEB_ARCH="i386"   ; PLATFORM="x86"    ;;
    *)
        ui_print "! 未知架构: ${ARCH}（继续安装，但发行版描述符可能无匹配）"
        DEB_ARCH="unknown"; PLATFORM="unknown"
        ;;
esac
ui_print "- 架构: ${ARCH} (deb: ${DEB_ARCH})"

# --- 2. data dirs (D8 / D9: 模块代码目录之外，升级不动) ------------------------
if [ ! -d "${DATA_ROOT}" ]; then
    ui_print "- 创建数据目录: ${DATA_ROOT}"
    mkdir -p "${DATA_ROOT}/profiles" 2>/dev/null || abort "无法创建 ${DATA_ROOT}/profiles"
    mkdir -p "${DATA_ROOT}/config"    2>/dev/null || abort "无法创建 ${DATA_ROOT}/config"
    mkdir -p "${DATA_ROOT}/tmp"       2>/dev/null || abort "无法创建 ${DATA_ROOT}/tmp"
else
    ui_print "- 数据目录已存在，保留升级: ${DATA_ROOT}"
    # 幂等补齐（老版本可能缺子目录）——目录建不出来直接影响后续，abort
    [ -d "${DATA_ROOT}/profiles" ] || mkdir -p "${DATA_ROOT}/profiles" 2>/dev/null || abort "无法创建 ${DATA_ROOT}/profiles"
    [ -d "${DATA_ROOT}/config"   ] || mkdir -p "${DATA_ROOT}/config"   2>/dev/null || abort "无法创建 ${DATA_ROOT}/config"
    [ -d "${DATA_ROOT}/tmp"      ] || mkdir -p "${DATA_ROOT}/tmp"      2>/dev/null || abort "无法创建 ${DATA_ROOT}/tmp"
fi

# --- 2.5 升级前容器对账清理（v0.1.19，warn-only 不阻断安装） ------------------
# 背景（v0.1.19 升级路径审计结论）：
#   - 容器挂载（rootfs 自 bind + proc/sys/dev/devpts/devshm/tmp）创建在宿主
#     全局 mount namespace（cm_mount_all 不在 unshare 内），跨软重启存续；
#   - v0.1.18 起 watchdog 守护进程 setsid 双重 fork 常驻，脱离安装器谱系；
#   - 旧模块文件被本次安装替换后，旧守护/旧挂载与新代码并存，状态文件可能与
#     实况脱节。软重启场景下全局挂载表非空，与重启期系统挂载操作互踩。
# 处理：先停守护（pidfile 精确 TERM→宽限→KILL），再卸载活跃容器挂载（优先
# 复用旧版 mgr 的 disable 完整终止序；不可用退化为手动逆序 umount + 校验）。
# 全程 warn-only，绝不阻断安装；绝不触碰 /data 挂载标志（panic 红线）。
OLD_MGR="/data/adb/modules/chroot-mgr/bin/chroot-mgr"
CLEAN_BB="${MODPATH}/bin/busybox"
[ -x "${CLEAN_BB}" ] || CLEAN_BB="${OLD_MGR%/*}/busybox"
if [ -d "${DATA_ROOT}/profiles" ]; then
    did_clean=0
    for pdir in "${DATA_ROOT}"/profiles/*/; do
        [ -d "${pdir}" ] || continue
        pid_dir="${pdir%/}"; pid_name="${pid_dir##*/}"
        # a) 停守护：pidfile 位于 profile 目录（升级不动数据目录，pid 仍有效）
        gpid="$(cat "${pdir}.guard.pid" 2>/dev/null)"
        if [ -n "${gpid}" ] && [ -d "/proc/${gpid}" ]; then
            kill -TERM "${gpid}" 2>/dev/null
            _w=0; while [ ${_w} -lt 3 ] && [ -d "/proc/${gpid}" ]; do sleep 1; _w=$((_w+1)); done
            [ -d "/proc/${gpid}" ] && kill -KILL "${gpid}" 2>/dev/null
            rm -f "${pdir}.guard.pid"
            ui_print "- 已停止进程守护: ${pid_name} (pid=${gpid})"
            did_clean=1
        fi
        # b) 卸载活跃挂载：优先旧版 mgr 完整终止序，失败退化为手动逆序卸载
        rootfs="${pid_dir}/rootfs"
        mnts="$(grep -F "${rootfs%/}" /proc/mounts 2>/dev/null | awk '{print $2}' | sort -r)"
        if [ -n "${mnts}" ]; then
            ui_print "- 检测到未卸载容器挂载: ${pid_name}（升级前清理）"
            if [ -x "${OLD_MGR}" ]; then
                "${OLD_MGR}" disable "${pid_name}" >/dev/null 2>&1 \
                    || ui_print "! 旧版 disable 未成功，退化为手动卸载"
            fi
            mnts="$(grep -F "${rootfs%/}" /proc/mounts 2>/dev/null | awk '{print $2}' | sort -r)"
            for _m in ${mnts}; do
                "${CLEAN_BB}" umount "${_m}" 2>/dev/null \
                    || "${CLEAN_BB}" umount -l "${_m}" 2>/dev/null
            done
            if grep -qF "${rootfs%/}" /proc/mounts 2>/dev/null; then
                warn "容器挂载未完全卸载: ${pid_name}（请先 disable 容器再升级，或重启后再试）"
            else
                ui_print "  挂载已全部卸载"
            fi
            did_clean=1
        fi
    done
    [ "${did_clean}" = "1" ] || ui_print "- 容器对账: 无活跃守护/挂载，跳过"
else
    ui_print "- 首次安装（无容器数据），跳过容器对账"
fi

# --- 3. state file bootstrap -------------------------------------------------
STATE_FILE="${DATA_ROOT}/.state"
if [ ! -f "${STATE_FILE}" ]; then
    cat > "${STATE_FILE}" 2>/dev/null <<EOF || abort "无法写入 ${STATE_FILE}"
version=1
updated=$(date +%s)
state=disabled
engine=chroot
active=
pid=
error_msg=
EOF
fi

# --- 4. permissions ----------------------------------------------------------
# 权限修正是"最好成功"：失败不影响本步继续，但用户应能看到 —— 用 warn 留痕。
# （data 目录权限错，chroot-mgr 运行时以 root 身份访问 /data/adb 仍可读写，
#   不构成功能阻断；但若你希望更严格，可把 warn 换成 abort —— 见头部原则）
chmod 0755 "${DATA_DIR}"           2>/dev/null || warn "chmod 0755 ${DATA_DIR} 失败"
chmod 0755 "${DATA_ROOT}"          2>/dev/null || warn "chmod 0755 ${DATA_ROOT} 失败"
chmod 0755 "${DATA_ROOT}/profiles" 2>/dev/null || warn "chmod 0755 ${DATA_ROOT}/profiles 失败"
chmod 0755 "${DATA_ROOT}/config"   2>/dev/null || warn "chmod 0755 ${DATA_ROOT}/config 失败"
chmod 1777 "${DATA_ROOT}/tmp"      2>/dev/null || warn "chmod 1777 ${DATA_ROOT}/tmp 失败"
chmod 0644 "${STATE_FILE}"         2>/dev/null || warn "chmod 0644 ${STATE_FILE} 失败"

# --- 5. SELinux context (best effort, 显式留痕不阻断) --------------------------
# chcon 在 KSU 注入的 su context 下可能无权限 —— 这不影响模块运行：
# v0.1.1 起模块不依赖额外 SELinux 规则（KSU 内核内置 su 域全放行，模块以
# su/root 运行），chcon 失败只是少了"整洁的 file context"，功能不受影响。
# 但失败必须可见 —— warn 打一行，让日志可查。
if [ -e "/sys/fs/selinux/enforce" ]; then
    BB_CTX="${MODPATH}/bin/busybox"
    for ctx_dir in "${DATA_DIR}" "${DATA_ROOT}" "${DATA_ROOT}/profiles"; do
        [ -d "${ctx_dir}" ] || continue
        # v0.1.20 安全修复：原 `chcon -R` 会在容器挂载期间穿越 rootfs/dev
        # （宿主 /dev 的 bind mount），把宿主 /dev/null 等节点错标为
        # adb_data_file -> 软重启后 init/cameraserver 打不开 /dev/null
        # -> system_server 崩溃循环卡 Logo（2026-09-07 实机实证）。
        # 现改为：-xdev 禁止跨挂载点、不跟随符号链接、剪掉 rootfs 子树；
        # 任何失败仅 warn（本步骤纯锦上添花，绝不阻断安装）。
        if "${BB_CTX}" find "${ctx_dir}" -xdev \( -name rootfs -prune \) -o \
                \( -type d -o -type f \) -exec "${BB_CTX}" chcon u:object_r:adb_data_file:s0 {} + 2>/dev/null; then
            :
        else
            chcon u:object_r:adb_data_file:s0 "${ctx_dir}" 2>/dev/null \
                || warn "chcon ${ctx_dir} 失败（非致命：运行期以 su/root 访问，无需该 context）"
        fi
    done
fi

# --- 5.5 强制恢复模块脚本可执行位（关键） ---------------------------------------
# KSU/Magisk 安装器 unzip 可能丢 Unix mode bits（ZIP 内 0o755 在设备上变 0o644），
# 必须在 busybox 校验前先 chmod 恢复。
# 失败不吞：chmod 失败会走到 step 6 的 [ -x ] 显式门卫 -> abort。
BB="${MODPATH}/bin/busybox"
[ -f "${BB}" ] && chmod 0755 "${BB}" 2>/dev/null
[ -f "${MODPATH}/bin/chroot-mgr" ]      && chmod 0755 "${MODPATH}/bin/chroot-mgr"      2>/dev/null
[ -f "${MODPATH}/bin/chroot-enter.sh" ] && chmod 0755 "${MODPATH}/bin/chroot-enter.sh" 2>/dev/null
[ -f "${MODPATH}/bin/net.sh" ]          && chmod 0755 "${MODPATH}/bin/net.sh"          2>/dev/null
if [ -d "${MODPATH}/include" ]; then
    find "${MODPATH}/include" -type f -name '*.sh' -exec chmod 0755 {} \; 2>/dev/null
fi

# --- 6. toolchain presence (强制, 全门卫) --------------------------------------
# v0.1.2: 模块自带 busybox 是必填项。
# 因为 KSU 自带的 /data/adb/ksu/bin/busybox 是精简版，没有 unshare applet，
# 在临时 root + SELinux 注入的 context 下执行 unshare(2) 会被拒绝，
# 导致 chroot-mgr enter 直接 fail（exit 127 "inaccessible or not found"）。
#
# 内置 busybox 要求：aarch64 ELF64 静态链接（musl），含 unshare/chroot/mount/tar/wget
# 来源：Alpine v3.22 main/busybox-static-1.37.0-r20（GPL-2.0）
if [ ! -f "${BB}" ]; then
    abort "${BB} 不存在 — 模块 ZIP 可能不完整或解压失败"
fi
if [ ! -x "${BB}" ]; then
    # 再试一次 chmod 0755（5.5 已试过，这里兜底；仍失败才 abort）
    chmod 0755 "${BB}" 2>/dev/null
    if [ ! -x "${BB}" ]; then
        abort "${BB} 不可执行 (chmod 0755 失败) — 设备文件系统可能不允许，或分区以 noexec 挂载"
    fi
fi
# 校验 ELF 头（防止 ZIP 损坏或下错文件）
BB_MAGIC="$(od -An -tx1 -N4 "${BB}" 2>/dev/null | tr -d ' \n')"
if [ "${BB_MAGIC}" != "7f454c46" ]; then
    abort "${BB} 不是 ELF 二进制 (magic=${BB_MAGIC}) — 模块 ZIP 可能在传输中损坏"
fi
# 校验架构（aarch64 = 0xb7，否则拒绝）
BB_MACHINE="$(od -An -tx1 -j18 -N2 "${BB}" 2>/dev/null | tr -d ' \n')"
if [ "${BB_MACHINE}" != "b700" ]; then
    abort "${BB} 不是 aarch64 (machine=0x${BB_MACHINE}) — 本模块需要 aarch64 设备"
fi
# 校验关键 applet
BB_MISSING=""
for app in unshare chroot mount umount tar wget sed awk grep; do
    if ! "${BB}" "${app}" --help >/dev/null 2>&1 && \
       ! "${BB}" "${app}" -h       >/dev/null 2>&1; then
        BB_MISSING="${BB_MISSING} ${app}"
    fi
done
if [ -n "${BB_MISSING}" ]; then
    abort "${BB} 缺关键 applet:${BB_MISSING} — 请检查模块 ZIP 是否完整"
fi
BB_VER="$("${BB}" 2>/dev/null | head -1 | sed -n 's/.*BusyBox \(v[0-9.]*\).*/\1/p')"
ui_print "- busybox: ${BB} (${BB_VER:-unknown}, aarch64-static)"

ui_print "- 数据目录: ${DATA_ROOT}"

# --- 7. 全局 PATH 注入（v0.1.21, warn-only 幂等）------------------------------
# 原理: KSU ksud 每次 su 调用都把 /data/adb/ksu/bin 前置进 PATH，symlink 进去
#       即可让所有 su 会话直接使用 chroot-mgr/sudobox（不写 /system，D11）。
#       生效前提是 ksud 在跑 → 与临时 root 同生共死，无需额外清理逻辑。
# 失败分级: 非核心 → warn 留痕不 abort（用户可稍后手动: chroot-mgr path install）
if [ -x "${MODPATH}/bin/chroot-mgr" ]; then
    if "${MODPATH}/bin/chroot-mgr" path install >/dev/null 2>&1; then
        ui_print "- 全局 PATH: 已注入（su 会话直接可用 chroot-mgr/sudobox）"
    else
        ui_print "- 全局 PATH 注入跳过（可稍后手动: su -c chroot-mgr path install）"
    fi
fi

ui_print "- 安装完成。用法: su -c chroot-mgr help"
ui_print "  v0.1.21 新增:"
ui_print "    path install/remove/status — 全局 PATH 注入（ksu/bin symlink，"
ui_print "    与临时 root 同生共死）"
ui_print "  v0.1.20 修复:"
ui_print "    升级期 SELinux 标注不再穿越容器挂载（软重启卡 Logo 根因）"
ui_print "  v0.1.19 新增:"
ui_print "    升级前自动对账：停止活跃进程守护 + 卸载活跃容器挂载"
ui_print "  v0.1.4 新增:"
ui_print "    错误处理分级：核心失败 abort（带原因），非核心失败 warn 留痕，"
ui_print "    不再用 || true 无声吞错"
ui_print "  v0.1.3 既有:"
ui_print "    set +e 防 KSU 安装器静默挂 / busybox 校验前强制 chmod 0755"
ui_print "  v0.1.2 既有:"
ui_print "    模块自带 busybox（避免 KSU 精简 busybox 缺 unshare）"
ui_print "    uninstall 子命令（彻底删 rootfs，区别于 disable 仅卸挂载）"
ui_print "    enter --name ID / switch --name ID 参数解析修复"
ui_print "********************************************"

exit 0
