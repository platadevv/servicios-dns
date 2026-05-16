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
echo "   GENERADOR DDNS INDESTRUCTIBLE (SINTAXIS DEL PROFESOR)"
echo "=========================================================="

# ========================================================
# 2. GENERAR LLAVE OFICIAL RNDC-KEY (Formato BIND9)
# ========================================================
cat > "$KEY_FILE" <<EOF
key "rndc-key" {
    algorithm hmac-sha256;
    secret "LaB/sEcReTa/DdNs/KeY==";
};
EOF

# Excepcion de AppArmor para la carpeta zonas
cat > "$APPARMOR_FILE" <<EOF
/etc/bind/zonas/** rw,
EOF

# Base del DHCP con la configuracion global DDNS
cat >> "$DHCP_CONF" <<EOF
ddns-updates on;
ddns-update-style interim;
update-static-leases on;
ignore client-updates;
authoritative;
include "/etc/dhcp/rndc.key";
EOF

# ========================================================
# 3. PREGUNTAS CLARAS CON EJEMPLOS
# ========================================================
echo
echo "--- 1. LAS TARJETAS DE RED ---"
echo "Tus redes internas son ens19, ens20, ens21 o ens22 (ens18 de Internet apagada)."
echo "Si usas varias, separalas con un espacio (ejemplo: ens19 ens20)"
read -p "Escribe las interfaces para DHCP: " INTERFAZ_DHCP

cat > "$DHCP_DEFAULT" <<EOF
INTERFACESv4="$INTERFAZ_DHCP"
INTERFACESv6=""
EOF

echo
echo "--- 2. EL MAESTRO WINDOWS ---"
echo "¿Vas a importar alguna zona esclava desde Windows Server?"
read -p "Pon 1 (Si) o 0 (No): " NUM_SLAVES

if [[ $NUM_SLAVES -gt 0 ]]; then
    echo
    read -p "IP del Windows Server (ejemplo: 2.4.6.8): " IP_WINDOWS
    read -p "Nombre del dominio en Windows (ejemplo: dominio.org): " DOM_SLAVE
    
    cat >> "$CONFIG" <<EOF

// ZONA COPIADA DE WINDOWS (ESCLAVO)
zone "$DOM_SLAVE" {
    type slave;
    file "/var/cache/bind/db.$DOM_SLAVE";
    masters { $IP_WINDOWS; };
    allow-query { any; };
};
EOF
fi

echo
echo "--- 3. TUS REDES DDNS (DHCP MÁSTER EN LINUX) ---"
echo "¿Para cuántas redes internas vas a configurar DHCP con DNS Dinamico?"
read -p "Pon un numero (ejemplo: 1): " NUM_DDNS

if [[ $NUM_DDNS -gt 0 ]]; then
    for ((d=1; d<=NUM_DDNS; d++))
    do
        echo
        echo "=== CONFIGURANDO RED DDNS $d ==="
        read -p "1. Nombre del dominio dinamico (ejemplo: alumnos.local): " DOM_DDNS
        read -p "2. Red (SOLO LOS 3 PRIMEROS OCTETOS) (ejemplo: 1.3.5): " RED_DDNS
        read -p "3. IP ESTÁTICA de este Linux en esta red (ejemplo: 1.3.5.4): " IP_LINUX_DDNS
        read -p "4. Primera IP que dara el DHCP (ejemplo: 1.3.5.50): " DHCP_START
        read -p "5. Ultima IP que dara el DHCP (ejemplo: 1.3.5.100): " DHCP_END

        # Inversa automática
        INV_DDNS=$(echo $RED_DDNS | awk -F. '{print $3"."$2"."$1}')

        # Inyectar en named.conf.local (CON COMILLAS en la llave para BIND9)
        cat >> "$CONFIG" <<EOF

// ZONA DDNS: $DOM_DDNS
zone "$DOM_DDNS" {
    type master;
    file "/etc/bind/zonas/db.$DOM_DDNS"; 
    allow-update { key "rndc-key"; };
    allow-query { any; };
};

zone "$INV_DDNS.in-addr.arpa" {
    type master;
    file "/etc/bind/zonas/db.$RED_DDNS";
    allow-update { key "rndc-key"; };
    allow-query { any; };
};
EOF

        # Inyectar en dhcpd.conf (SIN COMILLAS en la directiva 'key' de la zona para DHCP)
        cat >> "$DHCP_CONF" <<EOF

# DDNS PARA: $DOM_DDNS
zone $DOM_DDNS. {
    primary 127.0.0.1;
    key rndc-key;
}

zone $INV_DDNS.in-addr.arpa. {
    primary 127.0.0.1;
    key rndc-key;
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

        # Crear las plantillas base limpias
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
# 4. CREAR SCRIPT INSTALADOR AUTOMÁTICO
# ========================================================
cat > "$INSTALL_SCRIPT" << 'EOF'
#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "Usa: sudo ./instalar.sh"
  exit 1
fi

echo "1. Asegurando existencia de directorios..."
mkdir -p /etc/bind/zonas
cp zonas/* /etc/bind/zonas/ 2>/dev/null || true

echo "2. Copiando configuraciones principales..."
cp named.conf.local /etc/bind/
cp dhcpd.conf.generado /etc/dhcp/dhcpd.conf
cp isc-dhcp-server.generado /etc/default/isc-dhcp-server

echo "3. Instalando llaves oficiales rndc.key..."
cp rndc.key.generado /etc/bind/rndc.key
cp rndc.key.generado /etc/dhcp/rndc.key

echo "4. El paso del Profesor: Incluir la llave en el named.conf principal si no esta..."
if ! grep -q 'include "/etc/bind/rndc.key";' /etc/bind/named.conf; then
    # Lo añadimos al principio del fichero principal named.conf
    sed -i '1iinclude "/etc/bind/rndc.key";' /etc/bind/named.conf
fi

echo "5. Configurando excepciones de AppArmor..."
cp apparmor.named.generado /etc/apparmor.d/local/usr.sbin.named

echo "6. Ajustando propietarios y permisos de seguridad..."
chown bind:bind /etc/bind/rndc.key
chown dhcpd:dhcpd /etc/dhcp/rndc.key
chmod 640 /etc/bind/rndc.key
chmod 640 /etc/dhcp/rndc.key

chown -R bind:bind /etc/bind/zonas
chmod -R 775 /etc/bind/zonas

echo "7. Reiniciando seguridad y servicios..."
systemctl reload apparmor
systemctl restart bind9
systemctl restart isc-dhcp-server

echo "------------------------------------------------"
echo "VERIFICACIÓN DE ESTADO FINAL:"
systemctl status bind9 --no-pager | grep Active
systemctl status isc-dhcp-server --no-pager | grep Active
echo "------------------------------------------------"
EOF

chmod +x "$INSTALL_SCRIPT"

clear
echo "=========================================================="
echo "    INSTALADOR ACTUALIZADO CON ÉXITO (MÉTODO PROFESOR)"
echo "=========================================================="
echo "Para desplegar el entorno corregido ejecute:"
echo "  1) cd $DIR"
echo "  2) sudo ./instalar.sh"
echo "=========================================================="