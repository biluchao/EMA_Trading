#!/usr/bin/env bash
# ============================================================
# run.sh — EMA 量化交易系统一键启动脚本
# 版本：V8.2-Fixed
# 说明：启动后端服务 + 前端服务 + Redis
# 用法：./run.sh [start|stop|restart|status|logs]
# ============================================================
#
# 【审查与修复记录】
# ──────────────────────────────────────────────────────────────
# 问题 #1：未检查脚本依赖（如 redis-server、npm、python3）
#   └── 修复：添加依赖检查函数
#
# 问题 #2：未检查配置文件是否存在
#   └── 修复：添加配置文件检查
#
# 问题 #3：启动服务时未记录 PID，无法准确停止
#   └── 修复：使用 PID 文件管理进程
#
# 问题 #4：未处理信号（Ctrl+C），导致子进程残留
#   └── 修复：使用 trap 捕获信号
#
# 问题 #5：未区分开发模式和调试模式
#   └── 修复：添加 --debug 和 --dev 参数
#
# 问题 #6：跨平台兼容性（macOS/Linux/WSL）
#   └── 修复：检测操作系统，适配不同命令
#
# 问题 #7：未检查端口占用
#   └── 修复：启动前检查端口是否被占用
#
# 问题 #8：未显示启动状态和访问地址
#   └── 修复：启动后显示服务状态和访问地址
#
# 问题 #9：未支持后台运行（daemon）
#   └── 修复：添加 -d 参数支持后台运行
#
# 问题 #10：未检查后端可执行文件是否存在
#   └── 修复：添加可执行文件检查，提示构建
# ──────────────────────────────────────────────────────────────
# 兼容性：bash 4.0+，Linux/macOS/WSL
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
NC='\033[0m' # No Color
BOLD='\033[1m'

# ============================================================
# 路径配置
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
BACKEND_BIN="$PROJECT_ROOT/backend/build/ema_trading_system"
FRONTEND_DIR="$PROJECT_ROOT/frontend"
CONFIG_DIR="$PROJECT_ROOT/config"
PID_DIR="$PROJECT_ROOT/.run"
BACKEND_PID_FILE="$PID_DIR/backend.pid"
FRONTEND_PID_FILE="$PID_DIR/frontend.pid"
REDIS_PID_FILE="$PID_DIR/redis.pid"
LOGS_DIR="$PROJECT_ROOT/logs"
BACKEND_LOG="$LOGS_DIR/backend.log"
FRONTEND_LOG="$LOGS_DIR/frontend.log"
REDIS_LOG="$LOGS_DIR/redis.log"

# ============================================================
# 端口配置
# ============================================================
BACKEND_PORT=${BACKEND_PORT:-8080}
FRONTEND_PORT=${FRONTEND_PORT:-3000}
REDIS_PORT=${REDIS_PORT:-6379}

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
${BOLD}EMA 量化交易系统 — 一键启动脚本${NC}

用法: $0 [OPTIONS] [COMMAND]

命令:
  start     启动所有服务（默认）
  stop      停止所有服务
  restart   重启所有服务
  status    查看服务状态
  logs      查看日志

选项:
  -h, --help       显示帮助信息
  -d, --daemon     后台运行（守护进程模式）
  --dev            开发模式（使用 npm run dev 替代 npm start）
  --debug          调试模式（显示详细日志）
  --no-redis       不启动 Redis（使用外部 Redis）
  --no-frontend    不启动前端
  --no-backend     不启动后端

示例:
  ./run.sh                     # 前台启动所有服务
  ./run.sh -d                  # 后台启动所有服务
  ./run.sh --dev               # 开发模式启动
  ./run.sh stop                # 停止所有服务
  ./run.sh status              # 查看服务状态
  ./run.sh logs                # 查看日志

EOF
}

# ============================================================
# 检查依赖
# ============================================================
check_dependencies() {
    local missing=0

    # 检查 redis-server
    if ! command -v redis-server &> /dev/null; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            print_warning "redis-server 未安装，请运行: brew install redis"
        elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
            print_warning "redis-server 未安装，请运行: sudo apt install redis-server"
        else
            print_warning "redis-server 未安装"
        fi
        missing=1
    fi

    # 检查 node
    if ! command -v node &> /dev/null; then
        print_warning "node 未安装，请从 https://nodejs.org 下载安装"
        missing=1
    fi

    # 检查 npm
    if ! command -v npm &> /dev/null; then
        print_warning "npm 未安装"
        missing=1
    fi

    # 检查 python3
    if ! command -v python3 &> /dev/null; then
        print_warning "python3 未安装，请安装 Python 3.8+"
        missing=1
    fi

    if [[ $missing -eq 1 ]]; then
        print_error "缺少必要依赖，请安装后重试"
        return 1
    fi

    return 0
}

