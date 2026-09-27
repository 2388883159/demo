#!/usr/bin/env bash
#
# vps-manager.sh — Ubuntu 24.04 物理机一键开 VPS(KVM虚拟机) 管理脚本
# 特性:
#   - 基于 KVM/QEMU + libvirt，性能接近原生，比 Docker "VPS" 更真实(独立内核/root)
#   - 网页管理面板: Cockpit + cockpit-machines (浏览器里建机、开关机、控制台、看资源)
#   - 云镜像 + cloud-init 自动装系统，几分钟起一台全新系统，无需手动装ISO
#   - 只用一个公网IPv4: 虚拟机跑在 NAT 网段(192.168.122.0/24)，
#     用 iptables DNAT 把公网端口转发进每台虚拟机(比如 20022->VM1:22, 20122->VM2:22)
#
# 用法:
#   sudo ./vps-manager.sh install                     # 第一次执行，安装环境
#   sudo ./vps-manager.sh create <名字> <内存MB> <CPU核数> <磁盘GB> <系统> <端口映射>
#   sudo ./vps-manager.sh list                        # 列出所有VM及端口映射
#   sudo ./vps-manager.sh delete <名字>                # 删除VM并清理端口转发
#   sudo ./vps-manager.sh passwd <名字> <新密码>       # 改某台VM的root密码(重新生成cloud-init)
#
# 系统选项(<系统>): ubuntu2404 | ubuntu2204 | debian12
#
# 端口映射格式: "公网端口:VM端口,公网端口:VM端口,..."
#   例如 "20022:22,20080:80,20443:443"
#   会自动生成: 宿主机 <公网IP>:20022 -> 该VM的22端口，以此类推
#
# 示例:
#   sudo ./vps-manager.sh create web1 2048 2 20 ubuntu2404 "20022:22,20080:80,20443:443"
#
set -euo pipefail

STATE_DIR="/etc/vps-manager"
STATE_FILE="${STATE_DIR}/vms.conf"
IMG_DIR="/var/lib/libvirt/images"
CLOUDIMG_DIR="/var/lib/libvirt/base-images"
NET_NAME="default"
NET_CIDR="192.168.122"
NET_GATEWAY="${NET_CIDR}.1"
POOL_DIR="${IMG_DIR}"

log()  { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
die()  { echo -e "\033[1;31m[x]\033[0m $*" >&2; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || die "请用 root 或 sudo 运行本脚本"
}

detect_public_iface() {
  ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1
}

detect_public_ip() {
  ip -4 addr show "$(detect_public_iface)" | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1
}

# ---------- install ----------
cmd_install() {
  require_root
  log "更新软件源..."
  apt-get update -y

  log "安装 KVM / libvirt / cloud-init 工具链..."
  apt-get install -y \
    qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virtinst \
    cloud-image-utils genisoimage wget curl iptables-persistent \
    cockpit cockpit-machines

  log "启用并启动 libvirtd / cockpit ..."
  systemctl enable --now libvirtd
  systemctl enable --now cockpit.socket

  log "确保默认 NAT 网络(${NET_CIDR}.0/24)已启动..."
  if ! virsh net-info "${NET_NAME}" &>/dev/null; then
    die "libvirt 默认网络 ${NET_NAME} 不存在，请检查 libvirt 安装是否正常"
  fi
  virsh net-autostart "${NET_NAME}" || true
  virsh net-start "${NET_NAME}" 2>/dev/null || true

  mkdir -p "${STATE_DIR}" "${CLOUDIMG_DIR}"
  touch "${STATE_FILE}"

  local iface pub_ip
  iface="$(detect_public_iface)"
  pub_ip="$(detect_public_ip)"

  log "检测到公网出口网卡: ${iface}  公网IP: ${pub_ip}"

  if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    log "检测到 ufw 已开启，放行 Cockpit 网页面板端口 9090/tcp ..."
    ufw allow 9090/tcp
  else
    warn "未检测到启用的 ufw，如果你用其它防火墙，请自行放行 9090/tcp (Cockpit网页面板)"
  fi

  cat <<EOF

============================================================
安装完成！

网页管理面板: https://${pub_ip}:9090
  - 用系统 root 或有 sudo 权限的账号登录
  - 左侧菜单 "Virtual Machines" 里可以图形化创建/开关机/看控制台
  - 但建议还是用本脚本的 create 命令批量建机，省去手工点鼠标下载镜像的步骤

接下来可以用:
  sudo ./vps-manager.sh create web1 2048 2 20 ubuntu2404 "20022:22,20080:80,20443:443"
来一键起一台新VPS。
============================================================
EOF
}

# ---------- 云镜像 ----------
image_url_for() {
  case "$1" in
    ubuntu2404) echo "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img" ;;
    ubuntu2204) echo "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img" ;;
    debian12)   echo "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2" ;;
    *) die "不支持的系统: $1 (支持: ubuntu2404 / ubuntu2204 / debian12)" ;;
  esac
}

