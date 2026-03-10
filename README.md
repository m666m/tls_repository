# tls_repository

Auto deployment of an docker repository based on Docker Registry 2, supporting self-signed certificate for TLS and htpasswd authentication.

## Usage

    $ git clone --depth=1 https://github.com/m666m/tls_repository
    $ cd tls_repository

    $ ./deploy.sh
    用法: ./deploy.sh <密码> [仓库地址]
    示例:
    ./deploy.sh 123456                    # 使用 hostname.local 作为域名
    ./deploy.sh 123456 myregistry.local   # 使用指定域名（FQDN）
    ./deploy.sh 123456 myhost              # 短名，自动补 .local
    ./deploy.sh 123456 192.168.1.100       # 使用指定 IP，域名取 hostname.local

仓库地址可以是 IP 或域名（FQDN 或短名），用于CA证书SAN属性的域名和ip地址，docker 客户端访问仓库时使用。登录用户名 admin。

详细使用方法会在部署成功后列出，示例如下：

    $ ./deploy.sh 123456 192.168.1.100
    检测到输入为 IP 地址: 192.168.1.100
    证书SAN属性的 IP 地址: 192.168.1.100 172.17.0.1
    证书SAN属性的域名: my-host.local
    项目名: tls_repository
    compose.yml 已更新
    正在构建镜像并启动容器...
    [+] Building 1.8s (13/13) FINISHED
     => [internal] load local bake definitions          0.0s
      ...
     ✔ Container tls_repository-registry2-1 Started    0.6s
    ==========================================
    部署成功！
    私有镜像仓库主要地址: https://192.168.1.100

    查询仓库镜像列表：
      curl -k -u "admin:123456" https://192.168.1.100/v2/_catalog

    先执行 分发证书 步骤，将证书部署到 Docker 客户端，然后再尝试以下操作：

    登录: docker login 192.168.1.100 -u admin -p 123456
    注销登录: docker logout 192.168.1.100

    推送测试：

      docker tag tls_repository-registry2:latest 192.168.1.100/    tls_repository-registry2:latest

      docker push 192.168.1.100/tls_repository-registry2:latest

    ---------- 分发证书 ----------

    根据当前项目名（目录名），推测卷名如下：

      证书卷名: tls_repository_certs
      认证卷名: tls_repository_auth
      数据卷名: tls_repository_data

    提取证书到当前目录：

      docker run --rm -v tls_repository_certs:/certs alpine cat /certs/domain.crt > domain.crt

    查看证书的 SAN 属性：

      openssl x509 -in domain.crt -noout -text | grep -A 1 'Subject Alternative Name'

    分发证书到内网的各个主机（略）。

    各主机将证书部署到 Docker 客户端（以主要地址 192.168.1.100 为例）：

      sudo mkdir -p /etc/docker/certs.d/192.168.1.100
      sudo cp domain.crt /etc/docker/certs.d/192.168.1.100/ca.crt
      sudo systemctl restart docker   # 可选

    ---------- 日常使用 ----------
    启动仓库容器：
      cd /home/your_user/ghcode/tls_repository && docker compose up
    停止仓库容器：
      cd /home/your_user/ghcode/tls_repository && docker compose down

    ---------- 重置证书和密码 ----------

    如需重新生成证书（例如更换域名）或更改密码，但保留镜像数据：

      1. 停止容器：cd /home/your_user/ghcode/tls_repository && docker compose down

      2. 删除卷中的证书和密码文件：

        docker run --rm -v tls_repository_certs:/certs alpine rm -f /certs/domain.crt / certs/domain.key

        docker run --rm -v tls_repository_auth:/auth alpine rm -f /auth/htpasswd

      3. 重新运行 deploy.sh 并指定新密码和域名

    如果想完全重置所有数据，包括已推送到仓库中的镜像，可删除整个卷：

      docker compose down -v

    ==========================================
