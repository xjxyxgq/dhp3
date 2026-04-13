#!/bin/bash
#
# transform_grants.sh
#
# 将 pt-show-grants (MySQL 5.7) 的输出转换为 MySQL 8.x 兼容的授权语句
#
#   1. 合并 CREATE USER + ALTER USER IDENTIFIED 为单条语句
#   2. 过滤指定用户 (-e 参数)
#   3. 将所有 user@'IP' 替换为 user@'%'，同用户名只保留第一个 IP 的授权
#   4. 支持数据库名称映射 (-d 参数)
#   5. 支持用户名映射 (-u 参数)
#
# 用法:
#   pt-show-grants --host=xxx --user=xxx | ./transform_grants.sh [options]
#   ./transform_grants.sh [options] input.sql
#

set -euo pipefail

EXCLUDE_USERS=""
DB_MAP=""
USER_MAP=""
REPLACE_HOST_WITH_WILDCARD="1"
VERBOSE_LEVEL=0

usage() {
    cat <<'HELP'
Usage: transform_grants.sh [-e exclude] [-d db_map] [-u user_map] [-W 0|1] [-v|-vv] [input_file]

Options:
  -e  要过滤的用户名，逗号分隔
      例: "dbmgr,mysql.sys,mysql.session"
  -d  数据库名称映射，格式 "旧名=新名"，多个用逗号分隔
      例: "db1=database1,db2=database2"
  -u  用户名映射，格式 "旧名=新名"，多个用逗号分隔
      例: "user1=account1,user2=account2"
  -W  是否将 user@'IP' 替换为 user@'%'，默认 1
      设为 0 时保留原始 host，也不会按用户名去重
  -v  输出末尾变更汇总
  -vv 输出末尾变更汇总，以及正文中的变更提示注释
  -h  显示帮助

Examples:
  pt-show-grants --host=src | ./transform_grants.sh -e "dbmgr"
  ./transform_grants.sh -e "dbmgr" -d "db1=database1" -u "user1=account1" grants.sql
  ./transform_grants.sh -W 0 grants.sql
  ./transform_grants.sh -v grants.sql
  ./transform_grants.sh -vv grants.sql
HELP
    exit 0
}

while getopts "e:d:u:W:vh" opt; do
    case $opt in
        e) EXCLUDE_USERS="$OPTARG" ;;
        d) DB_MAP="$OPTARG" ;;
        u) USER_MAP="$OPTARG" ;;
        W) REPLACE_HOST_WITH_WILDCARD="$OPTARG" ;;
        v) VERBOSE_LEVEL=$((VERBOSE_LEVEL + 1)) ;;
        h) usage ;;
        *) echo "Usage: $0 [-e exclude] [-d db_map] [-u user_map] [-W 0|1] [-v|-vv] [input_file]" >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

if [[ "$REPLACE_HOST_WITH_WILDCARD" != "0" && "$REPLACE_HOST_WITH_WILDCARD" != "1" ]]; then
    echo "Error: -W 仅支持 0 或 1" >&2
    exit 1
fi

awk -v exclude="$EXCLUDE_USERS" -v db_map="$DB_MAP" -v user_map="$USER_MAP" -v replace_host_with_wildcard="$REPLACE_HOST_WITH_WILDCARD" -v verbose_level="$VERBOSE_LEVEL" '
BEGIN {
    # 解析排除用户列表
    n = split(exclude, arr, ",")
    for (i = 1; i <= n; i++) {
        gsub(/^[ \t]+|[ \t]+$/, "", arr[i])
        if (arr[i] != "") excluded[arr[i]] = 1
    }

    # 解析数据库名称映射: "old1=new1,old2=new2"
    db_count = 0
    n = split(db_map, pairs, ",")
    for (i = 1; i <= n; i++) {
        split(pairs[i], kv, "=")
        gsub(/^[ \t]+|[ \t]+$/, "", kv[1])
        gsub(/^[ \t]+|[ \t]+$/, "", kv[2])
        if (kv[1] != "" && kv[2] != "") {
            db_count++
            db_from[db_count] = kv[1]
            db_to[db_count]   = kv[2]
        }
    }

    # 解析用户名映射: "old1=new1,old2=new2"
    uname_count = 0
    n = split(user_map, pairs, ",")
    for (i = 1; i <= n; i++) {
        split(pairs[i], kv, "=")
        gsub(/^[ \t]+|[ \t]+$/, "", kv[1])
        gsub(/^[ \t]+|[ \t]+$/, "", kv[2])
        if (kv[1] != "" && kv[2] != "") {
            uname_count++
            uname_from[uname_count] = kv[1]
            uname_to[uname_count]   = kv[2]
        }
    }

    skip_block = 0
    create_line = ""
    current_uh = ""
}

