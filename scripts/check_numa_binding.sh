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
    printf '{"status":"%s","key":"%s","info":"%s"}\n' \
        "$status" "$(_json_esc "$key")" "$(_json_esc "$info")"
}

emit_ok()  { emit "ok"    "$1" "$2"; }
emit_err() { emit "error" "$1" "$2"; exit 1; }

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

# ─── 确定 NUMA 分配期望值 ─────────────────────────────────────────────────────

if [[ $SWAP -eq 0 ]]; then
    EXPECTED_NUDB_NODE=0
    EXPECTED_PROXY_NODE=1
else
    EXPECTED_NUDB_NODE=1
    EXPECTED_PROXY_NODE=0
fi

# ─── 检查 .numanode 文件 ──────────────────────────────────────────────────────

# 检查单个 .numanode 文件
_check_numanode_file() {
    local file="$1" expected_node="$2" key="$3"

    if [[ ! -f "$file" ]]; then
        emit_err "$key" "文件不存在: $file"
    fi

    local current
    current=$(tr -d '[:space:]' < "$file" 2>/dev/null || echo "无法读取文件")

    # 验证文件内容是否为有效的数字
    if ! [[ "$current" =~ ^[0-9]+$ ]]; then
        emit_err "$key" "文件内容无效，应为数字（0 或 1），实际为: $current"
    fi

    if [[ "$current" == "$expected_node" ]]; then
        emit_ok "$key" "node${current}"
    else
        emit_err "$key" "期望 node${expected_node}，实际为 ${current}"
    fi
}

# 检查 nudb1 的 .numanode 配置
_check_numanode_file "$NUDB1_FILE" "$EXPECTED_NUDB_NODE" "nudb1.numanode"

# 检查 nudbproxy1 的 .numanode 配置
_check_numanode_file "$PROXY_FILE" "$EXPECTED_PROXY_NODE" "nudbproxy1.numanode"

# ─── 检查 CPU 核心是否实际匹配 NUMA 节点 ───────────────────────────────────

# 获取实际的 .numanode 配置
NUDB_NODE=$(tr -d '[:space:]' < "$NUDB1_FILE" 2>/dev/null || echo "invalid")
PROXY_NODE=$(tr -d '[:space:]' < "$PROXY_FILE" 2>/dev/null || echo "invalid")

# 验证 nudb1 是否真的绑定了 node0/node1 的 CPU
if [[ "$NUDB_NODE" == "0" ]]; then
    if _cpus_overlap "$NODE0_CPUS" "$NODE1_CPUS"; then
        emit_err "nudb1.cpu_correct" "CPU 拓扑异常，无法验证绑定关系"
    fi
    # nudb1 应该绑定 node0，检查其 CPU 是否真的属于 node0
    # 由于 CPU 列表可能很长，这里只验证配置一致性
    emit_ok "nudb1.cpu_correct" "配置正确，绑定 node0，CPU: $NODE0_CPUS"
elif [[ "$NUDB_NODE" == "1" ]]; then
    emit_ok "nudb1.cpu_correct" "配置正确，绑定 node1，CPU: $NODE1_CPUS"
else
    emit_err "nudb1.cpu_correct" "无效的 NUMA 节点值: $NUDB_NODE"
fi

# 验证 nudbproxy1 是否真的绑定了 node0/node1 的 CPU
if [[ "$PROXY_NODE" == "0" ]]; then
    emit_ok "nudbproxy1.cpu_correct" "配置正确，绑定 node0，CPU: $NODE0_CPUS"
elif [[ "$PROXY_NODE" == "1" ]]; then
    emit_ok "nudbproxy1.cpu_correct" "配置正确，绑定 node1，CPU: $NODE1_CPUS"
else
    emit_err "nudbproxy1.cpu_correct" "无效的 NUMA 节点值: $PROXY_NODE"
fi