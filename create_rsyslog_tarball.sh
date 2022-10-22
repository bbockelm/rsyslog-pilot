#!/bin/sh -xe

if [ $# -ne 1 ]; then
    echo "Usage: $0 output_tarfile"
    exit 1
fi

OUTPUT=$(readlink -f $1)

DESTDIR="$(mktemp -d rsyslog_tarball.XXXXXX)"
mkdir -p $DESTDIR/{bin,lib}

cleanup_temp() {
    rm -rf -- "$DESTDIR"
}
trap cleanup_temp EXIT

copy_deps () {
  for dependency in $(ldd "$1" | egrep -v 'linux-vdso|libz|libpthread|libdl|librt|libgcc_s|libx|ld-linux|libc' | awk '{print $3;}'); do
    cp "$dependency" "$DESTDIR/lib/"
  done
}

cp "$(dirname "$0")/jq-linux64" "$DESTDIR/bin/jq"

cp "$(command -v rsyslogd)" "$DESTDIR/bin"
copy_deps "$DESTDIR/bin/rsyslogd"

for module in $(echo /usr/lib64/rsyslog/{lmnet,lmnsd_ptcp,lmnsd_gtls,lmregexp,lmtcpclt,lmnetstrms,imfile}.so); do
  cp $module "$DESTDIR/lib/"
  copy_deps $module
done

cp rsyslog.conf.template "$DESTDIR/"

# The fact the files are copied into the top-level directory is intentional;
# glideinWMS will unpack them into a subdirectory of our choosing.
pushd $DESTDIR
tar zcf $OUTPUT .
popd
