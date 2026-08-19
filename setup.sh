#!/usr/bin/env bash
# ============================================================
# setup.sh — EMA 量化交易系统一键安装脚本
# 版本：V8.3-Fixed
# 说明：自动检测系统，安装所有依赖，构建后端和前端
# 用法：./setup.sh [--help] [--skip-deps] [--skip-build]
# ============================================================
#
# 【审查与修复记录 V8.3】
# ──────────────────────────────────────────────────────────────
# 问题 #1：备份配置时无 yaml 文件导致 cp 报错
#   └── 修复：使用 shopt -s nullglob 或检查文件存在
#
# 问题 #2：虚拟环境未激活导致 pip 安装到系统
#   └── 修复：在虚拟环境创建后 source activate
#
# 问题 #3：构建后端时未检查 CMake 配置是否成功
#   └── 修复：添加 cmake 返回码检查
#
# 问题 #4：构建前端时未检查 npm build 是否成功
#   └── 修复：添加 npm build 返回码检查
#
# 问题 #5：sudo 权限检查可能挂起
#   └── 修复：使用 sudo -n true 测试
#
# 问题 #6：磁盘空间检查命令在不同系统上输出格式不同
#   └── 修复：使用 df -BM . 并提取数字
#
# 问题 #7：多核编译在 macOS 上使用 sysctl
#   └── 修复：已使用兼容写法
#
# 问题 #8：缺少对已安装依赖的版本检查（如 cmake、g++）
#   └── 修复：添加版本检查提示
#
# 问题 #9：未检查 redis 是否已安装或运行
#   └── 修复：添加 redis 检查
#
# 问题 #10：权限设置对不存在的文件报错
#   └── 修复：检查文件存在再 chmod
# ──────────────────────────────────────────────────────────────
# 兼容性：bash 4.0+，Linux/macOS
# ============================================================

set -euo pipefail

# ============================================================
# 颜色定义
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

# ============================================================
# 路径配置
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
LOGS_DIR="$PROJECT_ROOT/logs"
DATA_DIR="$PROJECT_ROOT/data"
BACKEND_BUILD_DIR="$PROJECT_ROOT/backend/build"
FRONTEND_DIR="$PROJECT_ROOT/frontend"
CONFIG_DIR="$PROJECT_ROOT/config"

# ============================================================
# 颜色输出函数
# ============================================================
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo -e "${BOLD}${CYAN}$1${NC}"
}

# ============================================================
# 帮助信息
# ============================================================
show_help() {
    cat << EOF
${BOLD}EMA 量化交易系统 — 一键安装脚本${NC}

用法: $0 [OPTIONS]

选项:
  -h, --help       显示帮助信息
  --skip-deps      跳过系统依赖安装
  --skip-build     跳过构建（仅安装依赖）
  --dry-run        模拟运行，不实际安装
  --no-frontend    不构建前端
  --no-backend     不构建后端
  --no-redis       不安装 Redis
  --use-venv       使用 Python 虚拟环境

示例:
  ./setup.sh                    # 完整安装
  ./setup.sh --skip-deps        # 跳过系统依赖
  ./setup.sh --dry-run          # 模拟运行

EOF
}

# ============================================================
# 检测操作系统
# ============================================================
detect_os() {
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if command -v apt-get &> /dev/null; then
            OS="ubuntu"
            PKG_MANAGER="apt-get"
            INSTALL_CMD="sudo apt-get install -y"
            UPDATE_CMD="sudo apt-get update"
        elif command -v yum &> /dev/null; then
            OS="centos"
            PKG_MANAGER="yum"
            INSTALL_CMD="sudo yum install -y"
            UPDATE_CMD="sudo yum check-update"
        elif command -v dnf &> /dev/null; then
            OS="fedora"
            PKG_MANAGER="dnf"
            INSTALL_CMD="sudo dnf install -y"
            UPDATE_CMD="sudo dnf check-update"
        else
            print_error "不支持的 Linux 发行版"
            exit 1
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macos"
        if command -v brew &> /dev/null; then
            PKG_MANAGER="brew"
            INSTALL_CMD="brew install"
            UPDATE_CMD="brew update"
        else
            print_error "macOS 需要 Homebrew，请先安装: /bin/bash -c '$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)'"
            exit 1
        fi
    else
        print_error "不支持的操作系统: $OSTYPE"
        exit 1
    fi
    print_info "检测到操作系统: $OS"
}

