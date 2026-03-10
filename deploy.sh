#!/bin/bash
set -e

# 用法：deploy.sh <密码> [地址]
if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "用法: $0 <密码> [仓库地址]"
    echo "示例:"
    echo "  $0 123456                    # 使用 hostname.local 作为域名"
    echo "  $0 123456 myregistry.local   # 使用指定域名（FQDN）"
    echo "  $0 123456 myhost              # 短名，自动补 .local"
    echo "  $0 123456 192.168.1.100       # 使用指定 IP，域名取 hostname.local"
    echo "仓库地址可以是 IP 或域名（FQDN 或短名），用于CA证书SAN属性的域名和ip地址，docker 客户端访问仓库时使用。登录用户名 admin。"
    exit 1
fi

PASSWORD="$1"
ADDRESS="$2"

# ---------- 辅助函数 ----------
# 向 IP_LIST 中添加 IP，确保唯一性并按指定位置插入
add_ip_to_list() {
    local ip="$1"
    local position="$2"   # front 或 back
    local new_list=""

    # 如果当前列表非空，先移除已有的相同 IP
    if [ -n "$IP_LIST" ]; then
        # 将列表拆分为行，过滤掉要添加的 IP，再重新组合
        new_list=$(echo "$IP_LIST" | tr ' ' '\n' | grep -v "^$ip$" | tr '\n' ' ' | sed 's/ $//')
    fi

    # 按位置插入 IP
    if [ "$position" = "front" ]; then
        IP_LIST="$ip $new_list"
    else
        IP_LIST="$new_list $ip"
    fi
    # 去除可能的多余空格
    IP_LIST=$(echo "$IP_LIST" | tr -s ' ' | sed 's/^ *//;s/ *$//')
}

# 向 DOMAINS 中添加域名（插入最前），自动去重
add_domain_front() {
    local domain="$1"
    local new_list=""

    if [ -n "$DOMAINS" ]; then
        new_list=$(echo "$DOMAINS" | tr ' ' '\n' | grep -v "^$domain$" | tr '\n' ' ' | sed 's/ $//')
    fi

    DOMAINS="$domain $new_list"
    DOMAINS=$(echo "$DOMAINS" | tr -s ' ' | sed 's/^ *//;s/ *$//')
}

