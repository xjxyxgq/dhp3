# -*- coding: utf-8 -*-
from __future__ import annotations
"""
GoldenDB 配置巡检引擎

核心模块，整合了配置加载、数据源工厂、result_transform 和检查执行流程。
v1 精简架构：config_loader 和 factory 内联在此文件中。

数据流:
  YAML 文件
      │
      ▼
  _load_config()  →  CheckItem 列表 + datasources 字典
      │
      ▼
  run_all() / run_by_name()
      │
      ├─ _resolve_hosts()  →  [(host_label, host_config), ...]
      │                         单主机时只有一个条目
      │
      ├─ 对每个 host:
      │    ├─ _create_datasource(host_config)  →  DataSource 实例
      │    ├─ datasource.fetch()               →  raw list[dict]
      │    ├─ _apply_transform()               →  transformed list[dict]
      │    └─ validator.validate()             →  CheckResult 列表（打上 host_label）
      │
      ▼
  Reporter 输出报告
"""

import os
import re
import time
import uuid
import logging
from datetime import datetime
from typing import Optional

import yaml

from precheck.models import CheckItem, CheckResult, CheckStatus, ConfigError
from precheck.datasource import (
    MockDataSource, SqlDataSource, HttpDataSource,
    SshDataSource, DispatchDataSource,
)
from precheck.datasource.base import DataSource
from precheck.datasource.remote_artifact import RemoteArtifactManager
from precheck.validators.rule_validator import RuleValidator

logger = logging.getLogger("precheck")


