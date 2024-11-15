#!/bin/bash
rm -f $0
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

function rand_psk()
{
    r_psk=`mkpasswd -l 9 -s 0 -c 3 -C 3 -d 3`
    echo $r_psk
}

function rand_pass()
{
    pass=`mkpasswd -l 6 -s 0 -c 0 -C 0 -d 6`
    echo $pass
}

rootness(){
    if [[ $EUID -ne 0 ]]; then
       echo "必须使用root账号运行!" 1>&2
       exit 1
    fi
}

tunavailable(){
    if [[ ! -e /dev/net/tun ]]; then
        echo "TUN/TAP设备不可用!" 1>&2
        exit 1
    fi
}

elinux(){
    if [ -s /etc/selinux/config ] && grep 'SELINUX=enforcing' /etc/selinux/config; then
        sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
        setenforce 0
    fi
}

get_os_info(){
    IP=$( ip addr | egrep -o '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | egrep -v "^192\.168|^172\.1[6-9]\.|^172\.2[0-9]\.|^172\.3[0-2]\.|^10\.|^127\.|^255\.|^0\." | head -n 1 )
    [ -z ${IP} ] && IP=$( wget -qO- -t1 -T2 ipv4.icanhazip.com )
}

preinstall_l2tp(){
    if [ -d "/proc/vz" ]; then
        echo -e "\\033[41;37m WARNING: \\033[0m Your VPS is based on OpenVZ, and IPSec might not be supported by the kernel."
        echo "Continue installation? (y/n)"
        read -p "(Default: n)" agree
        [ -z ${agree} ] && agree="n"
        if [ "${agree}" == "n" ]; then
            echo
            echo "L2TP installation cancelled."
            echo
            exit 0
        fi
    fi
    
    # IP 地址段
    iprange="192.168.18"
    
    # 预共享密钥
    mypsk="1472580++"
    
    echo "###"
    echo "公网ip: ${IP}"
    echo "l2tp网关: ${iprange}.1"
    echo "拨入客户端可用ip范围: ${iprange}.2-${iprange}.254"
    echo "PSK预共享密钥: ${mypsk}"
    echo "###########################"
}

install_l2tp(){
    mknod /dev/random c 1 9
    yum -y install epel-*
    yum -y install ppp libreswan xl2tpd iptables iptables-services
    yum_install
}

config_install(){
    # 配置 IPSec
    cat > /etc/ipsec.conf <<EOF
version 2.0

config setup
    protostack=netkey
    nhelpers=0
    uniqueids=no
    interfaces=%defaultroute
    virtual_private=%v4:10.0.0.0/8,%v4:192.168.0.0/16,%v4:172.16.0.0/12,%v4:!${iprange}.0/24

conn l2tp-psk
    rightsubnet=vhost:%priv
    also=l2tp-psk-nonat

conn l2tp-psk-nonat
    authby=secret
    pfs=no
    auto=add
    keyingtries=3
    rekey=no
    ikelifetime=8h
    keylife=1h
    type=transport
    left=%defaultroute
    leftid=${IP}
    leftprotoport=17/1701
    right=%any
    rightprotoport=17/%any
    dpddelay=40
    dpdtimeout=130
    dpdaction=clear
    sha2

EOF

    # 配置 IPSec 秘钥
    cat > /etc/ipsec.secrets <<EOF
%any %any : PSK "${mypsk}"
EOF

    # 配置 xl2tpd
    cat > /etc/xl2tpd/xl2tpd.conf <<EOF
[global]
port = 1701

[lns default]
ip range = ${iprange}.2-${iprange}.254
local ip = ${iprange}.1
require chap = yes
refuse pap = yes
require authentication = yes
name = l2tpd
ppp debug = yes
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF

    # 配置 PPP 选项
    cat > /etc/ppp/options.xl2tpd <<EOF
ipcp-accept-local
ipcp-accept-remote
require-mschap-v2
ms-dns 8.8.8.8
ms-dns 8.8.4.4
noccp
auth
hide-password
idle 0
mtu 1410
mru 1410
nodefaultroute
debug
proxyarp
connect-delay 5000
multilink
EOF

    # 配置 CHAP 秘钥
    rm -f /etc/ppp/chap-secrets
    cat > /etc/ppp/chap-secrets <<EOF
# Secrets for authentication using CHAP
# client    server    secret    IP addresses
ddvpn    l2tpd    dd123    *
EOF
}

yum_install(){
    config_install

    # 开启 IP 转发
    cp -pf /etc/sysctl.conf /etc/sysctl.conf.bak
    echo "# Added by L2TP VPN" >> /etc/sysctl.conf
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p

    # 开放必要的防火墙端口
    iptables -A INPUT -p udp --dport 500 -j ACCEPT
    iptables -A INPUT -p udp --dport 4500 -j ACCEPT
    iptables -A INPUT -p udp --dport 1701 -j ACCEPT
    service iptables save

    # 重启服务
    systemctl restart ipsec
    systemctl restart xl2tpd
    systemctl enable ipsec
    systemctl enable xl2tpd
}

# 执行安装
rootness
tunavailable
elinux
get_os_info
preinstall_l2tp
install_l2tp

echo "L2TP VPN 安装和配置完成，请检查防火墙和路由设置，确保端口 500, 4500, 1701 已开放。"
