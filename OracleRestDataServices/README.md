# Oracle REST Data Services Docker Image Documentation.

Oracle REST Data Services (ORDS) is a mid-tier Java application that provides a Database Management REST API, the browser-based client SQL Developer Web, a PL/SQL Gateway, SODA for REST, and the ability to publish RESTful Web Services for interacting with the data and stored procedures in your Oracle Database. See https://www.oracle.com/rest for more information.

## Building your own ORDS image


To build a custom ORDS image, you must first select the desired SQLCL and ORDS RPM packages from the Oracle repository to determine their versions. These versions should then be passed as build arguments (`--build-arg`) during the container build process.

[OL10 repository.](https://yum.oracle.com/repo/OracleLinux/OL10/oracle/software/x86_64/index.html)

- Build the image
```bash
# Set the variables for an ARM64 build and the ORDS version you selected.
export ords_ver=26.2.2
export sqlcl_rpm_url='https://public-yum.oracle.com/repo/OracleLinux/OL10/oracle/software/aarch64/getPackage/sqlcl-linux-26.1.2-2.el10.aarch64.rpm'
export ords_rpm_url='https://public-yum.oracle.com/repo/OracleLinux/OL10/oracle/software/aarch64/getPackage/ords-26.2.2-2.el10.noarch.rpm'
docker build   --platform linux/arm64   --build-arg ORDS_VERSION=$ords_ver --build-arg ORDS_RPM_URL=$ords_rpm_url --build-arg SQLCL_RPM_URL=$sqlcl_rpm_url -f Dockerfile   -t my_ords:$ords_ver .
```

This example builds for ARM64. For AMD64 or another platform, use matching
Oracle Linux RPM URLs and change the `--platform` value accordingly.

## Using This Image

### Starting an Oracle REST Data Services Instance

To start an ORDS instance, execute the following command: 
```sh
docker run --name <container_name> -v <ords-config>:/etc/ords/config my_ords:<ords_ver>
```
Where `<container_name>` is the name of your container and `<ords-config>` is the volume that contains the ORDS configuration details.

> **NOTE:**
> * The above command is the most basic execution for an ORDS container; assuming a valid ORDS configuration exists in the `<ords-config>` volume.
> * For startup without database-installation credentials, the configuration volume must contain `/etc/ords/config/global/settings.xml` and at least one pool definition at `/etc/ords/config/databases/<pool_name>/pool.xml`.
> * Throughout this document, words enclosed within angle brackets `< >` indicate variables in code lines.
> * To learn about advanced use cases, refer to the [Custom Configurations](#custom-configurations) section.
> * This document uses Docker as the prescribed container runtime, but any OCI-compatible[^1] container runtime can also be used.

[^1]: [About](https://opencontainers.org/) the Open Container Initiative (OCI).

### Custom Configurations

The Oracle REST Data Services container supports various configuration parameters to facilitate custom configurations.

#### Examples

##### Run ORDS instance

This example shows how you might structure a `docker run` command to run an ORDS instance, using the available ORDS installation custom configuration options.

```sh
docker run -d --name <container_name> \
  -p <http_host_port>:8080 -p <https_host_port>:8443 \
  -e FORCE_SECURE=TRUE \
  -e DEBUG=TRUE \
  -e DBHOST=<your_database_hostname> \
  -e DBPORT=<your_database_port> \
  -e DBSERVICENAME=<your_database_service_name> \
  -e ORDS_DB_POOL=<your_ords_pool_name> \
  -e ORACLE_PWD=<your_database_password> \
  -e ORACLE_USER_PWD=<your_ords_user_password> \
  -v <ords_config>:/etc/ords/config \
  -v <apex_files>:/opt/oracle/apex \
  -v <custom_scripts>:/ords-entrypoint.d:ro \
my_ords:<ords_ver>
```
<details>
  <summary><strong> <kbd>< Click</kbd> Obtaining the DBHOST, DBPORT, and DBSERVICENAME values from your running database container.</strong></summary><p></p>

  <em>Database Hostname Port (when using the latest 23ai/free image):</em> 

  `docker container inspect <Your database's container ID> --format "{{.Config.Hostname}}"`
    
  <em>Database Port (when using the latest 23ai/free image):</em>>

  For container-to-container connections, use the database service name and
  its internal listener port, `1521`; do not use the host-published port.

  <em>Database Servicename (when using the latest 23ai/free image):</em>

  `docker logs <Your database's container ID>` *then*, search for your Pluggable Database's Name. The PDB default for 23ai is `FREEPDB1`.

```sh
Parameters:
  -d                Starts the container in container in detached mode
  --name:           The name of the container (default: auto generated)
  -p:               The port mapping of the host port to the container port.
                    8080 by default for HTTP
                    8443 when both TLS certificate files are present
                    MongoDB support is enabled in ORDS configuration, but
                    the image does not expose or publish a separate Mongo port.
  -e DBHOST:        The IP/Hostname of your database this needs to be
                    reachable by the container. DBPORT and DBSERVICENAME
                    are required.
  -e DBPORT:        The port number where your database is listening 
                    connections. DBHOST and DBSERVICENAME are 
                    required.
  -e DBSERVICENAME: 
                    The database service name where you want to install
                    and configure your ORDS. DBPORT and DBHOST are 
                    required.
  -e ORDS_DB_POOL:
                    The ORDS database pool name. The pool is stored under
                    /etc/ords/config/databases/<pool_name> and is used in the
                    request mapping /ords/<pool_name>/. Defaults to "default".
  -e CONN_STRING:   The database custom URL "jdbc:oracle:thin:@<CONN_STRING>".
                    Use this instead of DBHOST, DBPORT and DBSERVICENAME.
  -e ORACLE_PWD:
                    The Oracle Database SYS password for standard databases;
                    for ADB connections, this is the ADMIN password.
  -e FORCE_SECURE   If the FORCE_SECURE flag is TRUE and valid certificates
                    files are not provided. at the configuration directory
                    /etc/ords/config/ssl. The ORDS instance will not start.
  -e DEBUG          If the DEBUG flag is set to TRUE the ORDS instance will 
                    set the config debug.printDebugToScreen true, if the flag 
                    is set to FALSE the ORDS instance will set the config 
                    debug.printDebugToScreen false.
  ORDS config defaults:
                    The image seeds standalone.access.log and mongo.enabled
                    only when each property is missing, so edits in
                    /etc/ords/config persist on restart. Access logs are
                    written under /tmp/ords_access_logs/.
  -v /etc/ords/config
                    The data volume to use for the ORDS configuration.
                    Must be writable from within the container by the 
                    Unix "oracle" (uid: 54321) user.
  -v /opt/oracle/apex
                    Optional: A volume Oracle Application EXpress files (APEX).
                    If this is mounted with the images folder to ORDS instance 
                    will set the standalone.static.path /opt/oracle/apex/images.
                    Must be readable from within the container by the Unix 
                    "oracle" (uid: 54321) user.
  -v /ords-entrypoint.d
                    Optional: A volume with custom scripts to be run before
                    ORDS instance start. Top-level scripts (*.sh) run
                    alphabetically with bash. They must be readable by the
                    Unix "oracle" (uid: 54321) user; executable permission is
                    not required.
```

##### Installing ORDS with a preconfigured database user

To install ORDS using an existing database user instead of SYS, set `ORACLE_PWD`,
`ORACLE_USER_NAME`, and `ORACLE_USER_PWD`. `ORACLE_PWD` is still required for
the container to detect and test the database connection as SYS:

```
-e ORACLE_PWD=<database_sys_password> \
-e ORACLE_USER_NAME=<existing_database_user> \
-e ORACLE_USER_PWD=<existing_database_user_password>
```

When both variables are specified, ORDS assumes the database user already exists and has the required privileges to install. The container does not create the user or grant the necessary privileges.

If the installation fails due to insufficient privileges, a user with SYS privileges must run the ORDS installer privilege script for the target user on the target database. After the required privileges have been granted, restart the container to retry the installation.

If `ORACLE_USER_NAME` is not specified, the installation uses the SYS credentials provided by `ORACLE_PWD`; `ORACLE_USER_PWD` is not used as the SYS password. A valid preset configuration can start without either credential.

##### Legacy TCPS certificate workaround

The SHA-1 algorithm has been disabled by default in GraalVM JDK 25 for TLS 1.2
and DTLS 1.2 handshake signatures. RFC 9155 deprecates the use of SHA-1 in TLS
1.2 and DTLS 1.2 digital signatures. Users can, at their own risk, re-enable
the SHA-1 algorithm in TLS 1.2 and DTLS 1.2 handshake signatures with the
following temporary workaround.

Create a `java-security-compat.properties` file with the following properties:

```properties
jdk.tls.disabledAlgorithms=SSLv3, TLSv1, TLSv1.1, DTLSv1.0, \
    RC4, DES, MD5withRSA, DH keySize < 1024, EC keySize < 224, \
    3DES_EDE_CBC, anon, NULL, ECDH, TLS_RSA_*, \
    ecdsa_sha1 usage HandshakeSignature, \
    dsa_sha1 usage HandshakeSignature
```

Mount it as read-only (`:ro`) when starting ORDS. Use the following environment
and volume options:

```sh
docker run --name ords \
  -e 'JDK_JAVA_OPTIONS=-Djava.security.properties=/etc/ords/config/java-security-compat.properties' \
  -v <ords-config>:/etc/ords/config \
  -v <absolute-path>/java-security-compat.properties:/etc/ords/config/java-security-compat.properties:ro \
  my_ords:<ords_ver>
```

> **IMPORTANT:** This replaces the full `jdk.tls.disabledAlgorithms` setting
> and relaxes TLS security for all Java processes in the container. Review it
> after each JDK or image upgrade.

##### Run ORDS instance using a preset configuration

> **NOTE:** Setting database variables is not necessary when using this option.

```sh
docker run -d --name <container_name> \
  -p <http_host_port>:8080 -p <https_host_port>:8443 \
  -e FORCE_SECURE=TRUE \
  -e DEBUG=TRUE \
  -v <ords_config>:/etc/ords/config \
  -v <apex_files>:/opt/oracle/apex \
  -v <custom_scripts>:/ords-entrypoint.d:ro \
my_ords:<ords_ver>
```
```sh
Parameters:
  -d                Starts the container in detached mode.
  --name:           The name of the container (default: auto generated)
  -p:               The port mapping of the host port to the container port.
                    8080 by default for HTTP
                    8443 (HTTPS) when both TLS certificate files are present
                    MongoDB support is enabled in ORDS configuration, but
                    the image does not expose or publish a separate Mongo port.
  -e FORCE_SECURE   NOTE: The ORDS instance will not start when the FORCE_SECURE 
                    flag is set to TRUE, but valid certificate files are not 
                    provided in the /etc/ords/config/ssl configuration directory. 
  -e DEBUG          If the DEBUG flag is set to TRUE the ORDS instance will set 
                    the ORDS config debug.printDebugToScreen true. 
  -v /etc/ords/config
                    The data volume to use for the ORDS configuration.
                    Must be writeable from within the container by the Unix 
                    "oracle" (uid: 54321) user.
  -v /opt/oracle/apex
                    Optional: A volume for Oracle Application EXpress files (APEX).
                    Mounting as the images folder for the ORDS instance 
                    will set the standalone.static.path to /opt/oracle/apex/images.
                    Must be readable from within the container by the Unix 
                    "oracle" (uid: 54321) user.
  -v /ords-entrypoint.d
                    Optional: A volume with custom scripts to be run before the
                    ORDS instance starts. Top-level scripts (*.sh) run
                    alphabetically with bash. They must be readable by the
                    Unix "oracle" (uid: 54321) user; executable permission is
                    not required.
```

##### Using the ORDS CLI

**Example 1:** This example shows how to use ORDS CLI commands to configure a Customer Managed ORDS (using the ADB-S service). 

> **NOTE:** Docker is used in this example.

1. Step 1: Create a volume, download a wallet, and create a secrets file.

    ```sh
    mkdir -p /<path>/ords_atp_config
    chmod 700 /<path>/ords_atp_config

    cat > secrets.txt <<'EOF'
      <PASSWORD FOR admin-user>
      <PASSWORD FOR db-user>
      <PASSWORD FOR gateway-user>
    EOF
    chmod 600 secrets.txt
    ```  
> **NOTE:** To download the wallet for the Autonomous Database instance, review the instructions for [Downloading Client Credentials](https://docs.oracle.com/en-us/iaas/autonomous-database-serverless/doc/connect-download-wallet.html#GUID-B06202D2-0597-41AA-9481-3B174F75D4B1). For additional information about passwords in the secrets file, review the [Installing and Configuring Customer Managed ORDS](https://docs.oracle.com/en/database/oracle/oracle-rest-data-services/25.2/ordig/installing-and-configuring-customer-managed-ords-autonomous-database.html#GUID-AC7F9A42-A7C2-4453-B8D1-BFD2784C3CA0) documentation.

2. Step 2: Install your customer managed ORDS.  

    ```sh
    cat secrets.txt | docker run --rm -i  \
        -v <your_path>/ords_atp_config:/etc/ords/config  \
        -v <your_path>/atp_wallet.zip:/atp_wallet.zip \
        my_ords:<ords_ver> install adb --admin-user <DATABASE USER> --db-user <DATABASE USER> --gateway-user <DATABASE USER> --wallet /atp_wallet.zip --wallet-service-name <NET SERVICE NAME> --feature-sdw true --password-stdin
    ```
3. Step 3: Create an SSL self signed certificate, CN (common name) should be the domain to be requested, and it could be localhost or a FQDNS. 

    ```sh
    mkdir -p <your_path>/ords_atp_config/ssl
    openssl req -newkey rsa:4096 -x509 -sha256 -days 3650 -nodes -out <your_path>/ords_atp_config/ssl/cert.crt -keyout <your_path>/ords_atp_config/ssl/key.key -subj "/C=US/ST=State/L=City/O=my_corp Corp/OU=my_unit/CN=localhost"
    chmod -R 777 <your_path>/ords_atp_config/ssl
    ```
4. Step 4: Start ORDS customer managed. 

    ```sh
    docker run --rm -i  \
        -p 8443:8443 \
        -v <your_path>/ords_atp_config:/etc/ords/config  \
        -v <your_path>/atp_wallet.zip:/atp_wallet.zip \
        -v <your_path>/apex_files/24.2/apex:/opt/oracle/apex \
        my_ords:<ords_ver>
    ```

**Example 2:** This example shows how to use ORDS CLI  commands to rotate the db password.

1. Step 1: Get the current password.

    ```sh
    docker run \
        -v <ords_config_volume>:/etc/ords/config \
        my_ords:<ords_ver> config get --secret db.password
    ```  

2. Step 2: Update the password. 

    ```sh
    docker run -it \
        -v <ords_config_volume>:/etc/ords/config \
        my_ords:<ords_ver> config secret db.password
    ```

> **NOTE:** For more details on ORDS CLI commands see [Help Center](https://docs.oracle.com/search/?q=CLI&lang=en&category=database&product=en%2Fdatabase%2Foracle%2Foracle-rest-data-services%2F25.2).

##### Using a Compose file

The Compose file uses two file-backed secrets:

- `ORACLE_PWD` is the Oracle Database SYS password. It is available to both
  services because the database needs it to start and ORDS uses it for a SYS
  based installation.
- `ORACLE_USER_PWD` is consumed for every new installation. It becomes the
  password for the ORDS admin/runtime account; it is not the SYS password.
  The entrypoint does not consume it when starting a valid preset
  configuration, but this Compose file still requires the corresponding
  file-backed secret to exist.

The `ords` service overrides the image entrypoint, reads both passwords from
`/run/secrets`, and then invokes `/usr/bin/docker-entrypoint.sh`.

Create both secret files before starting the stack. Each file must contain only
its password (with an optional trailing newline), and neither should be
committed to source control:

```sh
mkdir -p secrets
printf '%s\n' '<your_database_password>' > secrets/oracle_pwd
printf '%s\n' '<your_ords_user_password>' > secrets/oracle_user_pwd
chmod 600 secrets/oracle_pwd
chmod 600 secrets/oracle_user_pwd
```

Start the stack from the directory containing `compose.yml`. By default, secret
paths are relative to that directory; set `COMPOSE_SECRET_DIR` to use another
directory. Verify both secret paths are regular, non-empty files before
starting; Docker Compose may create a directory when a `file:` secret source is
missing:

```sh
test -f secrets/oracle_pwd && test -s secrets/oracle_pwd
test -f secrets/oracle_user_pwd && test -s secrets/oracle_user_pwd
```

The Compose file uses `DB_IMAGE=container-registry.oracle.com/database/free:latest`,
`DB_SERVICE=FREEPDB1`, `DB_PORT=1521`, `ORDS_PORT=8080`,
`ORDS_IMAGE=localhost/my_ords:latest`, `ORDS_DB_POOL=default`, and
`COMPOSE_SECRET_DIR=./secrets` by default. Override them when needed, for
example:

```sh
DB_SERVICE=FREEPDB1 ORDS_IMAGE=localhost/my_ords:${ords_ver} ORDS_DB_POOL=freedb1 docker compose up -d
```

For a preconfigured database user, provide `ORACLE_USER_NAME` along with the
`ORACLE_USER_PWD` secret. The user must already exist and have the privileges
required by ORDS; the container does not create or grant privileges in this
mode:

```sh
ORACLE_USER_NAME=ORDS_USER \
DB_SERVICE=FREEPDB1 \
ORDS_IMAGE=localhost/my_ords:${ords_ver} \
docker compose up -d
```

Compose passes `ORACLE_USER_NAME` to the ORDS container when it is set. Leave
it unset to use the SYS-based installation flow, but still provide the
`ORACLE_USER_PWD` secret.

`DB_SERVICE` controls both the database container's PDB name and the service
name used by ORDS. Set `ORDS_DB_POOL` to choose the database pool; it defaults
to `default`. For example, when `ORDS_DB_POOL=freedb1`, a new installation
creates `/etc/ords/config/databases/freedb1`, and requests for that pool use
`/ords/freedb1/` (including SQL Developer Web). This project variable is passed to ORDS as its
documented `--db-pool <pool_name>` install and repair option. See Oracle's
[ORDS installation and configuration guide](https://docs.oracle.com/en/database/oracle/oracle-rest-data-services/26.1/ordig/installing-and-configuring-oracle-rest-data-services.html)
and [configuration strategies for multiple databases](https://docs.oracle.com/en/database/oracle/oracle-rest-data-services/26.2/ordig/configuring-additional-databases.html).
Existing pool directories are not renamed automatically. The APEX static path,
when configured from `/opt/oracle/apex/images`, is applied as the standalone
configuration rather than being selected with `ORDS_DB_POOL`.

Database data and ORDS configuration are bind-mounted at `./db_files` and
`./ords_config`, respectively. These are the same default locations used by
earlier versions of this Compose file, so an upgrade keeps the existing
database, pools, wallets, and settings. Back up both directories before a
destructive cleanup such as deleting the project directory.

The Compose file uses file-backed secrets, so creating Docker-managed secrets
with `docker secret create` is not required and does not replace the files
above.

Override `COMPOSE_SECRET_DIR`, `DB_IMAGE`, `DB_SERVICE`, `DB_PORT`, `ORDS_PORT`,
`ORDS_IMAGE`, and `ORDS_DB_POOL` in your environment to use another secrets
directory, database image, ORDS image, or configuration. A non-default pool is
available at `/ords/<pool-name>/`.

## Configuration and operations

Compose publishes HTTP on port 8080 only. To expose HTTPS on 8443, add this
mapping under the `ords` service's `ports` list and provide the TLS files below:

```yaml
      - "8443:8443"
```

- Mount `/ords-entrypoint.d` read-only to run readable `.sh` files before ORDS starts.
- When using Compose, create the bind-mount source directory before starting:
  `mkdir -p custom-scripts`. Place readable `.sh` scripts there if needed.
- Mount APEX files at `/opt/oracle/apex`. If `/opt/oracle/apex/images` exists,
  the entrypoint configures it as the local APEX static-file directory. If the
  mount also contains `apxsilentins.sql`, startup checks the database APEX
  version and may install or upgrade APEX.
- Put TLS files at `/etc/ords/config/ssl/cert.crt` and
  `/etc/ords/config/ssl/key.key` to use HTTPS.
- Use `docker logs <container>` to inspect installation and runtime logs.
- Use `DEBUG=true` for redacted startup diagnostics.
- For a new installation, the entrypoint retries database connectivity up to
  60 times with a 10-second delay. For a preset configuration, it retries the
  selected pool (or the first available pool when the requested pool is
  absent) up to 10 times by default; override these with
  `DB_WAIT_RETRY` and `ORDS_DB_WAIT_RETRY`, respectively.

The Compose file is [`compose.yml`](compose.yml):

> **NOTE:** Running the ORDS container on a Docker machine with JVM low memory allocation may result in the container crashing with a Java out of memory exception. If needed, set `JDK_JAVA_OPTIONS` in the `ords` service environment in your Compose override file.


### Starting the ORDS container on secure port 8443

To enable HTTPS on port 8443, place both the SSL certificate and key files in
the ORDS config volume.

```sh
<ords_config_volume>/ssl/cert.crt
<ords_config_volume>/ssl/key.key
```

Alternatively, mount the files to the `/etc/ords/config/ssl` directory.

```sh
  -v <ssl_certificate_file>:/etc/ords/config/ssl/cert.crt:ro \
  -v <ssl_key_file>:/etc/ords/config/ssl/key.key:ro \
```

> **NOTE:** The SSL certificate and key files must be readable from within the container by the Unix "oracle" (uid: 54321) user. The container detects both files and enables HTTPS on port 8443. HTTP remains available on port 8080 unless separately disabled. With Compose, add a host-to-container `8443:8443` mapping to publish HTTPS externally.
>
> **NOTE** If the `FORCE_SECURE` flag has been set to `TRUE` and certificates files are unavaialbe, the container will exit with an error. However, if both the `FORCE_SECURE` flag is unset and certificate files are unavailable/missing, the container will start using the non-secure (HTTP) port 8080.

### Running Scripts prior to starting the ORDS instance

You can configure the Docker image to run scripts (.sh extensions are supported) as ORDS starts up. To include scripts so they run at startup, mount the directory on your host, where these scripts are located, to the `/ords-entrypoint.d` volume. Scripts are discovered at the top level, sorted alphabetically, and executed with `bash` as the container's `oracle` user. They must be readable; executable permission is not required. Script failures are not checked by the entrypoint, so scripts that must block startup should perform their own error handling and termination.

### Accessing ORDS logs

You can access the ORDS console logs with the following command (where `<ords>` is the service/container name):

```sh
 docker compose logs ords
```