ensure_base_image() {
  local os="$1" url file
  url="$(image_url_for "$os")"
  file="${CLOUDIMG_DIR}/${os}.qcow2"
  if [[ ! -f "$file" ]]; then
    log "首次使用 ${os}，下载基础云镜像 (只需下一次，之后复用)..."
    wget -q --show-progress -O "${file}.tmp" "$url"
    mv "${file}.tmp" "$file"
  fi
  echo "$file"
}

next_ip_suffix() {
  # 已用的 192.168.122.x 从 10 开始往上分配
  local used max=9
  if [[ -s "$STATE_FILE" ]]; then
    while IFS='|' read -r _ _ _ _ _ ip _; do
      [[ -z "$ip" ]] && continue
      local suf="${ip##*.}"
      (( suf > max )) && max=$suf
    done < "$STATE_FILE"
  fi
  echo $(( max + 1 ))
}

# ---------- create ----------
cmd_create() {
  require_root
  local name="${1:?缺少VM名字}" mem="${2:?缺少内存MB}" vcpu="${3:?缺少CPU核数}" \
        disk="${4:?缺少磁盘GB}" os="${5:?缺少系统: ubuntu2404/ubuntu2204/debian12}" \
        portmap="${6:?缺少端口映射, 例如 20022:22,20080:80}"

  virsh dominfo "$name" &>/dev/null && die "名字 ${name} 已存在的VM，换个名字"
  grep -q "^${name}|" "$STATE_FILE" 2>/dev/null && die "状态文件里已存在 ${name}"

  local base disk_path seed_path suffix vm_ip rootpass
  base="$(ensure_base_image "$os")"
  disk_path="${IMG_DIR}/${name}.qcow2"
  seed_path="${IMG_DIR}/${name}-seed.iso"
  suffix="$(next_ip_suffix)"
  vm_ip="${NET_CIDR}.${suffix}"
  rootpass="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)"

  log "复制基础镜像并扩容到 ${disk}G ..."
  cp "$base" "$disk_path"
  qemu-img resize "$disk_path" "${disk}G"

  log "生成 cloud-init 配置 (内网静态IP: ${vm_ip}) ..."
  local tmpdir; tmpdir="$(mktemp -d)"
  cat > "${tmpdir}/user-data" <<EOF
#cloud-config
hostname: ${name}
disable_root: false
ssh_pwauth: true
chpasswd:
  expire: false
  list:
    - root:${rootpass}
package_update: true
EOF

  cat > "${tmpdir}/meta-data" <<EOF
instance-id: ${name}-$(date +%s)
local-hostname: ${name}
EOF

  cat > "${tmpdir}/network-config" <<EOF
version: 2
ethernets:
  eth0:
    match:
      name: en*
    dhcp4: false
    addresses: [${vm_ip}/24]
    gateway4: ${NET_GATEWAY}
    nameservers:
      addresses: [8.8.8.8, 1.1.1.1]
EOF

  genisoimage -output "$seed_path" -volid cidata -joliet -rock \
    "${tmpdir}/user-data" "${tmpdir}/meta-data" "${tmpdir}/network-config"
  rm -rf "$tmpdir"

  log "创建虚拟机 ${name} (内存${mem}MB / ${vcpu}核 / 磁盘${disk}G) ..."
  virt-install \
    --name "$name" \
    --memory "$mem" \
    --vcpus "$vcpu" \
    --disk path="${disk_path}",format=qcow2 \
    --disk path="${seed_path}",device=cdrom \
    --os-variant detect=on,require=off \
    --network network="${NET_NAME}",model=virtio \
    --graphics none \
    --import \
    --noautoconsole

  log "写入端口转发规则: ${portmap}"
  local pair hport vport iface
  iface="$(detect_public_iface)"
  IFS=',' read -ra pairs <<< "$portmap"
  for pair in "${pairs[@]}"; do
    hport="${pair%%:*}"; vport="${pair##*:}"
    iptables -t nat -A PREROUTING -i "$iface" -p tcp --dport "$hport" \
      -j DNAT --to-destination "${vm_ip}:${vport}"
    iptables -A FORWARD -p tcp -d "${vm_ip}" --dport "$vport" -j ACCEPT
  done
  netfilter-persistent save >/dev/null 2>&1 || true

  echo "${name}|${mem}|${vcpu}|${disk}|${os}|${vm_ip}|${portmap}" >> "$STATE_FILE"

  local pub_ip; pub_ip="$(detect_public_ip)"
  cat <<EOF

============================================================
VM ${name} 创建完成！

  内网IP:      ${vm_ip}
  root 密码:   ${rootpass}   (请自行保存，未再显示)

  端口映射:
$(IFS=','; for p in $portmap; do echo "    公网 ${pub_ip}:${p%%:*}  ->  VM ${p##*:}"; done)

  SSH 登录示例 (若映射了22端口):
    ssh root@${pub_ip} -p ${portmap%%:*}

  首次启动系统安装/初始化大约需要 30~90 秒，请稍等再连接。
============================================================
EOF
}

