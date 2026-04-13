#!/usr/bin/env bash
# =============================================================================
# check_ini.sh
# 遍历一批目录，从第一个 INI 文件中检查指定 section/key 的值是否符合预期，
# 若符合则从第二个 INI 文件（可与第一个相同）读取另一组 section/key 的值。
#
# 用法:
#   bash check_ini.sh [选项]
#
# 必填选项:
#   --dirs      <glob>   目录 glob 模式，例如 '/data/dir*/etc'
#   --a-file    <name>   第一个配置文件名，例如 app.ini
#   --a-section <name>   第一个配置文件中要检查的 section
#   --a-key     <key>    第一个配置文件中要检查的 key
#   --a-expect  <value>  期望值（字符串完全匹配）
#   --b-section <name>   第二个配置文件中要读取的 section
#   --b-key     <key>    第二个配置文件中要读取的 key
#
# 可选选项:
#   --b-file    <name>   第二个配置文件名（默认与 --a-file 相同）
#   --ignore-case        比较 a 文件值时忽略大小写
#   --only-matched       只输出 a 值匹配的目录
#   -h, --help           显示帮助
#
# 示例:
#   bash check_ini.sh \
#       --dirs      '/data/dir*/etc' \
#       --a-file    'app.ini' \
#       --a-section 'database' \
#       --a-key     'host' \
#       --a-expect  'localhost' \
#       --b-file    'server.ini' \
#       --b-section 'network' \
#       --b-key     'port'
#
#   # a-file 与 b-file 相同时省略 --b-file：
#   bash check_ini.sh \
#       --dirs      '/data/dir*/etc' \
#       --a-file    'config.ini' \
#       --a-section 'app'  --a-key 'env'  --a-expect 'prod' \
#       --b-section 'db'   --b-key 'dsn'
# =============================================================================

set -euo pipefail

# ─── 颜色 ────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_RESET='\033[0m'; C_BOLD='\033[1m'
    C_GREEN='\033[32m'; C_YELLOW='\033[33m'
    C_RED='\033[31m';  C_CYAN='\033[36m'
else
    C_RESET=''; C_BOLD=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_CYAN=''
fi

# ─── 工具函数 ─────────────────────────────────────────────────────────────────

usage() {
    sed -n '/^# 用法/,/^# ====/p' "$0" | sed 's/^# \{0,3\}//'
    exit 0
}

die() { echo -e "${C_RED}[错误]${C_RESET} $*" >&2; exit 1; }

# trim 首尾空白
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# 从 INI 文件读取 section/key 的值
# 用法: ini_get <file> <section> <key>
# 成功返回 0 并将值写到 stdout；找不到返回 1
ini_get() {
    local file="$1" section="$2" key="$3"
    local in_section=0 cur_section="" line k v

    while IFS= read -r line || [[ -n "$line" ]]; do
        # 去首尾空白
        line="$(trim "$line")"

        # 跳过空行与注释（; 和 #）
        [[ -z "$line" || "$line" == ';'* || "$line" == '#'* ]] && continue

        # section 行：[section name]
        if [[ "$line" =~ ^\[([^\]]+)\]$ ]]; then
            cur_section="$(trim "${BASH_REMATCH[1]}")"
            [[ "$cur_section" == "$section" ]] && in_section=1 || in_section=0
            continue
        fi

        # key = value 行
        if [[ $in_section -eq 1 && "$line" == *'='* ]]; then
            k="$(trim "${line%%=*}")"
            v="$(trim "${line#*=}")"
            # 去除行内注释（值中 # 或 ; 之后的内容）
            v="${v%%[;#]*}"
            v="$(trim "$v")"
            if [[ "$k" == "$key" ]]; then
                printf '%s' "$v"
                return 0
            fi
        fi
    done < "$file"

    return 1
}

# ─── 参数解析 ─────────────────────────────────────────────────────────────────

DIRS=""
A_FILE=""
A_SECTION=""
A_KEY=""
A_EXPECT=""
B_FILE=""          # 空表示与 A_FILE 相同
B_SECTION=""
B_KEY=""
IGNORE_CASE=0
ONLY_MATCHED=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dirs)        DIRS="$2";      shift 2 ;;
        --a-file)      A_FILE="$2";    shift 2 ;;
        --a-section)   A_SECTION="$2"; shift 2 ;;
        --a-key)       A_KEY="$2";     shift 2 ;;
        --a-expect)    A_EXPECT="$2";  shift 2 ;;
        --b-file)      B_FILE="$2";    shift 2 ;;
        --b-section)   B_SECTION="$2"; shift 2 ;;
        --b-key)       B_KEY="$2";     shift 2 ;;
        --ignore-case) IGNORE_CASE=1;  shift   ;;
        --only-matched)ONLY_MATCHED=1; shift   ;;
        -h|--help)     usage ;;
        *) die "未知参数: $1，使用 -h 查看帮助" ;;
    esac
done

# ─── 必填校验 ─────────────────────────────────────────────────────────────────

[[ -z "$DIRS"      ]] && die "--dirs 不能为空"
[[ -z "$A_FILE"    ]] && die "--a-file 不能为空"
[[ -z "$A_SECTION" ]] && die "--a-section 不能为空"
[[ -z "$A_KEY"     ]] && die "--a-key 不能为空"
[[ -z "$A_EXPECT"  ]] && die "--a-expect 不能为空"
[[ -z "$B_SECTION" ]] && die "--b-section 不能为空"
[[ -z "$B_KEY"     ]] && die "--b-key 不能为空"

