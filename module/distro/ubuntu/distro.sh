#!/system/bin/sh
# SudoBox distro resolver — Ubuntu
# 由 chroot-mgr 在部署时 source 后调用：distro_resolve_url <suite> <arch> <mirror>
# 输出最终下载 URL（stdout）。
#
# v0.1.17 修复两个缺陷（均为实测发现，2026-09-07）：
#   1. 旧版计算了镜像 base 却从未使用（SOURCE_URL_TEMPLATE 硬编码 cdimage 官方域名），
#      --mirror tuna/ustc/aliyun 全部静默失效；
#   2. ubuntu-base 的 tarball 文件名带补丁版本号（如 24.04.4），旧版用 SUITE_VERSION_MAP
#      的 "24.04" 直接拼文件名 → 官方与镜像上均 404。现改为拉取目录列表动态解析
#      该 suite 下的最新补丁版本（与 alpine resolver 同一策略）。

distro_resolve_url()
{
    local suite="$1" arch="$2" mirror="$3"
    local version="" map_entry

    # suite -> 主版本映射（noble -> 24.04）
    for map_entry in ${SUITE_VERSION_MAP}; do
        case "${map_entry}" in
            "${suite}="*) version="${map_entry#*=}" ;;
        esac
    done
    [ -n "${version}" ] || { echo "E: 未知 suite: ${suite}（可用: ${SUITE_VERSION_MAP}）" >&2; return 1; }

    # 镜像前缀：ubuntu-base 随 ubuntu-cdimage 树同步，TUNA/USTC/阿里云路径一致（实测 2026-09-07）
    local base
    case "${mirror}" in
        tuna)   base="https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cdimage" ;;
        ustc)   base="https://mirrors.ustc.edu.cn/ubuntu-cdimage" ;;
        aliyun) base="https://mirrors.aliyun.com/ubuntu-cdimage" ;;
        *)      base="https://cdimage.ubuntu.com" ;;
    esac

    local dir="${base}/ubuntu-base/releases/${suite}/release/"
    local ver_full
    ver_full="$(wget -q -O - "${dir}" 2>/dev/null \
        | grep -oE "ubuntu-base-${version}(\.[0-9]+)?-base-${arch}\.tar\.gz" \
        | sed "s/ubuntu-base-//; s/-base-${arch}\.tar\.gz//" \
        | sort -t. -k1,1n -k2,2n -k3,3n \
        | tail -1)"

    if [ -z "${ver_full}" ]; then
        echo "E: 未在 ${dir} 解析到 ${arch} tarball（suite 或镜像路径可能已变更）" >&2
        return 1
    fi

    echo "${dir}ubuntu-base-${ver_full}-base-${arch}.tar.gz"
}
