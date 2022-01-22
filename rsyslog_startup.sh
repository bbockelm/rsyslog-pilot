#!/bin/sh -xe

if [ ! -e rsyslog ]; then
    echo "rsyslog bootstrap directory missing; skipping log uploads"
    exit 0
fi

if ! command -v curl > /dev/null; then
    echo "curl is missing; skipping log uploads"
    exit 0
fi

if ! command -v openssl > /dev/null; then
    echo "openssl is missing; skipping log uploads"
    exit 0
fi

if [ "$#" -ne 1 ]; then
    glidein_config="$(readlink -f glidein_config)"
else
    glidein_config="$1"
fi

if [ -e "$glidein_config" ]; then
    GLIDEIN_Site="$(grep -i "^GLIDEIN_Site " $glidein_config | awk '{print $2}')"
    GLIDEIN_ResourceName="$(grep -i "^GLIDEIN_ResourceName " $glidein_config | awk '{print $2}')"
    SYSLOG_HOST="$(grep -i "^SYSLOG_HOST " $glidein_config | awk '{print $2}')"
    REGISTRY_HOST="$(grep -i "^REGISTRY_HOST " $glidein_config | awk '{print $2}')"
else
    GLIDEIN_Site=Unknown
    GLIDEIN_ResourceName=Unknown
    SYSLOG_HOST="syslog.osgdev.chtc.io"
    REGISTRY_HOST="os-registry.osgdev.chtc.io"
fi

add_config_line_source=`grep '^ADD_CONFIG_LINE_SOURCE ' $glidein_config | awk '{print $2}'`
if [[ "x${add_config_line_source}" == "x" ]]; then
  DO_CONDOR_CONFIG=0
else
  DO_CONDOR_CONFIG=1
fi
if [ $DO_CONDOR_CONFIG -eq 1 ]; then
  source $add_config_line_source
  condor_vars_file=`grep -i "^CONDOR_VARS_FILE " $glidein_config | awk '{print $2}'`
fi


if [[ "x${SYSLOG_HOST}" == "x" ]]; then
    echo "No syslog host is configured; skipping log uploads"
    exit 0
fi

if [[ "x${REGISTRY_HOST}" == "x" ]]; then
    if [[ "${SYSLOG_HOST}" == "syslog.osg.chtc.io" ]]; then
        REGISTRY_HOST=os-registry.opensciencegrid.org
    else
        REGISTRY_HOST=os-registry.osgdev.chtc.io
    fi
fi

