#!/bin/bash

# =========================================================
# iptables 端口转发管理脚本 (支持端口段)
# Ubuntu 22.04 / 24.04
# 支持 TCP / UDP / TCP+UDP，单端口 / 端口段
#
# 端口段示例:
#   本机 15000-15100  ->  目标 1.2.3.4 同样的 15000-15100   (同端口)
#   本机 15000-15100  ->  目标 1.2.3.4 的 20000-20100        (逐一映射 15000->20000, 15001->20001 ...)
#   本机 15000-15100  ->  目标 1.2.3.4 的 443                (多对一, 整段都转到 443)
#
# 本脚本添加的每条规则都带有 comment 标记 (PF:...:E)，
# 因此可以精确删除，不会误伤 Docker 等其它程序的规则。
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

SYSCTL_FILE="/etc/sysctl.d/99-ip-forward.conf"
BACKUP_DIR="/etc/iptables/backup"

# ---------------------------------------------------------
# 检查 root
# ---------------------------------------------------------
if [ "$(id -u)" != "0" ]; then
    echo -e "${ERR} 请使用 root 运行"
    exit 1
fi

# ---------------------------------------------------------
# 通用工具函数
# ---------------------------------------------------------
confirm() {
    local ans
    read -r -p "$1 [y/N]: " ans
    [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]
}

