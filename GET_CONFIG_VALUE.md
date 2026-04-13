# get_config_value 设计与使用文档

## 1. 背景与目标

`get_config_value` 用于从配置文件中提取指定配置项的值，面向以下场景：

- 读取本地指定配置文件中的某个字段值
- 读取单个配置内容流并解析指定字段
- 通过 SSH 读取远程机器上的配置文件，再在本地完成解析
- 以文本或 JSON 结果输出，便于人工查看或脚本消费

统一约定：

- `--file` 始终表示目标配置文件路径
- 未指定 `--host` 时，`--file` 表示本地路径
- 指定 `--host` 时，`--file` 表示远程路径

支持的配置格式：

- `ini`
- `yaml`
- `json`
- `xml`

支持的路径表达式：

- 点路径：`server.port`
- 数组下标：`servers.0.host`

## 2. 设计原则

### 2.1 尽量降低目标机器依赖

最初目标是尽量减少运行时依赖，同时兼顾不同 Linux 发行版、不同 CPU 架构和不同工具链环境。

最终采用两层设计：

1. `shell` 启动器负责平台识别和远程读取
2. `Go` 二进制负责解析配置内容

这样做的原因：

- 纯 shell 很难可靠处理 `yaml/xml`
- 预编译 Go 二进制后，本地运行几乎无额外依赖
- 远程模式下无需在目标机器部署二进制，只要目标机器有 `ssh` 和 `cat`

### 2.2 本地解析，远程只负责读文件

远程模式不在目标机器上执行解析逻辑，而是：

1. 本地 shell 脚本通过 `ssh` 连接远程机器
2. 远程机器执行 `cat <配置文件>`
3. 文件内容通过标准输出回传
4. 本地 Go 程序通过 `--stdin` 读取内容并解析

优势：

- 远程机器无需关心 `amd64/arm64`
- 远程机器无需安装 `Go/jq/yq/xmllint/python`
- 远程环境差异对解析逻辑没有影响

## 3. 文件结构

相关文件如下：

- [get_config_value.sh](/Users/xuguoqiang/SynologyDrive/Backup/MI_office_notebook/D/myworkspace/nucc_workspace/program/src/nucc.com/dhp/get_config_value.sh)
  - shell 启动器
  - 识别当前操作系统和架构
  - 选择对应二进制
  - 处理远程读取模式

- [build_get_config_value.sh](/Users/xuguoqiang/SynologyDrive/Backup/MI_office_notebook/D/myworkspace/nucc_workspace/program/src/nucc.com/dhp/build_get_config_value.sh)
  - 多平台构建脚本
  - 一次生成 `darwin/linux + amd64/arm64` 四个二进制

- [get_config_value/main.go](/Users/xuguoqiang/SynologyDrive/Backup/MI_office_notebook/D/myworkspace/nucc_workspace/program/src/nucc.com/dhp/get_config_value/main.go)
  - 主程序
  - 参数解析
  - 配置内容读取
  - 四种格式解析
  - 路径查找
  - 输出格式控制

- [get_config_value/go.mod](/Users/xuguoqiang/SynologyDrive/Backup/MI_office_notebook/D/myworkspace/nucc_workspace/program/src/nucc.com/dhp/get_config_value/go.mod)
  - Go 模块定义

- `bin/`
  - 预编译产物目录

## 4. 支持能力

### 4.1 配置格式

#### INI

支持标准写法：

```ini
[server]
port = 3306
host = 127.0.0.1
```

也支持扩展写法，单独一行表示布尔开关开启：

```ini
[feature]
logon
audit
```

上述内容会被解析为：

```json
{
  "feature": {
    "logon": true,
    "audit": true
  }
}
```

说明：

- 单独一行的裸键会被当作 `true`
- 如果该行包含空格或制表符，仍视为非法格式并报错

#### YAML

支持嵌套对象和数组：

```yaml
server:
  hosts:
    - name: db01
      port: 3306
```

#### JSON

支持标准 JSON 对象和数组。

#### XML

XML 会被转换成树结构后再做路径查找。例如：

```xml
<config>
  <database>
    <host>127.0.0.1</host>
  </database>
</config>
```

查询路径为：

```text
config.database.host
```

特殊规则：

- XML 属性使用 `@属性名`
- 文本节点使用 `#text`

例如：

```xml
<node enabled="true">hello</node>
```

可查询：

- `node.@enabled`
- `node.#text`

## 5. 路径表达式规则

路径使用点分隔：

```text
aaa.bbb.ccc
```

数组使用数字下标：

```text
servers.0.host
```

示例：

- `server.port`
- `cluster.nodes.1.ip`
- `config.database.host`
- `config.items.0.name`

## 6. 输出模式

### 6.1 文本模式

默认模式为 `text`，适合人工查看。

示例：

```bash
./get_config_value.sh \
  --file /data/app/conf/app.yaml \
  --path server.port
```

### 6.2 JSON 模式

通过 `--output json` 启用，适合脚本消费。

示例输出：

```json
{"status":"ok","key":"aaa.bbb","value":"aaa","info":"成功解析"}
```

当前实际输出中还可能带有辅助字段：

- `dir`
- `file`
- `format`
- `error`

字段说明：

- `status`
  - `ok` 表示成功
  - `error` 表示失败
- `key`
  - 查询路径
- `value`
  - 成功时返回的值
- `info`
  - 结果说明

## 7. 使用方式

### 7.1 本地读取单个配置文件

`--file` 在本地模式下表示本地配置文件的完整路径。

