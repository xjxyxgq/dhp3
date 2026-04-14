#!/usr/bin/env bash
# =============================================================================
# check_numa_binding.sh
# 检查 nudb1 和 nudbproxy1 的 .numanode 配置是否使用了独立的 NUMA 节点
# 确保 node0 与 node1 的 CPU 核心互不重叠。
#
# 输出格式（每行一个 JSON）：
#   {"status":"ok"|"error","key":"<检查项>","info":"<说明>"}
#
# 检查项：
#   - lscpu.numa_node0: 获取 NUMA node0 的 CPU 列表
#   - lscpu.numa_node1: 获取 NUMA node1 的 CPU 列表
#   - lscpu.numa_cpu_overlap: 检查两个节点 CPU 是否重叠
#   - nudb1.numanode: 检查 nudb1 的 .numanode 配置
#   - nudbproxy1.numanode: 检查 nudbproxy1 的 .numanode 配置
#
# 用法:
#   bash check_numa_binding.sh [选项]
#
# 选项:
#   --nudb1-dir  <path>  nudb1 数据目录（默认 /data/goldendb/nudb1）
#   --proxy-dir  <path>  nudbproxy1 数据目录（默认 /data/goldendb/nudbproxy1）
#   --swap               交换期望检查：nudb1 应为 node1，nudbproxy1 应为 node0
#   -h, --help           显示帮助
# =============================================================================

set -uo pipefail

# ─── 输出函数 ─────────────────────────────────────────────────────────────────

# 结果缓存
RESULTS=()

# 转义 JSON 字符串中的特殊字符
_json_esc() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

emit() {
    local status="$1" key="$2" info="$3"
    RESULTS+=("$(printf '{"status":"%s","key":"%s","info":"%s"}' \
        "$status" "$(_json_esc "$key")" "$(_json_esc "$info")")")
}

emit_ok()  { emit "ok"    "$1" "$2"; }
emit_err() { emit "error" "$1" "$2"; }

# 输出所有结果（符合要求的格式）
output_results() {
    # 检查是否有错误
    local has_error=false
    for result in "${RESULTS[@]}"; do
        if [[ "$result" == *"\"status\":\"error\""* ]]; then
            has_error=true
            break
        fi
    done

    # 确定最终状态
    local final_status
    if [[ "$has_error" == "true" ]]; then
        final_status="error"
    else
        final_status="ok"
    fi

    # 转义所有结果
    local escaped_results="["

    for ((i=0; i<${#RESULTS[@]}; i++)); do
        if [[ $i -gt 0 ]]; then
            escaped_results+=", "
        fi
        # 使用 JSON 转义函数转义每个结果
        escaped_results+=$(_json_esc "${RESULTS[$i]}")
    done

    escaped_results+="]"

    # 输出最终结果
    printf '{"status":"%s","infos":%s}\n' "$final_status" "$escaped_results"
}

# 覆盖 emit_err，使其在错误时也输出最终结果
emit_err() {
    emit "error" "$1" "$2"
    output_results
    exit 1
}

# ─── 参数解析 ─────────────────────────────────────────────────────────────────

NUDB1_DIR="/data/goldendb/nudb1"
PROXY_DIR="/data/goldendb/nudbproxy1"
SWAP=0

usage() {
    sed -n '/^# 用法/,/^# ====/p' "$0" | sed 's/^# \{0,3\}//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --nudb1-dir) NUDB1_DIR="$2"; shift 2 ;;
        --proxy-dir) PROXY_DIR="$2"; shift 2 ;;
        --swap)      SWAP=1;         shift   ;;
        -h|--help)   usage ;;
        *) emit_err "args" "未知参数: $1，使用 -h 查看帮助" ;;
    esac
done

NUDB1_FILE="${NUDB1_DIR}/.numanode"
PROXY_FILE="${PROXY_DIR}/.numanode"

# ─── 获取 NUMA 拓扑信息 ─────────────────────────────────────────────────────

# 使用 lscpu 和 egrep 获取 NUMA 节点信息
LSCPU_OUT=$(lscpu 2>&1) || emit_err "lscpu" "lscpu 命令执行失败: $LSCPU_OUT"

NODE0_LINE=$(echo "$LSCPU_OUT" | grep -iE '^NUMA node0 CPU' || true)
NODE1_LINE=$(echo "$LSCPU_OUT" | grep -iE '^NUMA node1 CPU' || true)

[[ -z "$NODE0_LINE" ]] && emit_err "lscpu.numa_node0" "lscpu 中未找到 NUMA node0 CPU 信息"
[[ -z "$NODE1_LINE" ]] && emit_err "lscpu.numa_node1" "lscpu 中未找到 NUMA node1 CPU 信息"

NODE0_CPUS=$(echo "$NODE0_LINE" | awk -F: '{print $2}' | tr -d ' \t')
NODE1_CPUS=$(echo "$NODE1_LINE" | awk -F: '{print $2}' | tr -d ' \t')

[[ -z "$NODE0_CPUS" ]] && emit_err "lscpu.numa_node0" "NUMA node0 CPU 列表为空"
[[ -z "$NODE1_CPUS" ]] && emit_err "lscpu.numa_node1" "NUMA node1 CPU 列表为空"

emit_ok "lscpu.numa_node0" "$NODE0_CPUS"
emit_ok "lscpu.numa_node1" "$NODE1_CPUS"

# ─── 检查 CPU 集合无重叠 ──────────────────────────────────────────────────────

