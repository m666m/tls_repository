#!/bin/sh
set -e

# 接收如下环境变量
#   TZ            自制镜像支持用环境变量设置时区
#   DOMAIN        用于生成CA证书SAN属性的域名列表，docker 客户端访问仓库可以使用这些域名，否则 tls 报错。
#   IP_ADDRS      用于生成CA证书SAN属性的ip地址列表，docker 客户端访问仓库可以使用这些ip地址，否则 tls 报错。
#   AUTH_USER     用于生成 htpasswd 认证的用户名
#   AUTH_PASS     用于生成 htpasswd 认证的密码
#
# 为保证可多次执行，如果证书等文件已经存在则不使用这些变量生成对应的文件
# 然后引导 registry 启动仓库服务

# ---------- TLS 证书处理 ----------
if [ ! -f /certs/domain.crt ] || [ ! -f /certs/domain.key ]; then
    # 需要生成证书，必须提供域名或 IP 列表
    if [ -z "$DOMAIN" ] && [ -z "$IP_ADDRS" ]; then
        echo "错误：未找到现有证书，且环境变量 DOMAIN 和 IP_ADDRS 均为空。"
        echo "请挂载已有证书到 /certs，或通过 -e DOMAIN=... 和/或 -e IP_ADDRS=... 提供至少一个域名或 IP 以自动生成证书。"
        exit 1
    fi

    # 确定 CN：优先使用 DOMAIN，否则使用 IP_ADDRS 的第一个 IP
    if [ -n "$DOMAIN" ]; then
        CN="$DOMAIN"
    else
        CN=$(echo "$IP_ADDRS" | cut -d' ' -f1)
    fi
    echo "未找到证书文件，正在生成自签名证书，CN=${CN}..."

    # 构建 subjectAltName 扩展
    SAN="DNS:${CN}"   # 至少包含 CN
    if [ -n "$IP_ADDRS" ]; then
        for ip in $IP_ADDRS; do
            SAN="${SAN},IP:${ip}"
        done
    fi

    openssl req -x509 -newkey rsa:2048 -noenc \
        -keyout /certs/domain.key \
        -out /certs/domain.crt \
        -days 3650 \
        -subj "/CN=${CN}" \
        -addext "subjectAltName = ${SAN}" \
        -addext "basicConstraints = CA:TRUE"

    echo "自签名证书已生成到 /certs 目录"
    echo "提示：请将 /certs/domain.crt 复制到 Docker 客户端信任目录，路径格式为 /etc/docker/certs.d/${CN}/ca.crt"
else
    echo "使用现有证书（/certs/domain.crt 和 /certs/domain.key）"
    CN="$DOMAIN"
fi

export REGISTRY_HTTP_TLS_CERTIFICATE=/certs/domain.crt
export REGISTRY_HTTP_TLS_KEY=/certs/domain.key

# ---------- HTTP 认证处理 ----------
if [ ! -f /auth/htpasswd ]; then
    if [ -z "$AUTH_USER" ] || [ -z "$AUTH_PASS" ]; then
        echo "错误：未找到 /auth/htpasswd 文件，且未设置环境变量 AUTH_USER 和 AUTH_PASS"
        echo "请挂载已有的 htpasswd 文件，或通过 -e 提供初始用户名和密码以自动生成。"
        exit 1
    fi

    echo "根据环境变量创建 htpasswd 文件..."
    htpasswd -Bbc /auth/htpasswd "$AUTH_USER" "$AUTH_PASS"
    echo "用户 ${AUTH_USER} 已创建"
else
    echo "使用现有 htpasswd 文件（/auth/htpasswd）"
fi

export REGISTRY_AUTH=htpasswd
export REGISTRY_AUTH_HTPASSWD_REALM="Registry Realm"
export REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd

# ---------- 存储路径 ----------
export REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY=/data

# ---------- 启动 ----------
echo "启动 Docker Registry (HTTPS) - 主要地址: ${CN:-未知}"
exec registry serve /etc/docker/registry/config.yml

