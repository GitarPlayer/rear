# 310_network_devices.sh
#
# record network device configuration for Relax-and-Recover
#
# This file is part of Relax-and-Recover, licensed under the GNU General
# Public License. Refer to the included COPYING for full text of license.

# Notes:
# - Thanks to Markus Brylski for fixing some bugs with bonding.
# - Thanks to Gerhard Weick for coming up with a way to disable bonding if needed.

# TODO: Currently it supports only ethernet.

# Where to build networking configuration.
# When booting the rescue/recovery system
# /etc/scripts/system-setup.d/60-network-devices.sh
# is run to setup the network devices:
network_devices_setup_script=$ROOTFS_DIR/etc/scripts/system-setup.d/60-network-devices.sh
prepare_network_devices_script=$ROOTFS_DIR/etc/scripts/system-setup.d/50-prepare-network-devices.sh


# This script will also generate commands to prepare or enable a network device
# Example:  on s390 (zLinux) network devices must be removed from the ignore list and configured
# cf. https://github.com/rear/rear/pull/2142
# TODO: add case statement for different os vendors
if [[ "$ARCH" == "Linux-s390" && "$OS_MASTER_VENDOR" != "SUSE_LINUX" ]] ; then
cat >$prepare_network_devices_script << 'EOF'

echo "run cio_ignore -R"
cio_ignore -R
echo "znetconf -u " "$unconfig_devices"
znetconf -u
unconfig_devices=$( znetconf -u | grep -v "HiperSockets" | awk  'NR>3 { print $1 }'|awk -F"," '{ print $1 " " $2 " " $3 }' )
while read id1 id2 id3
do
    echo "znetconf -a " "$id1"
    znetconf -a  "$id1"
done < <( echo "$unconfig_devices" )
EOF
fi


# This script (rescue/GNU/Linux/310_network_devices.sh) is intended to
# autogenerate network devices setup code in the network_devices_setup_script
# according to the network devices setup in the currently running system
# to get an automated network devices setup in the rescue/recovery system
# that matches the network devices setup in the currently running system.
# This 310_network_devices.sh script should always run completely until its end
# to achieve that the network_devices_setup_script contains autogenerated code
# for a complete network devices setup that matches the currently running system.
# Therefore the autogenerated code in the network_devices_setup_script
# can return early or skip parts as needed but the network_devices_setup_script
# should always contain all code for the complete network devices setup.
# This way the network_devices_setup_script in the rescue/recovery system
# is intended to provide code for a complete network devices setup so that
# if needed the user can adapt and enhance the network_devices_setup_script
# and run it again as needed in the rescue/recovery system, cf.
# https://github.com/rear/rear/issues/819#issuecomment-224315823
# "run this script manual ... as: bash /etc/scripts/system-setup.d/60-network-devices.sh"
# https://github.com/rear/rear/issues/937#issuecomment-234493024
# "run commands like /etc/scripts/system-setup which runs the system startup scripts"

# Initialize network_devices_setup_script:
echo "# Network devices setup:" >$network_devices_setup_script

# Skip network_devices_setup_script if the kernel command line contains the 'noip' parameter
# (a kernel command line parameter has precedence over things like NETWORKING_PREPARATION_COMMANDS):
cat - <<EOT >>$network_devices_setup_script
# Skip network devices setup if the kernel command line parameter 'noip' is specified:
grep -q '\<noip\>' /proc/cmdline && return
EOT

# If IP address plus optionally netmask, network device, and default gateway
# were specified at recovery system boot time via kernel command line parameters like
#   ip=192.168.100.2 nm=255.255.255.0 netdev=eth0 gw=192.168.100.1
# setup only that single network device and skip the rest of the network_devices_setup_script
# (a kernel command line parameter has precedence over things like NETWORKING_PREPARATION_COMMANDS):
cat - <<EOT >>$network_devices_setup_script
# If kernel command line parameters like ip=192.168.100.2 nm=255.255.255.0 netdev=eth0 gw=192.168.100.1
# were specified setup only that single network device and skip the rest:
if [[ "\$IPADDR" ]] ; then
    device=\${NETDEV:-eth0}
    ip link set dev "\$device" up
    netmask=\${NETMASK:-255.255.255.0}
    ip addr add "\$IPADDR"/"\$netmask" dev "\$device"
    if [[ "\$GATEWAY" ]] ; then
        ip route add default via "\$GATEWAY"
    fi
    return
fi
EOT

