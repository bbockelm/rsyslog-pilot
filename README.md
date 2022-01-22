
Rsyslog Helper Scripts for GlideinWMS
=====================================

This package contains two scripts:

1. `create_rsyslog_tarball.sh`: Creates a tarball containing a small rsyslog
   distribution (copying binaries from the host environment) and template
   config.  The output should be added to a GlideinWMS frontend input file
   XML stanza and unpacked into the `rsyslog` directory in the main glidein
   directory.
2. `rsyslog_startup.sh`: Startup script for the pilot; customizes the rsyslog
   and condor configurations.  Should also be placed in an XML file stanza in
   the frontend.

If rsyslog is successfully configured in the pilot, it will be run underneath
the `condor_master` process.