# 将 CPU 列表字符串（如 "0-3,8-11"）展开为每行一个数字
_expand_cpus() {
    local spec="$1" segment lo hi
    local IFS=','
    for segment in $spec; do
        if [[ "$segment" == *-* ]]; then
            lo="${segment%-*}"; hi="${segment#*-}"
            seq "$lo" "$hi"
        else
            echo "$segment"
        fi
    done
}

_cpus_overlap() {
    local set_a set_b
    set_a=$(_expand_cpus "$1" | sort -n)
    set_b=$(_expand_cpus "$2" | sort -n)
    # 使用 grep 查找交集，替代 comm 命令
    local overlap
    overlap=$(grep -xFf <(echo "$set_a") <(echo "$set_b") | grep -c .)
    [[ $overlap -gt 0 ]]
}

if _cpus_overlap "$NODE0_CPUS" "$NODE1_CPUS"; then
    emit_err "lscpu.numa_cpu_overlap" "NUMA node0 与 node1 的 CPU 列表存在重叠，拓扑数据异常"
fi
emit_ok "lscpu.numa_cpu_overlap" "node0 与 node1 CPU 核心无重叠"

# ─── 检查 .numanode 文件 ──────────────────────────────────────────────────────

# 检查单个 .numanode 文件
_check_numanode_file() {
    local file="$1" expected_node="$2" node_cpus="$3" key="$4"

    if [[ ! -f "$file" ]]; then
        emit_err "$key" "文件不存在: $file"
    fi

    local current
    current=$(tr -d '[:space:]' < "$file" 2>/dev/null || echo "无法读取文件")

    # 验证文件内容是否为有效的 CPU 列表（如 "0-23" 或 "0-23,48-71"）
    if ! [[ "$current" =~ ^[0-9,-]+$ ]] || ! echo "$current" | grep -qE '^(-?[0-9]+(-[0-9]+)?,)*-?[0-9]+(-[0-9]+)?$'; then
        emit_err "$key" "文件内容无效，应为 CPU 列表格式（如 0-23 或 0-23,48-71），实际为: $current"
    fi

    # 检查 CPU 列表是否在正确的 NUMA 节点上
    if [[ $expected_node -eq 0 ]]; then
        # 检查是否与 node0 的 CPU 列表匹配
        if ! _cpu_sets_equal "$current" "$node_cpus"; then
            emit_err "$key" "CPU 列表不属于 node0 期望的 CPU 范围，实际: $current，期望: $node_cpus"
        fi
    else
        # 检查是否与 node1 的 CPU 列表匹配
        if ! _cpu_sets_equal "$current" "$node_cpus"; then
            emit_err "$key" "CPU 列表不属于 node1 期望的 CPU 范围，实际: $current，期望: $node_cpus"
        fi
    fi

    emit_ok "$key" "node${expected_node}，CPU: $current"
}

# 检查两个 CPU 列表是否相同（展开后）
_cpu_sets_equal() {
    local set1="$1" set2="$2"
    local expanded1 expanded2

    expanded1=$(_expand_cpus "$set1" | sort -n)
    expanded2=$(_expand_cpus "$set2" | sort -n)

    # 使用 diff 比较两个有序列表
    diff -q <(echo "$expanded1") <(echo "$expanded2") >/dev/null 2>&1
}

# 默认分配：nudb1 使用 node0，nudbproxy1 使用 node1
if [[ $SWAP -eq 0 ]]; then
    CHECK_NUDB_NODE=0
    CHECK_PROXY_NODE=1
    NUDB_CPUS="$NODE0_CPUS"
    PROXY_CPUS="$NODE1_CPUS"
else
    # 交换分配：nudb1 使用 node1，nudbproxy1 使用 node0
    CHECK_NUDB_NODE=1
    CHECK_PROXY_NODE=0
    NUDB_CPUS="$NODE1_CPUS"
    PROXY_CPUS="$NODE0_CPUS"
fi

# 检查 nudb1 的 .numanode 配置
_check_numanode_file "$NUDB1_FILE" "$CHECK_NUDB_NODE" "$NUDB_CPUS" "nudb1.numanode"

# 检查 nudbproxy1 的 .numanode 配置
_check_numanode_file "$PROXY_FILE" "$CHECK_PROXY_NODE" "$PROXY_CPUS" "nudbproxy1.numanode"

# ─── 检查两个服务的 CPU 列表是否互不重叠 ───────────────────────────────────

# 获取实际的 CPU 配置
NUDB_CPUS=$(tr -d '[:space:]' < "$NUDB1_FILE" 2>/dev/null || echo "")
PROXY_CPUS=$(tr -d '[:space:]' < "$PROXY_FILE" 2>/dev/null || echo "")

# 检查两个 CPU 列表是否重叠
if [[ -n "$NUDB_CPUS" && -n "$PROXY_CPUS" ]]; then
    if _cpus_overlap "$NUDB_CPUS" "$PROXY_CPUS"; then
        emit_err "service_cpu_overlap" "nudb1 和 nudbproxy1 的 CPU 列表存在重叠，nudb1: $NUDB_CPUS, nudbproxy1: $PROXY_CPUS"
    else
        emit_ok "service_cpu_overlap" "nudb1 和 nudbproxy1 CPU 核心互不重叠，nudb1: $NUDB_CPUS, nudbproxy1: $PROXY_CPUS"
    fi
else
    emit_err "service_cpu_overlap" "无法读取 CPU 配置：nudb1: ${NUDB_CPUS:-空}, nudbproxy1: ${PROXY_CPUS:-空}"
fi

# 输出所有结果
output_results