# ---------- list ----------
cmd_list() {
  require_root
  [[ -s "$STATE_FILE" ]] || { echo "暂无VM"; return; }
  printf "%-12s %-8s %-6s %-8s %-10s %-16s %s\n" "名字" "内存MB" "CPU" "磁盘GB" "系统" "内网IP" "端口映射"
  while IFS='|' read -r name mem vcpu disk os ip portmap; do
    [[ -z "$name" ]] && continue
    local status
    status="$(virsh domstate "$name" 2>/dev/null || echo '未知')"
    printf "%-12s %-8s %-6s %-8s %-10s %-16s %s  [%s]\n" "$name" "$mem" "$vcpu" "$disk" "$os" "$ip" "$portmap" "$status"
  done < "$STATE_FILE"
}

# ---------- delete ----------
cmd_delete() {
  require_root
  local name="${1:?缺少VM名字}"
  local line; line="$(grep "^${name}|" "$STATE_FILE" 2>/dev/null || true)"
  [[ -n "$line" ]] || die "找不到 ${name}"

  local ip portmap iface
  ip="$(echo "$line" | cut -d'|' -f6)"
  portmap="$(echo "$line" | cut -d'|' -f7)"
  iface="$(detect_public_iface)"

  log "关闭并删除虚拟机 ${name} ..."
  virsh destroy "$name" 2>/dev/null || true
  virsh undefine "$name" --remove-all-storage 2>/dev/null || \
    virsh undefine "$name" 2>/dev/null || true
  rm -f "${IMG_DIR}/${name}.qcow2" "${IMG_DIR}/${name}-seed.iso"

  log "清理端口转发规则..."
  IFS=',' read -ra pairs <<< "$portmap"
  for pair in "${pairs[@]}"; do
    local hport="${pair%%:*}" vport="${pair##*:}"
    iptables -t nat -D PREROUTING -i "$iface" -p tcp --dport "$hport" \
      -j DNAT --to-destination "${ip}:${vport}" 2>/dev/null || true
    iptables -D FORWARD -p tcp -d "${ip}" --dport "$vport" -j ACCEPT 2>/dev/null || true
  done
  netfilter-persistent save >/dev/null 2>&1 || true

  grep -v "^${name}|" "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
  log "已删除 ${name}"
}

# ---------- main ----------
case "${1:-}" in
  install) shift; cmd_install "$@" ;;
  create)  shift; cmd_create "$@" ;;
  list)    shift; cmd_list "$@" ;;
  delete)  shift; cmd_delete "$@" ;;
  *)
    cat <<EOF
用法:
  sudo $0 install
  sudo $0 create <名字> <内存MB> <CPU核数> <磁盘GB> <系统:ubuntu2404|ubuntu2204|debian12> <端口映射,如20022:22,20080:80>
  sudo $0 list
  sudo $0 delete <名字>
EOF
    exit 1
    ;;
esac
