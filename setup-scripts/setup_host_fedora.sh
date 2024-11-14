#!/usr/bin/env bash

# setup a Fedora linux host machine to provide internet for USB device connected
# this should be run ONCE on the host machine

set -e  # bail on any errors

# need to be root
if [ "$(id -u)" != "0" ]; then
    echo "Must be run as root"
    exit 1
fi

if [ "$(uname -s)" != "Linux" ]; then
    echo "Only works on Linux!"
    exit 1
fi

# install needed packages
dnf install -y net-tools git htop gcc gcc-c++ cmake python3 python3-devel python3-pip iptables adb android-tools

# Install Python packages
python3 -m pip install --break-system-packages virtualenv nuitka ordered-set || {
    python3 -m pip install virtualenv nuitka ordered-set
}
python3 -m pip install --break-system-packages git+https://github.com/superna9999/pyamlboot || {
    python3 -m pip install git+https://github.com/superna9999/pyamlboot
}

HOST_NAME="superbird"
USBNET_PREFIX="192.168.7"  # usb network will use .1 as host device, and .2 for superbird

# Wait briefly for the USB device to be detected
sleep 2

# Try to find the Car Thing's network interface
if ip link show usb0 &> /dev/null; then
    INACTIVE_INTERFACE="usb0"
elif ip link show | grep -q "usb.*: <.*> mtu"; then
    INACTIVE_INTERFACE=$(ip link show | grep "usb.*: <.*> mtu" | cut -d: -f2 | tr -d ' ')
elif ip link show | grep -q "enp.*u.*: <.*> mtu"; then
    # Look for USB-connected interfaces with enp naming scheme
    INACTIVE_INTERFACE=$(ip link show | grep "enp.*u.*: <.*> mtu" | cut -d: -f2 | tr -d ' ')
else
    # Look for interfaces with Google Inc. as manufacturer
    for interface in $(ls /sys/class/net/); do
        if [ -e "/sys/class/net/$interface/device/manufacturer" ]; then
            if grep -q "Google Inc." "/sys/class/net/$interface/device/manufacturer"; then
                INACTIVE_INTERFACE="$interface"
                break
            fi
        fi
    done
fi

if [ -z "$INACTIVE_INTERFACE" ]; then
    echo "No Car Thing USB network interface found. Please ensure:"
    echo "1. The Car Thing is properly connected via USB"
    echo "2. You've waited a few seconds after connecting it"
    echo "3. Try unplugging and replugging the device"
    echo ""
    echo "Available network interfaces:"
    ip -br link
    echo ""
    echo "USB devices:"
    lsusb
    exit 1
fi

echo "Using Car Thing network interface: $INACTIVE_INTERFACE"

# Modified verification to handle enp* naming scheme
if ! (ip link show "$INACTIVE_INTERFACE" | grep -q -E '(usb|enp.*u)' || \
      ([ -e "/sys/class/net/$INACTIVE_INTERFACE/device/manufacturer" ] && \
       grep -q "Google Inc." "/sys/class/net/$INACTIVE_INTERFACE/device/manufacturer")); then
    echo "Warning: Selected interface $INACTIVE_INTERFACE may not be the Car Thing."
    echo "Please verify this is correct before continuing."
    read -p "Continue? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

function remove_if_exists() {
    # remove a file if it exists
    FILEPATH="$1"
    if [ -f "$FILEPATH" ]; then
        echo "found ${FILEPATH}, removing"
        rm "$FILEPATH"
    fi
}

function append_if_missing() {
    # append string to file only if it does not already exist in the file
    STRING="$1"
    FILEPATH="$2"
    grep -q "$STRING" "$FILEPATH" || {
        echo "appending \"$STRING\" to $FILEPATH"
        echo "$STRING" >> "$FILEPATH"
        return 1
    }
    echo "Already found \"$STRING\" in $FILEPATH"
    return 0
}

function forward_port() {
    # usage: forward_port <host port> <superbird port>
    # forward a tcp port to access service on superbird via host
    SOURCE="$1"
    DEST="$2"
    if [ -z "$DEST" ]; then
        DEST="$SOURCE"
    fi

    # Add firewalld rules
    firewall-cmd --permanent --add-port="${SOURCE}/tcp"

    # Add iptables rules
    iptables -t nat -A PREROUTING -p tcp --dport "$SOURCE" -j DNAT --to-destination "${USBNET_PREFIX}.2:$DEST"
    iptables -A FORWARD -p tcp -d "${USBNET_PREFIX}.2" --dport "$DEST" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT
}