# b-file 默认与 a-file 相同
[[ -z "$B_FILE" ]] && B_FILE="$A_FILE"

SAME_FILE=0
[[ "$A_FILE" == "$B_FILE" ]] && SAME_FILE=1

# ─── 展开目录 ─────────────────────────────────────────────────────────────────

# 用 eval + glob 展开，支持 /data/dir*/etc 这类模式
mapfile -t DIRECTORIES < <(eval "ls -d ${DIRS} 2>/dev/null" | sort -u || true)

if [[ ${#DIRECTORIES[@]} -eq 0 ]]; then
    die "未找到任何匹配目录: ${DIRS}"
fi

echo -e "${C_BOLD}共找到 ${#DIRECTORIES[@]} 个目录，开始检查 …${C_RESET}"
echo ""

# ─── 统计计数 ─────────────────────────────────────────────────────────────────

COUNT_TOTAL=0
COUNT_MATCHED=0
COUNT_UNMATCHED=0
COUNT_ERROR=0

SEP="$(printf '─%.0s' {1..72})"

# ─── 遍历目录 ─────────────────────────────────────────────────────────────────

for DIR in "${DIRECTORIES[@]}"; do
    (( COUNT_TOTAL++ )) || true

    A_PATH="${DIR}/${A_FILE}"
    B_PATH="${DIR}/${B_FILE}"

    # ── 检查 a 文件 ──────────────────────────────────────────────────────────
    if [[ ! -f "$A_PATH" ]]; then
        (( COUNT_ERROR++ )) || true
        [[ $ONLY_MATCHED -eq 1 ]] && continue
        echo -e "${C_CYAN}目录:${C_RESET} ${DIR}"
        echo -e "  ${C_RED}⚠ ${A_FILE} 不存在: ${A_PATH}${C_RESET}"
        echo ""
        continue
    fi

    if ! A_VAL="$(ini_get "$A_PATH" "$A_SECTION" "$A_KEY")"; then
        (( COUNT_ERROR++ )) || true
        [[ $ONLY_MATCHED -eq 1 ]] && continue
        echo -e "${C_CYAN}目录:${C_RESET} ${DIR}"
        echo -e "  ${C_RED}⚠ ${A_FILE} 中未找到 [${A_SECTION}] ${A_KEY}${C_RESET}"
        echo ""
        continue
    fi

    # ── 值比较 ───────────────────────────────────────────────────────────────
    if [[ $IGNORE_CASE -eq 1 ]]; then
        LHS="${A_VAL,,}"; RHS="${A_EXPECT,,}"
    else
        LHS="$A_VAL"; RHS="$A_EXPECT"
    fi

    if [[ "$LHS" != "$RHS" ]]; then
        (( COUNT_UNMATCHED++ )) || true
        [[ $ONLY_MATCHED -eq 1 ]] && continue
        echo -e "${C_CYAN}目录:${C_RESET} ${DIR}"
        echo -e "  ${A_FILE} [${A_SECTION}] ${A_KEY} = ${C_YELLOW}'${A_VAL}'${C_RESET}" \
                " ${C_YELLOW}✘ 不匹配 (期望: '${A_EXPECT}')${C_RESET}"
        echo ""
        continue
    fi

    # ── a 值匹配，读取 b 文件 ────────────────────────────────────────────────
    (( COUNT_MATCHED++ )) || true

    echo -e "${C_CYAN}目录:${C_RESET} ${DIR}"
    echo -e "  ${A_FILE} [${A_SECTION}] ${A_KEY} = ${C_GREEN}'${A_VAL}'${C_RESET}" \
            " ${C_GREEN}✔ 匹配${C_RESET}"

    # 若两文件相同，无需重新检查文件是否存在（已在上面验证）
    if [[ $SAME_FILE -eq 0 && ! -f "$B_PATH" ]]; then
        (( COUNT_ERROR++ )) || true
        echo -e "  ${C_RED}⚠ ${B_FILE} 不存在: ${B_PATH}${C_RESET}"
        echo ""
        continue
    fi

    if ! B_VAL="$(ini_get "$B_PATH" "$B_SECTION" "$B_KEY")"; then
        (( COUNT_ERROR++ )) || true
        echo -e "  ${C_RED}⚠ ${B_FILE} 中未找到 [${B_SECTION}] ${B_KEY}${C_RESET}"
    else
        echo -e "  ${B_FILE} [${B_SECTION}] ${B_KEY} = '${B_VAL}'"
    fi

    echo ""
done

# ─── 汇总 ────────────────────────────────────────────────────────────────────

echo -e "${C_BOLD}${SEP}${C_RESET}"
echo -e "${C_BOLD}  检查完毕${C_RESET}"
printf "  目录总数: %-4s | " "$COUNT_TOTAL"
echo -e "${C_GREEN}匹配: ${COUNT_MATCHED}${C_RESET}  |  ${C_YELLOW}未匹配: ${COUNT_UNMATCHED}${C_RESET}  |  ${C_RED}错误: ${COUNT_ERROR}${C_RESET}"
echo -e "${C_BOLD}${SEP}${C_RESET}"

# 有错误时以非零状态退出
[[ $COUNT_ERROR -gt 0 ]] && exit 1 || exit 0
