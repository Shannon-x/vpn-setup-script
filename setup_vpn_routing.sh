#!/bin/bash

# ==============================================================================
#  一键式 OpenVPN 策略路由设置脚本 (版本 2)
#  功能:
#  1. 提示用户输入文件名并直接粘贴OpenVPN配置内容。
#  2. 自动检测网络环境 (网关, 网卡)。
#  3. 创建独立的路由表以保留 SSH 连接。
#  4. 生成 route-up.sh 和 route-down.sh 脚本。
#  5. 修改 OpenVPN 客户端配置以启用策略路由。
#  6. 所有出站流量将通过 VPN，但 SSH 连接将保持直连。
# ==============================================================================

# --- 变量和颜色定义 ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- 核心函数 ---

# 检查脚本是否以 root 权限运行
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误：此脚本必须以 root 权限运行。请使用 'sudo ./setup_vpn_routing_v2.sh'。${NC}"
        exit 1
    fi
}

# 检查所需的依赖命令
check_dependencies() {
    echo -e "${YELLOW}正在检查依赖项...${NC}"
    local missing_deps=0
    for cmd in openvpn iptables ip; do
        if ! command -v "$cmd" &> /dev/null; then
            echo -e "${RED}  -> 依赖 '$cmd' 未找到。请先安装它。${NC}"
            missing_deps=1
        else
            echo -e "${GREEN}  -> 依赖 '$cmd' 已找到。${NC}"
        fi
    done

    if [ "$missing_deps" -eq 1 ]; then
        echo -e "${RED}请安装缺失的依赖项后重试 (例如: sudo apt-get update && sudo apt-get install openvpn iptables iproute2)。${NC}"
        exit 1
    fi
}

# 自动检测默认网关和主网卡
get_network_info() {
    echo -e "${YELLOW}正在自动检测网络信息...${NC}"
    local route_info
    route_info=$(ip route get 8.8.8.8)

    GATEWAY_IP=$(echo "$route_info" | awk '/via/ {print $3}')
    MAIN_IF=$(echo "$route_info" | awk '/dev/ {print $5}')

    if [ -z "$GATEWAY_IP" ] || [ -z "$MAIN_IF" ]; then
        echo -e "${RED}错误：无法自动检测到默认网关或主网卡。请检查您的网络配置。${NC}"
        exit 1
    fi
    echo -e "${GREEN}  -> 检测到原始默认网关 (Gateway): ${GATEWAY_IP}${NC}"
    echo -e "${GREEN}  -> 检测到主网卡名称 (Interface): ${MAIN_IF}${NC}"
}

# 【已优化】提示用户输入文件名并直接粘贴配置内容
get_ovpn_config() {
    OVPN_CLIENT_DIR="/etc/openvpn/client"
    mkdir -p "$OVPN_CLIENT_DIR"
    
    local OVPN_FILENAME
    while true; do
        read -p "$(echo -e ${YELLOW}"请输入您想创建的 OpenVPN 配置文件名 (例如: my-vpn.conf): "${NC})" OVPN_FILENAME
        if [[ "$OVPN_FILENAME" =~ \.conf$ || "$OVPN_FILENAME" =~ \.ovpn$ ]]; then
            break
        else
            echo -e "${RED}错误：文件名必须以 '.conf' 或 '.ovpn' 结尾。请重新输入。${NC}"
        fi
    done

    OVPN_CONFIG_FILE="$OVPN_CLIENT_DIR/$OVPN_FILENAME"
    OVPN_SERVICE_NAME=$(basename "$OVPN_FILENAME" | sed 's/\.conf$//' | sed 's/\.ovpn$//')

    echo -e "${YELLOW}请将您的 OpenVPN 配置文件的【全部内容】粘贴到下面。"
    echo -e "粘贴完成后，另起一个新行，然后按下 ${GREEN}Ctrl+D${YELLOW} 来结束输入。${NC}"
    
    local OVPN_CONTENT
    OVPN_CONTENT=$(cat)

    if [ -z "$OVPN_CONTENT" ]; then
        echo -e "${RED}错误：没有接收到任何内容。请重新运行脚本。${NC}"
        exit 1
    fi

    echo "$OVPN_CONTENT" > "$OVPN_CONFIG_FILE"
    echo -e "${GREEN}  -> 配置已成功保存到: $OVPN_CONFIG_FILE${NC}"
}


# 设置独立的路由表
setup_routing_table() {
    echo -e "${YELLOW}正在配置路由表 /etc/iproute2/rt_tables...${NC}"
    if ! grep -q "main_route" /etc/iproute2/rt_tables; then
        echo "100   main_route" >> /etc/iproute2/rt_tables
        echo -e "${GREEN}  -> 已添加路由表 '100 main_route'。${NC}"
    else
        echo -e "${GREEN}  -> 路由表 'main_route' 已存在，无需修改。${NC}"
    fi
}