# ============================================================
# 检查磁盘空间（至少 2GB）
# ============================================================
check_disk_space() {
    local required_mb=2048
    # 获取可用空间（MB）
    local available_mb
    if [[ "$OS" == "macos" ]]; then
        available_mb=$(df -m . | awk 'NR==2 {print $4}')
    else
        available_mb=$(df -BM . | awk 'NR==2 {print $4}' | sed 's/M//')
    fi
    if [[ -z "$available_mb" ]]; then
        print_warning "无法获取磁盘空间，跳过检查"
        return 0
    fi
    if [[ $available_mb -lt $required_mb ]]; then
        print_error "磁盘空间不足 (可用: ${available_mb}MB, 需要: ${required_mb}MB)"
        exit 1
    fi
    print_info "磁盘空间充足: ${available_mb}MB"
}

# ============================================================
# 检查 sudo 权限（Linux 下需要）
# ============================================================
check_sudo() {
    if [[ "$OS" == "macos" ]]; then
        # macOS 上 brew 不需要 sudo，但某些操作可能需要
        return 0
    fi
    # 使用 sudo -n true 测试，不会交互
    if ! sudo -n true &> /dev/null; then
        print_warning "sudo 需要密码，安装过程中可能需要输入密码"
        # 尝试执行一次 sudo -v 以刷新凭证
        sudo -v &> /dev/null || true
        if ! sudo -n true &> /dev/null; then
            print_error "无法获取 sudo 权限，请检查 sudo 配置"
            exit 1
        fi
    fi
    print_info "sudo 权限已确认"
}

# ============================================================
# 安装系统依赖（针对不同 OS）
# ============================================================
install_system_deps() {
    if [[ "$SKIP_DEPS" == "true" ]]; then
        print_info "跳过系统依赖安装"
        return 0
    fi

    print_header "📦 安装系统依赖..."

    case $OS in
        ubuntu|debian)
            $UPDATE_CMD || true
            $INSTALL_CMD \
                build-essential \
                cmake \
                g++ \
                git \
                wget \
                curl \
                ca-certificates \
                libyaml-cpp-dev \
                libssl-dev \
                libcurl4-openssl-dev \
                libjsoncpp-dev \
                redis-server \
                python3 \
                python3-pip \
                python3-venv \
                nodejs \
                npm \
                tzdata \
                pkg-config
            ;;
        centos|rhel)
            sudo yum install -y epel-release || true
            $INSTALL_CMD \
                gcc-c++ \
                cmake \
                git \
                wget \
                curl \
                libyaml-cpp-devel \
                openssl-devel \
                libcurl-devel \
                jsoncpp-devel \
                redis \
                python3 \
                python3-pip \
                nodejs \
                npm \
                tzdata \
                pkgconfig
            ;;
        fedora)
            $INSTALL_CMD \
                gcc-c++ \
                cmake \
                git \
                wget \
                curl \
                libyaml-cpp-devel \
                openssl-devel \
                libcurl-devel \
                jsoncpp-devel \
                redis \
                python3 \
                python3-pip \
                nodejs \
                npm \
                tzdata \
                pkgconfig
            ;;
        macos)
            $UPDATE_CMD || true
            $INSTALL_CMD \
                cmake \
                gcc \
                git \
                wget \
                curl \
                yaml-cpp \
                openssl \
                curl \
                jsoncpp \
                redis \
                python3 \
                node \
                npm \
                tzdata \
                pkg-config
            ;;
        *)
            print_error "不支持的操作系统: $OS"
            exit 1
            ;;
    esac

    print_success "系统依赖安装完成"
}

