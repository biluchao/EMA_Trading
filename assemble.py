#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
================================================================================
模块名称：assemble.py
模块路径：scripts/assemble.py
功能描述：EMA量化交易系统自动组装主脚本
          按模块依赖顺序编译、测试、组装完整系统

作者：     EMA Trading System Team <dev@ema.com>
创建日期： 2026-08-18
最后修改： 2026-08-19
版本：     8.1.0

兼容性：
    - Python >= 3.8
    - 依赖包见 requirements.txt

使用示例：
    python3 scripts/assemble.py              # 完整组装
    python3 scripts/assemble.py --dry-run    # 仅显示步骤
    python3 scripts/assemble.py --skip-tests # 跳过测试

接口契约：
    main() -> int                        成功返回0，失败返回非0
    run_assemble(config) -> bool         执行组装流程

变更日志：
    v8.1.0 (2026-08-19): 修复模块依赖检测、增加增量构建支持
    v8.0.0 (2026-08-18): 重构为模块化架构，增加并行编译支持
    v7.0.0 (2026-08-16): 初始版本

版权信息： Copyright (c) 2026 EMA Trading System. All rights reserved.
许可证：   Proprietary - 仅供内部使用
================================================================================
"""

# ==================== 标准库导入 ====================
import argparse
import json
import logging
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

# ==================== 第三方库导入 ====================
try:
    import yaml
except ImportError:
    print("❌ 缺少 pyyaml 依赖，请运行: pip install pyyaml")
    sys.exit(1)

try:
    from rich.console import Console
    from rich.progress import Progress, SpinnerColumn, TextColumn, BarColumn
    from rich.table import Table
    from rich.panel import Panel
    from rich import print as rprint
except ImportError:
    # 降级到标准输出
    class Console:
        def print(self, *args, **kwargs):
            print(*args)

    def rprint(*args, **kwargs):
        print(*args)

    class Progress:
        def __init__(self, *args, **kwargs):
            pass

        def __enter__(self):
            return self

        def __exit__(self, *args, **kwargs):
            pass

        def add_task(self, *args, **kwargs):
            return 0

        def update(self, *args, **kwargs):
            pass

# ==================== 公开 API 定义 ====================
__all__ = [
    "Assembler",
    "ModuleInfo",
    "AssembleResult",
    "run_assemble",
    "main",
]

# ==================== 日志 ====================
logger = logging.getLogger(__name__)

# ==================== 常量定义 ====================
DEFAULT_CONFIG_PATH: str = "assemble_config.yaml"
BUILD_DIR: str = "build"
BACKEND_BUILD_DIR: str = "backend/build"
FRONTEND_BUILD_DIR: str = "frontend/dist"
MAX_PARALLEL_JOBS: int = 4

# 颜色定义（用于非 rich 环境）
COLORS = {
    "red": "\033[91m",
    "green": "\033[92m",
    "yellow": "\033[93m",
    "blue": "\033[94m",
    "magenta": "\033[95m",
    "cyan": "\033[96m",
    "white": "\033[97m",
    "reset": "\033[0m",
    "bold": "\033[1m",
}

# 检测操作系统
SYSTEM = platform.system()


# ==================== 数据模型 ====================
class ModuleInfo:
    """模块信息"""

    def __init__(self, name: str, config: Dict):
        self.name = name
        self.description = config.get("description", name)
        self.depends = config.get("depends", [])
        self.files = config.get("files", [])
        self.build_cmd = config.get("build_cmd", [])
        self.test_cmd = config.get("test_cmd", [])
        self.enabled = config.get("enabled", True)
        self.build_dir = config.get("build_dir", "")
        self.source_dir = config.get("source_dir", "")


class AssembleResult:
    """组装结果"""

    def __init__(self):
        self.success: bool = True
        self.start_time: float = time.time()
        self.end_time: float = 0.0
        self.modules: List[Tuple[str, bool, str]] = []
        self.errors: List[str] = []
        self.warnings: List[str] = []
        self.skipped: List[str] = []

    def add_module_result(self, name: str, success: bool, message: str = ""):
        self.modules.append((name, success, message))
        if not success:
            self.success = False
            self.errors.append(f"{name}: {message}")

    def add_skipped(self, name: str, reason: str = ""):
        self.skipped.append(f"{name}: {reason}")
        self.warnings.append(f"跳过了 {name}: {reason}")

    def get_elapsed(self) -> float:
        return self.end_time - self.start_time if self.end_time > 0 else 0.0

    def __str__(self) -> str:
        return f"AssembleResult(success={self.success}, modules={len(self.modules)})"


# ==================== 核心组装器 ====================
class Assembler:
    """系统组装器"""

    def __init__(self, config_path: str = DEFAULT_CONFIG_PATH, dry_run: bool = False):
        self.project_root = Path(__file__).parent.parent
        self.config_path = self.project_root / config_path
        self.dry_run = dry_run
        self.console = Console()
        self.result = AssembleResult()
        self.modules: Dict[str, ModuleInfo] = {}
        self.parallel_jobs = MAX_PARALLEL_JOBS
        self.verbose = False

        # 配置日志
        self._setup_logging()

    def _setup_logging(self):
        """配置日志"""
        logging.basicConfig(
            level=logging.INFO,
            format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
            handlers=[logging.StreamHandler()],
        )
        logger.setLevel(logging.INFO)

    def set_verbose(self, verbose: bool):
        """设置详细输出模式"""
        self.verbose = verbose
        if verbose:
            logger.setLevel(logging.DEBUG)

    def _colorize(self, text: str, color: str = "white") -> str:
        """为文本添加颜色（非 rich 环境降级）"""
        if self.console.__class__.__name__ == "Console":
            return text
        return f"{COLORS.get(color, '')}{text}{COLORS['reset']}"

    def _print_header(self):
        """打印标题"""
        header = """