valid_ip() {
    local ip="$1" o x
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS=. read -r -a o <<< "$ip"
    for x in "${o[@]}"; do
        (( 10#$x <= 255 )) || return 1
    done
    return 0
}

# 解析端口/端口段: 支持 8080 / 15000-15100 / 15000:15100
# 结果写入 PS_START PS_END
parse_ports() {
    local s="${1// /}"
    s="${s//:/-}"

    if [[ "$s" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        PS_START=$((10#${BASH_REMATCH[1]}))
        PS_END=$((10#${BASH_REMATCH[2]}))
    elif [[ "$s" =~ ^[0-9]+$ ]]; then
        PS_START=$((10#$s))
        PS_END=$PS_START
    else
        return 1
    fi

    (( PS_START >= 1 && PS_END <= 65535 && PS_START <= PS_END ))
}

# iptables 格式: 单端口 "80"，端口段 "15000:15100"
ipt_spec() { if [ "$1" = "$2" ]; then echo "$1"; else echo "$1:$2"; fi; }
# 显示格式: 单端口 "80"，端口段 "15000-15100"
txt_spec() { if [ "$1" = "$2" ]; then echo "$1"; else echo "$1-$2"; fi; }

# ---------------------------------------------------------
# 安装 iptables
# ---------------------------------------------------------
install_iptables() {
    if ! command -v iptables >/dev/null 2>&1; then
        echo -e "${INFO} 正在安装 iptables..."
        apt-get update
        apt-get install -y iptables
    fi

    if ! command -v iptables >/dev/null 2>&1; then
        echo -e "${ERR} iptables 安装失败"
        exit 1
    fi
}

# ---------------------------------------------------------
# 开启 IP 转发 (已开启则跳过)
# ---------------------------------------------------------
enable_forward() {
    if [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = "1" ] && [ -f "$SYSCTL_FILE" ]; then
        return 0
    fi

    echo -e "${INFO} 开启 IPv4 转发..."

    cat > "$SYSCTL_FILE" <<SYSCTL
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
SYSCTL

    sysctl --system >/dev/null 2>&1
    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    echo -e "${OK} IPv4 转发已开启"
}

# ---------------------------------------------------------
# 规则标记相关
#   tag 格式: PF:<proto>:<本机端口>:<目标IP>:<目标端口>:<模式>:E
#   模式: same=同端口  map=逐一映射  one=多对一
# ---------------------------------------------------------
list_tags() {
    iptables-save -t nat 2>/dev/null | grep -o 'PF:[^" ]*:E' | sort -u
}

# 检查与已有转发的本机端口是否重叠，重叠则输出对方端口并返回 0
check_conflict() {
    local proto="$1" s="$2" e="$3" p lp ls le
    while IFS=: read -r _ p lp _; do
        [ "$p" = "$proto" ] || continue
        ls="${lp%-*}"
        le="${lp#*-}"
        if (( s <= le && e >= ls )); then
            echo "$lp"
            return 0
        fi
    done < <(list_tags)
    return 1
}

# ---------------------------------------------------------
# 添加一个协议的转发规则 (通过 iptables-restore 批量原子写入)
# 参数: proto lS lE ip mode tS tE
# ---------------------------------------------------------
apply_rules() {
    local proto="$1" lS="$2" lE="$3" ip="$4" mode="$5" tS="$6" tE="$7"
    local lspec tspec tag f i

    lspec=$(ipt_spec "$lS" "$lE")
    tspec=$(ipt_spec "$tS" "$tE")
    tag="PF:${proto}:$(txt_spec "$lS" "$lE"):${ip}:$(txt_spec "$tS" "$tE"):${mode}:E"

    if iptables-save -t nat | grep -qF -- "$tag"; then
        echo -e "${WARN} 规则已存在，跳过: ${tag%:E}"
        return 0
    fi

    f=$(mktemp)

    {
        echo "*nat"

        case "$mode" in
            same)
                # 不指定目标端口 -> 端口保持不变，端口段天然一一对应
                echo "-A PREROUTING -p $proto --dport $lspec -m comment --comment \"$tag\" -j DNAT --to-destination $ip"
                ;;
            one)
                echo "-A PREROUTING -p $proto --dport $lspec -m comment --comment \"$tag\" -j DNAT --to-destination ${ip}:${tS}"
                ;;
            map)
                for (( i = 0; i <= lE - lS; i++ )); do
                    echo "-A PREROUTING -p $proto --dport $((lS + i)) -m comment --comment \"$tag\" -j DNAT --to-destination ${ip}:$((tS + i))"
                done
                ;;
        esac

        echo "-A POSTROUTING -p $proto -d $ip --dport $tspec -m comment --comment \"$tag\" -j MASQUERADE"
        echo "COMMIT"

        echo "*filter"
        echo "-A FORWARD -p $proto -d $ip --dport $tspec -m conntrack --ctstate NEW,ESTABLISHED,RELATED -m comment --comment \"$tag\" -j ACCEPT"
        echo "-A FORWARD -p $proto -s $ip --sport $tspec -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment \"$tag\" -j ACCEPT"
        echo "COMMIT"
    } > "$f"

    if iptables-restore --noflush < "$f"; then
        echo -e "${OK} ${proto^^} 转发完成: 本机 $(txt_spec "$lS" "$lE") -> ${ip}:$(txt_spec "$tS" "$tE")"
        rm -f "$f"
        return 0
    else
        echo -e "${ERR} ${proto^^} 转发添加失败"
        rm -f "$f"
        return 1
    fi
}

# ---------------------------------------------------------
# 保存规则
# ---------------------------------------------------------
save_rules() {
    echo -e "${INFO} 保存 iptables 规则..."

    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4

    if ! command -v netfilter-persistent >/dev/null 2>&1; then
        echo -e "${INFO} 安装 iptables-persistent..."
        DEBIAN_FRONTEND=noninteractive \
        apt-get install -y iptables-persistent netfilter-persistent
    fi

    netfilter-persistent save >/dev/null 2>&1 || true

    echo -e "${OK} iptables 配置已保存"
}

# ---------------------------------------------------------
# 添加转发
# ---------------------------------------------------------
add_forward() {
    local in ip proto_choice mode choice len tlen p
    local -a protos=()
    local L_S L_E T_S T_E

    echo
    read -r -p "本机监听端口/端口段 (如 8080 或 15000-15100): " in
    if ! parse_ports "$in"; then
        echo -e "${ERR} 端口格式无效 (范围 1-65535，起始不能大于结束)"
        return 1
    fi
    L_S=$PS_START
    L_E=$PS_END
    len=$((L_E - L_S + 1))

    read -r -p "目标 IP: " ip
    if ! valid_ip "$ip"; then
        echo -e "${ERR} IP 格式无效"
        return 1
    fi

    read -r -p "目标端口/端口段 (回车 = 与本机相同): " in
    if [ -z "${in// /}" ]; then
        T_S=$L_S
        T_E=$L_E
    else
        if ! parse_ports "$in"; then
            echo -e "${ERR} 目标端口格式无效"
            return 1
        fi
        T_S=$PS_START
        T_E=$PS_END
    fi
    tlen=$((T_E - T_S + 1))

    # 判断映射模式
    if (( T_S == L_S && T_E == L_E )); then
        mode="same"
    elif (( tlen == len )); then
        mode="map"
    elif (( tlen == 1 && len > 1 )); then
        echo
        echo "本机是端口段，目标只给了一个端口 ${T_S}，请选择映射方式:"
        echo "1. 逐一映射 (${L_S}->${T_S}, $((L_S + 1))->$((T_S + 1)) ... 依次递增)"
        echo "2. 多对一   (整段 ${L_S}-${L_E} 全部转发到 ${T_S})"
        read -r -p "选择 [1-2]: " choice
        case "$choice" in
            1)
                T_E=$((T_S + len - 1))
                if (( T_E > 65535 )); then
                    echo -e "${ERR} 目标端口超出 65535"
                    return 1
                fi
                if (( T_S == L_S )); then mode="same"; else mode="map"; fi
                ;;
            2)
                mode="one"
                ;;
            *)
                echo -e "${ERR} 无效选择"
                return 1
                ;;
        esac
    else
        echo -e "${ERR} 目标端口段长度(${tlen})与本机端口段长度(${len})不一致"
        return 1
    fi

    if [ "$mode" = "map" ] && (( len > 2000 )); then
        echo -e "${WARN} 逐一映射将生成 ${len} 条 PREROUTING 规则"
        confirm "继续?" || return 1
    fi

    echo
    echo "请选择协议:"
    echo "1. TCP"
    echo "2. UDP"
    echo "3. TCP + UDP"
    read -r -p "选择 [1-3]: " proto_choice

    case "$proto_choice" in
        1) protos=(tcp) ;;
        2) protos=(udp) ;;
        3) protos=(tcp udp) ;;
        *)
            echo -e "${ERR} 无效选择"
            return 1
            ;;
    esac

    # 冲突检查
    for p in "${protos[@]}"; do
        local c
        c=$(check_conflict "$p" "$L_S" "$L_E")
        if [ -n "$c" ]; then
            echo -e "${WARN} ${p^^} 本机端口与已有转发 (${c}) 重叠，先添加的规则优先生效"
            confirm "仍要继续?" || return 1
        fi
    done

    # SSH 端口保护: 防止把自己的 SSH 转走导致失联
    local ssh_port="${SSH_CONNECTION##* }"
    if [[ " ${protos[*]} " == *" tcp "* ]] && [[ "$ssh_port" =~ ^[0-9]+$ ]] \
        && (( ssh_port >= L_S && ssh_port <= L_E )); then
        echo -e "${WARN} 本机端口范围包含当前 SSH 连接端口 ${ssh_port}，转发后可能导致 SSH 断连!"
        confirm "确定继续?" || return 1
    fi

    echo
    echo -e "${INFO} 即将添加:"
    echo "      协议:     ${protos[*]}"
    echo "      本机端口: $(txt_spec "$L_S" "$L_E")"
    echo "      目标:     ${ip}:$(txt_spec "$T_S" "$T_E")"
    case "$mode" in
        same) echo "      模式:     同端口" ;;
        map)  echo "      模式:     逐一映射" ;;
        one)  echo "      模式:     多对一" ;;
    esac
    confirm "确认添加?" || { echo "取消"; return 0; }

    echo
    for p in "${protos[@]}"; do
        apply_rules "$p" "$L_S" "$L_E" "$ip" "$mode" "$T_S" "$T_E"
    done

    save_rules
    echo
}