# fix usb enumeration when connecting superbird in maskroom mode
echo '# Amlogic S905 series can be booted up in Maskrom Mode, and it needs a rule to show up correctly' > /etc/udev/rules.d/70-carthing-maskrom-mode.rules
echo 'SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="1b8e", ATTR{idProduct}=="c003", MODE:="0666", SYMLINK+="worldcup"' >> /etc/udev/rules.d/70-carthing-maskrom-mode.rules

# Add USB network device rules
cat << 'EOF' > /etc/udev/rules.d/99-carthing-usb-net.rules
# Car Thing USB network interface rules
SUBSYSTEM=="net", ACTION=="add", ATTRS{idVendor}=="18d1", ATTRS{idProduct}=="4e42", NAME="usb0"
SUBSYSTEM=="net", ACTION=="add", ATTRS{idVendor}=="18d1", ATTRS{idProduct}=="4e42", RUN+="/usr/sbin/ip link set usb0 up"
EOF

# Reload udev rules
udevadm control --reload-rules
udevadm trigger

# prevent systemd / udev from renaming usb network devices by mac address
remove_if_exists /lib/systemd/network/73-usb-net-by-mac.link
remove_if_exists /lib/udev/rules.d/73-usb-net-by-mac.rules

# allow IP forwarding
append_if_missing "net.ipv4.ip_forward = 1" /etc/sysctl.conf || {
    sysctl -p  # reload from conf
}

# forwarding rules
mkdir -p /etc/iptables

# clear all iptables rules
iptables -F
iptables -X
iptables -Z
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
iptables -t raw -F
iptables -t raw -X

# rewrite iptables rules
iptables -P FORWARD ACCEPT
iptables -A FORWARD -o eth0 -i eth1 -s "${USBNET_PREFIX}.0/24" -m conntrack --ctstate NEW -j ACCEPT
iptables -A FORWARD -o eth0 -i eth1 -s "${USBNET_PREFIX}.0/24" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A POSTROUTING -t nat -j MASQUERADE -s "${USBNET_PREFIX}.0/24"

# port forwards:
#   2022: ssh on superbird
#   5900: vnc on superbird
#   9222: chromium remote debugging on superbird
#   9223: Chrome remote debugging via socat

forward_port 2022 22
forward_port 5900
forward_port 9222
forward_port 9223

# persist rules to file
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4

# Remove any existing USB-Ethernet connection
nmcli connection delete USB-Ethernet || true

# Wait for interface to be available
echo "Waiting for interface $INACTIVE_INTERFACE to be available..."
for i in {1..10}; do
    if ip link show "$INACTIVE_INTERFACE" &> /dev/null; then
        break
    fi
    sleep 1
done

# Create new connection with more specific settings
nmcli connection add type ethernet \
    con-name "USB-Ethernet" \
    ifname "$INACTIVE_INTERFACE" \
    ipv4.method manual \
    ipv4.addresses "${USBNET_PREFIX}.1/24" \
    ipv4.never-default true \
    connection.autoconnect yes \
    connection.autoconnect-priority 100

# Try to activate the connection
echo "Attempting to activate USB-Ethernet connection..."
nmcli connection up USB-Ethernet || {
    echo "Failed to activate connection immediately. This is normal if the interface isn't ready yet."
    echo "The connection will be activated automatically when the interface becomes available."
}

# add superbird to /etc/hosts
append_if_missing "${USBNET_PREFIX}.2  ${HOST_NAME}"  "/etc/hosts"

# Enable and start firewalld if not already running
systemctl enable --now firewalld

# Configure firewalld for IP forwarding
firewall-cmd --permanent --add-masquerade
firewall-cmd --reload

echo "Setup complete! The system needs to be rebooted for all changes to take effect."
echo "After reboot, the USB network interface should automatically configure itself."
echo "If you have any issues, check the NetworkManager connection settings for 'USB-Ethernet'"