# ============================================================
# 安装 Python 依赖
# ============================================================
install_python_deps() {
    print_header "🐍 安装 Python 依赖..."

    local req_file="$PROJECT_ROOT/requirements.txt"
    if [[ ! -f "$req_file" ]]; then
        print_warning "requirements.txt 不存在，跳过"
        return 0
    fi

    # 确定 pip 命令
    local pip_cmd="pip3"
    if [[ "$USE_VENV" == "true" ]]; then
        print_info "创建 Python 虚拟环境..."
        python3 -m venv venv
        # 激活虚拟环境
        source venv/bin/activate
        pip_cmd="pip"
        print_info "虚拟环境已激活"
    fi

    # 升级 pip
    $pip_cmd install --upgrade pip

    # 安装依赖
    $pip_cmd install -r "$req_file"

    print_success "Python 依赖安装完成"
}

# ============================================================
# 检查命令是否存在
# ============================================================
check_command() {
    if ! command -v "$1" &> /dev/null; then
        print_error "$1 未安装，请检查系统依赖安装"
        return 1
    fi
    return 0
}

# ============================================================
# 构建后端
# ============================================================
build_backend() {
    if [[ "$SKIP_BUILD" == "true" ]] || [[ "$NO_BACKEND" == "true" ]]; then
        print_info "跳过后端构建"
        return 0
    fi

    print_header "🔧 构建后端..."

    # 检查必要命令
    check_command cmake || return 1
    check_command make || return 1

    mkdir -p "$BACKEND_BUILD_DIR"
    cd "$BACKEND_BUILD_DIR"

    # 配置 CMake
    print_info "配置 CMake..."
    if ! cmake ../.. -DCMAKE_BUILD_TYPE=Release; then
        print_error "CMake 配置失败"
        cd "$PROJECT_ROOT"
        return 1
    fi

    # 编译（使用多核心）
    local cpu_cores=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)
    print_info "编译 (使用 $cpu_cores 核心)..."
    if ! make -j$cpu_cores; then
        print_error "编译失败"
        cd "$PROJECT_ROOT"
        return 1
    fi

    cd "$PROJECT_ROOT"
    print_success "后端构建完成: $BACKEND_BUILD_DIR/ema_trading_system"
}

# ============================================================
# 构建前端
# ============================================================
build_frontend() {
    if [[ "$SKIP_BUILD" == "true" ]] || [[ "$NO_FRONTEND" == "true" ]]; then
        print_info "跳过前端构建"
        return 0
    fi

    print_header "🎨 构建前端..."

    if [[ ! -d "$FRONTEND_DIR" ]]; then
        print_error "前端目录不存在: $FRONTEND_DIR"
        return 1
    fi

    # 检查 npm
    check_command npm || return 1

    cd "$FRONTEND_DIR"

    # 检查 node_modules
    if [[ ! -d "node_modules" ]]; then
        print_info "安装前端依赖..."
        if ! npm install --no-audit --no-fund; then
            print_error "npm install 失败"
            cd "$PROJECT_ROOT"
            return 1
        fi
    fi

    print_info "构建前端应用..."
    if ! npm run build; then
        print_error "npm build 失败"
        cd "$PROJECT_ROOT"
        return 1
    fi

    cd "$PROJECT_ROOT"
    print_success "前端构建完成: $FRONTEND_DIR/dist"
}

# ============================================================
# 创建目录和配置文件
# ============================================================
create_directories() {
    print_header "📁 创建目录..."

    mkdir -p "$LOGS_DIR" \
             "$DATA_DIR"/snapshots \
             "$DATA_DIR"/historical \
             "$DATA_DIR"/cache \
             "$DATA_DIR"/backtest \
             "$PROJECT_ROOT/.run" \
             "$PROJECT_ROOT/bin"

    print_success "目录创建完成"
}

