#!/bin/bash

clear

# 1. CREAR EL DIRECTORIO DE TRABAJO
DIR_SALIDA="despliegue_ddns"
mkdir -p "$DIR_SALIDA/zonas"

CONFIG="$DIR_SALIDA/named.conf.local"
DHCP_CONF="$DIR_SALIDA/dhcpd.conf.generado"
KEY_FILE="$DIR_SALIDA/rndc.key.generado"
APPARMOR_FILE="$DIR_SALIDA/apparmor.named.generado"
INSTALL_SCRIPT="$DIR_SALIDA/instalar.sh"

echo "" > "$CONFIG"
echo "" > "$DHCP_CONF"

echo "=========================================================="
echo "   GENERADOR DNS MULTIZONA (ESCLAVO + DDNS MAESTRO)"
echo "=========================================================="

#################################################
# 2. LLAVE TSIG (SIN COMILLAS EN EL NOMBRE)
#################################################
LLAVE_SECRETA="LaB/sEcReTa/DdNs/KeY=="

cat > "$KEY_FILE" <<EOF
key rndc-key {
    algorithm hmac-sha256;
    secret "$LLAVE_SECRETA";
};
EOF

#################################################
# 3. EXCEPCIÓN APPARMOR
#################################################
cat > "$APPARMOR_FILE" <<EOF
# Excepcion local para permitir a BIND escribir los .jnl en la carpeta zonas
/etc/bind/zonas/** rw,
EOF

cat >> "$CONFIG" <<EOF
// Importar la llave de seguridad para actualizaciones dinamicas
include "/etc/bind/rndc.key";

EOF

cat >> "$DHCP_CONF" <<EOF
# Configuracion DDNS Global
ddns-updates on;
ddns-update-style interim;
update-static-leases on;
ignore client-updates;
authoritative;

# Importar la llave TSIG
include "/etc/dhcp/rndc.key";

EOF

#################################################
# 4. ZONAS ESCLAVAS (VIENEN DE WINDOWS)
#################################################
echo
echo "--- FASE 1: ZONAS ESCLAVAS (WINDOWS -> LINUX) ---"
read -p "¿Cuántas zonas directas vas a descargar del Maestro Windows? (0 si ninguna): " NUM_SLAVES

if [[ $NUM_SLAVES -gt 0 ]]; then
    read -p "IP del Windows Server (Maestro): " IP_WINDOWS
    
    for ((i=1; i<=NUM_SLAVES; i++))
    do
        echo
        read -p "[$i] Nombre de la zona principal en Windows (ej: dominio.org): " DOM_SLAVE
        read -p "[$i] Red de su zona inversa (ej: 6.4.2 para red 2.4.6.x) (Deja vacio si no tiene): " INV_SLAVE
        
        cat >> "$CONFIG" <<EOF
//////////////////////////////////////////////////
// ESCLAVO: $DOM_SLAVE
//////////////////////////////////////////////////
zone "$DOM_SLAVE" {
    type slave;
    file "/var/cache/bind/db.$DOM_SLAVE";
    masters { $IP_WINDOWS; };
    allow-query { any; };
};
EOF

        if [[ -n "$INV_SLAVE" ]]; then
            cat >> "$CONFIG" <<EOF
zone "$INV_SLAVE.in-addr.arpa" {
    type slave;
    file "/var/cache/bind/db.$INV_SLAVE";
    masters { $IP_WINDOWS; };
    allow-query { any; };
};
EOF
        fi
    done
fi

#################################################
# 5. ZONAS DINÁMICAS (LINUX + DHCP)
#################################################
echo
echo "--- FASE 2: ZONAS DINAMICAS DDNS (LINUX MAESTRO) ---"
read -p "¿Para cuántas redes vas a dar servicio DHCP + DDNS? (0 si ninguna): " NUM_DDNS

if [[ $NUM_DDNS -gt 0 ]]; then
    for ((d=1; d<=NUM_DDNS; d++))
    do
        echo
        echo "=========== RED DINAMICA $d ==========="
        read -p "Nombre del dominio DDNS (ej: red1.dominio.org): " DOM_DDNS
        read -p "Red dinamica, pon SOLO LOS 3 PRIMEROS OCTETOS (ej: 192.168.10): " RED_DDNS
        read -p "Mascara CIDR (ej: 24): " MASK_DDNS
        read -p "IP de este servidor Linux en esta red: " IP_LINUX_DDNS
        read -p "Rango DHCP Inicio (ej: 192.168.10.50): " DHCP_START
        read -p "Rango DHCP Fin (ej: 192.168.10.100): " DHCP_END

        INV_DDNS=$(echo $RED_DDNS | awk -F. '{print $3"."$2"."$1}')

        #################################################
        # named.conf.local (Añadir Zonas sin comillas en key)
        #################################################
        cat >> "$CONFIG" <<EOF

//////////////////////////////////////////////////
// ZONA DDNS: $DOM_DDNS
//////////////////////////////////////////////////
zone "$DOM_DDNS" {
    type master;
    file "/etc/bind/zonas/db.$DOM_DDNS"; 
    allow-update { key rndc-key; };
    allow-query { any; };
};

zone "$INV_DDNS.in-addr.arpa" {
    type master;
    file "/etc/bind/zonas/db.$RED_DDNS";
    allow-update { key rndc-key; };
    allow-query { any; };
};
EOF

        #################################################
        # DHCP (Añadir Subred y Zonas sin comillas en key)
        #################################################
        cat >> "$DHCP_CONF" <<EOF

# Actualizacion DDNS para $DOM_DDNS
zone $DOM_DDNS. {
    primary 127.0.0.1;
    key rndc-key;
}

zone $INV_DDNS.in-addr.arpa. {
    primary 127.0.0.1;
    key rndc-key;
}

# Subred $RED_DDNS.0
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

        #################################################
        # Archivos de zona base
        #################################################
        DIRECTO="$DIR_SALIDA/zonas/db.$DOM_DDNS"
        INVERSO="$DIR_SALIDA/zonas/db.$RED_DDNS"

        cat > "$DIRECTO" <<EOF
\$ORIGIN $DOM_DDNS.
\$TTL 86400
@   IN  SOA ns1.$DOM_DDNS. admin.$DOM_DDNS. (
            1 3600 1800 604800 86400 )
@   IN  NS  ns1.$DOM_DDNS.
ns1 IN  A   $IP_LINUX_DDNS
EOF

        cat > "$INVERSO" <<EOF
\$ORIGIN $INV_DDNS.in-addr.arpa.
\$TTL 86400
@   IN  SOA ns1.$DOM_DDNS. admin.$DOM_DDNS. (
            1 3600 1800 604800 86400 )
@   IN  NS  ns1.$DOM_DDNS.
EOF

        OCT_LINUX=$(echo $IP_LINUX_DDNS | awk -F. '{print $4}')
        echo "$OCT_LINUX   IN  PTR ns1.$DOM_DDNS." >> "$INVERSO"

    done
fi

#################################################
# 6. SCRIPT INSTALADOR
#################################################
cat > "$INSTALL_SCRIPT" << 'EOF'
#!/bin/bash

echo "============================================="
echo "   INSTALADOR DE DDNS (BIND9 + DHCP)"
echo "============================================="

if [ "$EUID" -ne 0 ]; then
  echo "ERROR: Por favor, ejecuta este script con permisos de root."
  echo "Usa: sudo ./instalar.sh"
  exit 1
fi

echo "[1/6] Creando directorios y copiando zonas base..."
mkdir -p /etc/bind/zonas
cp zonas/* /etc/bind/zonas/ 2>/dev/null || true

echo "[2/6] Aplicando configuración de BIND y DHCP..."
cp named.conf.local /etc/bind/
cp dhcpd.conf.generado /etc/dhcp/dhcpd.conf

echo "[3/6] Instalando llaves de seguridad TSIG..."
cp rndc.key.generado /etc/bind/rndc.key
cp rndc.key.generado /etc/dhcp/rndc.key

echo "[4/6] Aplicando reglas de seguridad AppArmor..."
cp apparmor.named.generado /etc/apparmor.d/local/usr.sbin.named

echo "[5/6] Ajustando permisos y propietarios..."
chown bind:bind /etc/bind/rndc.key
chown dhcpd:dhcpd /etc/dhcp/rndc.key
chmod 640 /etc/bind/rndc.key
chmod 640 /etc/dhcp/rndc.key

chown -R bind:bind /etc/bind/zonas
chmod -R 775 /etc/bind/zonas

echo "[6/6] Reiniciando todos los servicios..."
systemctl reload apparmor
systemctl restart bind9
systemctl restart isc-dhcp-server

echo "============================================="
echo "        ¡INSTALACION COMPLETADA!"
echo "============================================="
echo "Estado de BIND9:"
systemctl status bind9 --no-pager | grep Active
echo "Estado de DHCP:"
systemctl status isc-dhcp-server --no-pager | grep Active
echo "============================================="
EOF

chmod +x "$INSTALL_SCRIPT"

clear
echo "=========================================================="
echo "    ARCHIVOS Y SCRIPT INSTALADOR GENERADOS CON EXITO"
echo "=========================================================="
echo "Se ha creado la carpeta: $DIR_SALIDA/"
echo ""
echo "Recuerda entrar y ejecutar el instalador:"
echo "  1) cd $DIR_SALIDA"
echo "  2) sudo ./instalar.sh"
echo "=========================================================="