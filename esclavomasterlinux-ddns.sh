#!/bin/bash

clear

# ========================================================
# 1. PREPARAR CARPETAS Y ARCHIVOS
# ========================================================
DIR="despliegue_ddns"
mkdir -p "$DIR/zonas"

CONFIG="$DIR/named.conf.local"
DHCP_CONF="$DIR/dhcpd.conf.generado"
DHCP_DEFAULT="$DIR/isc-dhcp-server.generado"
KEY_FILE="$DIR/rndc.key.generado"
APPARMOR_FILE="$DIR/apparmor.named.generado"
INSTALL_SCRIPT="$DIR/instalar.sh"

echo "" > "$CONFIG"
echo "" > "$DHCP_CONF"

echo "=========================================================="
echo "   GENERADOR DDNS (ENTORNO AISLADO ens19 - ens22)"
echo "=========================================================="

# ========================================================
# 2. GENERAR LLAVE DE SEGURIDAD
# ========================================================
cat > "$KEY_FILE" <<EOF
key claveddns {
    algorithm hmac-sha256;
    secret "LaB/sEcReTa/DdNs/KeY==";
};
EOF

# Excepcion de AppArmor
cat > "$APPARMOR_FILE" <<EOF
/etc/bind/zonas/** rw,
EOF

# Configuracion base BIND
cat >> "$CONFIG" <<EOF
include "/etc/bind/rndc.key";
EOF

# Configuracion base DHCP
cat >> "$DHCP_CONF" <<EOF
ddns-updates on;
ddns-update-style interim;
update-static-leases on;
ignore client-updates;
authoritative;
include "/etc/dhcp/rndc.key";
EOF

# ========================================================
# 3. PREGUNTAS DEL ENTORNO
# ========================================================
echo
echo "--- 1. LAS TARJETAS DE RED ---"
echo "Tus redes internas son ens19, ens20, ens21 o ens22 (ens18 esta apagada)."
echo "Si vas a repartir DHCP por varias, separalas por espacios (ej: ens19 ens20)."
read -p "Escribe las interfaces para DHCP: " INTERFAZ_DHCP

# Configurar archivo default del DHCP
cat > "$DHCP_DEFAULT" <<EOF
INTERFACESv4="$INTERFAZ_DHCP"
INTERFACESv6=""
EOF

echo
echo "--- 2. EL MAESTRO WINDOWS ---"
echo "¿Vas a importar una zona principal desde un Windows Server?"
read -p "Pon 1 (Si) o 0 (No): " NUM_SLAVES

if [[ $NUM_SLAVES -gt 0 ]]; then
    echo
    read -p "IP del Windows Server (ej: 192.168.1.10): " IP_WINDOWS
    read -p "Nombre del dominio en Windows (ej: principal.com): " DOM_SLAVE
    
    cat >> "$CONFIG" <<EOF

// ZONA COPIADA DE WINDOWS
zone "$DOM_SLAVE" {
    type slave;
    file "/var/cache/bind/db.$DOM_SLAVE";
    masters { $IP_WINDOWS; };
    allow-query { any; };
};
EOF
fi

echo
echo "--- 3. TUS REDES DDNS (DHCP) ---"
echo "¿Para cuántas redes internas vas a configurar DHCP+DNS Automático?"
read -p "Pon un numero (0 si no quieres DDNS): " NUM_DDNS

if [[ $NUM_DDNS -gt 0 ]]; then
    for ((d=1; d<=NUM_DDNS; d++))
    do
        echo
        echo "=== CONFIGURANDO RED DDNS $d ==="
        echo "Rellena los datos copiando el formato de los ejemplos:"
        read -p "1. Nombre del dominio (ej: red1.local): " DOM_DDNS
        read -p "2. Red (SOLO 3 NUMEROS) (ej: 192.168.20): " RED_DDNS
        read -p "3. IP ESTÁTICA de este Linux (ej: 192.168.20.2): " IP_LINUX_DDNS
        read -p "4. Primera IP a repartir (ej: 192.168.20.50): " DHCP_START
        read -p "5. Ultima IP a repartir (ej: 192.168.20.100): " DHCP_END

        # Le damos la vuelta a la red para la inversa
        INV_DDNS=$(echo $RED_DDNS | awk -F. '{print $3"."$2"."$1}')

        # Inyectar en BIND
        cat >> "$CONFIG" <<EOF

// ZONA DDNS: $DOM_DDNS
zone "$DOM_DDNS" {
    type master;
    file "/etc/bind/zonas/db.$DOM_DDNS"; 
    allow-update { key claveddns; };
    allow-query { any; };
};

zone "$INV_DDNS.in-addr.arpa" {
    type master;
    file "/etc/bind/zonas/db.$RED_DDNS";
    allow-update { key claveddns; };
    allow-query { any; };
};
EOF

        # Inyectar en DHCP
        cat >> "$DHCP_CONF" <<EOF

# DDNS PARA: $DOM_DDNS
zone $DOM_DDNS. {
    primary 127.0.0.1;
    key claveddns;
}

zone $INV_DDNS.in-addr.arpa. {
    primary 127.0.0.1;
    key claveddns;
}

subnet $RED_DDNS.0 netmask 255.255.255.0 {
    range $DHCP_START $DHCP_END;
    option domain-name "$DOM_DDNS";
    option domain-name-servers $IP_LINUX_DDNS;
    option routers $IP_LINUX_DDNS;
    option broadcast-address $RED_DDNS.255;
    default-lease-time 600;
    max-lease-time 7200;
}
EOF

        # Crear las plantillas de los ficheros
        cat > "$DIR/zonas/db.$DOM_DDNS" <<EOF
\$ORIGIN $DOM_DDNS.
\$TTL 86400
@   IN  SOA ns1.$DOM_DDNS. admin.$DOM_DDNS. ( 1 3600 1800 604800 86400 )
@   IN  NS  ns1.$DOM_DDNS.
ns1 IN  A   $IP_LINUX_DDNS
EOF

        cat > "$DIR/zonas/db.$RED_DDNS" <<EOF
\$ORIGIN $INV_DDNS.in-addr.arpa.
\$TTL 86400
@   IN  SOA ns1.$DOM_DDNS. admin.$DOM_DDNS. ( 1 3600 1800 604800 86400 )
@   IN  NS  ns1.$DOM_DDNS.
EOF

        OCT_LINUX=$(echo $IP_LINUX_DDNS | awk -F. '{print $4}')
        echo "$OCT_LINUX   IN  PTR ns1.$DOM_DDNS." >> "$DIR/zonas/db.$RED_DDNS"
    done
fi

# ========================================================
# 4. CREAR INSTALADOR
# ========================================================
cat > "$INSTALL_SCRIPT" << 'EOF'
#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "Usa: sudo ./instalar.sh"
  exit 1
fi

echo "1. Creando carpetas..."
mkdir -p /etc/bind/zonas
cp zonas/* /etc/bind/zonas/ 2>/dev/null || true

echo "2. Copiando configuraciones..."
cp named.conf.local /etc/bind/
cp dhcpd.conf.generado /etc/dhcp/dhcpd.conf
cp isc-dhcp-server.generado /etc/default/isc-dhcp-server

echo "3. Configurando llaves y permisos..."
cp rndc.key.generado /etc/bind/rndc.key
cp rndc.key.generado /etc/dhcp/rndc.key
chown bind:bind /etc/bind/rndc.key
chown dhcpd:dhcpd /etc/dhcp/rndc.key
chmod 640 /etc/bind/rndc.key
chmod 640 /etc/dhcp/rndc.key

echo "4. Desbloqueando la carpeta zonas para DDNS..."
cp apparmor.named.generado /etc/apparmor.d/local/usr.sbin.named
chown -R bind:bind /etc/bind/zonas
chmod -R 775 /etc/bind/zonas

echo "5. Reiniciando servicios..."
systemctl reload apparmor
systemctl restart bind9
systemctl restart isc-dhcp-server

echo "------------------------------------------------"
systemctl status bind9 --no-pager | grep Active
systemctl status isc-dhcp-server --no-pager | grep Active
echo "------------------------------------------------"
EOF

chmod +x "$INSTALL_SCRIPT"

clear
echo "¡CONFIGURACIÓN GENERADA CON ÉXITO!"
echo "Ahora, asegúrate de que tu interfaz (ej. ens19) tenga la IP estática configurada en el sistema."
echo ""
echo "Para aplicar todo, ejecuta:"
echo "1) cd $DIR"
echo "2) sudo ./instalar.sh"