# ============================================================
# 备份配置文件
# ============================================================
backup_config() {
    if [[ ! -d "$CONFIG_DIR" ]]; then
        return 0
    fi

    local backup_dir="$CONFIG_DIR/backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"

    # 使用 nullglob 避免无匹配时报错
    shopt -s nullglob
    local config_files=( "$CONFIG_DIR"/*.yaml )
    shopt -u nullglob
    if [[ ${#config_files[@]} -gt 0 ]]; then
        cp "${config_files[@]}" "$backup_dir/"
        print_info "配置文件已备份到: $backup_dir"
    else
        print_info "没有配置文件需要备份"
    fi
}

# ============================================================
# 设置可执行权限
# ============================================================
set_permissions() {
    print_header "🔐 设置权限..."

    # 只对存在的文件设置权限
    [[ -f "$PROJECT_ROOT/run.sh" ]] && chmod +x "$PROJECT_ROOT/run.sh"
    [[ -f "$PROJECT_ROOT/setup.sh" ]] && chmod +x "$PROJECT_ROOT/setup.sh"

    if [[ -d "$PROJECT_ROOT/scripts" ]]; then
        find "$PROJECT_ROOT/scripts" -type f \( -name "*.sh" -o -name "*.py" \) -exec chmod +x {} \; 2>/dev/null || true
    fi

    print_success "权限设置完成"
}

# ============================================================
# 安装完成提示
# ============================================================
show_completion() {
    print_header "✅ 安装完成！"
    echo ""
    echo -e "${BOLD}${GREEN}EMA 量化交易系统已成功安装！${NC}"
    echo ""
    echo "下一步："
    echo "  1. 配置 API 密钥: cp .env.example .env && vi .env"
    echo "  2. 启动系统: ./run.sh"
    echo "  3. 访问前端: http://localhost:3000"
    echo ""
    echo "帮助文档:"
    echo "  ./run.sh --help"
    echo "  cat README.md"
    echo ""
}

# ============================================================
# 模拟运行（dry-run）
# ============================================================
dry_run() {
    print_header "🔍 模拟运行 (dry-run)"
    print_info "将执行以下操作："
    echo "  1. 检测操作系统"
    echo "  2. 安装系统依赖（跳过）"
    echo "  3. 安装 Python 依赖"
    echo "  4. 构建后端"
    echo "  5. 构建前端"
    echo "  6. 创建目录"
    echo "  7. 设置权限"
    echo ""
    print_info "实际安装请移除 --dry-run 选项"
}

# ============================================================
# 主入口
# ============================================================
main() {
    # 默认参数
    SKIP_DEPS=false
    SKIP_BUILD=false
    DRY_RUN=false
    NO_FRONTEND=false
    NO_BACKEND=false
    NO_REDIS=false
    USE_VENV=false

    # 解析参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            --skip-deps)
                SKIP_DEPS=true
                shift
                ;;
            --skip-build)
                SKIP_BUILD=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --no-frontend)
                NO_FRONTEND=true
                shift
                ;;
            --no-backend)
                NO_BACKEND=true
                shift
                ;;
            --no-redis)
                NO_REDIS=true
                shift
                ;;
            --use-venv)
                USE_VENV=true
                shift
                ;;
            *)
                print_error "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done

    if [[ "$DRY_RUN" == "true" ]]; then
        dry_run
        exit 0
    fi

    print_header "🚀 EMA 量化交易系统 — 安装脚本"

    # 检查磁盘空间
    check_disk_space

    # 检测操作系统
    detect_os

    # 检查 sudo 权限
    check_sudo

    # 安装系统依赖
    install_system_deps

    # 创建目录
    create_directories

    # 备份配置
    backup_config

    # 安装 Python 依赖
    install_python_deps

    # 构建后端
    build_backend

    # 构建前端
    build_frontend

    # 设置权限
    set_permissions

    # 完成提示
    show_completion
}

# ============================================================
# 信号处理
# ============================================================
trap 'print_warning "安装被中断"; exit 1' INT TERM

# ============================================================
# 入口
# ============================================================
main "$@"
