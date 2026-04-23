#!/bin/bash
set -e

# 用法：deploy.sh <密码> [地址]
if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "用法: $0 <密码> [仓库地址]"
    echo "示例:"
    echo "  $0 123456                     # 使用 hostname.local 作为域名"
    echo "  $0 123456 myregistry.local    # 使用指定域名（FQDN）"
    echo "  $0 123456 myhost              # 短名，自动补 .local"
    echo "  $0 123456 192.168.1.100       # 使用指定 IP，域名取 hostname.local"
    echo "仓库地址可以是 IP 或域名（FQDN 或短名），用于CA证书SAN属性的域名和ip地址，docker 客户端访问仓库时使用。登录用户名 admin。"
    exit 1
fi

PASSWORD="$1"
ADDRESS="$2"
BASE64UP=$(echo -n "admin:${PASSWORD}" | base64)

# 检查 _ssca.sh 是否存在
if [ ! -f _ssca.sh ]; then
    echo "错误：当前目录下未找到 _ssca.sh 文件"
    exit 1
fi

# ---------- 调用 _ssca.sh 生成证书信息 ----------
source ./_ssca.sh "$ADDRESS"

# 此时已获得以下环境变量：
#   _ssca_CN         证书 CN（第一个域名）
#   _ssca_SAN        完整的 subjectAltName 字符串（可用于 openssl）
#   _ssca_SAN_DNS    空格分隔的域名列表
#   _ssca_SAN_IP     空格分隔的 IP 列表

# 输出信息供用户确认
echo "证书SAN属性的域名: $_ssca_SAN_DNS"
echo "证书SAN属性的 IP 地址: $_ssca_SAN_IP"

# 项目名（目录名）
PROJECT_NAME=$(basename "$(pwd)")
echo "项目名: $PROJECT_NAME"

# 检查 compose.yaml 是否存在
if [ ! -f compose.yaml ]; then
    echo "错误：当前目录下未找到 compose.yaml 文件"
    exit 1
fi

# 替换 compose.yaml 中的变量（使用双引号包裹）
sed -i "s|^\(\s*- DOMAINS=\).*|\1\"${_ssca_SAN_DNS}\"|" compose.yaml
sed -i "s|^\(\s*- IP_ADDRS=\).*|\1\"${_ssca_SAN_IP}\"|" compose.yaml
sed -i "s|^\(\s*- AUTH_PASS=\).*|\1${PASSWORD}|" compose.yaml
sed -i "s|^\(\s*- NGINX_PROXY_HEADER_Authorization=\).*|\1Basic ${BASE64UP}|" compose.yaml

echo "compose.yaml 已更新"
# 静默正常输出，但保留错误信息（推荐）
docker compose config >/dev/null || {
    echo "❌ compose.yaml error!" >&2
    exit 1
}

echo "正在构建镜像并启动容器..."
docker compose up --build -d

if [ $? -eq 0 ]; then
    # 确定主要地址（纯主机名/IP，不带端口）
    if echo "$ADDRESS" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' 2>/dev/null; then
        MAIN_ADDR="$ADDRESS"
    else
        MAIN_ADDR="$_ssca_CN"
    fi

    echo "等待容器启动并获取映射端口（最多10秒）..."
    # 等待最多10秒，直到容器运行且端口映射可用
    WAIT_SECONDS=10
    while [ $WAIT_SECONDS -gt 0 ]; do
        # 检查容器状态是否为 running
        if docker compose ps --status running registry2 | grep -q "registry2"; then
            # 尝试获取端口
            HOST_PORT=$(docker compose port registry2 5000 2>/dev/null | cut -d: -f2)
            WEB_PORT=$(docker compose port registry-ui 80 2>/dev/null | cut -d: -f2)
            if [ -n "$HOST_PORT" ] && [ -n "$WEB_PORT" ]; then
                break
            fi
        fi

        sleep 1
        WAIT_SECONDS=$((WAIT_SECONDS - 1))
    done

    if [ -z "$HOST_PORT" ]; then
        echo "警告：等待10秒后仍无法获取映射端口，使用说明默认按 443 输出内容。"
        HOST_PORT="443"
    fi

    # 根据端口生成带端口的访问地址和证书目录名
    if [ "$HOST_PORT" = "443" ]; then
        ADDR_WITH_PORT="$MAIN_ADDR"
        CERT_DIR="$MAIN_ADDR"
    else
        ADDR_WITH_PORT="${MAIN_ADDR}:${HOST_PORT}"
        CERT_DIR="${MAIN_ADDR}:${HOST_PORT}"
    fi

    echo "=========================================="
    echo "部署成功！"
    echo "私有镜像仓库主要地址: https://$ADDR_WITH_PORT"
    echo "浏览器访问 UI 管理镜像: http://${MAIN_ADDR}:${WEB_PORT}"
    echo ""
    echo "查询仓库镜像列表："
    echo "  curl -k -u \"admin:${PASSWORD}\" https://${ADDR_WITH_PORT}/v2/_catalog"
    echo ""
    echo "先执行 分发证书 步骤，将证书部署到 Docker 客户端，然后再尝试以下操作："
    echo ""
    echo "登录: docker login $ADDR_WITH_PORT -u admin -p $PASSWORD"
    echo "注销登录: docker logout $ADDR_WITH_PORT"
    echo ""
    echo "推送测试："
    echo ""
    echo "  docker tag ${PROJECT_NAME}-registry2:latest ${ADDR_WITH_PORT}/${PROJECT_NAME}-registry2:latest"
    echo ""
    echo "  docker push ${ADDR_WITH_PORT}/${PROJECT_NAME}-registry2:latest"
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
    echo "各主机将证书部署到 Docker 客户端（以主要地址 $ADDR_WITH_PORT 为例）："
    echo ""
    echo "  sudo mkdir -p /etc/docker/certs.d/$CERT_DIR"
    echo "  sudo cp domain.crt /etc/docker/certs.d/$CERT_DIR/ca.crt"
    echo "  sudo systemctl restart docker   # 可选"
    echo ""
    echo "---------- 日常管理 ----------"
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
    echo "部署失败，请检查日志： docker compose logs registry2"
    exit 1
fi

