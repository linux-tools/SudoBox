#!/system/bin/sh
# SudoBox distro resolver — Alpine
# minirootfs 文件名含 patch 版本号（如 alpine-minirootfs-3.21.0-aarch64.tar.gz），
# 需从官方目录列表动态解析最新版本，避免硬编码失效。
# 调用：distro_resolve_url <suite> <arch> <mirror>

distro_resolve_url()
{
    local suite="$1" arch="$2" mirror="$3"
    local base="https://dl-cdn.alpinelinux.org/alpine/${suite}/releases/${arch}/"

    case "${mirror}" in
        tuna)   base="https://mirrors.tuna.tsinghua.edu.cn/alpine/${suite}/releases/${arch}/" ;;
        aliyun) base="https://mirrors.aliyun.com/alpine/${suite}/releases/${arch}/" ;;
        ustc)   base="https://mirrors.ustc.edu.cn/alpine/${suite}/releases/${arch}/" ;;
    esac

    local listing ver
    listing="$(wget -q -O - "${base}" 2>/dev/null)"
    if [ -z "${listing}" ]; then
        echo "E: 无法获取目录列表: ${base}" >&2
        return 1
    fi

    # 提取 minirootfs 版本号并数值排序取最新
    ver="$(echo "${listing}" \
        | grep -o "alpine-minirootfs-[0-9][0-9.]*-${arch}\.tar\.gz" \
        | sed "s/alpine-minirootfs-//; s/-${arch}\.tar\.gz//" \
        | sort -t. -k1,1n -k2,2n -k3,3n \
        | tail -1)"

    if [ -z "${ver}" ]; then
        echo "E: 未解析到 minirootfs（目录: ${base}）" >&2
        return 1
    fi

    echo "${base}alpine-minirootfs-${ver}-${arch}.tar.gz"
}