╔══════════════════════════════════════════════════════════════════╗
║                                                                  ║
║     EMA 量化交易系统 — 自动组装脚本 V8.1                        ║
║                                                                  ║
║     数据结构决定策略边界 — 数据驱动一切                          ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝
        """
        rprint(f"\n[bold cyan]{header}[/bold cyan]")
        rprint(f"[dim]  开始时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}[/dim]")
        rprint(f"[dim]  操作系统: {SYSTEM}[/dim]\n")

    def _load_config(self) -> bool:
        """加载配置文件"""
        try:
            if not self.config_path.exists():
                rprint(f"[red]❌ 配置文件不存在: {self.config_path}[/red]")
                rprint("[yellow]请确保 assemble_config.yaml 文件位于项目根目录[/yellow]")
                return False

            with open(self.config_path, "r", encoding="utf-8") as f:
                config = yaml.safe_load(f)

            if not config:
                rprint("[red]❌ 配置文件为空[/red]")
                return False

            # 解析模块
            modules_config = config.get("modules", {})
            if not modules_config:
                rprint("[yellow]⚠️ 配置文件中没有定义任何模块[/yellow]")
                return False

            for name, cfg in modules_config.items():
                self.modules[name] = ModuleInfo(name, cfg)

            # 解析并行任务数
            self.parallel_jobs = config.get("parallel_jobs", MAX_PARALLEL_JOBS)
            # 限制并行数
            cpu_count = os.cpu_count() or 2
            self.parallel_jobs = min(self.parallel_jobs, cpu_count)

            rprint(f"[green]✅ 加载配置成功: {len(self.modules)} 个模块[/green]")
            rprint(f"[dim]   并行编译数: {self.parallel_jobs} (CPU核心: {cpu_count})[/dim]")
            return True

        except yaml.YAMLError as e:
            rprint(f"[red]❌ YAML 解析失败: {e}[/red]")
            logger.error(f"YAML 解析错误: {e}")
            return False
        except Exception as e:
            rprint(f"[red]❌ 加载配置失败: {e}[/red]")
            logger.exception(f"加载配置异常: {e}")
            return False

    def _check_environment(self) -> bool:
        """检查环境依赖"""
        rprint("\n[bold]📋 检查环境依赖...[/bold]")

        deps = {
            "cmake": "cmake --version",
            "g++": "g++ --version",
            "python3": "python3 --version",
            "node": "node --version",
            "npm": "npm --version",
            "redis-server": "redis-server --version",
        }

        # Windows 下使用不同的检测命令
        if SYSTEM == "Windows":
            deps["make"] = "make --version"  # 需要 MinGW 或 WSL

        missing = []
        found = []

        for name, cmd in deps.items():
            try:
                # Windows 下某些命令可能不存在，使用 where
                if SYSTEM == "Windows":
                    check_cmd = f"where {name}" if name != "make" else "where make"
                    result = subprocess.run(
                        check_cmd, shell=True, capture_output=True, text=True, timeout=5
                    )
                    if result.returncode == 0:
                        found.append(name)
                        rprint(f"  [green]✓[/green] {name}: 已安装")
                        continue
                    else:
                        missing.append(name)
                        rprint(f"  [red]✗[/red] {name}: 未找到")
                        continue

                result = subprocess.run(
                    cmd, shell=True, capture_output=True, text=True, timeout=5
                )
                if result.returncode == 0:
                    version = result.stdout.split("\n")[0][:50]
                    found.append(name)
                    rprint(f"  [green]✓[/green] {name}: {version}")
                else:
                    missing.append(name)
                    rprint(f"  [red]✗[/red] {name}: 未找到")
            except (subprocess.TimeoutExpired, FileNotFoundError):
                missing.append(name)
                rprint(f"  [red]✗[/red] {name}: 未找到")
            except Exception as e:
                missing.append(name)
                rprint(f"  [red]✗[/red] {name}: 检查失败 ({e})")

        if missing:
            rprint(f"\n[red]❌ 缺少依赖: {', '.join(missing)}[/red]")
            rprint("[yellow]请安装缺少的依赖后重试[/yellow]")

            # 给出安装建议
            self._print_install_hints(missing)
            return False

        rprint("[green]✅ 环境检查通过[/green]")
        return True

    def _print_install_hints(self, missing: List[str]):
        """打印安装建议"""
        rprint("\n[bold]📖 安装建议:[/bold]")

        for dep in missing:
            if dep == "cmake":
                rprint(f"  [cyan]• {dep}[/cyan]: sudo apt install cmake (Ubuntu) | brew install cmake (macOS)")
            elif dep == "g++":
                rprint(f"  [cyan]• {dep}[/cyan]: sudo apt install g++ (Ubuntu) | brew install gcc (macOS)")
            elif dep == "python3":
                rprint(f"  [cyan]• {dep}[/cyan]: sudo apt install python3 python3-pip (Ubuntu)")
            elif dep == "node":
                rprint(f"  [cyan]• {dep}[/cyan]: curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash - && sudo apt install nodejs")
            elif dep == "npm":
                rprint(f"  [cyan]• {dep}[/cyan]: 随 Node.js 一起安装")
            elif dep == "redis-server":
                rprint(f"  [cyan]• {dep}[/cyan]: sudo apt install redis-server (Ubuntu) | brew install redis (macOS)")
            elif dep == "make":
                rprint(f"  [cyan]• {dep}[/cyan]: sudo apt install make (Ubuntu) | brew install make (macOS)")
            else:
                rprint(f"  [cyan]• {dep}[/cyan]: 请参考项目文档安装")

    def _get_module_order(self) -> List[str]:
        """获取模块构建顺序（拓扑排序）"""
        # 构建依赖图
        in_degree = {name: 0 for name in self.modules}
        graph = {name: [] for name in self.modules}
        enabled_modules = [name for name, m in self.modules.items() if m.enabled]

        if not enabled_modules:
            rprint("[yellow]⚠️ 没有启用的模块[/yellow]")
            return []

        for name, module in self.modules.items():
            if not module.enabled:
                continue
            for dep in module.depends:
                if dep in self.modules and self.modules[dep].enabled:
                    # 避免重复添加依赖边
                    if name not in graph[dep]:
                        graph[dep].append(name)
                        in_degree[name] += 1
                elif dep not in self.modules:
                    # 依赖的模块不存在
                    rprint(f"[yellow]⚠️ 模块 '{name}' 依赖不存在的模块 '{dep}'[/yellow]")
                    self.result.add_skipped(name, f"依赖模块 '{dep}' 不存在")

        # Kahn 算法
        queue = [name for name, degree in in_degree.items() 
                 if degree == 0 and self.modules[name].enabled]
        result = []

        while queue:
            # 按依赖数排序，确保稳定性
            queue.sort()
            node = queue.pop(0)
            result.append(node)
            for neighbor in graph[node]:
                in_degree[neighbor] -= 1
                if in_degree[neighbor] == 0:
                    queue.append(neighbor)

        # 检查循环依赖
        if len(result) < len(enabled_modules):
            remaining = set(enabled_modules) - set(result)
            rprint("[red]❌ 检测到循环依赖或缺失依赖![/red]")
            rprint(f"[red]   未处理的模块: {remaining}[/red]")

            # 打印依赖关系图帮助调试
            for name in remaining:
                deps = self.modules[name].depends
                rprint(f"  [dim]{name} -> {deps}[/dim]")

            # 尝试分析循环依赖
            cycles = self._detect_cycles(graph, enabled_modules)
            if cycles:
                rprint("[yellow]   可能的循环依赖:[/yellow]")
                for cycle in cycles:
                    rprint(f"  [yellow]→ {' → '.join(cycle)}[/yellow]")

            return []

        return result

    def _detect_cycles(self, graph: Dict, modules: List[str]) -> List[List[str]]:
        """检测依赖图中的循环"""
        visited = set()
        cycles = []

        def dfs(node: str, path: List[str]) -> bool:
            if node in path:
                cycle = path[path.index(node):] + [node]
                cycles.append(cycle)
                return True
            if node in visited:
                return False

            visited.add(node)
            path.append(node)

            for neighbor in graph.get(node, []):
                if neighbor in modules:
                    if dfs(neighbor, path):
                        return True

            path.pop()
            return False

        for node in modules:
            if node not in visited:
                dfs(node, [])

        return cycles

    def _build_backend(self, build_dir: Path) -> Tuple[bool, str]:
        """构建后端（CMake）"""
        try:
            build_dir.mkdir(parents=True, exist_ok=True)

            # 检查是否存在 CMakeLists.txt
            cmake_file = build_dir.parent / "CMakeLists.txt"
            if not cmake_file.exists():
                return False, f"CMakeLists.txt 不存在: {cmake_file}"

            # CMake 配置
            cmake_cmd = [
                "cmake",
                "..",
                "-DCMAKE_BUILD_TYPE=Release",
            ]

            # 添加平台特定的编译选项
            if SYSTEM == "Linux":
                cmake_cmd.append("-DCMAKE_CXX_FLAGS=-O3 -march=native")
            elif SYSTEM == "Darwin":
                cmake_cmd.append("-DCMAKE_CXX_FLAGS=-O3 -march=arm64")
            elif SYSTEM == "Windows":
                cmake_cmd.append("-G", "MinGW Makefiles")
                cmake_cmd.append("-DCMAKE_CXX_FLAGS=-O3 -march=native")

            rprint(f"    [dim]配置 CMake: {' '.join(cmake_cmd)}[/dim]")
            if not self.dry_run:
                result = subprocess.run(
                    cmake_cmd,
                    cwd=build_dir,
                    capture_output=True,
                    text=True,
                    timeout=120,
                )
                if result.returncode != 0:
                    logger.error(result.stderr)
                    return False, f"CMake 配置失败\n{result.stderr[:200]}"

            # 编译（根据操作系统选择构建工具）
            if SYSTEM == "Windows":
                make_cmd = ["mingw32-make", "-j", str(self.parallel_jobs)]
            else:
                make_cmd = ["make", "-j", str(self.parallel_jobs)]

            rprint(f"    [dim]编译: {' '.join(make_cmd)}[/dim]")
            if not self.dry_run:
                result = subprocess.run(
                    make_cmd,
                    cwd=build_dir,
                    capture_output=True,
                    text=True,
                    timeout=600,
                )
                if result.returncode != 0:
                    logger.error(result.stderr)
                    return False, f"编译失败\n{result.stderr[:200]}"

            # 检查可执行文件
            exe_name = "ema_trading_system"
            if SYSTEM == "Windows":
                exe_name += ".exe"
            exe_path = build_dir / exe_name

            if not self.dry_run and not exe_path.exists():
                return False, f"可执行文件不存在: {exe_path}"

            return True, "构建成功"

        except subprocess.TimeoutExpired as e:
            return False, f"构建超时 ({e.timeout}秒)"
        except Exception as e:
            return False, f"构建异常: {e}"

    def _build_frontend(self, build_dir: Path) -> Tuple[bool, str]:
        """构建前端（npm）"""
        try:
            frontend_dir = self.project_root / "frontend"

            if not frontend_dir.exists():
                return False, f"前端目录不存在: {frontend_dir}"

            # 检查 package.json
            package_json = frontend_dir / "package.json"
            if not package_json.exists():
                return False, f"package.json 不存在: {package_json}"

            # 安装依赖
            rprint("    [dim]安装 npm 依赖...[/dim]")
            if not self.dry_run:
                result = subprocess.run(
                    ["npm", "install", "--no-fund", "--no-audit"],
                    cwd=frontend_dir,
                    capture_output=True,
                    text=True,
                    timeout=300,
                )
                if result.returncode != 0:
                    logger.error(result.stderr)
                    return False, f"npm install 失败\n{result.stderr[:200]}"

            # 构建
            rprint("    [dim]构建前端...[/dim]")
            if not self.dry_run:
                result = subprocess.run(
                    ["npm", "run", "build"],
                    cwd=frontend_dir,
                    capture_output=True,
                    text=True,
                    timeout=300,
                )
                if result.returncode != 0:
                    logger.error(result.stderr)
                    return False, f"npm build 失败\n{result.stderr[:200]}"

            # 检查构建产物
            dist_dir = frontend_dir / "dist"
            if not self.dry_run and not dist_dir.exists():
                return False, f"前端构建产物不存在: {dist_dir}"

            return True, "构建成功"

        except subprocess.TimeoutExpired as e:
            return False, f"构建超时 ({e.timeout}秒)"
        except Exception as e:
            return False, f"构建异常: {e}"

    def _build_generic(self, module: ModuleInfo, build_dir: Path) -> Tuple[bool, str]:
        """通用构建"""
        try:
            build_dir.mkdir(parents=True, exist_ok=True)

            for cmd in module.build_cmd:
                rprint(f"    [dim]执行: {cmd}[/dim]")
                if not self.dry_run:
                    result = subprocess.run(
                        cmd,
                        shell=True,
                        cwd=build_dir,
                        capture_output=True,
                        text=True,
                        timeout=120,
                    )
                    if result.returncode != 0:
                        logger.error(result.stderr)
                        return False, f"命令失败: {cmd}\n{result.stderr[:200]}"

            return True, "构建成功"

        except subprocess.TimeoutExpired as e:
            return False, f"构建超时 ({e.timeout}秒)"
        except Exception as e:
            return False, f"构建异常: {e}"

    def _run_tests(self, module_name: str) -> Tuple[bool, str]:
        """运行模块测试"""
        module = self.modules.get(module_name)
        if not module or not module.test_cmd:
            return True, "无测试"

        rprint(f"  [yellow]🧪 测试: {module_name}[/yellow]")

        if self.dry_run:
            rprint(f"    [dim]DRY RUN: 跳过测试[/dim]")
            return True, "Dry run"

        try:
            for cmd in module.test_cmd:
                result = subprocess.run(
                    cmd,
                    shell=True,
                    cwd=self.project_root,
                    capture_output=True,
                    text=True,
                    timeout=120,
                )
                if result.returncode != 0:
                    logger.error(result.stderr)
                    return False, f"测试失败: {cmd}\n{result.stderr[:200]}")

            return True, "测试通过"

        except subprocess.TimeoutExpired as e:
            return False, f"测试超时 ({e.timeout}秒)"
        except Exception as e:
            return False, f"测试异常: {e}"

    def _print_summary(self):
        """打印组装摘要"""
        elapsed = self.result.get_elapsed()

        rprint(f"\n[bold cyan]╔{'═' * 70}╗[/bold cyan]")
        rprint(f"[bold cyan]║{' ' * 25}组装完成 {' ' * 25}║[/bold cyan]")
        rprint(f"[bold cyan]╚{'═' * 70}╝[/bold cyan]\n")

        # 如果有跳过或警告，先显示
        if self.result.skipped:
            rprint("[yellow]⚠️ 跳过的模块:[/yellow]")
            for skipped in self.result.skipped:
                rprint(f"  • {skipped}")

        if self.result.warnings:
            rprint("[yellow]⚠️ 警告:[/yellow]")
            for warn in self.result.warnings:
                rprint(f"  • {warn}")

        # 模块结果表格
        table = Table(title="模块组装结果")
        table.add_column("模块", style="cyan", width=20)
        table.add_column("状态", width=12)
        table.add_column("信息", style="dim")

        for name, success, message in self.result.modules:
            status = "[green]✅ 成功[/green]" if success else "[red]❌ 失败[/red]"
            table.add_row(name, status, message[:40] + "..." if len(message) > 40 else message)

        rprint(table)

        # 统计信息
        total = len(self.result.modules)
        failed = len(self.result.errors)
        passed = total - failed

        rprint(f"\n[bold]📊 统计:[/bold]")
        rprint(f"  总模块: {total}")
        rprint(f"  [green]成功: {passed}[/green]")
        rprint(f"  [red]失败: {failed}[/red]")
        rprint(f"  [yellow]跳过: {len(self.result.skipped)}[/yellow]")
        rprint(f"  ⏱️  耗时: {elapsed:.2f} 秒")

        if self.result.errors:
            rprint(f"\n[red]❌ 错误列表:[/red]")
            for err in self.result.errors:
                rprint(f"  • {err}")

        # 给出下一步建议
        rprint(f"\n[bold]📋 下一步:[/bold]")
        if self.result.success:
            rprint("  ✅ 系统组装成功，可以启动运行")
            rprint("  [dim]  ./run.sh[/dim]")
            rprint("  [dim]  cd backend/build && ./ema_trading_system[/dim]")
        else:
            rprint("  ⚠️ 系统组装存在失败，请检查错误信息并修复")
            rprint("  [dim]  检查构建日志: cat build.log[/dim]")
            rprint("  [dim]  重新运行: python3 scripts/assemble.py[/dim]")

    def _check_build_artifacts(self) -> bool:
        """检查构建产物"""
        rprint("\n[bold]📦 检查构建产物...[/bold]")

        artifacts = {
            "后端可执行文件": self.project_root / "backend/build/ema_trading_system",
            "前端构建目录": self.project_root / "frontend/dist",
            "配置文件": self.project_root / "config/params.yaml",
        }

        # Windows 可执行文件后缀
        if SYSTEM == "Windows":
            artifacts["后端可执行文件"] = self.project_root / "backend/build/ema_trading_system.exe"

        all_exist = True
        for name, path in artifacts.items():
            if path.exists():
                if path.is_file():
                    size = path.stat().st_size
                    size_str = f"{size / 1024:.1f} KB" if size < 1024 * 1024 else f"{size / (1024*1024):.1f} MB"
                    rprint(f"  [green]✓[/green] {name}: {path} ({size_str})")
                else:
                    # 目录
                    count = len(list(path.glob("*"))) if path.exists() else 0
                    rprint(f"  [green]✓[/green] {name}: {path} ({count} 文件)")
            else:
                rprint(f"  [yellow]⚠[/yellow] {name}: {path} (不存在，可能未构建)")
                all_exist = False

        return all_exist

    def run(self) -> int:
        """执行组装"""
        self._print_header()

        # 1. 加载配置
        if not self._load_config():
            return 1

        # 2. 检查环境
        if not self._check_environment():
            return 1

        # 3. 获取模块顺序
        module_order = self._get_module_order()
        if not module_order:
            return 1

        rprint(f"\n[bold]📋 模块构建顺序: {', '.join(module_order)}[/bold]\n")

        # 4. 构建模块
        with Progress(
            SpinnerColumn(),
            TextColumn("[progress.description]{task.description}"),
            BarColumn(),
            TextColumn("[progress.percentage]{task.percentage:>3.0f}%"),
            console=self.console,
        ) as progress:
            task = progress.add_task("[cyan]组装中...", total=len(module_order))

            for module_name in module_order:
                module = self.modules.get(module_name)

                # 跳过禁用的模块
                if not module or not module.enabled:
                    rprint(f"  [yellow]⏭️ 跳过: {module_name} (已禁用)[/yellow]")
                    self.result.add_skipped(module_name, "模块已禁用")
                    progress.update(task, advance=1)
                    continue

                # 构建
                build_dir = self.project_root / (module.build_dir or f"build/{module_name}")

                if "backend" in module_name.lower() or module_name == "core":
                    success, message = self._build_backend(build_dir)
                elif "frontend" in module_name.lower():
                    success, message = self._build_frontend(build_dir)
                else:
                    success, message = self._build_generic(module, build_dir)

                self.result.add_module_result(module_name, success, message)

                if not success:
                    rprint(f"  [red]❌ 构建失败: {module_name} - {message}[/red]")
                    progress.update(task, advance=1)
                    continue

                # 测试
                if not self.dry_run:
                    test_success, test_message = self._run_tests(module_name)
                    if not test_success:
                        self.result.warnings.append(f"{module_name}: {test_message}")

                progress.update(task, advance=1)

        # 5. 检查构建产物
        self._check_build_artifacts()

        # 6. 记录结束时间
        self.result.end_time = time.time()

        # 7. 打印摘要
        self._print_summary()

        return 0 if self.result.success else 1


# ==================== 模块自测 ====================
def run_assemble(config_path: str = DEFAULT_CONFIG_PATH, dry_run: bool = False, verbose: bool = False) -> bool:
    """
    执行组装流程

    Args:
        config_path: 配置文件路径
        dry_run: 是否为模拟运行
        verbose: 是否详细输出

    Returns:
        bool: 是否成功
    """
    assembler = Assembler(config_path, dry_run)
    if verbose:
        assembler.set_verbose(True)
    return assembler.run() == 0


def main() -> int:
    """命令行入口"""
    parser = argparse.ArgumentParser(
        description="EMA 量化交易系统自动组装脚本",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  %(prog)s                      # 完整组装
  %(prog)s --dry-run            # 仅显示步骤
  %(prog)s --skip-tests         # 跳过测试
  %(prog)s --config custom.yaml # 使用自定义配置
        """,
    )
    parser.add_argument(
        "--config",
        default=DEFAULT_CONFIG_PATH,
        help=f"配置文件路径 (默认: {DEFAULT_CONFIG_PATH})",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="模拟运行，不实际执行构建",
    )
    parser.add_argument(
        "--skip-tests",
        action="store_true",
        help="跳过测试运行",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="详细输出",
    )

    args = parser.parse_args()

    try:
        assembler = Assembler(args.config, args.dry_run)
        if args.verbose:
            assembler.set_verbose(True)

        # 如果跳过测试，清空所有模块的测试命令
        if args.skip_tests:
            for module in assembler.modules.values():
                module.test_cmd = []

        return assembler.run()

    except KeyboardInterrupt:
        rprint("\n[yellow]⚠️ 用户中断[/yellow]")
        return 130
    except Exception as e:
        rprint(f"\n[red]❌ 未预期错误: {e}[/red]")
        if args.verbose:
            import traceback
            traceback.print_exc()
        return 1


if __name__ == "__main__":
    sys.exit(main())