# ---------------------------------------------------------
# 查看已添加的转发 (摘要)
# ---------------------------------------------------------
show_summary() {
    local i=0 proto lp ip tp mode label

    echo
    echo "=============================================="
    echo " 本脚本添加的转发"
    echo "=============================================="

    while IFS=: read -r _ proto lp ip tp mode _; do
        i=$((i + 1))
        case "$mode" in
            same) label="同端口" ;;
            map)  label="逐一映射" ;;
            one)  label="多对一" ;;
            *)    label="$mode" ;;
        esac
        printf " %2d. %-3s  本机 %-13s ->  %s:%-13s [%s]\n" "$i" "${proto^^}" "$lp" "$ip" "$tp" "$label"
    done < <(list_tags)

    if (( i == 0 )); then
        echo " (暂无)"
    fi
    echo
}

# ---------------------------------------------------------
# 查看 iptables 详细规则
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
# 过滤掉匹配的规则并重新载入 (先备份，防止误清空)
# 参数: grep -v 的参数
# ---------------------------------------------------------
filter_restore() {
    local tmp
    tmp=$(mktemp)

    mkdir -p "$BACKUP_DIR"
    iptables-save > "${BACKUP_DIR}/rules-$(date +%Y%m%d-%H%M%S).v4"

    iptables-save | grep -v "$@" > "$tmp"

    if ! grep -q '^COMMIT' "$tmp"; then
        echo -e "${ERR} 生成的规则文件异常，已中止 (未做任何修改)"
        rm -f "$tmp"
        return 1
    fi

    if iptables-restore < "$tmp"; then
        rm -f "$tmp"
        return 0
    else
        echo -e "${ERR} 规则载入失败"
        rm -f "$tmp"
        return 1
    fi
}

