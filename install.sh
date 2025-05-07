#!/bin/bash

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Exiting."
    exit 1
fi

# Stop on any error
set -e

echo "Updating package lists..."
apt update

echo "Disabling systemd-resolved..."
systemctl disable --now systemd-resolved
rm -f /etc/resolv.conf
ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf

# Install curl first
echo "Installing curl..."
apt install -y curl

# Install dnsmasq
echo "Installing dnsmasq..."
apt install -y dnsmasq

# Install unbound but do not start it yet
echo "Installing unbound..."
apt install -y unbound
systemctl stop unbound

# Install ufw
echo "Installing ufw..."
apt install -y ufw

echo "Downloading the latest root hints file..."
curl -o /var/lib/unbound/root.hints https://www.internic.net/domain/named.cache

echo "Configuring Unbound as a caching recursive DNS server with root hints..."
UNBOUND_CONF="/etc/unbound/unbound.conf.d/custom.conf"

tee "$UNBOUND_CONF" > /dev/null <<EOF
server:
    # Listen only on localhost, port 5353
    interface: 127.0.0.1
    port: 5353
    access-control: 127.0.0.1 allow

    # Use root hints for resolving
    root-hints: "/var/lib/unbound/root.hints"
    do-not-query-localhost: no

    # Enable caching
    cache-min-ttl: 3600
    cache-max-ttl: 86400
    msg-cache-size: 50m
    rrset-cache-size: 100m

    # Harden against cache poisoning
    harden-glue: yes
    harden-dnssec-stripped: yes
    use-caps-for-id: yes

    # Performance tuning
    num-threads: 2
EOF

echo "Configuring dnsmasq to use Unbound as an upstream DNS server..."
DNSMASQ_CONF="/etc/dnsmasq.d/custom.conf"

tee "$DNSMASQ_CONF" > /dev/null <<EOF
# Make sure eth0 is your interface name
interface=eth0
server=127.0.0.1#5353
no-hosts
addn-hosts=/etc/dnsmasq/hosts.blocklist
addn-hosts=/etc/dnsmasq/hosts.custom
log-queries
EOF

echo "Downloading and processing the StevenBlack hosts file..."
BLOCKLIST_URL="https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/fakenews-gambling/hosts"
BLOCKLIST_FILE="/etc/dnsmasq/hosts.blocklist"

# Ensure /etc/dnsmasq directory exists
mkdir -p /etc/dnsmasq

# Download and convert the hosts file into a format compatible with dnsmasq
if curl -s "$BLOCKLIST_URL" | grep "^0.0.0.0" | awk '{if ($2 != "0.0.0.0") print "127.0.0.1", $2}' > "$BLOCKLIST_FILE"; then
    echo "Blocklist successfully downloaded and processed."
else
    echo "Failed to download blocklist. Exiting."
    exit 1
fi

echo "Setting up a custom hosts file for user-defined entries..."
CUSTOM_HOSTS_FILE="/etc/dnsmasq/hosts.custom"

# Create the file if it doesn't exist
touch "$CUSTOM_HOSTS_FILE"

echo "Restarting dnsmasq..."
systemctl restart dnsmasq

echo "Starting Unbound..."
systemctl start unbound

echo "Enabling services to start on boot..."
systemctl enable dnsmasq unbound ufw

echo "Setting up firewall rules..."
# Allow DNS traffic for dnsmasq (port 53)
ufw allow 53/tcp
ufw allow 53/udp

# Allow SSH (change port if needed)
ufw allow 22/tcp

# Enable UFW
ufw enable

echo "Installation and configuration complete!"
echo "You can now add your own custom host entries in $CUSTOM_HOSTS_FILE (Format: X.X.X.X hostname)"