# 创建 route-up 和 route-down 脚本
create_route_scripts() {
    local script_dir="$OVPN_CLIENT_DIR"
    local up_script="$script_dir/route-up.sh"
    local down_script="$script_dir/route-down.sh"

    echo -e "${YELLOW}正在创建优化的 route-up.sh 脚本...${NC}"
    cat << EOF > "$up_script"
#!/bin/bash
# -- 根据您的环境自动填充的变量 --
GATEWAY_IP="${GATEWAY_IP}"
MAIN_IF="${MAIN_IF}"
# -- 配置参数 --
FWMARK="0x100"
TABLE_ID="main_route"
# 等待网络接口就绪
sleep 5
# --- 第1部分：确保内核参数允许策略路由 ---
sysctl -w net.ipv4.conf.all.rp_filter=2
sysctl -w net.ipv4.conf.default.rp_filter=2
sysctl -w net.ipv4.conf.\${MAIN_IF}.rp_filter=2
# --- 第2部分：配置iptables，为入站连接打标记 ---
iptables -t mangle -A PREROUTING -i \${MAIN_IF} -j MARK --set-mark \${FWMARK}
iptables -t mangle -A PREROUTING -j CONNMARK --save-mark
iptables -t mangle -A OUTPUT -j CONNMARK --restore-mark
# --- 第3部分：配置策略路由 ---
ip route replace default via \${GATEWAY_IP} dev \${MAIN_IF} table \${TABLE_ID}
ip rule add fwmark \${FWMARK} table \${TABLE_ID} prio 100
# --- 第4部分：刷新路由缓存 ---
ip route flush cache
exit 0
EOF
    echo -e "${GREEN}  -> 脚本 '$up_script' 已创建。${NC}"

    echo -e "${YELLOW}正在创建优化的 route-down.sh 脚本...${NC}"
    cat << EOF > "$down_script"
#!/bin/bash
FWMARK="0x100"
TABLE_ID="main_route"
MAIN_IF="${MAIN_IF}"
# -- 清除规则 (与添加顺序相反) --
ip rule del prio 100
ip route flush table \${TABLE_ID}
iptables -t mangle -D OUTPUT -j CONNMARK --restore-mark
iptables -t mangle -D PREROUTING -j CONNMARK --save-mark
iptables -t mangle -D PREROUTING -i \${MAIN_IF} -j MARK --set-mark \${FWMARK}
# -- 恢复内核默认值 --
sysctl -w net.ipv4.conf.all.rp_filter=1
sysctl -w net.ipv4.conf.default.rp_filter=1
sysctl -w net.ipv4.conf.\${MAIN_IF}.rp_filter=1
# 刷新路由缓存
ip route flush cache
exit 0
EOF
    echo -e "${GREEN}  -> 脚本 '$down_script' 已创建。${NC}"

    echo -e "${YELLOW}正在为脚本添加执行权限...${NC}"
    chmod +x "$up_script" "$down_script"
    echo -e "${GREEN}  -> 权限设置完成。${NC}"
}

# 修改 OpenVPN 配置文件
modify_ovpn_config() {
    echo -e "${YELLOW}正在修改 OpenVPN 配置文件: $OVPN_CONFIG_FILE...${NC}"

    # 1. 注释掉 redirect-gateway def1
    if grep -q "redirect-gateway def1" "$OVPN_CONFIG_FILE"; then
        sed -i 's/^\s*redirect-gateway def1/#redirect-gateway def1/' "$OVPN_CONFIG_FILE"
        echo -e "${GREEN}  -> 已注释掉 'redirect-gateway def1'。${NC}"
    else
        echo -e "${GREEN}  -> 'redirect-gateway def1' 未找到，无需注释。${NC}"
    fi

    # 2. 添加脚本指令
    local script_dir="$OVPN_CLIENT_DIR"
    
    # 删除旧的指令以防万一
    sed -i '/^script-security/d' "$OVPN_CONFIG_FILE"
    sed -i 's#^up .*##' "$OVPN_CONFIG_FILE"
    sed -i 's#^down .*##' "$OVPN_CONFIG_FILE"
    # 清理可能产生的空行
    sed -i '/^$/N;/^\n$/D' "$OVPN_CONFIG_FILE"


    # 添加新的指令到文件末尾
    cat << EOF >> "$OVPN_CONFIG_FILE"

# --- 由 setup_vpn_routing.sh 脚本自动添加 ---
script-security 2
up $script_dir/route-up.sh
down $script_dir/route-down.sh
EOF
    echo -e "${GREEN}  -> 已添加 script-security, up, 和 down 指令。${NC}"
}

# --- 主逻辑 ---
main() {
    echo -e "${GREEN}=====================================================${NC}"
    echo -e "${GREEN}  OpenVPN 保留 SSH 策略路由一键配置脚本 (v2)  ${NC}"
    echo -e "${GREEN}=====================================================${NC}"
    
    check_root
    check_dependencies
    get_network_info
    get_ovpn_config
    setup_routing_table
    create_route_scripts
    modify_ovpn_config

    echo -e "\n${GREEN}================= 配置完成! =================${NC}"
    echo -e "所有配置已自动完成。现在，请重启 OpenVPN 服务来应用更改。"
    echo -e "\n${YELLOW}请运行以下命令来启动/重启您的VPN连接:${NC}"
    echo -e "sudo systemctl restart openvpn-client@${OVPN_SERVICE_NAME}.service"
    
    echo -e "\n${YELLOW}等待大约 15 秒后，运行以下命令检查服务状态:${NC}"
    echo -e "sudo systemctl status openvpn-client@${OVPN_SERVICE_NAME}.service"
    
    echo -e "\n${YELLOW}最后，通过以下方式进行验证:${NC}"
    echo -e "1. 您的 SSH 连接应该没有断开。"
    echo -e "2. 在服务器上运行 ${GREEN}curl ip.sb${NC} 或 ${GREEN}curl ifconfig.me${NC}，显示的应该是您的 VPN 服务器 IP。"
    echo -e "3. 从另一台机器 ${GREEN}ping ${NC} 您的服务器公网 IP，应该能够 ping 通。"
}

# 执行主函数
main
