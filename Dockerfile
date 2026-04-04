# 使用 Docker 官方的 Registry 镜像版本 V2 作为基础，其基础镜像是 Alpine
FROM registry:2

# 换国内镜像源，安装时总有软件包找不到，没办法
#RUN sed -i 's#https\?://dl-cdn.alpinelinux.org/alpine#https://mirrors.tuna.tsinghua.edu.cn/alpine#g' /etc/apk/repositories

# 安装必要的工具：openssl（生成证书）、apache2-utils（生成 htpasswd）、tzdata（设置时区）、curl（健康检查）
# 减少包容量，不用 RUN apk update && apk add --no-cache xxx
# https://linuxvox.com/blog/explanation-of-the-update-add-command-for-alpine-linux/
RUN apk --update add --no-cache \
      openssl \
      apache2-utils \
      tzdata \
      curl

# 支持运行容器时使用环境变量 TZ 设置时区 https://wiki.alpinelinux.org/wiki/Setting_the_timezone
ENV TZ=UTC
#RUN ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime && \
#    echo ${TZ} > /etc/timezone

# 创建必要的目录
RUN mkdir -p /certs /auth /var/lib/registry
RUN mkdir -p /etc/docker/registry

# 复制预置的默认配置文件，支持删除镜像
COPY config.yml /etc/docker/registry/config.yml

# 复制启动脚本
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# 声明卷，与宿主机挂载点对应
VOLUME ["/certs", "/auth", "/var/lib/registry"]

# 声明容器内服务端口为 5000，来自基础镜像 registry:2
EXPOSE 5000

# 健康检查，放到 compose 文件里做
# 每隔30秒检查一次，超时10秒，容器启动后等待10秒开始检查，连续失败3次视为不健康
# 检查命令：使用 curl 访问 registry 的 v2 端点（忽略证书验证），只要服务能响应（包括 401 未授权）即视为健康
#HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
#  CMD curl -k https://localhost:5000/v2/ || exit 1

ENTRYPOINT ["/entrypoint.sh"]
