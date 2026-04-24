# MySQL 参数自动化更新 Playbook (命令行版)

## 功能概述

✅ **双任务并行**：
1. 🔹 **动态修改**：连接 3306 端口，使用 `mysql` 客户端执行 `SET GLOBAL`，立即生效
2. 🔹 **持久配置**：修改 MySQL 配置文件，确保重启后参数依然生效

✅ **零依赖**：纯 Ansible core 模块 + `mysql` 命令行，无需安装 PyMySQL 等 Python 包  
✅ **灵活路径**：支持通过 `mysql_install_dir` 指定 MySQL 安装目录  
✅ **安全备份**：修改配置前自动备份原文件

## 前置要求

```bash
# 仅需 Ansible 核心 (无需额外集合)
# 目标机器需满足:
#   - mysql 客户端可执行
#   - 对配置文件有写权限 (sudo)
#   - MySQL 用户具备 SYSTEM_VARIABLES_ADMIN 或 SUPER 权限
```

## 快速开始

### 基础执行

```bash
# 修改 buffer_pool_size=4G (动态+持久化)
ansible-playbook -i inventory.ini mysql_config_update.yml \
  -e "mysql_connection_password=your_pass" \
  -e "buffer_pool_size=4G" \
  -e "target_hosts=mysql_servers"
```

### 指定 MySQL 安装目录

```bash
# mysql 不在 PATH 中时指定路径
ansible-playbook -i inventory.ini mysql_config_update.yml \
  -e "mysql_connection_password=xxx" \
  -e "mysql_install_dir=/opt/mysql-8.0.35" \
  -e "buffer_pool_size=8G" \
  -e "max_connections=1000"
```

### 指定配置文件路径

```bash
# 非标准配置文件位置
ansible-playbook -i inventory.ini mysql_config_update.yml \
  -e "mysql_connection_password=xxx" \
  -e "mysql_config_path=/custom/path/my.cnf" \
  -e "buffer_pool_size=4G"
```

### 使用 ansible-vault 管理密码

```bash
# 创建加密变量
ansible-vault create group_vars/mysql_servers/vault.yml
# 内容: mysql_connection_password: your_secure_password

# 执行
ansible-playbook -i inventory.ini mysql_config_update.yml \
  --vault-password-file=~/.vault_pass \
  -e "buffer_pool_size=4G"
```

## 参数说明

| 变量名 | 默认值 | 说明 |
|--------|--------|------|
| `target_hosts` | `all` | Ansible 目标主机组 |
| `mysql_install_dir` | *自动* | MySQL 安装根目录 |
| `mysql_config_path` | *自动检测* | 配置文件路径 (支持多发行版) |
| `mysql_connection_host` | `127.0.0.1` | MySQL 连接地址 |
| `mysql_connection_port` | `3306` | MySQL 端口 |
| `mysql_connection_user` | `root` | 连接用户名 |
| `mysql_connection_password` | *必填* | 连接密码 |
| `buffer_pool_size` | `2G` | InnoDB 缓冲池大小 |
| `max_connections` | `500` | 最大连接数 |
| `tmp_table_size` | `64M` | 临时表内存限制 |
| `sort_buffer_size` | `2M` | 排序缓冲区大小 |

## 支持的参数

默认配置以下参数（可编辑 `mysql_params` 扩展）：

```yaml
mysql_params:
  - innodb_buffer_pool_size    # InnoDB 缓冲池 ⭐关键性能参数
  - max_connections            # 最大连接数
  - tmp_table_size             # 内存临时表上限
  - sort_buffer_size           # 排序缓冲区
```

> 📌 仅支持 `SET GLOBAL` 可修改的动态参数。如需修改静态参数（如 `innodb_log_file_size`），需手动编辑配置文件并重启。

## 标签 (Tags) 使用

```bash
# 仅执行动态参数修改
--tags dynamic

# 仅执行配置文件修改
--tags config

# 执行验证步骤
--tags verify

# 跳过备份
--skip-tags backup

# 查看详细报告
--tags report
```

## 执行结果解读

```
✅ MySQL 参数更新完成 (db-01)

📊 执行结果:
- 动态参数: 4/4 成功
- 配置文件: 4/4 已更新
- 配置路径: /etc/mysql/mysql.conf.d/mysqld.cnf

⚠️ 注意:
- 动态参数 (SET GLOBAL) 仅对新建连接生效
- 配置文件修改需重启 MySQL 才能完全生效
- 备份文件: /etc/mysql/mysql.conf.d/mysqld.cnf.bak.1713945600
```

## 权限要求

```sql
-- MySQL 用户需具备以下权限之一:
GRANT SYSTEM_VARIABLES_ADMIN ON *.* TO 'admin'@'%';  -- MySQL 8.0.2+
-- 或
GRANT SUPER ON *.* TO 'admin'@'%';                     -- MySQL 5.x / 8.0 早期

-- 配置文件修改需目标机器 sudo 权限
```

## 常见问题

### ❓ 动态修改成功但查询仍是旧值？
`SET GLOBAL` 仅对**新建连接**生效。已存在连接需重连：
```bash
mysql -h host -u user -p -e "SHOW GLOBAL VARIABLES LIKE 'innodb_buffer_pool_size';"
```

### ❓ 配置文件路径检测错误？
手动指定路径：`-e "mysql_config_path=/your/path/my.cnf"`

### ❓ 如何添加新参数？
编辑 playbook 中 `mysql_params` 列表：
```yaml
- { name: "your_param_name", value: "your_value" }
```

### ❓ 修改后需要重启吗？
| 修改类型 | 生效时机 | 是否需重启 |
|----------|----------|-----------|
| 动态参数 (SET GLOBAL) | 新建连接立即生效 | ❌ 否 |
| 配置文件修改 | 下次启动时加载 | ✅ 是 |

> 💡 建议：先执行动态修改验证参数效果，确认无误后再安排维护窗口重启使配置持久化。

## 安全建议

🔐 **密码管理**: 使用 `ansible-vault` 或 CI/CD 变量注入，避免明文  
🔐 **最小权限**: 专用管理账号 + 限制来源 IP  
🔐 **变更审计**: 开启 MySQL general_log 记录 SET GLOBAL 操作  
🔐 **备份策略**: playbook 自动备份配置文件，建议定期归档到远程存储