# ---------------------------------------------------------
# 删除指定转发
# ---------------------------------------------------------
delete_forward() {
    local -a tags=()
    local n proto lp ip tp mode i

    mapfile -t tags < <(list_tags)

    if (( ${#tags[@]} == 0 )); then
        echo -e "${WARN} 没有可删除的转发"
        return 0
    fi

    echo
    for i in "${!tags[@]}"; do
        IFS=: read -r _ proto lp ip tp mode _ <<< "${tags[$i]}"
        printf " %2d. %-3s  本机 %-13s ->  %s:%s\n" "$((i + 1))" "${proto^^}" "$lp" "$ip" "$tp"
    done
    echo

    read -r -p "输入要删除的序号 (回车取消): " n
    [ -z "$n" ] && return 0

    if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n < 1 || n > ${#tags[@]} )); then
        echo -e "${ERR} 序号无效"
        return 1
    fi

    if filter_restore -F -- "${tags[$((n - 1))]}"; then
        echo -e "${OK} 已删除: ${tags[$((n - 1))]%:E}"
        save_rules
    fi
}

# ---------------------------------------------------------
# 清除本脚本添加的全部转发 (不影响其它规则)
# ---------------------------------------------------------
clear_rules() {
    echo -e "${WARN} 即将清除本脚本添加的全部端口转发规则 (Docker 等其它规则不受影响)"

    read -r -p "确认清除？输入 YES: " CONFIRM

    if [ "$CONFIRM" != "YES" ]; then
        echo "取消"
        return
    fi

    if filter_restore -E -- 'PF:(tcp|udp):'; then
        echo -e "${OK} 转发规则已经清除"
        save_rules
    fi
}

# ---------------------------------------------------------
# 测试目标端口 (TCP)
# ---------------------------------------------------------
test_target() {
    read -r -p "目标 IP: " TEST_IP
    read -r -p "目标 TCP 端口: " TEST_PORT

    if ! valid_ip "$TEST_IP" || ! parse_ports "$TEST_PORT" || [ "$PS_START" != "$PS_END" ]; then
        echo -e "${ERR} IP 或端口无效 (测试只支持单个端口)"
        return 1
    fi

    echo
    echo -e "${INFO} 测试 ${TEST_IP}:${TEST_PORT}"

    if ! command -v nc >/dev/null 2>&1; then
        apt-get install -y netcat-openbsd
    fi

    nc -vz -w 5 "$TEST_IP" "$TEST_PORT"
}

# ---------------------------------------------------------
# 菜单
# ---------------------------------------------------------
menu() {
    while true; do
        echo
        echo "=============================================="
        echo "     iptables 端口转发管理 (支持端口段)"
        echo "=============================================="
        echo " 1. 安装/初始化"
        echo " 2. 添加端口转发 (单端口 / 端口段)"
        echo " 3. 查看已添加的转发"
        echo " 4. 查看 iptables 详细规则"
        echo " 5. 删除指定转发"
        echo " 6. 清除全部转发"
        echo " 7. 测试目标端口"
        echo " 8. 保存规则"
        echo " 0. 退出"
        echo "=============================================="

        read -r -p "请选择: " CHOICE

        case "$CHOICE" in
            1)
                install_iptables
                enable_forward
                echo -e "${OK} 初始化完成"
                ;;
            2) add_forward ;;
            3) show_summary ;;
            4) show_rules ;;
            5) delete_forward ;;
            6) clear_rules ;;
            7) test_target ;;
            8) save_rules ;;
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
