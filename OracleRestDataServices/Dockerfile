# Based on GraalVM
ARG ORDS_VERSION
ARG ORDS_RPM_URL
ARG SQLCL_RPM_URL
ARG GRAALVM_BASE_IMAGE=container-registry.oracle.com/graalvm/jdk:25

FROM maven:3.9-eclipse-temurin-21 AS jar-downloader

COPY <<'EOF' /tmp/pom.xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.oracle.ords</groupId>
  <artifactId>graalvm-js-jars</artifactId>
  <version>25.0.0</version>

  <properties>
    <graalvm.version>25.0.0</graalvm.version>
  </properties>

  <dependencies>
    <dependency><groupId>org.graalvm.sdk</groupId><artifactId>collections</artifactId><version>${graalvm.version}</version></dependency>
    <dependency><groupId>org.graalvm.shadowed</groupId><artifactId>icu4j</artifactId><version>${graalvm.version}</version></dependency>
    <dependency><groupId>org.graalvm.sdk</groupId><artifactId>jniutils</artifactId><version>${graalvm.version}</version></dependency>
    <dependency><groupId>org.graalvm.js</groupId><artifactId>js-language</artifactId><version>${graalvm.version}</version></dependency>
    <dependency><groupId>org.graalvm.sdk</groupId><artifactId>nativeimage</artifactId><version>${graalvm.version}</version></dependency>
    <dependency><groupId>org.graalvm.polyglot</groupId><artifactId>polyglot</artifactId><version>${graalvm.version}</version></dependency>
    <dependency><groupId>org.graalvm.regex</groupId><artifactId>regex</artifactId><version>${graalvm.version}</version></dependency>
    <dependency><groupId>org.graalvm.truffle</groupId><artifactId>truffle-api</artifactId><version>${graalvm.version}</version></dependency>
    <dependency><groupId>org.graalvm.truffle</groupId><artifactId>truffle-compiler</artifactId><version>${graalvm.version}</version></dependency>
    <dependency><groupId>org.graalvm.truffle</groupId><artifactId>truffle-runtime</artifactId><version>${graalvm.version}</version></dependency>
    <dependency><groupId>org.graalvm.sdk</groupId><artifactId>word</artifactId><version>${graalvm.version}</version></dependency>
    <dependency><groupId>org.graalvm.shadowed</groupId><artifactId>xz</artifactId><version>${graalvm.version}</version></dependency>
  </dependencies>
</project>
EOF

RUN mvn --batch-mode --no-transfer-progress -f /tmp/pom.xml dependency:copy-dependencies \
      -DoutputDirectory=/tmp/jar-files \
      -DincludeScope=compile \
      -DexcludeTransitive=true \
    && rm -rf /root/.m2 /tmp/pom.xml

FROM ${GRAALVM_BASE_IMAGE} AS builder
ARG ORDS_VERSION
ARG ORDS_RPM_URL
ARG SQLCL_RPM_URL
COPY --from=jar-downloader /tmp/jar-files /tmp/jar-files

RUN  microdnf install -y curl ncurses procps-ng \
     && microdnf clean all \
     && curl --fail --location --show-error \
          "${ORDS_RPM_URL}" \
          --output /tmp/ords.rpm \
     && curl --fail --location --show-error \
          "${SQLCL_RPM_URL}" \
          --output /tmp/sqlcl.rpm \
     && rpm -i --nodeps /tmp/ords.rpm \
     && rpm -i --nodeps /tmp/sqlcl.rpm \
     && mkdir -p /opt/oracle/ords/lib/ext \
     && cp /tmp/jar-files/*.jar /opt/oracle/ords/lib/ext/. \
     && chmod 644 /opt/oracle/ords/lib/ext/*.jar \
     # set ords config default when not installed by rpm
     && sed -i 's/rpm -qf/echo/g' /opt/oracle/ords/bin/ords \
     && rm -rf /tmp/jar-files /tmp/pom.xml
FROM ${GRAALVM_BASE_IMAGE}


ARG  ORDS_VERSION
ENV  ORDS_VER=$ORDS_VERSION \
     JAVA_HOME=/opt/graalvm \
     DB_WAIT_RETRY=60 \
     PATH=/opt/graalvm/bin/:$PATH

RUN  microdnf install -y curl ncurses \
     && microdnf clean all \
     && GRAALVM_HOME="$(java -XshowSettings:properties -version 2>&1 | awk -F'= ' '/java.home =/ { print $2; exit }')" \
     && test -x "${GRAALVM_HOME}/bin/java" \
     && if [ "${GRAALVM_HOME}" != "/opt/graalvm" ]; then rm -rf /opt/graalvm && ln -s "${GRAALVM_HOME}" /opt/graalvm; fi \
     && groupadd -f -g 54321 oinstall  \
     && if ! id -u oracle >/dev/null 2>&1; then useradd -u 54321 -g oinstall -c "The Oracle Software Owner User" oracle; fi \
     && mkdir -p /etc/ords/config && chown oracle:oinstall /etc/ords/config

COPY --from=builder ["/opt/oracle/", "/opt/oracle/"]
COPY srcfiles/entrypoint.sh /usr/bin/docker-entrypoint.sh

RUN  ln -s  /opt/oracle/ords/bin/ords  /usr/bin/ords \
     && ln -s  /opt/oracle/sqlcl/bin/sql  /usr/bin/sql 

USER oracle
WORKDIR /opt/oracle/ords
EXPOSE 8080 8443
ENTRYPOINT ["/usr/bin/docker-entrypoint.sh"]