# ============================================================
# 检查配置文件
# ============================================================
check_config() {
    if [[ ! -f "$CONFIG_DIR/params.yaml" ]]; then
        print_error "配置文件不存在: $CONFIG_DIR/params.yaml"
        print_info "请从 config/params.yaml.example 复制并配置"
        return 1
    fi

    if [[ ! -f "$CONFIG_DIR/exchange.yaml" ]]; then
        print_warning "交易所配置文件不存在: $CONFIG_DIR/exchange.yaml"
        print_info "请从 config/exchange.yaml.example 复制并配置"
    fi

    return 0
}

# ============================================================
# 检查后端可执行文件
# ============================================================
check_backend_binary() {
    if [[ ! -f "$BACKEND_BIN" ]]; then
        print_warning "后端可执行文件不存在: $BACKEND_BIN"
        print_info "正在尝试构建后端..."
        if [[ -f "$PROJECT_ROOT/scripts/build.sh" ]]; then
            bash "$PROJECT_ROOT/scripts/build.sh" --backend-only
        elif [[ -f "$PROJECT_ROOT/assemble.py" ]]; then
            python3 "$PROJECT_ROOT/assemble.py" --skip-frontend
        else
            print_error "无法自动构建，请手动构建后端"
            print_info "   cd backend && mkdir build && cd build && cmake .. && make"
            return 1
        fi
        return $?
    fi
    return 0
}

# ============================================================
# 检查端口占用
# ============================================================
check_port() {
    local port=$1
    if command -v lsof &> /dev/null; then
        if lsof -Pi :$port -sTCP:LISTEN &> /dev/null; then
            return 0
        fi
    elif command -v netstat &> /dev/null; then
        if netstat -tuln 2>/dev/null | grep -q ":$port "; then
            return 0
        fi
    fi
    return 1
}

# ============================================================
# PID 管理
# ============================================================
ensure_pid_dir() {
    mkdir -p "$PID_DIR"
    mkdir -p "$LOGS_DIR"
}

write_pid() {
    local pid_file=$1
    local pid=$2
    echo "$pid" > "$pid_file"
}

read_pid() {
    local pid_file=$1
    if [[ -f "$pid_file" ]]; then
        cat "$pid_file"
    else
        echo ""
    fi
}

is_running() {
    local pid=$1
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        return 0
    fi
    return 1
}

# ============================================================
# 服务管理
# ============================================================

# 启动 Redis
start_redis() {
    if [[ "$SKIP_REDIS" == "true" ]]; then
        print_info "跳过 Redis（使用外部 Redis）"
        return 0
    fi

    if check_port $REDIS_PORT; then
        print_info "Redis 已在运行 (端口 $REDIS_PORT)"
        return 0
    fi

    print_info "启动 Redis (端口 $REDIS_PORT)..."
    if [[ "$DAEMON_MODE" == "true" ]]; then
        redis-server --daemonize yes --port $REDIS_PORT --logfile "$REDIS_LOG" --pidfile "$REDIS_PID_FILE"
        sleep 2
        if check_port $REDIS_PORT; then
            print_success "Redis 启动成功 (PID: $(cat $REDIS_PID_FILE 2>/dev/null || echo 'unknown'))"
        else
            print_error "Redis 启动失败，请检查日志: $REDIS_LOG"
            return 1
        fi
    else
        redis-server --port $REDIS_PORT &
        local redis_pid=$!
        write_pid "$REDIS_PID_FILE" "$redis_pid"
        sleep 2
        if check_port $REDIS_PORT; then
            print_success "Redis 启动成功 (PID: $redis_pid)"
        else
            print_error "Redis 启动失败"
            return 1
        fi
    fi
    return 0
}

# 启动后端
start_backend() {
    if [[ "$SKIP_BACKEND" == "true" ]]; then
        print_info "跳过后端服务"
        return 0
    fi

    if ! check_backend_binary; then
        return 1
    fi

    if check_port $BACKEND_PORT; then
        print_info "后端服务已在运行 (端口 $BACKEND_PORT)"
        return 0
    fi

    print_info "启动后端服务 (端口 $BACKEND_PORT)..."

    # 构建启动命令
    local cmd="$BACKEND_BIN --config $CONFIG_DIR/params.yaml"

    if [[ "$DEBUG_MODE" == "true" ]]; then
        cmd="$cmd --debug"
    fi

    if [[ "$DAEMON_MODE" == "true" ]]; then
        nohup $cmd >> "$BACKEND_LOG" 2>&1 &
        local backend_pid=$!
        write_pid "$BACKEND_PID_FILE" "$backend_pid"
        sleep 3
        if check_port $BACKEND_PORT; then
            print_success "后端服务启动成功 (PID: $backend_pid)"
        else
            print_error "后端服务启动失败，请检查日志: $BACKEND_LOG"
            return 1
        fi
    else
        $cmd &
        local backend_pid=$!
        write_pid "$BACKEND_PID_FILE" "$backend_pid"
        sleep 3
        if check_port $BACKEND_PORT; then
            print_success "后端服务启动成功 (PID: $backend_pid)"
        else
            print_error "后端服务启动失败"
            return 1
        fi
    fi
    return 0
}