# 提取用户名: '\''user'\''@'\''host'\'' -> user
function extract_user(line,    u) {
    if (match(line, /\047[^\047]+\047@\047/)) {
        u = substr(line, RSTART + 1)
        sub(/\047@\047.*/, "", u)
        return u
    }
    return ""
}

# 提取完整的 user@host 标识: '\''user'\''@'\''host'\''
function extract_uh(line) {
    if (match(line, /\047[^\047]+\047@\047[^\047]+\047/))
        return substr(line, RSTART, RLENGTH)
    return ""
}

# 提取 host: '\''user'\''@'\''host'\'' -> host
function extract_host(line,    h) {
    if (match(line, /\047[^\047]+\047@\047[^\047]+\047/)) {
        h = substr(line, RSTART, RLENGTH)
        sub(/^.*\047@\047/, "", h)
        sub(/\047$/, "", h)
        return h
    }
    return ""
}

function compare_ip(ip1, ip2,    a1, a2, n1, n2, i, v1, v2) {
    n1 = split(ip1, a1, ".")
    n2 = split(ip2, a2, ".")
    for (i = 1; i <= 4; i++) {
        v1 = (i <= n1) ? a1[i] + 0 : 0
        v2 = (i <= n2) ? a2[i] + 0 : 0
        if (v1 < v2) return -1
        if (v1 > v2) return 1
    }
    if (ip1 < ip2) return -1
    if (ip1 > ip2) return 1
    return 0
}

function sort_strings(arr, n,    i, j, tmp) {
    for (i = 1; i <= n; i++) {
        for (j = i + 1; j <= n; j++) {
            if (compare_ip(arr[i], arr[j]) > 0) {
                tmp = arr[i]
                arr[i] = arr[j]
                arr[j] = tmp
            }
        }
    }
}

# 将 host 替换为 %
function replace_host(line) {
    gsub(/\047@\047[^\047]+\047/, "\047@\047%\047", line)
    return line
}

# 应用数据库名称映射和用户名映射
function apply_mappings(line,    i) {
    # 库名: `old_db`. → `new_db`.
    for (i = 1; i <= db_count; i++) {
        gsub("`" db_from[i] "`\\.", "`" db_to[i] "`.", line)
    }
    # 用户名: '\''old_user'\''@ → '\''new_user'\''@
    for (i = 1; i <= uname_count; i++) {
        gsub("\047" uname_from[i] "\047@", "\047" uname_to[i] "\047@", line)
    }
    return line
}

function mapped_user(user,    i, result) {
    result = user
    for (i = 1; i <= uname_count; i++) {
        if (result == uname_from[i]) {
            result = uname_to[i]
        }
    }
    return result
}

function mapped_host(host) {
    if (replace_host_with_wildcard == "1" && host != "") return "%"
    return host
}

function format_uh(user, host) {
    return "\047" user "\047@\047" host "\047"
}

function mapped_uh(user, host) {
    return format_uh(mapped_user(user), mapped_host(host))
}

function map_line_db_only(line,    i, mapped_line) {
    mapped_line = line
    for (i = 1; i <= db_count; i++) {
        gsub("`" db_from[i] "`\\.", "`" db_to[i] "`.", mapped_line)
    }
    return mapped_line
}

function map_line_user_only(line,    i, mapped_line) {
    mapped_line = line
    for (i = 1; i <= uname_count; i++) {
        gsub("\047" uname_from[i] "\047@", "\047" uname_to[i] "\047@", mapped_line)
    }
    return mapped_line
}

