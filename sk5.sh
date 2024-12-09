#!/bin/bash
yum -y install epel-release
yum -y update
yum -y remove firewalld
yum -y install iptables iptables-services
yum -y install gcc vim wget make
##配置selinux及主机名
hostnamectl set-hostname ss5_server_X
setenforce 0
sed -i "s/SELINUX=enforcing/SELINUX=disabled/" /etc/selinux/config
 
 
yum -y install pam-devel openssl-devel openldap-devel
##安装配置ss5代理
##wget https://nchc.dl.sourceforge.net/project/ss5/ss5/3.8.9-8/ss5-3.8.9-8.tar.gz
wget http://down.sstp.top/Socks/ss5-3.8.9-8.tar.gz
tar vzxf  ss5-3.8.9-8.tar.gz
cp -r ss5-3.8.9 ss5-3.8.9-modify
cd ss5-3.8.9
./configure
make
make install
##sed -i "s/^#auth /auth /" /etc/opt/ss5/ss5.conf
##sed -i "s/^#permit /permit /" /etc/opt/ss5/ss5.conf
 
cat >/etc/opt/ss5/ss5.conf<<EOF
auth    0.0.0.0/0               -              u
permit u       0.0.0.0/0       -       0.0.0.0/0       -       -       -       -    -
EOF
 
 
 
 
 
##添加用户
for((i=6001;i<=6200;i++));do /usr/sbin/useradd socks$i -u $i -M -s /sbin/nologin ;done
 
 
##配置网卡IP
cat>/etc/sysconfig/network-scripts/ifcfg-en33<<EOF
TYPE=Ethernet
BOOTPROTO=static
PEERROUTES=YES
DEFROUTE=yes
NAME=ens33
DEVICE=ens33
ONBOOT=yes
DEFROUTE=YES
DEFDNS=YES
DNS1=114.114.114.114
NETMASK=255.255.255.0
GATEWAY0=192.168.100.254
IPADDR0=192.168.100.201
IPADDR1=192.168.100.1
IPADDR2=192.168.100.2
IPADDR3=192.168.100.3
IPADDR4=192.168.100.4
IPADDR5=192.168.100.5
IPADDR6=192.168.100.6
IPADDR7=192.168.100.7
IPADDR8=192.168.100.8
IPADDR9=192.168.100.9
IPADDR10=192.168.100.10
IPADDR11=192.168.100.11
IPADDR12=192.168.100.12
IPADDR13=192.168.100.13
IPADDR14=192.168.100.14
IPADDR15=192.168.100.15
IPADDR16=192.168.100.16
IPADDR17=192.168.100.17
IPADDR18=192.168.100.18
IPADDR19=192.168.100.19
IPADDR20=192.168.100.20
EOF
##for((i=1;i<=200;i++));do /sbin/ip address add 192.168.100.$i/24 dev ens33;done
##配置iptables
systemctl enable iptables
iptables -F
iptables -t mangle -F OUTPUT
for ((i=6001; i <= 6200 ; i++))
do
iptables -t mangle -A OUTPUT -m owner --uid-owner $i -j MARK --set-mark $i
done
iptables -t nat -F POSTROUTING
for ((i=6001; i<=6200 ; i++))
do
iptables -t nat -A POSTROUTING -m mark --mark $i -j SNAT --to 192.168.100.$(($i-6000))
done
iptables-save >/etc/sysconfig/iptables
 
##配置SS5自动启动
cat>/etc/rc.d/rc.local<<EOF
#!/bin/bash
touch /var/local/subsys/local
mkdir -p /var/run/ss5
for i in `seq 6001 6200`
do
usleep 300
ss5 -m -t -u socks$i -b 0.0.0.0:$i
ss5radius -m -t -u socks$i -b 0.0.0.0:$(($i+1000))
done
EOF
chmod +x /etc/rc.d/rc.local
 
/systemctl start iptables
