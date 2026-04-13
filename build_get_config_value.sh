#!/usr/bin/env bash
# =============================================================================
# build_get_config_value.sh
# 构建 get_config_value 的多平台二进制输出到 bin/ 目录。
#
# 用法:
#   bash build_get_config_value.sh
#
# 输出文件:
#   bin/get_config_value-darwin-amd64
#   bin/get_config_value-darwin-arm64
#   bin/get_config_value-linux-amd64
#   bin/get_config_value-linux-arm64
# =============================================================================

set -euo pipefail

if [[ -t 1 ]]; then
    C_RESET='\033[0m'; C_BOLD='\033[1m'
    C_GREEN='\033[32m'; C_CYAN='\033[36m'
    C_RED='\033[31m'
else
    C_RESET=''; C_BOLD=''; C_GREEN=''; C_CYAN=''; C_RED=''
fi

die() { echo -e "${C_RED}[错误]${C_RESET} $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${SCRIPT_DIR}"
BIN_DIR="${SCRIPT_DIR}/bin"

GO_BIN="$(command -v go || true)"
[[ -n "$GO_BIN" ]] || die "未找到 go 命令"

# 某些环境里 PATH 上的 go 和 GOROOT 指向的工具链不是同一套，这里统一到 go 可执行文件所在目录。
GO_ROOT_FROM_BIN="$(cd "$(dirname "$GO_BIN")/.." && pwd)"

mkdir -p "$BIN_DIR"

build_one() {
    local os="$1"
    local arch="$2"
    local output="${BIN_DIR}/get_config_value-${os}-${arch}"

    echo -e "${C_CYAN}构建:${C_RESET} ${os}/${arch} -> ${output}"
    (
        cd "$SRC_DIR"
        GOROOT="$GO_ROOT_FROM_BIN" \
        PATH="${GO_ROOT_FROM_BIN}/bin:${PATH}" \
        GOCACHE=/tmp/gocache \
        CGO_ENABLED=0 \
        GOOS="$os" \
        GOARCH="$arch" \
        go build -o "$output" .
    )
}

build_one darwin amd64
build_one darwin arm64
build_one linux amd64
build_one linux arm64

echo ""
echo -e "${C_GREEN}构建完成${C_RESET}"
ls -lh "$BIN_DIR"
