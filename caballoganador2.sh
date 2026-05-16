#!/bin/bash

cp /etc/bind/rndc.key /etc/bind/rndc.key.old

rndc-confgen > /etc/bind/rndc.key

sed -i '/^options {$/,/^};$/d' /etc/bind/rndc.key

cp /etc/bind/rndc.key /etc/bind/zonas/rndc.key

namedconf="/etc/bind/named.conf"

cat <<'EOF' >> "$namedconf"

// Configuracion-ddns
include "/etc/bind/zonas/rndc.key";
controls
{
	inet 127.0.0.1 port 953
	allow {127.0.0.1;} keys { "rndc-key"; };
};

EOF

echo "Configuración named.conf añadida correctamente."

# =====================================================
# Añadir subredes DDNS al dhcpd.conf existente
# =====================================================

generate_reverse_zone() {
    local network="$1"

    IFS='.' read -r o1 o2 o3 o4 <<< "$network"

    echo "${o3}.${o2}.${o1}.in-addr.arpa."
}

echo "=================================================="
echo " Añadir configuración DDNS a dhcpd.conf "
echo "=================================================="
echo

read -rp "Ruta del dhcpd.conf [/etc/dhcp/dhcpd.conf]: " DHCP_FILE
DHCP_FILE=${DHCP_FILE:-/etc/dhcp/dhcpd.conf}

if [[ ! -f "$DHCP_FILE" ]]; then
    echo
    echo "ERROR: El archivo no existe:"
    echo "$DHCP_FILE"
    exit 1
fi

# -------------------------------------------------
# Borrar línea antigua
# -------------------------------------------------

sed -i '/ddns-update-style none;/d' "$DHCP_FILE"

# -------------------------------------------------
# Añadir configuración DDNS al final del archivo
# -------------------------------------------------

cat <<'EOF' >> "$DHCP_FILE"

#Configuracion-ddns
ddns-updates on;
update-static-leases on;
ddns-update-style interim;
ignore client-updates;
deny client-updates;

include "/etc/bind/zonas/rndc.key";

EOF

echo "Configuración DDNS añadida correctamente."

read -rp "¿Cuántas subredes quieres añadir? [1]: " TOTAL
TOTAL=${TOTAL:-1}

for ((i=1; i<=TOTAL; i++)); do

    echo
    echo "========== SUBRED $i =========="

    read -rp "Nombre descriptivo (ej: dpto101): " DESC_NAME

    read -rp "Subnet (ej: 10.100.101.0): " SUBNET
    read -rp "Netmask [255.255.255.0]: " NETMASK
    NETMASK=${NETMASK:-255.255.255.0}

    read -rp "Server Identifier (ej: 10.100.101.250): " SERVER_ID

    read -rp "Dominio DDNS (ej: dpto101.empresa.org): " DOMAIN

    read -rp "IP DNS primaria [127.0.0.1]: " PRIMARY_IP
    PRIMARY_IP=${PRIMARY_IP:-127.0.0.1}

    DEFAULT_REVERSE=$(generate_reverse_zone "$SUBNET")

    read -rp "Zona inversa [$DEFAULT_REVERSE]: " REVERSE_ZONE
    REVERSE_ZONE=${REVERSE_ZONE:-$DEFAULT_REVERSE}

    read -rp "Rango inicio DHCP: (IP COMPLETA)" RANGE_START
    read -rp "Rango fin DHCP: (IP COMPLETA)" RANGE_END

    read -rp "Gateway/Router: (IP COMPLETA)" ROUTER

    read -rp "Servidor DNS: (IP SERVIDOR)" DNS_SERVER

    read -rp "Default lease time [10800]: " DEFAULT_LEASE
    DEFAULT_LEASE=${DEFAULT_LEASE:-10800}

    read -rp "Max lease time [10800]: " MAX_LEASE
    MAX_LEASE=${MAX_LEASE:-10800}

cat <<EOF >> "$DHCP_FILE"

#SUBRED $DESC_NAME
subnet $SUBNET netmask $NETMASK {
    server-identifier $SERVER_ID;
    ddns-domainname "$DOMAIN.";
    ddns-rev-domainname "in-addr.arpa.";

    zone $DOMAIN.
    {
        primary $PRIMARY_IP;
        key "rndc-key";
    }

    zone $REVERSE_ZONE
    {
        primary $PRIMARY_IP;
        key "rndc-key";
    }

    range $RANGE_START $RANGE_END;

    option routers $ROUTER;
    option domain-name "$DOMAIN";
    option domain-name-servers $DNS_SERVER;

    default-lease-time $DEFAULT_LEASE;
    max-lease-time $MAX_LEASE;
}

EOF

    echo
    echo "Subred añadida correctamente."

done

echo
echo "Configuración añadida a:"
echo "$DHCP_FILE"

echo "!!!!!!!!!!!!!!!! NO TE OLVIDES DE PONER LAS TARJETAS DE RED EN /etc/default/isc-dhcp-server !!!!!!!!!!!!!!!!!"
echo 'EJEMPLO: INTERFACESv4="ens19 ens20 ens21"'

ln -s /etc/apparmor.d/usr.sbin.named /etc/apparmor.d/disable/
apparmor_parser -R /etc/apparmor.d/usr.sbin.named

ln -s /etc/apparmor.d/usr.sbin.dhcpd /etc/apparmor.d/disable/
apparmor_parser -R /etc/apparmor.d/usr.sbin.dhcpd