# 启动前端
start_frontend() {
    if [[ "$SKIP_FRONTEND" == "true" ]]; then
        print_info "跳过前端服务"
        return 0
    fi

    if [[ ! -d "$FRONTEND_DIR" ]]; then
        print_error "前端目录不存在: $FRONTEND_DIR"
        return 1
    fi

    if check_port $FRONTEND_PORT; then
        print_info "前端服务已在运行 (端口 $FRONTEND_PORT)"
        return 0
    fi

    print_info "启动前端服务 (端口 $FRONTEND_PORT)..."

    cd "$FRONTEND_DIR"

    # 检查 node_modules
    if [[ ! -d "node_modules" ]]; then
        print_info "安装前端依赖..."
        npm install --no-audit --no-fund
    fi

    local cmd=""
    if [[ "$DEV_MODE" == "true" ]]; then
        cmd="npm run dev"
    else
        # 检查是否已构建
        if [[ ! -d "dist" ]]; then
            print_info "构建前端..."
            npm run build
        fi
        # 使用 serve 或 preview 提供静态文件
        if command -v serve &> /dev/null; then
            cmd="serve -s dist -l $FRONTEND_PORT"
        else
            # 使用 npm preview 或 serve 命令
            if grep -q '"preview"' package.json; then
                cmd="npm run preview -- --port $FRONTEND_PORT"
            else
                # 使用 npx serve
                cmd="npx serve -s dist -l $FRONTEND_PORT"
            fi
        fi
    fi

    if [[ "$DAEMON_MODE" == "true" ]]; then
        nohup $cmd >> "$FRONTEND_LOG" 2>&1 &
        local frontend_pid=$!
        write_pid "$FRONTEND_PID_FILE" "$frontend_pid"
        sleep 3
        if check_port $FRONTEND_PORT; then
            print_success "前端服务启动成功 (PID: $frontend_pid)"
        else
            print_warning "前端服务可能未完全启动，请检查日志: $FRONTEND_LOG"
        fi
    else
        $cmd &
        local frontend_pid=$!
        write_pid "$FRONTEND_PID_FILE" "$frontend_pid"
        sleep 3
        if check_port $FRONTEND_PORT; then
            print_success "前端服务启动成功 (PID: $frontend_pid)"
        else
            print_warning "前端服务可能未完全启动"
        fi
    fi

    cd "$PROJECT_ROOT"
    return 0
}

# ============================================================
# 停止服务
# ============================================================
stop_service() {
    local pid_file=$1
    local service_name=$2
    local pid=$(read_pid "$pid_file")

    if [[ -n "$pid" ]] && is_running "$pid"; then
        print_info "停止 $service_name (PID: $pid)..."
        kill -TERM "$pid" 2>/dev/null || true
        # 等待进程退出
        for i in {1..10}; do
            if ! is_running "$pid"; then
                break
            fi
            sleep 1
        done
        if is_running "$pid"; then
            print_warning "$service_name 未响应，强制停止..."
            kill -KILL "$pid" 2>/dev/null || true
        fi
        rm -f "$pid_file"
        print_success "$service_name 已停止"
    else
        print_info "$service_name 未运行"
        rm -f "$pid_file"
    fi
}

stop_all() {
    print_header "停止所有服务..."

    # 停止顺序：前端 → 后端 → Redis
    stop_service "$FRONTEND_PID_FILE" "前端服务"
    stop_service "$BACKEND_PID_FILE" "后端服务"
    stop_service "$REDIS_PID_FILE" "Redis"

    print_success "所有服务已停止"
}