# Prepend the commands specified in NETWORKING_PREPARATION_COMMANDS.
# This is done before the DHCP check so that NETWORKING_PREPARATION_COMMANDS
# could be used to fix up things if setup via 58-start-dhclient.sh may have failed
# (e.g. if there is not yet an IP address, set up one via NETWORKING_PREPARATION_COMMANDS):
if test "${NETWORKING_PREPARATION_COMMANDS[*]}" ; then
    # For the above 'test' one must have all array members as a single word i.e. "${name[*]}"
    # (the test should succeed when there is any non-empty array member, not necessarily the first one)
    # while later one must have the array members as separated 'command' words i.e. "${name[@]}".
    echo "# Prepare network devices setup as specified in NETWORKING_PREPARATION_COMMANDS:" >>$network_devices_setup_script
    for command in "${NETWORKING_PREPARATION_COMMANDS[@]}" ; do
        test "$command" && echo "$command" >>$network_devices_setup_script
    done
fi

# When DHCP is used via 58-start-dhclient.sh do not change the existing networking setup here:
cat - <<EOT >>$network_devices_setup_script
# When DHCP was used via 58-start-dhclient.sh do not change the existing networking setup here:
is_true \$USE_DHCLIENT && ! is_true \$USE_STATIC_NETWORKING && return
EOT

# Output header before the autogenerated network devices setup code:
cat - <<EOT >>$network_devices_setup_script
# The following is autogenerated code to setup network interfaces
# in the recovery system which have all these on the original system:
# - they are UP
# - they have an IP address
# - they are somehow linked to a physical device
# For details see the rescue/GNU/Linux/310_network_devices.sh script.
EOT

# Detect whether 'readlink' supports multiple filenames or not
# e.g. RHEL6 doesn't support that
if readlink /foo /bar 2>/dev/null ; then
    function resolve () {
        readlink -e "$@"
    }
else
    function resolve () {
        for path in "$@" ; do
            readlink -e $path
        done
    }
fi