# ---------- 初始化 IP_LIST ----------
IP_LIST=""
# 收集本机所有非回环 IPv4 地址（按原有顺序）
for ip in $(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.'); do
    add_ip_to_list "$ip" "back"
done
# 添加 127.0.0.1（若已存在则自动去重，并置于最后）
add_ip_to_list "127.0.0.1" "back"

# ---------- 初始化 DOMAINS ----------
HOSTNAME=$(hostname)
if [[ "$HOSTNAME" == *.* ]]; then
    # 主机名已包含点，直接使用
    INIT_DOMAIN="$HOSTNAME"
else
    # 否则添加 .local
    INIT_DOMAIN="${HOSTNAME}.local"
fi
DOMAINS="$INIT_DOMAIN localhost"

# ---------- 处理用户输入 ----------
if [ -n "$ADDRESS" ]; then
    # 判断是否为 IPv4 地址
    if echo "$ADDRESS" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        echo "检测到输入为 IP 地址: $ADDRESS"
        # 将用户输入的 IP 添加到 IP_LIST 最前面
        add_ip_to_list "$ADDRESS" "front"
        echo "证书SAN属性的 IP 地址: $IP_LIST"
        echo "证书SAN属性的域名: $DOMAINS"   # 域名保持初始值
    else
        # 用户输入的是域名
        echo "检测到输入为域名: $ADDRESS"
        # 构造完整域名
        if [ "$ADDRESS" = "localhost" ]; then
            FULL_DOMAIN="localhost"
        elif ! echo "$ADDRESS" | grep -q '\.'; then
            FULL_DOMAIN="${ADDRESS}.local"
        else
            FULL_DOMAIN="$ADDRESS"
        fi
        # 添加到 DOMAINS 最前面
        add_domain_front "$FULL_DOMAIN"
        echo "证书SAN属性的域名: $DOMAINS"
        echo "证书SAN属性的 IP 地址: $IP_LIST"
    fi
else
    echo "未指定地址，使用默认值"
    echo "证书SAN属性的域名: $DOMAINS"
    echo "证书SAN属性的 IP 地址: $IP_LIST"
fi

# 项目名（目录名）
PROJECT_NAME=$(basename "$(pwd)")
echo "项目名: $PROJECT_NAME"

# 检查 compose.yml 是否存在
if [ ! -f compose.yml ]; then
    echo "错误：当前目录下未找到 compose.yml 文件"
    exit 1
fi

# 替换 compose.yml 中的变量（使用双引号包裹）
sed -i "s|^\(\s*- DOMAINS=\).*|\1\"${DOMAINS}\"|" compose.yml
sed -i "s|^\(\s*- IP_ADDRS=\).*|\1\"${IP_LIST}\"|" compose.yml
sed -i "s|^\(\s*- AUTH_PASS=\).*|\1${PASSWORD}|" compose.yml

echo "compose.yml 已更新"

echo "正在构建镜像并启动容器..."
docker compose up --build -d

if [ $? -eq 0 ]; then
    if echo "$ADDRESS" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        MAIN_ADDR="$ADDRESS"
    else
        # 取第一个域名作为主要地址
        MAIN_ADDR=$(echo "$DOMAINS" | cut -d' ' -f1)
    fi

    echo "=========================================="
    echo "部署成功！"
    echo "私有镜像仓库主要地址: https://$MAIN_ADDR"
    echo ""
    echo "查询仓库镜像列表："
    echo "  curl -k -u \"admin:${PASSWORD}\" https://${MAIN_ADDR}/v2/_catalog"
    echo ""
    echo "先执行 分发证书 步骤，将证书部署到 Docker 客户端，然后再尝试以下操作："
    echo ""
    echo "登录: docker login $MAIN_ADDR -u admin -p $PASSWORD"
    echo "注销登录: docker logout $MAIN_ADDR "
    echo ""
    echo "推送测试："
    echo ""
    echo "  docker tag ${PROJECT_NAME}-registry2:latest ${MAIN_ADDR}/${PROJECT_NAME}-registry2:latest"
    echo ""
    echo "  docker push ${MAIN_ADDR}/${PROJECT_NAME}-registry2:latest"
    echo ""
    echo "---------- 分发证书 ----------"
    echo ""
    echo "根据当前项目名（目录名），推测卷名如下："
    echo ""
    CERT_VOL="${PROJECT_NAME}_certs"
    AUTH_VOL="${PROJECT_NAME}_auth"
    DATA_VOL="${PROJECT_NAME}_data"
    echo "  证书卷名: $CERT_VOL"
    echo "  认证卷名: $AUTH_VOL"
    echo "  数据卷名: $DATA_VOL"
    echo ""
    echo "提取证书到当前目录："
    echo ""
    echo "  docker run --rm -v $CERT_VOL:/certs alpine cat /certs/domain.crt > domain.crt"
    echo ""
    echo "查看证书的 SAN 属性："
    echo ""
    echo "  openssl x509 -in domain.crt -noout -text | grep -A 1 'Subject Alternative Name'"
    echo ""
    echo "分发证书到内网的各个主机（略）。"
    echo ""
    echo "各主机将证书部署到 Docker 客户端（以主要地址 $MAIN_ADDR 为例）："
    echo ""
    echo "  sudo mkdir -p /etc/docker/certs.d/$MAIN_ADDR"
    echo "  sudo cp domain.crt /etc/docker/certs.d/$MAIN_ADDR/ca.crt"
    echo "  sudo systemctl restart docker   # 可选"
    echo ""
    echo "---------- 日常使用 ----------"
    echo "启动仓库容器："
    echo "  cd $(pwd) && docker compose up"
    echo "停止仓库容器："
    echo "  cd $(pwd) && docker compose down"
    echo ""
    echo "---------- 重置证书和密码 ----------"
    echo ""
    echo "如需重新生成证书（例如更换域名）或更改密码，但保留镜像数据："
    echo ""
    echo "  1. 停止容器：cd $(pwd) && docker compose down"
    echo ""
    echo "  2. 删除卷中的证书和密码文件："
    echo ""
    echo "    docker run --rm -v $CERT_VOL:/certs alpine rm -f /certs/domain.crt /certs/domain.key"
    echo ""
    echo "    docker run --rm -v $AUTH_VOL:/auth alpine rm -f /auth/htpasswd"
    echo ""
    echo "  3. 重新运行 deploy.sh 并指定新密码和域名"
    echo ""
    echo "如果想完全重置所有数据，包括已推送到仓库中的镜像，可删除整个卷："
    echo ""
    echo "  docker compose down -v"
    echo ""
    echo "=========================================="
else
    echo "部署失败，请检查日志"
    exit 1
fi

