# ---------- 构建阶段：Maven + JDK17，最终不会被打进运行镜像 ----------
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /build

# 先只拷 pom.xml 单独一层：改业务代码时这一层命中缓存，不会重新下载依赖
COPY pom.xml .
RUN mvn -B dependency:go-offline

COPY src ./src
RUN mvn -B clean package -DskipTests

# ---------- 运行阶段：只有 JRE，没有 Maven 和源码 ----------
FROM eclipse-temurin:17-jre-jammy

# HEALTHCHECK 依赖 curl，而精简 JRE 镜像默认不带 —— 这里必须显式装。
# 不装的话 healthcheck 永远失败，而 compose 里 nginx 依赖 web 的 service_healthy，
# 结果是 nginx 永远起不来，很容易被误判成"后端启动慢"。
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd -r app && useradd -r -g app app \
 && mkdir -p /app/logs && chown -R app:app /app

WORKDIR /app
COPY --from=build --chown=app:app /build/target/app.jar /app/app.jar

ENV TZ=Asia/Shanghai \
    SPRING_PROFILES_ACTIVE=prod \
    JAVA_OPTS="-Xms256m -Xmx512m"

USER app
EXPOSE 8080

HEALTHCHECK --interval=15s --timeout=5s --retries=5 --start-period=40s \
  CMD curl -fsS http://localhost:8080/actuator/health || exit 1

ENTRYPOINT ["sh","-c","exec java $JAVA_OPTS -jar /app/app.jar"]