# Detect whether 'lower_*' symlinks for network interfaces exist or not
# e.g. RHEL6 doesn't have that
net_devices_have_lower_links='false'
ls /sys/class/net/* | grep -q ^lower_ && net_devices_have_lower_links='true'

# Detect whether 'ip link add name NAME type bridge ...' exists or not
ip_link_supports_bridge='false'
ip link help 2>&1 | grep -qw bridge && ip_link_supports_bridge='true'

# ############################################################################
# EXPLANATION OF THE ALGORITHM USED
# ############################################################################
#
# We are only interested in network interfaces which have all these:
# - they are UP
# - they have an IP address
# - they are somehow linked to a physical device
#
# For each such interface, apply the following algorithm (ALGO)
#
# - if this is a physical interface, configure it
#
# - otherwise determine type of the virtual interface
#
#   - if it is a bridge
#
#     - if SIMPLIFY_BRIDGE is set
#       - configure the first UP underlying interface using ALGO
#       - keep record of interface mapping into new underlying interface
#     - otherwise
#       - configure the bridge
#       - configure all UP underlying interfaces using ALGO
#
#   - if it is a bond
#
#     - if SIMPLIFY_BONDING is set and mode is not 4 (IEEE 802.3ad policy)
#       - configure the first UP underlying interface using ALGO
#       - keep record of interface mapping into new underlying interface
#     - otherwise
#       - configure the bond
#       - configure all UP underlying interfaces using ALGO
#
#   - if it is a vlan
#
#     - configure the vlan based on parent's interface
#
#   - if it is a team
#
#     - if SIMPLIFY_TEAMING is set and runner is not 'lacp' (IEEE 802.3ad policy)
#       - configure the first UP underlying interface using ALGO
#       - keep record of interface mapping into new underlying interface
#     - otherwise
#       - configure the team
#       - configure all UP underlying interfaces using ALGO
#
# - in any case, a given interface is only configured once; when an interface
#   has already been configured, configuration code should be ignored by
#   caller.
#
# IMPORTANT NOTE:
#
# Because simplification can be used, it may happen that configuring an
# interface 'someitf' leads to configuring another interface 'anotheritf'
# instead.
# For example, when configuring a 'team', the underlying interface (e.g.
# 'bond0') will be configured instead.
#
# This can leads to very deep mapping, as shown in the example below, with all
# simplifications active:
#
# br0: bridge over team0, hosting IP address 1.2.3.4
# bond0: bond on phys devices eth0 and eth1
# team0: team on vlan bond0.10 and eth2.10
#
# This will result in:
#
# eth0.10 configured with IP address 1.2.3.4
#
# Explanation:
#
# 'br0' is first mapped into 'team0' because of bridge simplification
# but 'team0' is mapped into 'bond0.10'
# and 'bond0.10' itself is mapped into 'eth0.10', because 'bond0' is mapped
#   into 'eth0' because of bonding simplification
# this results in 'br0' be mapped recursively into 'eth0.10'
#
# Because of all this, each time 'handle_interface' is called, the code should
# be checked to verify whether the configured interface is effectively the
# expected one, or a mapping occurred instead.

# Array of mapped network interfaces.
# Global because it is also used in 350_routing.sh.
#
# Each line consists in "source_interface mapped_interface" values.
# Examples:
# 1. Map a team 'team0' into lower interface 'eth0': "team0 eth0"
# 2. Map a bond 'bond0' into lower interface 'eth0': "bond0 eth0"
# 3. Map vlan 'bond0.441' of mapped 'bond0' into corresponding 'eth0' vlan: "bond0.441 eth0.441"
MAPPED_NETWORK_INTERFACES=()

# Function to map an interface to a new interface
function map_network_interface () {
    local network_interface=$1
    local mapped_as=$2

    if printf "%s\n" "${MAPPED_NETWORK_INTERFACES[@]}" | grep -qw "^$network_interface" ; then
        # There is an error in the code. This means a handle_* function has
        # been called on an already mapped interface, which shouldn't happen.
        BugError "'$network_interface' is already mapped."
    fi

    DebugPrint "Mapping $network_interface onto $mapped_as"

    MAPPED_NETWORK_INTERFACES+=( "$network_interface $mapped_as" )
}

# Function returning the new interface when an interface is mapped, otherwise
# itself
function get_mapped_network_interface () {
    local network_interface=$1

    local mapped_as=$( printf "%s\n" "${MAPPED_NETWORK_INTERFACES[@]}" |
        awk "\$1 == \"$network_interface\" { print \$2 }" )

    echo ${mapped_as:-$network_interface}
}

# Function returning whether a device path is linked to some physical device
# return 0 if True
# return 1 otherwise
function is_devpath_linked_to_physical () {
    local sysfspath=$1

    # If device is a physical device, return success
    [ ! -e $sysfspath/device ] || return 0

    # Otherwise recurse on lower devices (if any)
    local devices
    if is_true $net_devices_have_lower_links ; then
        devices=$( resolve $sysfspath/lower_* 2>/dev/null )
    else
        # Fallback to probing as much as we can
        # - slave_*: for bonding
        # - brif: for bridges
        # - xxx.nn: for vlan (using awk, checking for '.')
        # - teams are not supported (at least on RHEL6)
        devices="$( resolve $sysfspath/slave_* )"
        devices+=" $( for d in $( resolve $sysfspath/brif/* ) ; do dirname $d ; done )"
        devices+=" $( echo $sysfspath | awk -F '.' '$2 { print $1 }' )"

        # NOTE: because teams are not supported using this method, they will be
        # detected as pure virtual devices, hence skipped.
    fi
    local dev
    for dev in $devices ; do
        ! is_devpath_linked_to_physical $dev || return 0
    done

    # Device is not linked to a physical device
    return 1
}

# Function returning whether an interface is somehow linked to physical
function is_linked_to_physical () {
    local network_interface=$1
    local sysfspath=/sys/class/net/$network_interface

    is_devpath_linked_to_physical $sysfspath
}

# Function returning lower interfaces of the specified network interface
function get_lower_interfaces () {
    local network_interface=$1
    local sysfspath=/sys/class/net/$network_interface

    local devices
    if is_true $net_devices_have_lower_links ; then
        devices=$( resolve $sysfspath/lower_* 2>/dev/null )
    else
        # Fallback to probing as much as we can
        # - slave_*: for bonding
        # - brif: for bridges
        # - xxx.nn: for vlan (using awk, checking for '.')
        # - teams are not supported (at least on RHEL6)
        devices="$( resolve $sysfspath/slave_* )"
        devices+=" $( for d in $( resolve $sysfspath/brif/* ) ; do dirname $d ; done )"
        devices+=" $( echo $sysfspath | awk -F '.' '$2 { print $1 }' )"
    fi
    local dev
    for dev in $devices ; do
        echo $( get_mapped_network_interface $( basename $dev ) )
    done
}

function get_interface_state () {
    local network_interface=$1
    local sysfspath=/sys/class/net/$network_interface

    local operstate="$( cat $sysfspath/operstate )"
    case "$operstate" in
    down|up)
            echo "$operstate"
            ;;
    *)
            # Some network drivers do not set "operstate" to "down" or "up", in
            # such case, rely on "carrier", for which `cat` fails when link is
            # administratively down, returns 0 when link is down and 1
            # otherwise.
            if [ $( cat $sysfspath/carrier 2>/dev/null || echo 0 ) -eq 0 ]; then
                echo "down"
            else
                echo "up"
            fi
            ;;
    esac
}

function is_interface_up () {
    local network_interface=$1
    local sysfspath=/sys/class/net/$network_interface

    if IsInArray "$network_interface" "${EXCLUDE_NETWORK_INTERFACES[@]}"; then
        LogPrint "Excluding '$network_interface' per EXCLUDE_NETWORK_INTERFACES directive."
        return 1
    fi

    local state=$( cat $sysfspath/operstate )
    if [ "$state" = "down" ] ; then
        return 1
    elif [ "$state" = "up" ] ; then
        return 0
    else
        # Some network drivers do not set "operstate" to "down" or "up", in
        # such case, rely on "carrier", for which `cat` fails when link is
        # administratively down, returns 0 when link is down and 1 otherwise.
        state=$( cat $sysfspath/carrier 2>/dev/null || echo 0 )
        if [ $state -eq 0 ]; then
            return 1
        else
            return 0
        fi
    fi
}

# Configures the IP addresses of the network interface
function ipaddr_setup () {
    local network_interface=$1
    local mapped_as=$( get_mapped_network_interface $network_interface )

    # Handle ip_addresses mapping
    # FIXME? In old code, the IP addresses were mapped for all devices
    # specified in the file and nothing more, other devices weren't set up at
    # all.
    # Since I believe this was not the intended behaviour, I fixed that by
    # applying new mapping to devices listed in ip_addresses file only and
    # still using the system IP address for other devices.
    # If that was the intended behaviour, then block 'ipaddrs' has to be
    # modified.

    local ipmapfile=$TMP_DIR/mappings/ip_addresses
    if [ ! -f $ipmapfile ] ; then
        mkdir -p $v $TMP_DIR/mappings >&2
        if test -f $CONFIG_DIR/mappings/ip_addresses ; then
            read_and_strip_file $CONFIG_DIR/mappings/ip_addresses > $ipmapfile
        else
            touch $ipmapfile
        fi
    fi

    local ipaddr
    local ipaddrs=$( awk "\$1 == \"$network_interface\" { print \$2 }" $TMP_DIR/mappings/ip_addresses )
    if [ -n "$ipaddrs" ] ; then
        # If some IP is found for the network interface, then use them
        for ipaddr in $ipaddrs ; do
            if IsInArray "${ipaddr%%/*}" "${EXCLUDE_IP_ADDRESSES[@]}"; then
                LogPrint "Excluding IP address '$ipaddr' per EXCLUDE_IP_ADDRESSES directive even through it's defined in mapping file '$CONFIG_DIR/mappings/ip_addresses'."
                continue
            fi
            echo "ip addr add $ipaddr dev $mapped_as"
        done
    else
        # Otherwise, collect IP addresses for the network interface on the system
        for ipaddr in $( ip a show dev $network_interface scope global | grep "inet.*\ " | tr -s " " | cut -d " " -f 3 ) ; do
            if IsInArray "${ipaddr%%/*}" "${EXCLUDE_IP_ADDRESSES[@]}"; then
                LogPrint "Excluding IP address '$ipaddr' per EXCLUDE_IP_ADDRESSES directive."
                continue
            fi
            echo "ip addr add $ipaddr dev $mapped_as"
        done
    fi
}

function setup_device_params () {
    local network_interface=$1
    local sysfspath=/sys/class/net/$network_interface
    local mapped_as=$( get_mapped_network_interface $network_interface )

    local state=$( get_interface_state $network_interface )
    echo "ip link set dev $mapped_as $state"

    # Record interface MTU
    if test -e "$sysfspath/mtu" ; then
        mtu="$( cat $sysfspath/mtu )" || LogPrint "Could not read MTU for '$network_interface'."
        [[ "$mtu" ]] && echo "ip link set dev $mapped_as mtu $mtu"
    fi
}

# Return codes for the handle_* functions below
# rc_success: OK
# rc_error:   Not supported / some unexpected error occurred
# rc_ignore:  Nothing to do
rc_success=0
rc_error=1
rc_ignore=2

already_set_up_interfaces=""

function handle_interface () {
    local network_interface=$1
    local sysfspath=/sys/class/net/$network_interface

    if [[ " $already_set_up_interfaces " == *\ $network_interface\ * ]] ; then
        DebugPrint "$network_interface already handled..."
        return $rc_ignore
    fi
    already_set_up_interfaces+=" $network_interface"

    local code
    local rc
    local tmpfile=$( mktemp )
    for func in "handle_physdev" "handle_bridge" "handle_team" "handle_bond" "handle_vlan" ; do
        $func $network_interface >$tmpfile
        rc=$?
        code="$( cat $tmpfile )"
        [ $rc -ne $rc_error ] || continue
        break
    done
    rm $tmpfile

    # Falling here means either 'success' or 'error' (no handler matching)
    if [ $rc -eq $rc_error ] ; then
        LogPrintError "Skipping '$network_interface': not yet supported."
        return $rc_error
    fi

    [ $rc -eq $rc_success ] && echo "$code"

    return $rc
}

# List of bridges already set up
already_set_up_bridges=""

function handle_bridge () {
    local network_interface=$1
    local sysfspath=/sys/class/net/$network_interface

    if [ ! -d "$sysfspath/bridge" ] ; then
        return $rc_error
    fi

    DebugPrint "$network_interface is a bridge"

    if [ -z "$already_set_up_bridges" ] ; then
        MODULES+=( 'bridge' )
    elif [[ " $already_set_up_bridges " == *\ $network_interface\ * ]] ; then
        DebugPrint "$network_interface already handled..."
        return $rc_ignore
    fi
    already_set_up_bridges+=" $network_interface"

    local rc
    local nitfs=0
    local tmpfile=$( mktemp )
    local itf

    if is_true "$SIMPLIFY_BRIDGE" ; then
        for itf in $( get_lower_interfaces $network_interface ) ; do
            DebugPrint "$network_interface has lower interface $itf"
            is_interface_up $itf || continue
            is_linked_to_physical $itf || continue
            handle_interface $itf >$tmpfile
            rc=$?
            [ $rc -eq $rc_error ] && continue
            let nitfs++
            # itf may have been mapped into some other interface
            itf=$( get_mapped_network_interface $itf )
            echo "# Original interface was $network_interface, now is $itf"
            if [ $rc -eq $rc_success ] ; then
                cat $tmpfile
            fi
            # We found an interface, so stop here after mapping bridge to lower interface
            map_network_interface $network_interface $itf
            break
        done
        rm $tmpfile

        # If we didn't find any lower interface, we are in trouble ...
        if [ $nitfs -eq 0 ] ; then
            LogPrintError "Couldn't find any suitable lower interface for '$network_interface'."
            return $rc_error
        fi

        # setup_device_params has already been called by interface bridge was mapped onto

        return $rc_success
    fi

    #
    # Non-simplified bridge mode
    #

    # Create the bridge
    # TODO Add more properties if needed
    stp=$( cat "$sysfspath/bridge/stp_state")
    if is_true $ip_link_supports_bridge ; then
        echo "ip link add name $network_interface type bridge stp_state $stp"
    elif has_binary brctl ; then
        IsInArray "brctl" "${REQUIRED_PROGS[@]}" || REQUIRED_PROGS+=( "brctl" )
        echo "brctl addbr $network_interface"
        echo "brctl stp $network_interface $stp"
    else
        BugError "No 'brctl' utility nor support for bridges in 'ip', please try using 'SIMPLIFY_BRIDGE=yes'."
    fi

    for itf in $( get_lower_interfaces $network_interface ) ; do
        DebugPrint "$network_interface has lower interface $itf"
        is_interface_up $itf || continue
        is_linked_to_physical $itf || continue
        handle_interface $itf >$tmpfile
        rc=$?
        [ $rc -eq $rc_error ] && continue
        let nitfs++
        [ $rc -eq $rc_success ] && cat $tmpfile
        # itf may have been mapped into some other interface
        itf=$( get_mapped_network_interface $itf )
        if is_true $ip_link_supports_bridge ; then
            echo "ip link set dev $itf master $network_interface"
        else
            echo "brctl addif $network_interface $itf"
        fi
    done
    rm $tmpfile

    # If we didn't find any lower interface, we are in trouble ...
    if [ $nitfs -eq 0 ] ; then
        LogPrintError "Couldn't find any suitable lower interface for '$network_interface'."
        return $rc_error
    fi

    setup_device_params $network_interface

    return $rc_success
}

already_set_up_teams=""
team_initialized=

function handle_team () {
    local network_interface=$1
    local sysfspath=/sys/class/net/$network_interface

    if has_binary ethtool ; then
        if [ "$( ethtool -i $network_interface | awk '$1 == "driver:" { print $2 }' )" != "team" ] ; then
            return $rc_error
        fi
    else
        LogPrintError "Couldn't determine if network interface '$network_interface' is a Team, skipping."
        return $rc_error
    fi

    DebugPrint "$network_interface is a team"

    if [[ " $already_set_up_teams " == *\ $network_interface\ * ]] ; then
        DebugPrint "$network_interface already handled..."
        return $rc_ignore
    fi
    already_set_up_teams+=" $network_interface"

    local rc
    local nitfs=0
    local tmpfile=$( mktemp )
    local itf
    local teaming_runner="$( teamdctl "$network_interface" state item get setup.runner_name )"

    if is_true "$SIMPLIFY_TEAMING" && [ "$teaming_runner" != "lacp" ] ; then

        for itf in $( get_lower_interfaces $network_interface ) ; do
            DebugPrint "$network_interface has lower interface $itf"
            is_interface_up $itf || continue
            is_linked_to_physical $itf || continue
            handle_interface $itf >$tmpfile
            rc=$?
            [ $rc -eq $rc_error ] && continue
            let nitfs++
            echo "# Original interface was $network_interface, now is $itf"
            [ $rc -eq $rc_success ] && cat $tmpfile
            # itf may have been mapped into some other interface
            itf=$( get_mapped_network_interface $itf )
            # We found an interface, so stop here after mapping team to lower interface
            map_network_interface $network_interface $itf
            break
        done
        rm $tmpfile

        # If we didn't find any lower interface, we are in trouble ...
        if [ $nitfs -eq 0 ] ; then
            LogPrintError "Couldn't find any suitable lower interface for '$network_interface'."
            return $rc_error
        fi

        # setup_device_params has already been called by interface team was mapped onto

        return $rc_success
    elif is_true "$SIMPLIFY_TEAMING" ; then
        # Teaming runner 'lacp' (IEEE 802.3ad policy) cannot be simplified
        # because there is some special setup on the switch itself, requiring
        # to keep the system's network interface's configuration intact.
        LogPrint "Note: not simplifying network configuration for '$network_interface' because teaming runner is 'lacp' (IEEE 802.3ad policy)."
    fi

    #
    # Non-simplified teaming mode
    #

    if [ -z "$team_initialized" ] ; then
        PROGS+=( 'teamd' 'teamdctl' )
        team_initialized="y"
    fi

    local teamconfig="$( teamdctl -o "$network_interface" config dump actual )"

    for itf in $( get_lower_interfaces $network_interface ) ; do
        DebugPrint "$network_interface has lower interface $itf"
        is_interface_up $itf || continue
        is_linked_to_physical $itf || continue
        handle_interface $itf >$tmpfile
        rc=$?
        [ $rc -eq $rc_error ] && continue
        let nitfs++
        [ $rc -eq $rc_success ] && cat $tmpfile
        # itf may have been mapped into some other interface
        local newitf=$( get_mapped_network_interface $itf )
        if [ "$itf" != "$newitf" ] ; then
            # Fix the teaming configuration
            teamconfig="$( echo "$teamconfig" | sed "s/\"$itf\"/\"$newitf\"/g" )"
        fi
        # Make sure lower device is down before configuring the team
        echo "ip link set dev $itf down"
    done
    rm $tmpfile

    # If we didn't find any lower interface, we are in trouble ...
    if [ $nitfs -eq 0 ] ; then
        LogPrintError "Couldn't find any suitable lower interface for '$network_interface'."
        return $rc_error
    fi

    echo "teamd -d -c '$teamconfig'"

    setup_device_params $network_interface

    return $rc_success
}

already_set_up_bonds=""
bond_initialized=

function handle_bond () {
    local network_interface=$1
    local sysfspath=/sys/class/net/$network_interface

    if [ ! -d "$sysfspath/bonding" ] ; then
        return $rc_error
    fi

    DebugPrint "$network_interface is a bond"

    if [[ " $already_set_up_bonds " == *\ $network_interface\ * ]] ; then
        DebugPrint "$network_interface already handled..."
        return $rc_ignore
    fi
    already_set_up_bonds+=" $network_interface"

    local rc
    local nitfs=0
    local tmpfile=$( mktemp )
    local itf
    local bonding_mode=$( awk '{ print $2 }' $sysfspath/bonding/mode )

    if is_true "$SIMPLIFY_BONDING" && [ $bonding_mode -ne 4 ] ; then
        for itf in $( get_lower_interfaces $network_interface ) ; do
            DebugPrint "$network_interface has lower interface $itf"
            is_interface_up $itf || continue
            is_linked_to_physical $itf || continue
            handle_interface $itf >$tmpfile
            rc=$?
            [ $rc -eq $rc_error ] && continue
            let nitfs++
            # itf may have been mapped into some other interface
            itf=$( get_mapped_network_interface $itf )
            echo "# Original interface was $network_interface, now is $itf"
            if [ $rc -eq $rc_success ] ; then
                cat $tmpfile
            fi
            # We found an interface, so stop here after mapping bond to lower interface
            map_network_interface $network_interface $itf
            break
        done
        rm $tmpfile

        # If we didn't find any lower interface, we are in trouble ...
        if [ $nitfs -eq 0 ] ; then
            LogPrintError "Couldn't find any suitable lower interface for '$network_interface'."
            return $rc_error
        fi

        # setup_device_params has already been called by interface bond was mapped onto

        return $rc_success
    elif is_true "$SIMPLIFY_BONDING" ; then
        # Bond mode '4' (IEEE 802.3ad policy) cannot be simplified because
        # there is some special setup on the switch itself, requiring to keep
        # the system's network interface's configuration intact.
        LogPrint "Note: not simplifying network configuration for '$network_interface' because bonding mode is '4' (IEEE 802.3ad policy)."
    fi

    #
    # Non-simplified bonding mode
    #

    if [ -z "$bond_initialized" ] ; then
        echo "modprobe bonding"
        MODULES+=( 'bonding' )
        bond_initialized="y"
    fi

    local miimon=$( cat $sysfspath/bonding/miimon )
    local use_carrier=$( cat $sysfspath/bonding/use_carrier )

    cat - << EOT
if ! grep -qw "$network_interface" /sys/class/net/bonding_masters ; then
    echo "+$network_interface" > /sys/class/net/bonding_masters 2>/dev/null
fi
echo "$bonding_mode" > $sysfspath/bonding/mode
echo "$miimon" > $sysfspath/bonding/miimon
echo "$use_carrier" > $sysfspath/bonding/use_carrier
EOT

    echo "ip link set dev $network_interface down"

    for itf in $( get_lower_interfaces $network_interface ) ; do
        DebugPrint "$network_interface has lower interface $itf"
        is_interface_up $itf || continue
        is_linked_to_physical $itf || continue
        handle_interface $itf >$tmpfile
        rc=$?
        [ $rc -eq $rc_error ] && continue
        let nitfs++
        [ $rc -eq $rc_success ] && cat $tmpfile
        # itf may have been mapped into some other interface
        itf=$( get_mapped_network_interface $itf )
        # Make sure lower device is down before joining the bond
        echo "ip link set dev $itf down"
        echo "echo \"+$itf\" > /sys/class/net/$network_interface/bonding/slaves 2>/dev/null"
    done
    rm $tmpfile

    # If we didn't find any lower interface, we are in trouble ...
    if [ $nitfs -eq 0 ] ; then
        LogPrintError "Couldn't find any suitable lower interface for '$network_interface'."
        return $rc_error
    fi

    setup_device_params $network_interface

    return $rc_success
}

# Variable keeping track of already set up vlans
already_set_up_vlans=""

# List of generated vlans (see corner case with mapped parent)
generated_vlans=""

function handle_vlan () {
    local network_interface=$1
    local sysfspath=/sys/class/net/$network_interface

    if [ ! -e "/proc/net/vlan/$network_interface" ] ; then
        return $rc_error
    fi

    DebugPrint "$network_interface is a vlan"

    if [ -z "$already_set_up_vlans" ] ; then
        if [[ -f /proc/net/vlan/config ]] ; then
            # Config file contains a line like "vlan163        | 163  | bond1" describing the vlan.
            # Save a copy to our recovery area.
            # We might need it if we ever want to implement VLAN Migration.
            cp /proc/net/vlan/config $VAR_DIR/recovery/vlan.config
        fi
        echo "modprobe 8021q"
    elif [[ " $already_set_up_vlans " == *\ $network_interface\ * ]] ; then
        DebugPrint "$network_interface already handled..."
        return $rc_ignore
    fi
    already_set_up_vlans+=" $network_interface"

    local parent=$( get_lower_interfaces $network_interface )
    [ $( echo "$parent" | wc -w ) -eq 1 ] || BugError "'$network_interface' has more than 1 parent."

    DebugPrint "$network_interface has $parent as parent"
    handle_interface $parent
    [ $? -eq $rc_error ] && return $rc_error

    local vlan_id=$( awk '$2 == "VID:" { print $3 }' /proc/net/vlan/$network_interface )
    [ -n "$vlan_id" ] || BugError "'$network_interface' has no vlan id."

    # parent may have been mapped into some other interface
    if [ $( get_mapped_network_interface $parent ) != "$parent" ] ; then
        parent=$( get_mapped_network_interface $parent )
        # Update child device (ourselves) into new device $parent.$vlan_id
        echo "# Original interface was $network_interface, now is $parent.$vlan_id"
        map_network_interface $network_interface "$parent.$vlan_id"
    fi

    local new_network_interface=$( get_mapped_network_interface $network_interface )

    # Check whether parent already has the same vlan id. This is done by
    # checking 'generated_vlans' with the new network interface.
    if [[ " $generated_vlans " == *\ $new_network_interface\ * ]] ; then
        LogPrint "Vlan $vlan_id already exists for interface '$parent', skipping"
        return $rc_ignore
    fi
    generated_vlans+=" $new_network_interface"

    echo ip link add link $parent name $new_network_interface type vlan id $vlan_id

    setup_device_params $network_interface

    return $rc_success
}

# Variable keeping track of already set up physical devices
already_set_up_physdevs=""
# Variable keeping track of drivers already included
already_set_up_physdev_drivers=""

function handle_physdev () {
    local network_interface=$1
    local sysfspath=/sys/class/net/$network_interface

    if [ ! -e "$sysfspath/device" ] ; then
        return $rc_error
    fi

    DebugPrint "$network_interface is a physical device"

    local mac=""

    if [ "$ARCH" == "Linux-s390" ] ; then
        mac="$( ifconfig $network_interface 2>/dev/null |grep ether |awk '{ print $2 }' )"
    elif has_binary ethtool ; then
        mac="$( ethtool -P $network_interface 2>/dev/null | awk '{ print $NF }' )"
    fi
    if [ -z "$mac" ] ; then
        if [ -e $sysfspath/bonding_slave/perm_hwaddr ] ; then
            mac="$( cat $sysfspath/bonding_slave/perm_hwaddr )"
        else
            mac="$( cat $sysfspath/address )" || BugError "Could not read a MAC address for '$network_interface'."
        fi
    fi
    # Skip fake interfaces without MAC address
    [ "$mac" != "00:00:00:00:00:00" ] || return $rc_error

    if [[ " $already_set_up_physdevs " == *\ $network_interface\ * ]] ; then
        DebugPrint "$network_interface already handled..."
        return $rc_ignore
    fi
    already_set_up_physdevs+=" $network_interface"

    echo "$network_interface $mac" >>$ROOTFS_DIR/etc/mac-addresses

    # Determine the driver to load, relevant only for non-udev environments
    local driver
    if [ -e "$sysfspath/device/driver" ] ; then
        driver=$( basename $( resolve $sysfspath/device/driver ) )
        if [ "$driver" = "vif" ] ; then
            # xennet driver announces itself as vif :-(
            driver=xennet
        fi
    elif [ -e "$sysfspath/driver" ] ; then
        # This should work for virtio_net, xennet and vmxnet on older kernels (2.6.18)
        driver=$( basename $( resolve $sysfspath/driver ) )
    elif has_binary ethtool ; then
        driver=$( ethtool -i $network_interface 2>/dev/null | awk '$1 == "driver:" { print $2 }' )
    else
        LogPrint "Could not determine driver for '$network_interface'. To ensure it gets loaded add it to MODULES_LOAD."
    fi

    if [ -n "$driver" ] && [[ " $already_set_up_physdev_drivers " == *\ $driver\ * ]] ; then
        grep -qw ^$driver /proc/modules || LogPrint "Driver '$driver' for '$network_interface' not loaded - is that okay?"
        echo "$driver" >>$ROOTFS_DIR/etc/modules
        already_set_up_physdev_drivers+=" $driver"
    fi

    setup_device_params $network_interface

    return $rc_success
}

#
# Collect list of all network interfaces to deal with.
#
# These must match all of the following:
# - interfaces with an IP address and associated route
# - interfaces linked to a physical device somehow
#

tmpfile=$( mktemp )
rc=

# Use output of 'ls /sys/class/net/' to select all available interfaces
# in particular to make networking also work with IPv6 only NICs
# see https://github.com/rear/rear/issues/2902
for network_interface in $( ls /sys/class/net/ ) ; do
    if ! is_linked_to_physical $network_interface ; then
        LogPrint "Skipping '$network_interface': not bound to any physical interface."
        continue
    fi
    is_interface_up $network_interface || continue

    DebugPrint "Handling network interface '$network_interface'"

    handle_interface $network_interface >$tmpfile
    rc=$?
    if [ $rc -eq $rc_error ] ; then
        LogPrintError "Failed to handle network interface '$network_interface'."
        continue
    fi
    [ $rc -eq $rc_success ] && cat $tmpfile

    ipaddr_setup $network_interface

    DebugPrint "Handled network interface '$network_interface'"
done >>$network_devices_setup_script

rm $tmpfile

unset -f resolve
unset -f map_network_interface
# Don't unset 'get_mapped_network_interface' because it is used in 350_routing.sh.
#unset -f get_mapped_network_interface
unset -f is_devpath_linked_to_physical
unset -f is_linked_to_physical
unset -f get_lower_interfaces
unset -f get_interface_state
unset -f is_interface_up
unset -f ipaddr_setup
unset -f setup_device_params
unset -f handle_interface
unset -f handle_bridge
unset -f handle_team
unset -f handle_bond
unset -f handle_vlan
unset -f handle_physdev

# vim: set et ts=4 sw=4:
