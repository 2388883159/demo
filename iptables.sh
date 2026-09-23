#!/bin/bash

# =========================================================
# iptables 端口转发脚本
# Ubuntu 22.04 / 24.04
# 支持 TCP / UDP / TCP+UDP
# =========================================================

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[36m'
NC='\033[0m'

INFO="[${BLUE}INFO${NC}]"
OK="[${GREEN}OK${NC}]"
WARN="[${YELLOW}WARN${NC}]"
ERR="[${RED}ERR${NC}]"

# ---------------------------------------------------------
# 检查 root
# ---------------------------------------------------------
if [ "$(id -u)" != "0" ]; then
    echo -e "${ERR} 请使用 root 运行"
    exit 1
fi

# ---------------------------------------------------------
# 安装 iptables
# ---------------------------------------------------------
install_iptables() {
    echo -e "${INFO} 检查 iptables..."

    if ! command -v iptables >/dev/null 2>&1; then
        echo -e "${INFO} 正在安装 iptables..."
        apt-get update
        apt-get install -y iptables
    fi

    echo -e "${OK} iptables 已安装"
}

# ---------------------------------------------------------
# 开启 IP 转发
# ---------------------------------------------------------
enable_forward() {
    echo -e "${INFO} 开启 IPv4 转发..."

    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    cat > /etc/sysctl.d/99-ip-forward.conf <<SYSCTL
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
SYSCTL

    sysctl --system >/dev/null 2>&1

    echo -e "${OK} IPv4 转发已开启"
}

# ---------------------------------------------------------
# 添加 TCP 转发
# ---------------------------------------------------------
add_tcp() {
    LOCAL_PORT="$1"
    TARGET_IP="$2"
    TARGET_PORT="$3"

    echo -e "${INFO} 添加 TCP 转发:"
    echo "      本机端口: ${LOCAL_PORT}"
    echo "      目标地址: ${TARGET_IP}:${TARGET_PORT}"

    iptables -t nat -A PREROUTING \
        -p tcp \
        --dport "${LOCAL_PORT}" \
        -j DNAT \
        --to-destination "${TARGET_IP}:${TARGET_PORT}"

    iptables -t nat -A POSTROUTING \
        -p tcp \
        -d "${TARGET_IP}" \
        --dport "${TARGET_PORT}" \
        -j MASQUERADE

    iptables -A FORWARD \
        -p tcp \
        -d "${TARGET_IP}" \
        --dport "${TARGET_PORT}" \
        -m conntrack \
        --ctstate NEW,ESTABLISHED,RELATED \
        -j ACCEPT

    iptables -A FORWARD \
        -p tcp \
        -s "${TARGET_IP}" \
        --sport "${TARGET_PORT}" \
        -m conntrack \
        --ctstate ESTABLISHED,RELATED \
        -j ACCEPT

    echo -e "${OK} TCP 转发完成"
}

# ---------------------------------------------------------
# 添加 UDP 转发
# ---------------------------------------------------------
add_udp() {
    LOCAL_PORT="$1"
    TARGET_IP="$2"
    TARGET_PORT="$3"

    echo -e "${INFO} 添加 UDP 转发:"
    echo "      本机端口: ${LOCAL_PORT}"
    echo "      目标地址: ${TARGET_IP}:${TARGET_PORT}"

    iptables -t nat -A PREROUTING \
        -p udp \
        --dport "${LOCAL_PORT}" \
        -j DNAT \
        --to-destination "${TARGET_IP}:${TARGET_PORT}"

    iptables -t nat -A POSTROUTING \
        -p udp \
        -d "${TARGET_IP}" \
        --dport "${TARGET_PORT}" \
        -j MASQUERADE

    iptables -A FORWARD \
        -p udp \
        -d "${TARGET_IP}" \
        --dport "${TARGET_PORT}" \
        -j ACCEPT

    iptables -A FORWARD \
        -p udp \
        -s "${TARGET_IP}" \
        --sport "${TARGET_PORT}" \
        -j ACCEPT

    echo -e "${OK} UDP 转发完成"
}

# ---------------------------------------------------------
# 保存规则
# ---------------------------------------------------------
save_rules() {
    echo -e "${INFO} 保存 iptables 规则..."

    mkdir -p /etc/iptables

    iptables-save > /etc/iptables/rules.v4

    # 安装持久化工具
    if ! command -v netfilter-persistent >/dev/null 2>&1; then
        echo -e "${INFO} 安装 iptables-persistent..."

        DEBIAN_FRONTEND=noninteractive \
        apt-get install -y iptables-persistent netfilter-persistent
    fi

    netfilter-persistent save >/dev/null 2>&1 || true

    echo -e "${OK} iptables 配置已保存"
}

# ---------------------------------------------------------
# 显示规则
# ---------------------------------------------------------
show_rules() {
    echo
    echo "=============================================="
    echo " PREROUTING"
    echo "=============================================="
    iptables -t nat -L PREROUTING -n -v --line-numbers

    echo
    echo "=============================================="
    echo " POSTROUTING"
    echo "=============================================="
    iptables -t nat -L POSTROUTING -n -v --line-numbers

    echo
    echo "=============================================="
    echo " FORWARD"
    echo "=============================================="
    iptables -L FORWARD -n -v --line-numbers

    echo
}

# ---------------------------------------------------------
# 清除转发规则
# ---------------------------------------------------------
clear_rules() {
    echo -e "${WARN} 即将清除 NAT 和 FORWARD 规则"

    read -r -p "确认清除？输入 YES: " CONFIRM

    if [ "$CONFIRM" != "YES" ]; then
        echo "取消"
        return
    fi

    iptables -t nat -F PREROUTING
    iptables -t nat -F POSTROUTING
    iptables -F FORWARD

    echo -e "${OK} 转发规则已经清除"
}

# ---------------------------------------------------------
# 测试目标
# ---------------------------------------------------------
test_target() {
    read -r -p "目标 IP: " TEST_IP
    read -r -p "目标 TCP 端口: " TEST_PORT

    echo
    echo -e "${INFO} 测试 ${TEST_IP}:${TEST_PORT}"

    if command -v nc >/dev/null 2>&1; then
        nc -vz -w 5 "$TEST_IP" "$TEST_PORT"
    else
        apt-get install -y netcat-openbsd
        nc -vz -w 5 "$TEST_IP" "$TEST_PORT"
    fi
}

# ---------------------------------------------------------
# 添加转发
# ---------------------------------------------------------
add_forward() {
    read -r -p "本机监听端口: " LOCAL_PORT
    read -r -p "目标 IP: " TARGET_IP
    read -r -p "目标端口: " TARGET_PORT

    echo
    echo "请选择协议:"
    echo "1. TCP"
    echo "2. UDP"
    echo "3. TCP + UDP"

    read -r -p "选择 [1-3]: " PROTOCOL

    case "$PROTOCOL" in

        1)
            add_tcp "$LOCAL_PORT" "$TARGET_IP" "$TARGET_PORT"
            ;;

        2)
            add_udp "$LOCAL_PORT" "$TARGET_IP" "$TARGET_PORT"
            ;;

        3)
            add_tcp "$LOCAL_PORT" "$TARGET_IP" "$TARGET_PORT"
            add_udp "$LOCAL_PORT" "$TARGET_IP" "$TARGET_PORT"
            ;;

        *)
            echo -e "${ERR} 无效选择"
            return 1
            ;;
    esac

    save_rules

    echo
    echo -e "${OK} iptables 配置完成"
    echo
}

# ---------------------------------------------------------
# 菜单
# ---------------------------------------------------------
menu() {

    while true; do

        echo
        echo "=============================================="
        echo "        iptables 端口转发管理"
        echo "=============================================="
        echo " 1. 安装/初始化"
        echo " 2. 添加端口转发"
        echo " 3. 查看当前规则"
        echo " 4. 测试目标端口"
        echo " 5. 清除转发规则"
        echo " 6. 保存规则"
        echo " 0. 退出"
        echo "=============================================="

        read -r -p "请选择: " CHOICE

        case "$CHOICE" in

            1)
                install_iptables
                enable_forward
                ;;

            2)
                add_forward
                ;;

            3)
                show_rules
                ;;

            4)
                test_target
                ;;

            5)
                clear_rules
                ;;

            6)
                save_rules
                ;;

            0)
                echo "退出"
                exit 0
                ;;

            *)
                echo -e "${ERR} 无效选择"
                ;;
        esac

    done
}

# ---------------------------------------------------------
# 主程序
# ---------------------------------------------------------
install_iptables
enable_forward
menu