class CheckEngine:
    """GoldenDB 配置巡检引擎

    CLI、Flask 路由、FastAPI 端点都只是给它套壳。
    """

    # 数据源类型映射（工厂逻辑内联）
    DATASOURCE_MAP = {
        "sql": SqlDataSource,
        "http": HttpDataSource,
        "ssh": SshDataSource,
        "dispatch": DispatchDataSource,
        "mock": MockDataSource,
    }

    def __init__(self, config_path: str, variables: dict = None):
        """加载 YAML 配置，初始化检查项

        Args:
            config_path: YAML 配置文件路径
            variables: 外部传入的变量字典，用于替换 {{var}} 模板占位符。
                       解析优先级: YAML vars 默认值 < variables 参数 < ${环境变量}

        Raises:
            ConfigError: 配置文件不存在、格式错误、或关键字段缺失
        """
        self.config_path = config_path
        self.external_vars = variables or {}
        self.mock_mode = False
        self.datasources_config: dict = {}
        self.checks: list[CheckItem] = []
        self._datasource_cache: dict[str, DataSource] = {}
        self._runtime_context: dict = {}

        self._load_config()

    def _load_config(self):
        """从 YAML 文件加载配置

        流程:
          1. 读取并解析 YAML
          2. 合并变量（YAML defaults + 外部变量）并替换 {{var}} 模板
          3. 提取全局配置（mock_mode）
          4. 提取数据源定义（非 mock 模式时解析 ${ENV} 环境变量）
          5. 提取检查项列表，映射为 CheckItem 对象
        """
        # 1. 读取 YAML
        if not os.path.exists(self.config_path):
            raise ConfigError(f"配置文件不存在: {self.config_path}")

        try:
            with open(self.config_path, "r", encoding="utf-8") as f:
                raw_config = yaml.safe_load(f)
        except yaml.YAMLError as e:
            raise ConfigError(f"YAML 配置格式错误: {e}")

        if not isinstance(raw_config, dict):
            raise ConfigError("YAML 配置格式错误: 顶层必须是字典")

        # 2. 变量模板替换
        #    优先级: YAML vars 默认值 < external_vars（--vars 文件 + --var CLI）
        yaml_defaults = raw_config.pop("vars", {}) or {}
        merged_vars = dict(yaml_defaults)
        merged_vars.update(self.external_vars)

        # 总是执行模板替换（即使 merged_vars 为空，也需要处理 {{var:默认值}} 语法）
        raw_config = self._resolve_template_vars(raw_config, merged_vars)
        if merged_vars:
            logger.info("模板变量已替换: %d 个变量", len(merged_vars))

        # 3. 全局配置
        global_config = raw_config.get("global", {})
        self.mock_mode = global_config.get("mock_mode", False)

        # 4. 数据源定义
        self.datasources_config = raw_config.get("datasources", {})

        # 非 mock 模式时解析 ${ENV} 环境变量
        if not self.mock_mode:
            self.datasources_config = self._resolve_env_in_dict(self.datasources_config)

        # 4. 检查项列表
        checks_raw = raw_config.get("checks", [])
        if not isinstance(checks_raw, list):
            raise ConfigError("YAML 配置格式错误: checks 必须是列表")

        for check_raw in checks_raw:
            check_item = self._parse_check_item(check_raw)
            self.checks.append(check_item)

        logger.info("配置加载完成: %d 个检查项, mock_mode=%s",
                     len(self.checks), self.mock_mode)

    def _parse_check_item(self, raw: dict) -> CheckItem:
        """将 YAML 中的检查项字典解析为 CheckItem 对象"""
        validator_raw = raw.get("validator", {})

        return CheckItem(
            name=raw.get("name", "未命名检查项"),
            description=raw.get("description", ""),
            datasource_ref=raw.get("datasource", ""),
            query=raw.get("query", ""),
            validator_type=validator_raw.get("type", ""),
            validator_rules=validator_raw.get("rules", []),
            result_transform=raw.get("result_transform"),
            output_parser=raw.get("output_parser"),
            response_path=raw.get("response_path"),
            method=raw.get("method"),
            request_params=raw.get("request_params"),
            script_args=raw.get("script_args"),
            script=raw.get("script"),
            script_entry=raw.get("script_entry"),
            env=raw.get("env"),
            mock_data=raw.get("mock_data"),
            host_overrides=raw.get("host_overrides"),
            retry=raw.get("retry"),
            enabled=self._coerce_bool(raw.get("enabled", True), field_name="enabled"),
        )

    @staticmethod
    def _coerce_bool(value, field_name: str = "") -> bool:
        """将配置值规范化为布尔值。"""
        if isinstance(value, bool):
            return value

        if isinstance(value, str):
            normalized = value.strip().lower()
            truthy = {"true", "1", "yes", "on"}
            falsy = {"false", "0", "no", "off", ""}
            if normalized in truthy:
                return True
            if normalized in falsy:
                return False

        raise ConfigError(
            f"字段 '{field_name or 'boolean'}' 必须是布尔值，当前为: {value!r}"
        )

    def _resolve_env_in_dict(self, obj):
        """递归解析字典/列表中的 ${VAR_NAME} 环境变量

        Args:
            obj: 字典、列表或字符串

        Returns:
            解析后的对象

        Raises:
            ConfigError: 环境变量未定义
        """
        if isinstance(obj, str):
            return self._resolve_env_vars(obj)
        elif isinstance(obj, dict):
            return {k: self._resolve_env_in_dict(v) for k, v in obj.items()}
        elif isinstance(obj, list):
            return [self._resolve_env_in_dict(item) for item in obj]
        return obj

    @staticmethod
    def _resolve_env_vars(value: str) -> str:
        """将 ${VAR_NAME} 替换为环境变量值

        Args:
            value: 可能包含 ${VAR_NAME} 的字符串

        Returns:
            替换后的字符串

        Raises:
            ConfigError: 环境变量未定义时 fail fast
        """
        def replacer(match):
            var_name = match.group(1)
            val = os.environ.get(var_name)
            if val is None:
                raise ConfigError(f"环境变量 '{var_name}' 未定义")
            return val

        return re.sub(r'\$\{(\w+)\}', replacer, value)

    @staticmethod
    def _resolve_template_vars(obj, variables: dict):
        """递归替换 {{var_name}} 模板变量

        支持两种模板语法:
          {{var_name}}     - 简单替换
          {{var_name:默认值}} - 带默认值，变量未定义时使用默认值

        整个值是 {{var}} 且变量值为数字时，保持数字类型（不转字符串）。

        Args:
            obj: YAML 解析后的对象（字典、列表、字符串等）
            variables: 变量字典

        Returns:
            替换后的对象
        """
        if isinstance(obj, str):
            # 检查是否整个值就是一个变量引用（保持类型）
            full_match = re.fullmatch(r'\{\{\s*(\w+)(?::([^}]*))?\s*\}\}', obj)
            if full_match:
                var_name = full_match.group(1)
                default_val = full_match.group(2)
                if var_name in variables:
                    return variables[var_name]
                elif default_val is not None:
                    return default_val
                else:
                    return obj  # 变量未定义，保持原样

            # 部分替换（字符串拼接场景）
            def replacer(match):
                var_name = match.group(1)
                default_val = match.group(2)
                if var_name in variables:
                    return str(variables[var_name])
                elif default_val is not None:
                    return default_val
                return match.group(0)  # 未定义，保持原样

            return re.sub(r'\{\{\s*(\w+)(?::([^}]*))?\s*\}\}', replacer, obj)

        elif isinstance(obj, dict):
            return {k: CheckEngine._resolve_template_vars(v, variables)
                    for k, v in obj.items()}
        elif isinstance(obj, list):
            return [CheckEngine._resolve_template_vars(item, variables)
                    for item in obj]
        return obj

    def _resolve_hosts(self, datasource_ref: str) -> list[tuple[str, dict]]:
        """解析数据源的主机列表

        支持两种配置方式（向下兼容）：
          1. 单主机: host: "10.0.0.1"
          2. 多主机: hosts:
                       - {host: "10.0.0.1", label: "CN-1"}
                       - {host: "10.0.0.2", label: "CN-2", port: 3308}

        多主机时，每个 host 条目可以覆盖基础配置中的任意字段。

        Args:
            datasource_ref: 数据源引用名

        Returns:
            list[(host_label, merged_config)]: 主机标识和合并后的配置列表。
            单主机时返回 [(None, config)]。

        Raises:
            ConfigError: 数据源引用名不存在
        """
        if datasource_ref not in self.datasources_config:
            raise ConfigError(f"数据源 '{datasource_ref}' 未在 datasources 中定义")

        ds_config = dict(self.datasources_config[datasource_ref])
        hosts_list = ds_config.pop("hosts", None)

        if not hosts_list:
            # 单主机模式（向下兼容）
            return [(None, ds_config)]

        # 多主机模式：每个 host 条目和基础配置合并
        result = []
        for i, host_entry in enumerate(hosts_list):
            merged = dict(ds_config)  # 复制基础配置
            label = host_entry.get("label", host_entry.get("host", f"host-{i+1}"))
            merged.update(host_entry)  # host 条目的字段覆盖基础配置
            merged.pop("label", None)  # label 不传给 DataSource
            result.append((label, merged))

        return result

    def _create_datasource(self, config: dict) -> DataSource:
        """根据配置创建数据源实例

        Args:
            config: 合并后的单主机配置

        Returns:
            DataSource: 数据源实例

        Raises:
            ConfigError: 数据源类型未知
        """
        ds_type = config.get("type", "")

        if ds_type not in self.DATASOURCE_MAP:
            raise ConfigError(f"未知的数据源类型: '{ds_type}'")

        ds_class = self.DATASOURCE_MAP[ds_type]
        datasource = ds_class(config)
        datasource.set_runtime_context(self._runtime_context)
        return datasource

    @staticmethod
    def _make_runtime_context() -> dict:
        """为单次巡检运行创建共享上下文。"""
        run_id = uuid.uuid4().hex[:12]
        return {
            "run_id": run_id,
            "artifact_manager": RemoteArtifactManager(run_id=run_id),
        }

    def _get_validator(self, validator_type: str):
        """获取验证器实例

        v1 所有类型都使用 RuleValidator。

        Args:
            validator_type: 验证器类型标识

        Returns:
            RuleValidator: 验证器实例
        """
        # v1 精简：所有类型统一使用 RuleValidator
        return RuleValidator()

    def _apply_transform(self, data: list[dict],
                         transform_config: Optional[dict]) -> list[dict]:
        """在 fetch 和 validate 之间应用数据转换

        v1 支持 pivot 转换：将 key-value 行格式转为每行一个独立字典。
        典型场景：SHOW VARIABLES 返回 (Variable_name, Value) 行，
        转为 [{hwm: "2:1"}, {lwm: "1:0"}]，每个变量独立一行。

        Args:
            data: 原始数据列表
            transform_config: 转换配置，None 表示不转换

        Returns:
            list[dict]: 转换后的数据列表
        """
        if transform_config is None:
            return data

        transform_type = transform_config.get("type", "")

        if transform_type == "pivot":
            key_col = transform_config.get("key_col", "")
            value_col = transform_config.get("value_col", "")

            if not key_col or not value_col:
                logger.warning("pivot 转换缺少 key_col 或 value_col 配置，跳过转换")
                return data

            # 每个 key-value 对转为独立的一行字典
            pivoted = []
            for row in data:
                key = row.get(key_col, "")
                value = row.get(value_col, "")
                if key:
                    pivoted.append({key: value})

            return pivoted if pivoted else data

        else:
            logger.warning("未知的 transform 类型: '%s'，跳过转换", transform_type)
            return data

    def run_all(self) -> list[CheckResult]:
        """执行所有启用的检查项

        Returns:
            list[CheckResult]: 所有检查结果
        """
        self._runtime_context = self._make_runtime_context()
        all_results = []

        for check in self.checks:
            if not check.enabled:
                all_results.append(CheckResult(
                    check_name=check.name,
                    status=CheckStatus.SKIP,
                    message=f"检查项 '{check.name}' 已禁用，跳过",
                    timestamp=datetime.now().isoformat(),
                ))
                logger.info("跳过禁用的检查项: %s", check.name)
                continue

            results = self._run_single_check(check)
            all_results.extend(results)

        return all_results

    def run_by_name(self, name: str) -> list[CheckResult]:
        """按名称执行指定检查项

        Args:
            name: 检查项名称

        Returns:
            list[CheckResult]: 指定检查项的结果

        Raises:
            ConfigError: 检查项名称不存在
        """
        self._runtime_context = self._make_runtime_context()
        for check in self.checks:
            if check.name == name:
                if not check.enabled:
                    return [CheckResult(
                        check_name=check.name,
                        status=CheckStatus.SKIP,
                        message=f"检查项 '{check.name}' 已禁用，跳过",
                        timestamp=datetime.now().isoformat(),
                    )]
                return self._run_single_check(check)

        raise ConfigError(f"检查项 '{name}' 不存在")

    def _run_single_check(self, check: CheckItem) -> list[CheckResult]:
        """执行单个检查项（支持多主机）

        流程:
          1. 解析主机列表（单主机或多主机）
          2. 对每个主机：
             a. 选择 mock_data（按 host_label 匹配或共用）
             b. 选择验证规则（host_overrides 或默认）
             c. fetch → transform → validate
             d. 给结果打上 host_label
          3. 错误隔离：单个主机失败不影响其他主机

        Args:
            check: 检查项对象

        Returns:
            list[CheckResult]: 该检查项在所有主机上的结果
        """
        logger.info("开始执行检查项: %s", check.name)

        # 1. 解析主机列表
        try:
            host_entries = self._resolve_hosts(check.datasource_ref)
        except ConfigError:
            raise

        all_results = []

        for host_label, host_config in host_entries:
            label_display = host_label or "default"
            if host_label:
                logger.info("  -> 主机: %s", label_display)

            try:
                # 2a. 选择 mock_data
                mock_data_for_host = self._select_mock_data(
                    check.mock_data, host_label
                )

                # 2b. 选择验证规则（host_overrides 支持）
                rules = self._select_rules(check, host_label)

                # 2c. fetch 数据
                if self.mock_mode:
                    if mock_data_for_host is None:
                        logger.warning("检查项 '%s' 主机 '%s' 无 mock_data，跳过",
                                       check.name, label_display)
                        all_results.append(CheckResult(
                            check_name=check.name,
                            status=CheckStatus.SKIP,
                            message=f"检查项 '{check.name}' 主机 '{label_display}' 无 mock_data",
                            host_label=host_label,
                            timestamp=datetime.now().isoformat(),
                        ))
                        continue
                    datasource = MockDataSource({})
                    raw_data = datasource.fetch(
                        check.query, mock_data=mock_data_for_host,
                    )
                else:
                    datasource = self._create_datasource(host_config)
                    raw_data = self._fetch_with_retry(
                        datasource, check, label_display,
                    )

                # transform
                data = self._apply_transform(raw_data, check.result_transform)

                # validate
                validator = self._get_validator(check.validator_type)
                results = validator.validate(data, rules, check.name)

                # 给结果打上 host_label
                for r in results:
                    r.host_label = host_label

                all_results.extend(results)

            except ConnectionError as e:
                logger.error("数据源连接失败: %s [%s], error=%s",
                             check.name, label_display, str(e))
                all_results.append(CheckResult(
                    check_name=check.name,
                    status=CheckStatus.ERROR,
                    message=f"[{label_display}] 数据源连接失败: {e}",
                    host_label=host_label,
                    timestamp=datetime.now().isoformat(),
                ))
            except TimeoutError as e:
                logger.error("数据获取超时: %s [%s], error=%s",
                             check.name, label_display, str(e))
                all_results.append(CheckResult(
                    check_name=check.name,
                    status=CheckStatus.ERROR,
                    message=f"[{label_display}] 数据获取超时: {e}",
                    host_label=host_label,
                    timestamp=datetime.now().isoformat(),
                ))
            except ConfigError:
                raise
            except Exception as e:
                logger.error("未预期的错误: %s [%s], error=%s",
                             check.name, label_display, str(e))
                all_results.append(CheckResult(
                    check_name=check.name,
                    status=CheckStatus.ERROR,
                    message=f"[{label_display}] 未预期的错误: {e}",
                    host_label=host_label,
                    timestamp=datetime.now().isoformat(),
                ))

        pass_count = sum(1 for r in all_results if r.status == CheckStatus.PASS)
        fail_count = sum(1 for r in all_results if r.status == CheckStatus.FAIL)
        logger.info("检查项完成: %s, 结果: %d PASS / %d FAIL",
                    check.name, pass_count, fail_count)

        return all_results

    @staticmethod
    def _select_mock_data(mock_data, host_label: Optional[str]) -> Optional[list]:
        """选择当前主机对应的 mock 数据

        支持两种 mock_data 格式：
          1. list: 所有主机共用同一份数据
             mock_data:
               - {field: value}
          2. dict: 按 host_label 区分
             mock_data:
               CN-1:
                 - {field: value_a}
               CN-2:
                 - {field: value_b}

        Args:
            mock_data: 原始 mock_data 配置
            host_label: 当前主机标识

        Returns:
            list 或 None
        """
        if mock_data is None:
            return None

        if isinstance(mock_data, list):
            # 所有主机共用
            return mock_data

        if isinstance(mock_data, dict) and host_label:
            # 按 host_label 查找
            return mock_data.get(host_label)

        return None

    @staticmethod
    def _select_rules(check: CheckItem, host_label: Optional[str]) -> list:
        """选择当前主机对应的验证规则

        支持 host_overrides 字段为特定主机指定不同的验证规则：
          host_overrides:
            CN-3:
              rules:
                - field: xxx
                  expected: "特殊值"

        Args:
            check: 检查项对象
            host_label: 当前主机标识

        Returns:
            list: 验证规则列表
        """
        # 检查是否有 host_overrides（存储在 CheckItem 的扩展字段中）
        if hasattr(check, 'host_overrides') and check.host_overrides and host_label:
            override = check.host_overrides.get(host_label)
            if override and "rules" in override:
                return override["rules"]

        return check.validator_rules

    def _fetch_with_retry(self, datasource, check: CheckItem,
                          host_label: str) -> list[dict]:
        """带重试的数据获取

        当检查项配置了 retry 时，在 ConnectionError 或 TimeoutError
        时自动重试，使用指数退避策略。

        YAML 配置示例:
          retry:
            count: 3        # 最多重试 3 次
            backoff_s: 2    # 初始退避 2 秒，每次翻倍

        Args:
            datasource: 数据源实例
            check: 检查项对象
            host_label: 主机标识（日志用）

        Returns:
            list[dict]: 获取到的数据

        Raises:
            ConnectionError: 重试次数用尽后仍失败
            TimeoutError: 重试次数用尽后仍超时
        """
        retry_config = check.retry or {}
        max_retries = retry_config.get("count", 0)
        backoff_s = retry_config.get("backoff_s", 1)

        fetch_kwargs = dict(
            output_parser=check.output_parser,
            response_path=check.response_path,
            method=check.method,
            request_params=check.request_params,
            script_args=check.script_args,
            script=check.script,
            script_entry=check.script_entry,
            env=check.env,
        )

        last_error = None
        for attempt in range(max_retries + 1):
            try:
                return datasource.fetch(check.query, **fetch_kwargs)
            except (ConnectionError, TimeoutError) as e:
                last_error = e
                if attempt < max_retries:
                    wait = backoff_s * (2 ** attempt)
                    logger.warning(
                        "  [%s] 第 %d/%d 次重试，%ds 后重试: %s",
                        host_label, attempt + 1, max_retries, wait, str(e)[:100]
                    )
                    time.sleep(wait)

        # 重试次数用尽
        raise last_error

