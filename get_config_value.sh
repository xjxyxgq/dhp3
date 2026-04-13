#!/usr/bin/env bash
# =============================================================================
# get_config_value.sh
# 按当前操作系统和 CPU 架构，选择对应的 get_config_value 二进制并执行。
#
# 用法:
#   bash get_config_value.sh [选项]
#
# 说明:
#   1. 实际解析逻辑由预编译好的二进制完成
#   2. 默认从脚本所在目录下的 bin/ 目录查找二进制
#   3. 支持通过 CONFIG_READER_BIN_DIR 覆盖二进制目录
#   4. --file 始终表示目标配置文件路径
#      未指定 --host 时表示本地文件路径
#      指定 --host 时表示远程文件路径
#   5. 远程模式支持私钥认证、连接超时和 sudo 读取
#
# 常用参数:
#   --file <path>           配置文件完整路径
#   --path <expr>           配置路径，例如 server.port 或 servers.0.host
#   --format <name>         ini|yaml|json|xml；stdin/远程模式建议显式指定
#   --output <mode>         text|json
#   --stdin                 从标准输入读取配置内容
#   --show-file             输出文件完整路径
#
# 远程参数:
#   --host <host>           远程主机
#   --user <user>           SSH 用户
#   --port <port>           SSH 端口
#   --identity-file <path>  SSH 私钥文件
#   --ssh-timeout <sec>     SSH 连接超时秒数
#   --sudo                  远程使用 sudo -n cat 读取文件
#
# 示例:
#   本地读取:
#     bash get_config_value.sh --file /etc/myapp/app.yaml --path server.port
#
#   远程读取:
#     bash get_config_value.sh --host 10.0.0.8 --user root --file /etc/myapp/app.yaml --format yaml --path server.port
#
# 预期二进制命名:
#   get_config_value-darwin-amd64
#   get_config_value-darwin-arm64
#   get_config_value-linux-amd64
#   get_config_value-linux-arm64
# =============================================================================

set -euo pipefail

if [[ -t 1 ]]; then
    C_RESET='\033[0m'; C_BOLD='\033[1m'
    C_RED='\033[31m';  C_CYAN='\033[36m'
else
    C_RESET=''; C_BOLD=''; C_RED=''; C_CYAN=''
fi

usage() {
    sed -n '/^# 用法/,/^# =============================================================================/p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

die() { echo -e "${C_RED}[错误]${C_RESET} $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${CONFIG_READER_BIN_DIR:-${SCRIPT_DIR}/bin}"
REMOTE_HOST=""
REMOTE_USER=""
REMOTE_PORT=""
SSH_IDENTITY_FILE=""
SSH_TIMEOUT=""
USE_SUDO=0

detect_os() {
    local os
    os="$(uname -s)"
    case "$os" in
        Linux)  printf 'linux' ;;
        Darwin) printf 'darwin' ;;
        *) die "不支持的操作系统: ${os}" ;;
    esac
}

detect_arch() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)        printf 'amd64' ;;
        aarch64|arm64)       printf 'arm64' ;;
        armv7l|armv7|armv6l) printf 'arm' ;;
        *) die "不支持的 CPU 架构: ${arch}" ;;
    esac
}