IDTOKEN_FILE=$(ls -1 ticket/*.idtoken | head -n 1)
if [[ "x${IDTOKEN_FILE}" == "x" ]]; then
    echo "No idtoken found; cannot upload to syslog server"
    exit 0
fi

set +x
IDTOKEN=$(cat "${IDTOKEN_FILE}")
set -x

# Setup working directory
rm -rf rsyslog/{workdir,conf,certs}
mkdir -p rsyslog/{workdir,conf,certs}
RSYSLOG_BIN=$(readlink -f rsyslog/bin)
RSYSLOG_LIB=$(readlink -f rsyslog/lib)
RSYSLOG_CERTS=$(readlink -f rsyslog/certs)
RSYSLOG_CONF=$(readlink -f rsyslog/conf)
RSYSLOG_WORKDIR=$(readlink -f rsyslog/workdir)
CONDOR_LOGS=$(readlink -f log)
GLIDEIN_LOGS=$(readlink -f logs/*)

cat rsyslog/rsyslog.conf.template | \
    sed -e "s|%RSYSLOG_BIN%|${RSYSLOG_BIN}|" \
        -e "s|%RSYSLOG_LIB%|${RSYSLOG_LIB}|" \
        -e "s|%RSYSLOG_CERTS%|${RSYSLOG_CERTS}|" \
        -e "s|%RSYSLOG_CONF%|${RSYSLOG_CONF}|" \
        -e "s|%RSYSLOG_WORKDIR%|${RSYSLOG_WORKDIR}|" \
        -e "s|%CONDOR_LOGS%|${CONDOR_LOGS}|" \
        -e "s|%GLIDEIN_LOGS%|${GLIDEIN_LOGS}|" \
        -e "s|%SYSLOG_HOST%|${SYSLOG_HOST}|" \
    > "${RSYSLOG_CONF}/rsyslog.conf"

export LD_LIBRARY_PATH="${RSYSLOG_LIB}:${LD_LIBRARY_PATH}"

umask 077
cat > "${RSYSLOG_WORKDIR}/curl.configuration" << EOF
-X POST
-H "Authorization: Bearer ${IDTOKEN}"
-F "csr=<${RSYSLOG_CERTS}/tls.csr"
--fail
EOF

# Generate necessary certificates
openssl genrsa -out "${RSYSLOG_CERTS}/tls.key" 2048
openssl req -new -out "${RSYSLOG_CERTS}/tls.csr" -key "${RSYSLOG_CERTS}/tls.key" -subj /CN=will_be_overwritten

# Actually request the certificate from the registry.
if ! curl -K "${RSYSLOG_WORKDIR}/curl.configuration" https://${REGISTRY_HOST}/syslog-ca/issue > "${RSYSLOG_WORKDIR}/results"; then
    echo "Attempt to download syslog certificate failed"
    rm -rf "${RSYSLOG_WORKDIR}" "${RSYSLOG_CERTS}"
    exit 0
fi
rm "${RSYSLOG_WORKDIR}/curl.configuration"

export PATH="${RSYSLOG_BIN}:${PATH}"
if ! cat "${RSYSLOG_WORKDIR}/results" | jq -e -r .ca > "${RSYSLOG_CERTS}/ca.crt"; then
    echo "Registry response does not include a CA certificate"
    rm -rf "${RSYSLOG_WORKDIR}" "${RSYSLOG_CERTS}"
    exit 0
fi
if ! cat "${RSYSLOG_WORKDIR}/results" | jq -e -r .certificate > "${RSYSLOG_CERTS}/tls.crt"; then
    echo "Registry response does not include a certificate"
    rm -rf "${RSYSLOG_WORKDIR}" "${RSYSLOG_CERTS}"
    exit 0
fi
rm "${RSYSLOG_WORKDIR}/results"

cat > "${RSYSLOG_BIN}/rsyslog_launch" << EOF
#!/bin/sh
export RSYSLOG_MODDIR="${RSYSLOG_LIB}"
export GLIDEIN_Site="${GLIDEIN_Site}"
export GLIDEIN_ResourceName="${GLIDEIN_ResourceName}"
export LD_LIBRARY_PATH="${RSYSLOG_LIB}:\${LD_LIBRARY_PATH}"
exec "$RSYSLOG_BIN/rsyslogd" -n -i "$(readlink -f rsyslog/rsyslog.pid)" -f "$RSYSLOG_CONF/rsyslog.conf" "\$@"
EOF
chmod 0700 "${RSYSLOG_BIN}/rsyslog_launch"

if [ $DO_CONDOR_CONFIG -eq 1 ]; then
    add_config_line MAX_DEFAULT_LOG "0"
    add_condor_vars_line MAX_DEFAULT_LOG "C" "-" "+" "N" "N" "-"
    add_config_line ALL_DEBUG "D_CAT,D_SUB_SECOND,D_PID"
    add_condor_vars_line ALL_DEBUG "C" "-" "+" "N" "N" "-"
    add_config_line RSYSLOG "${RSYSLOG_BIN}/rsyslog_launch"
    add_condor_vars_line RSYSLOG "C" "-" "+" "N" "N" "-"
    add_config_line DAEMON_LIST "MASTER,STARTD,RSYSLOG"
    add_condor_vars_line DAEMON_LIST "C" "-" "+" "N" "N" "-"
fi