示例：

```bash
./get_config_value.sh \
  --file /data/app/conf/app.yaml \
  --path server.port
```

指定输出为 JSON：

```bash
./get_config_value.sh \
  --file /data/app/conf/app.yaml \
  --path server.port \
  --output json
```

### 7.2 从标准输入读取

适合配合 `cat`、管道、远程命令输出等场景。

示例：

```bash
cat /etc/myapp/app.yaml | ./get_config_value.sh \
  --stdin \
  --format yaml \
  --path server.port \
  --output json
```

说明：

- `--stdin` 模式下不能再传 `--file`
- `--stdin` 模式下必须显式指定 `--format`

### 7.3 读取远程配置文件

远程模式下，`--file` 表示远程配置文件的完整路径。shell 脚本会通过 SSH 执行远程 `cat`，并将文件内容传给本地解析器。

支持的远程能力：

- 指定 SSH 私钥认证
- 指定 SSH 连接超时
- 使用 `sudo -n cat` 读取受限文件

示例：

```bash
./get_config_value.sh \
  --host 10.0.0.8 \
  --user root \
  --file /etc/myapp/app.yaml \
  --format yaml \
  --path server.port \
  --output json
```

指定 SSH 端口：

```bash
./get_config_value.sh \
  --host 10.0.0.8 \
  --user root \
  --port 2222 \
  --file /etc/myapp/app.yaml \
  --format yaml \
  --path server.port \
  --output json
```

指定 SSH 私钥：

```bash
./get_config_value.sh \
  --host 10.0.0.8 \
  --user root \
  --identity-file ~/.ssh/id_rsa \
  --file /etc/myapp/app.yaml \
  --format yaml \
  --path server.port \
  --output json
```

指定 SSH 超时：

```bash
./get_config_value.sh \
  --host 10.0.0.8 \
  --user root \
  --ssh-timeout 5 \
  --file /etc/myapp/app.yaml \
  --format yaml \
  --path server.port \
  --output json
```

使用 sudo 读取：

```bash
./get_config_value.sh \
  --host 10.0.0.8 \
  --user appuser \
  --sudo \
  --file /etc/myapp/app.yaml \
  --format yaml \
  --path server.port \
  --output json
```

远程模式要求：

- 本地机器可以执行 `ssh`
- 远程机器允许 SSH 登录
- 远程文件对登录用户可读
- `--format` 需要显式指定
- 使用 `--sudo` 时，远程用户需具备非交互 sudo 权限，因为脚本使用的是 `sudo -n`

## 8. 参数说明

### 8.1 shell 启动器参数

`get_config_value.sh` 会透传大部分参数给 Go 程序，自身额外识别以下远程参数：

- `--host`
  - 远程主机名或 IP
- `--user`
  - SSH 用户名
- `--port`
  - SSH 端口
- `--identity-file`
  - SSH 私钥文件路径，对应 `ssh -i`
- `--ssh-timeout`
  - SSH 连接超时时间，单位为秒，对应 `ssh -o ConnectTimeout=<seconds>`
- `--sudo`
  - 远程读取时使用 `sudo -n cat`

### 8.2 Go 程序参数

- `--file`
  - 配置文件完整路径；本地模式为本地路径，远程模式为远程路径
- `--path`
  - 配置路径
- `--format`
  - `ini|yaml|json|xml`
- `--output`
  - `text|json`
- `--stdin`
  - 从标准输入读取
- `--show-file`
  - 文本模式下显示完整文件路径

## 9. 构建与分发

### 9.1 生成多平台二进制

执行：

```bash
bash build_get_config_value.sh
```

会生成：

- `bin/get_config_value-darwin-amd64`
- `bin/get_config_value-darwin-arm64`
- `bin/get_config_value-linux-amd64`
- `bin/get_config_value-linux-arm64`

### 9.2 分发方式建议

推荐将以下内容一起分发：

- `get_config_value.sh`
- `bin/` 目录中对应平台的二进制

如果仅使用远程读取模式，则只需保证运行脚本的本地机器具备对应平台的二进制即可。

## 10. 兼容性说明

### 10.1 本地模式

本地模式依赖：

- shell 启动器运行环境
- 当前机器对应平台的预编译二进制

### 10.2 远程模式

远程模式不依赖远程机器架构和 Go 环境，仅依赖：

- SSH
- `cat`
- 配置文件读取权限
- 如使用 `--sudo`，还依赖远程用户具备非交互 sudo 权限

因此远程模式通常比“在远端部署二进制”更稳。

## 11. 错误处理约定

常见失败情况：

- 目录不存在
- 文件不存在
- 配置格式无法识别
- 配置内容解析失败
- 路径不存在
- 数组下标越界
- SSH 无法连接
- 远程文件无权限读取
- sudo 权限不足或需要交互密码

JSON 模式下失败示例：

```json
{"status":"error","key":"server.port","info":"未找到路径节点: port","format":"yaml"}
```

## 12. 已知限制

- XML 的路径模型是通用树映射，不是 XPath
- INI 仅支持节 + 键值模型，不支持更复杂方言
- `--show-file` 主要对目录遍历模式有意义
- `--sudo` 使用的是 `sudo -n`，不会交互输入密码

## 13. 后续可扩展方向

- 增加 `--sudo` 支持远程 `sudo cat`
- 增加 `--timeout` 控制 SSH 超时
- JSON 模式增加固定最小字段集选项
- 增加批量路径查询，一次读取多个 key
- 增加更严格的 XML 查询能力