function record_change(section, from, to,    key) {
    key = section SUBSEP from SUBSEP to
    if (!(key in change_seen)) {
        change_seen[key] = 1
        change_order[section, ++change_count[section]] = from SUBSEP to
    }
}

function record_db_changes_in_line(line,    i, line_user) {
    line_user = mapped_user(extract_user(line))
    for (i = 1; i <= db_count; i++) {
        if (index(line, "`" db_from[i] "`.") > 0 && map_line_db_only(line) != line) {
            record_change("db", line_user " " db_from[i], db_to[i])
        }
    }
}

function record_user_changes_in_line(line,    i) {
    for (i = 1; i <= uname_count; i++) {
        if (index(line, "\047" uname_from[i] "\047@") > 0 && map_line_user_only(line) != line) {
            record_change("user", uname_from[i], uname_to[i])
        }
    }
}

function emit_change_comments(line,    i, line_user) {
    if (verbose_level < 2) return
    line_user = mapped_user(extract_user(line))
    for (i = 1; i <= db_count; i++) {
        if (index(line, "`" db_from[i] "`.") > 0 && map_line_db_only(line) != line) {
            print "-- [DB-MAPPED] " "\047" line_user "\047" ": `" db_from[i] "` -> `" db_to[i] "`"
        }
    }
    for (i = 1; i <= uname_count; i++) {
        if (index(line, "\047" uname_from[i] "\047@") > 0 && map_line_user_only(line) != line) {
            print "-- [USER-MAPPED] " "\047" uname_from[i] "\047" " -> " "\047" uname_to[i] "\047"
        }
    }
}

# 输出没有匹配到 ALTER USER 的 CREATE USER（无密码用户）
function flush_create() {
    if (create_line != "") {
        emit_change_comments(create_line)
        record_db_changes_in_line(create_line)
        record_user_changes_in_line(create_line)
        print apply_mappings(create_line " IDENTIFIED WITH \"mysql_native_password\";")
        create_line = ""
    }
}

{
    user = extract_user($0)
    uh   = extract_uh($0)
    host = extract_host($0)

    # 无 user@host 的行（空行、普通注释等）
    if (user == "") {
        if (!skip_block) { flush_create(); print }
        next
    }

    # 检测 user@host 变化 → 新的用户块
    if (uh != "" && uh != current_uh) {
        if (!skip_block) flush_create()
        current_uh = uh

        done_key = (replace_host_with_wildcard == "1") ? user : uh
        if (!(user in excluded) && replace_host_with_wildcard == "1" && host != "" && host != "%") {
            if (done_key in done) {
                record_change("host_merge", format_uh(user, host), mapped_uh(user, host))
            } else {
                record_change("host_change", format_uh(user, host), mapped_uh(user, host))
            }
        }
        if (user in excluded || done_key in done) {
            skip_block = 1
            if (!(user in excluded) && replace_host_with_wildcard == "1" && host != "" && host != "%") {
                if (verbose_level >= 2) {
                    print "-- [HOST-MERGED] " format_uh(user, host) " -> " mapped_uh(user, host)
                    print "-- [SQL-SKIPPED] same user merged under wildcard host"
                }
            }
        } else {
            skip_block = 0
            done[done_key] = 1
        }
    }

    if (skip_block) next

    line = $0
    if (replace_host_with_wildcard == "1") {
        line = replace_host(line)
    }

    # CREATE USER → 暂存，等待与 ALTER USER IDENTIFIED 合并
    if (line ~ /^CREATE USER/) {
        sub(/;[[:space:]]*$/, "", line)
        if (replace_host_with_wildcard == "1" && host != "" && host != "%") {
            if (verbose_level >= 2) {
                print "-- [HOST-CHANGED] " format_uh(user, host) " -> " mapped_uh(user, host)
            }
        }
        create_line = line
        next
    }

    # ALTER USER ... IDENTIFIED → 合并到 CREATE USER
    if (line ~ /^ALTER USER.*IDENTIFIED/) {
        if (match(line, /IDENTIFIED.*/)) {
            id_part = substr(line, RSTART, RLENGTH)
            # 去掉 REQUIRE NONE PASSWORD EXPIRE DEFAULT ... 尾部
            sub(/ REQUIRE .*/, ";", id_part)
            if (create_line != "") {
                print apply_mappings(create_line " " id_part)
                create_line = ""
            }
        }
        next
    }

    # 其他行（GRANT, REVOKE, 注释等）原样输出（host 已替换，映射已应用）
    flush_create()
    emit_change_comments($0)
    record_db_changes_in_line($0)
    record_user_changes_in_line($0)
    print apply_mappings(line)
}

