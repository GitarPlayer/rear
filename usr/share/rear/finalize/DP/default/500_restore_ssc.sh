# 500_restore_ssc.sh
# Purpose:
# Make Secure Socket Communication usable after restoring the client system.
# Reasoning:
# The client certificate is currently excluded from a Data Protector backup due to security concerns.
# This means it is not restored using BACKUP=DP. This might change within Data Protector (in the future).
# The current implementation in ReaR will get the required files from the running client,
# use it during "rear recover" and place it on the recovered/recreated system (if not found there).
# This allows to resume backup and restore operation without manual intervention.
# The current implementation will not replace the certificate if it gets restored using BACKUP=DP (in the future).

# Only needed for Data Protector 10.x and later when Secure Communication is configured:
test -s /etc/opt/omni/client/ssconfig || return 0

local sscpath=/etc/opt/omni/client/sscertificates
local certfile=$sscpath/localhost_cert.*
local keyfile=$sscpath/localhost_key.*

# Nothing to do when the certificate files already exist in the recreated system:
test -s $TARGET_FS_ROOT/$certfile -a -s $TARGET_FS_ROOT/$keyfile && return 0

# Tell what will be done so that subsequent (error) messages make sense for the user:
LogPrint "Restoring Data Protector client certificate:"
LogPrint "$certfile"
LogPrint "$keyfile"

# Inform the user but do not error out here at this late state of "rear recover"
# when it failed to copy specific files into the recreated system:
cp $v $certfile $TARGET_FS_ROOT/$certfile || LogPrintError "Failed to copy $certfile"
cp $v $keyfile  $TARGET_FS_ROOT/$keyfile  || LogPrintError "Failed to copy $keyfile"

# All is done when the certificate files exist now in the recreated system:
test -s $TARGET_FS_ROOT/$certfile -a -s $TARGET_FS_ROOT/$keyfile && return 0

LogPrint "Client certificate not properly restored. A new certificate will be generated now"
local omnicc=/opt/omni/bin/omnicc
# Inform the user but do not error out here at this late state of "rear recover"
# when it failed to generate the certificate:
if ! chroot $TARGET_FS_ROOT $omnicc -secure_comm -regenerate_cert ; then
    LogPrintError "Failed to regenerate certificate"
    return 1
fi
if ! chroot $TARGET_FS_ROOT $omnicc -secure_comm -get_fingerprint ; then
    LogPrintError "Failed to get fingerprint"
    return 1
fi
LogPrint "Generated a new Data Protector client certificate"
LogPrint "Run 'omnicc -secure_comm -configure_peer <Client>' on the Cell Manager after rebooting the client"