# ============================================================
# 查看状态
# ============================================================
show_status() {
    print_header "服务状态"

    # Redis
    local redis_pid=$(read_pid "$REDIS_PID_FILE")
    if is_running "$redis_pid"; then
        echo -e "  ${GREEN}●${NC} Redis: 运行中 (PID: $redis_pid, 端口: $REDIS_PORT)"
    elif check_port $REDIS_PORT; then
        echo -e "  ${YELLOW}●${NC} Redis: 运行中（外部进程，端口 $REDIS_PORT）"
    else
        echo -e "  ${RED}●${NC} Redis: 未运行"
    fi

    # 后端
    local backend_pid=$(read_pid "$BACKEND_PID_FILE")
    if is_running "$backend_pid"; then
        echo -e "  ${GREEN}●${NC} 后端服务: 运行中 (PID: $backend_pid, 端口: $BACKEND_PORT)"
    elif check_port $BACKEND_PORT; then
        echo -e "  ${YELLOW}●${NC} 后端服务: 运行中（外部进程，端口 $BACKEND_PORT）"
    else
        echo -e "  ${RED}●${NC} 后端服务: 未运行"
    fi

    # 前端
    local frontend_pid=$(read_pid "$FRONTEND_PID_FILE")
    if is_running "$frontend_pid"; then
        echo -e "  ${GREEN}●${NC} 前端服务: 运行中 (PID: $frontend_pid, 端口: $FRONTEND_PORT)"
    elif check_port $FRONTEND_PORT; then
        echo -e "  ${YELLOW}●${NC} 前端服务: 运行中（外部进程，端口 $FRONTEND_PORT）"
    else
        echo -e "  ${RED}●${NC} 前端服务: 未运行"
    fi

    echo ""
    echo "访问地址:"
    echo "  🌐 前端: http://localhost:$FRONTEND_PORT"
    echo "  🔌 后端 API: http://localhost:$BACKEND_PORT/api"
    echo "  📊 健康检查: http://localhost:$BACKEND_PORT/api/health"
}

# ============================================================
# 查看日志
# ============================================================
show_logs() {
    local service=$1
    case "$service" in
        backend)
            tail -f "$BACKEND_LOG" 2>/dev/null || echo "后端日志不存在"
            ;;
        frontend)
            tail -f "$FRONTEND_LOG" 2>/dev/null || echo "前端日志不存在"
            ;;
        redis)
            tail -f "$REDIS_LOG" 2>/dev/null || echo "Redis日志不存在"
            ;;
        *)
            echo "用法: $0 logs [backend|frontend|redis]"
            ;;
    esac
}

# ============================================================
# 启动所有服务
# ============================================================
start_all() {
    print_header "🚀 EMA 量化交易系统启动"

    # 检查环境和配置
    if ! check_dependencies; then
        return 1
    fi
    if ! check_config; then
        return 1
    fi

    ensure_pid_dir

    # 启动服务
    start_redis || return 1
    start_backend || return 1
    start_frontend || return 1

    echo ""
    print_success "所有服务已启动！"
    echo ""
    echo "访问地址:"
    echo "  🌐 前端: http://localhost:$FRONTEND_PORT"
    echo "  🔌 后端 API: http://localhost:$BACKEND_PORT/api"
    echo "  📊 健康检查: http://localhost:$BACKEND_PORT/api/health"
    echo ""
    print_warning "按 Ctrl+C 停止所有服务"

    # 如果是前台模式，等待信号
    if [[ "$DAEMON_MODE" != "true" ]]; then
        # 设置信号处理
        trap stop_all EXIT INT TERM
        # 等待所有子进程退出
        wait
    fi
}

# ============================================================
# 信号处理
# ============================================================
cleanup() {
    print_info "正在清理..."
    stop_all
    exit 0
}

# ============================================================
# 主入口
# ============================================================
main() {
    # 默认参数
    DAEMON_MODE=false
    DEV_MODE=false
    DEBUG_MODE=false
    SKIP_REDIS=false
    SKIP_BACKEND=false
    SKIP_FRONTEND=false
    COMMAND="start"
    LOG_SERVICE=""

    # 解析参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            start|stop|restart|status|logs)
                COMMAND="$1"
                if [[ "$1" == "logs" ]] && [[ $# -gt 1 ]]; then
                    shift
                    LOG_SERVICE="$1"
                fi
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -d|--daemon)
                DAEMON_MODE=true
                shift
                ;;
            --dev)
                DEV_MODE=true
                shift
                ;;
            --debug)
                DEBUG_MODE=true
                shift
                ;;
            --no-redis)
                SKIP_REDIS=true
                shift
                ;;
            --no-backend)
                SKIP_BACKEND=true
                shift
                ;;
            --no-frontend)
                SKIP_FRONTEND=true
                shift
                ;;
            *)
                print_error "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done

    # 执行命令
    case $COMMAND in
        start)
            start_all
            ;;
        stop)
            stop_all
            ;;
        restart)
            stop_all
            sleep 2
            start_all
            ;;
        status)
            show_status
            ;;
        logs)
            show_logs "$LOG_SERVICE"
            ;;
        *)
            print_error "未知命令: $COMMAND"
            show_help
            exit 1
            ;;
    esac
}

# ============================================================
# 入口
# ============================================================
main "$@"