if [[ $# -gt 0 ]]; then
    case "$1" in
        -h|--help) usage ;;
    esac
fi

OS_NAME="$(detect_os)"
ARCH_NAME="$(detect_arch)"
BIN_PATH="${BIN_DIR}/get_config_value-${OS_NAME}-${ARCH_NAME}"

[[ -d "$BIN_DIR" ]] || die "二进制目录不存在: ${BIN_DIR}"
[[ -f "$BIN_PATH" ]] || die "未找到对应二进制: ${BIN_PATH}"
[[ -x "$BIN_PATH" ]] || die "二进制不可执行: ${BIN_PATH}"

FORWARD_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)
            [[ $# -ge 2 ]] || die "--host 缺少参数"
            REMOTE_HOST="$2"
            shift 2
            ;;
        --user)
            [[ $# -ge 2 ]] || die "--user 缺少参数"
            REMOTE_USER="$2"
            shift 2
            ;;
        --port)
            [[ $# -ge 2 ]] || die "--port 缺少参数"
            REMOTE_PORT="$2"
            shift 2
            ;;
        --identity-file)
            [[ $# -ge 2 ]] || die "--identity-file 缺少参数"
            SSH_IDENTITY_FILE="$2"
            shift 2
            ;;
        --ssh-timeout)
            [[ $# -ge 2 ]] || die "--ssh-timeout 缺少参数"
            SSH_TIMEOUT="$2"
            shift 2
            ;;
        --sudo)
            USE_SUDO=1
            shift
            ;;
        *)
            FORWARD_ARGS+=("$1")
            shift
            ;;
    esac
done

extract_file_arg() {
    local i
    for ((i = 0; i < ${#FORWARD_ARGS[@]}; i++)); do
        if [[ "${FORWARD_ARGS[$i]}" == "--file" ]]; then
            if (( i + 1 >= ${#FORWARD_ARGS[@]} )); then
                die "--file 缺少参数"
            fi
            printf '%s' "${FORWARD_ARGS[$((i + 1))]}"
            return 0
        fi
    done
    return 1
}

remove_file_arg() {
    local filtered=()
    local i=0
    while (( i < ${#FORWARD_ARGS[@]} )); do
        if [[ "${FORWARD_ARGS[$i]}" == "--file" ]]; then
            ((i += 2))
            continue
        fi
        filtered+=("${FORWARD_ARGS[$i]}")
        ((i += 1))
    done
    printf '%s\0' "${filtered[@]}"
}

extract_optional_arg() {
    local key="$1"
    local i
    for ((i = 0; i < ${#FORWARD_ARGS[@]}; i++)); do
        if [[ "${FORWARD_ARGS[$i]}" == "$key" ]]; then
            if (( i + 1 >= ${#FORWARD_ARGS[@]} )); then
                die "${key} 缺少参数"
            fi
            printf '%s' "${FORWARD_ARGS[$((i + 1))]}"
            return 0
        fi
    done
    return 1
}

has_flag_arg() {
    local key="$1"
    local i
    for ((i = 0; i < ${#FORWARD_ARGS[@]}; i++)); do
        if [[ "${FORWARD_ARGS[$i]}" == "$key" ]]; then
            return 0
        fi
    done
    return 1
}

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

print_wrapper_error() {
    local output_mode="$1"
    local key="$2"
    local info="$3"
    local file_path="$4"

    if [[ "$output_mode" == "json" ]]; then
        printf '{"status":"error","key":"%s","info":"%s"' "$(json_escape "$key")" "$(json_escape "$info")"
        if [[ -n "$file_path" ]]; then
            printf ',"file":"%s"' "$(json_escape "$file_path")"
        fi
        printf '}\n'
        return
    fi

    if [[ -n "$file_path" ]]; then
        printf '  文件: %s\n' "$file_path"
    fi
    printf '  路径: %s\n' "$key"
    printf '  [错误] %s\n' "$info"
}

if [[ -n "$REMOTE_HOST" || -n "$REMOTE_USER" || -n "$REMOTE_PORT" || -n "$SSH_IDENTITY_FILE" || -n "$SSH_TIMEOUT" || "$USE_SUDO" -eq 1 ]]; then
    [[ -n "$REMOTE_HOST" ]] || die "远程模式下 --host 不能为空"
    REMOTE_FILE="$(extract_file_arg)" || die "远程模式下 --file 不能为空"
    REMOTE_FORWARD_ARGS=()
    while IFS= read -r -d '' arg; do
        REMOTE_FORWARD_ARGS+=("$arg")
    done < <(remove_file_arg)

    SSH_TARGET="$REMOTE_HOST"
    if [[ -n "$REMOTE_USER" ]]; then
        SSH_TARGET="${REMOTE_USER}@${REMOTE_HOST}"
    fi

    SSH_ARGS=()
    if [[ -n "$REMOTE_PORT" ]]; then
        SSH_ARGS+=("-p" "$REMOTE_PORT")
    fi
    if [[ -n "$SSH_IDENTITY_FILE" ]]; then
        [[ -f "$SSH_IDENTITY_FILE" ]] || die "私钥文件不存在: ${SSH_IDENTITY_FILE}"
        SSH_ARGS+=("-i" "$SSH_IDENTITY_FILE")
    fi
    if [[ -n "$SSH_TIMEOUT" ]]; then
        [[ "$SSH_TIMEOUT" =~ ^[0-9]+$ ]] || die "--ssh-timeout 仅支持正整数秒"
        SSH_ARGS+=("-o" "ConnectTimeout=${SSH_TIMEOUT}")
    fi

    REMOTE_FILE_ESCAPED="${REMOTE_FILE//\'/\'\\\'\'}"
    if [[ "$USE_SUDO" -eq 1 ]]; then
        REMOTE_CMD="sudo -n cat '$REMOTE_FILE_ESCAPED'"
    else
        REMOTE_CMD="cat '$REMOTE_FILE_ESCAPED'"
    fi

    OUTPUT_MODE="$(extract_optional_arg --output || true)"
    [[ -n "$OUTPUT_MODE" ]] || OUTPUT_MODE="text"
    PATH_EXPR="$(extract_optional_arg --path || true)"
    SHOW_FILE=0
    if has_flag_arg --show-file; then
        SHOW_FILE=1
    fi

    SSH_STDOUT="$(mktemp)"
    SSH_STDERR="$(mktemp)"
    if ssh "${SSH_ARGS[@]}" "$SSH_TARGET" "$REMOTE_CMD" >"$SSH_STDOUT" 2>"$SSH_STDERR"; then
        "$BIN_PATH" --stdin "${REMOTE_FORWARD_ARGS[@]}" <"$SSH_STDOUT"
        STATUS=$?
        rm -f "$SSH_STDOUT" "$SSH_STDERR"
        exit $STATUS
    fi

    SSH_ERR_MSG="$(tr '\n' ' ' <"$SSH_STDERR" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
    rm -f "$SSH_STDOUT" "$SSH_STDERR"
    [[ -n "$SSH_ERR_MSG" ]] || SSH_ERR_MSG="SSH 远程读取失败"
    if [[ "$SHOW_FILE" -eq 1 ]]; then
        print_wrapper_error "$OUTPUT_MODE" "$PATH_EXPR" "$SSH_ERR_MSG" "$REMOTE_FILE"
    else
        print_wrapper_error "$OUTPUT_MODE" "$PATH_EXPR" "$SSH_ERR_MSG" ""
    fi
    exit 1
fi

exec "$BIN_PATH" "${FORWARD_ARGS[@]}"