END {
    if (!skip_block) flush_create()
    if (verbose_level >= 1 && (change_count["host_change"] > 0 || change_count["host_merge"] > 0 || change_count["db"] > 0 || change_count["user"] > 0)) {
        print ""
        print "-- [CHANGE-SUMMARY]"
        if (change_count["host_change"] > 0) {
            print "-- [HOST-CHANGED]"
            for (i = 1; i <= change_count["host_change"]; i++) {
                split(change_order["host_change", i], parts, SUBSEP)
                print "-- --- " parts[1] " -> " parts[2]
            }
            for (i = 1; i <= change_count["host_merge"]; i++) {
                split(change_order["host_merge", i], parts, SUBSEP)
                print "-- --- " parts[1] " -> " parts[2]
            }
            for (i = 1; i <= change_count["host_change"]; i++) {
                split(change_order["host_change", i], parts, SUBSEP)
                split(parts[1], host_parts, /\047@\047/)
                original_host_ip = host_parts[2]
                sub(/\047$/, "", original_host_ip)
                if (!(original_host_ip in original_host_ip_seen)) {
                    original_host_ip_seen[original_host_ip] = 1
                    original_host_ip_order[++original_host_ip_count] = original_host_ip
                }
            }
            for (i = 1; i <= change_count["host_merge"]; i++) {
                split(change_order["host_merge", i], parts, SUBSEP)
                split(parts[1], host_parts, /\047@\047/)
                original_host_ip = host_parts[2]
                sub(/\047$/, "", original_host_ip)
                if (!(original_host_ip in original_host_ip_seen)) {
                    original_host_ip_seen[original_host_ip] = 1
                    original_host_ip_order[++original_host_ip_count] = original_host_ip
                }
            }
            print "-- [ORIGINAL-HOSTS]"
            sort_strings(original_host_ip_order, original_host_ip_count)
            for (i = 1; i <= original_host_ip_count; i++) {
                ip = original_host_ip_order[i]
                if (ip == "%") {
                    cidr = "0.0.0.0/0"
                } else if (match(ip, /^([0-9]+)\.\%$/)) {
                    split(ip, _o, ".")
                    cidr = _o[1] ".0.0.0/8"
                } else if (match(ip, /^([0-9]+)\.([0-9]+)\.\%$/)) {
                    split(ip, _o, ".")
                    cidr = _o[1] "." _o[2] ".0.0/16"
                } else if (match(ip, /^([0-9]+)\.([0-9]+)\.([0-9]+)\.\%$/)) {
                    split(ip, _o, ".")
                    cidr = _o[1] "." _o[2] "." _o[3] ".0/24"
                } else {
                    cidr = ip
                }
                print "-- --- " ip " => " cidr
            }
        }
        if (change_count["host_merge"] > 0) {
            print "-- [HOST-MERGED]"
            for (i = 1; i <= change_count["host_merge"]; i++) {
                split(change_order["host_merge", i], parts, SUBSEP)
                print "-- --- " parts[1] " -> " parts[2]
            }
        }
        if (change_count["db"] > 0) {
            print "-- [DB-MAPPED]"
            for (i = 1; i <= change_count["db"]; i++) {
                split(change_order["db", i], parts, SUBSEP)
                split(parts[1], db_parts, " ")
                print "-- --- " "\047" db_parts[1] "\047" ": `" db_parts[2] "` -> `" parts[2] "`"
            }
        }
        if (change_count["user"] > 0) {
            print "-- [USER-MAPPED]"
            for (i = 1; i <= change_count["user"]; i++) {
                split(change_order["user", i], parts, SUBSEP)
                print "-- --- " "\047" parts[1] "\047" " -> " "\047" parts[2] "\047"
            }
        }
    }
}
' "$@"
