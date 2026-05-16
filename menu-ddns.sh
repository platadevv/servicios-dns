#!/bin/bash

clear

# ========================================================
# 1. PREPARACIÓN INICIAL
# ========================================================
DIR="despliegue_ddns"
mkdir -p "$DIR/zonas"

CONFIG="$DIR/named.conf.local"
DHCP_CONF="$DIR/dhcpd.conf.generado"
DHCP_DEFAULT="$DIR/isc-dhcp-server.generado"
APPARMOR_FILE="$DIR/apparmor.named.generado"
INSTALL_SCRIPT="$DIR/instalar.sh"

echo "" > "$CONFIG"
echo "" > "$DHCP_CONF"
echo "" > "$APPARMOR_FILE"
CARPETA_ESCLAVOS=""

# ========================================================
# 2. MENÚ PRINCIPAL
# ========================================================
echo "=========================================================="
echo "      MEGA ASISTENTE BIND9 + DHCP (DEBIAN/UBUNTU)"
echo "=========================================================="
echo "Elige el escenario que deseas configurar:"
echo "  1) Modo Híbrido: Esclavo de Principal + DDNS Maestro local"
echo "  2) Modo Puro: Solo DDNS Maestro local (Sin Maestro externo)"
echo "  3) Modo Delegado: Esclavo de TODAS las zonas + DHCP al Maestro"
echo "  4) Modo Esclavo Puro: Solo DNS Esclavo (APAGA EL DHCP LOCAL)"
echo "  5) Limpieza Total: Resetear Servidor (Borrar todo rastro DDNS/DHCP)"
echo "  6) Salir"
echo "=========================================================="
read -p "Opción [1-6]: " OPCION

if [[ "$OPCION" == "6" ]]; then
    echo "Saliendo del asistente..."
    rm -rf "$DIR"
    exit 0
fi

if [[ ! "$OPCION" =~ ^[1-5]$ ]]; then
    echo "Opción no válida. Saliendo."
    exit 1
fi

# ========================================================
# OPCIÓN 5: LIMPIEZA TOTAL (RESET DE FÁBRICA)
# ========================================================
if [[ "$OPCION" == "5" ]]; then
    cat > "$INSTALL_SCRIPT" << 'EOF'
#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "Usa: sudo ./instalar.sh"
  exit 1
fi

echo "1. Deteniendo y desactivando el servicio DHCP..."
systemctl stop isc-dhcp-server 2>/dev/null
systemctl disable isc-dhcp-server 2>/dev/null
echo "" > /etc/dhcp/dhcpd.conf

echo "2. Vaciando configuraciones locales de BIND9..."
echo "" > /etc/bind/named.conf.local

echo "3. Eliminando llaves de seguridad y rastros del Profesor..."
rm -f /etc/bind/rndc.key /etc/dhcp/rndc.key
sed -i '/rndc.key/d' /etc/bind/named.conf

echo "4. Borrando carpetas de zonas dinámicas y esclavas..."
rm -rf /etc/bind/zonas /etc/bind/esclavos
rm -f /var/cache/bind/db.*

echo "5. Restaurando seguridad AppArmor..."
echo "" > /etc/apparmor.d/local/usr.sbin.named
systemctl reload apparmor

echo "6. Reiniciando BIND9 limpio..."
systemctl restart bind9

echo "=========================================================="
echo "   ¡SERVIDOR TOTALMENTE LIMPIO Y RESETEADO A FÁBRICA!"
echo "=========================================================="
systemctl status bind9 --no-pager | grep Active
EOF

    chmod +x "$INSTALL_SCRIPT"
    clear
    echo "=========================================================="
    echo "   SCRIPT DE LIMPIEZA GENERADO"
    echo "=========================================================="
    echo "Ejecuta: sudo ./$DIR/instalar.sh para limpiar la máquina."
    exit 0
fi

# ========================================================
# FLUJO NORMAL (OPCIONES 1 a 4)
# ========================================================
if [[ "$OPCION" != "4" ]]; then
    # Configuracion DHCP Base solo para opciones que lo usan (1, 2, 3)
    cat >> "$DHCP_CONF" <<EOF
ddns-updates on;
ddns-update-style interim;
update-static-leases on;
ignore client-updates;
authoritative;
include "/etc/dhcp/rndc.key";
EOF

    echo "/etc/bind/zonas/** rw," > "$APPARMOR_FILE"
    
    echo
    echo "--- CONFIGURACIÓN DE RED (DHCP) ---"
    read -p "Escribe las interfaces para DHCP (ej: ens19): " INTERFAZ_DHCP
    cat > "$DHCP_DEFAULT" <<EOF
INTERFACESv4="$INTERFAZ_DHCP"
INTERFACESv6=""
EOF
fi

# ========================================================
# BLOQUE ESCLAVO (OPCIONES 1, 3 Y 4)
# ========================================================
if [[ "$OPCION" == "1" || "$OPCION" == "3" || "$OPCION" == "4" ]]; then
    echo
    echo "--- CONFIGURACIÓN DE LA ZONA PRINCIPAL ESCLAVA ---"
    read -p "IP del servidor Maestro (Windows o Linux) (ej: 192.168.1.10): " IP_MAESTRO
    read -p "Nombre del dominio principal (ej: principal.com): " DOM_SLAVE
    read -p "Red de la zona inversa del maestro (SOLO 3 OCTETOS) (ej: 192.168.1): " RED_INV_MASTER
    
    INV_MASTER_ARPA=$(echo $RED_INV_MASTER | awk -F. '{print $3"."$2"."$1}')
    
    echo
    read -p "Nombre de la carpeta para guardar estas zonas en /etc/bind/ (ej: esclavos): " CARPETA_ESCLAVOS
    CARPETA_ESCLAVOS=${CARPETA_ESCLAVOS:-esclavos}

    echo "/etc/bind/$CARPETA_ESCLAVOS/** rw," >> "$APPARMOR_FILE"

    cat >> "$CONFIG" <<EOF
// ====================================================
// ZONA ESCLAVA 
// ====================================================
zone "$DOM_SLAVE" {
    type slave;
    file "/etc/bind/$CARPETA_ESCLAVOS/db.$DOM_SLAVE";
    masters { $IP_MAESTRO; };
    allow-query { any; };
};

zone "$INV_MASTER_ARPA.in-addr.arpa" {
    type slave;
    file "/etc/bind/$CARPETA_ESCLAVOS/db.$RED_INV_MASTER";
    masters { $IP_MAESTRO; };
    allow-query { any; };
};
EOF
fi

# ========================================================
# CONFIGURACIÓN DDNS Y DHCP (SOLO OPCIONES 1, 2 Y 3)
# ========================================================
if [[ "$OPCION" == "1" || "$OPCION" == "2" || "$OPCION" == "3" ]]; then
    echo
    echo "--- ZONAS DDNS Y DHCP ---"
    read -p "¿Para cuántas subredes vas a configurar DHCP con DDNS? (Pon un numero, ej: 1): " NUM_DDNS

    if [[ $NUM_DDNS -gt 0 ]]; then
        for ((d=1; d<=NUM_DDNS; d++))
        do
            echo
            echo "=== CONFIGURANDO RED DDNS $d ==="
            read -p "1. Nombre del dominio dinamico (ej: subred1.local): " DOM_DDNS
            read -p "2. Red (SOLO 3 OCTETOS) (ej: 1.3.5): " RED_DDNS
            read -p "3. IP ESTÁTICA de este Linux (ej: 1.3.5.4): " IP_LINUX_DDNS
            
            read -p "Tiempo de concesión defecto (Enter=600s): " DEFAULT_LEASE
            DEFAULT_LEASE=${DEFAULT_LEASE:-600}
            read -p "Tiempo máximo de concesión (Enter=7200s): " MAX_LEASE
            MAX_LEASE=${MAX_LEASE:-7200}

            read -p "Primera IP que dara el DHCP (ej: 1.3.5.50): " DHCP_START
            read -p "Ultima IP que dara el DHCP (ej: 1.3.5.100): " DHCP_END

            read -p "¿Deseas excluir un bloque de IPs en medio? (1=Si, 0=No): " TIENE_EXCLUSION
            
            RANGOS_DHCP=""
            if [[ "$TIENE_EXCLUSION" == "1" ]]; then
                read -p "   - PRIMERA IP de exclusión (ej: 1.3.5.70): " EXC_START
                read -p "   - ÚLTIMA IP de exclusión (ej: 1.3.5.80): " EXC_END
                
                BASE_IP=$(echo $DHCP_START | cut -d. -f1-3)
                START_OCT=$(echo $DHCP_START | cut -d. -f4)
                END_OCT=$(echo $DHCP_END | cut -d. -f4)
                EXC_START_OCT=$(echo $EXC_START | cut -d. -f4)
                EXC_END_OCT=$(echo $EXC_END | cut -d. -f4)

                if [[ $START_OCT -lt $EXC_START_OCT ]]; then
                    R1_END=$((EXC_START_OCT - 1))
                    RANGOS_DHCP="    range $BASE_IP.$START_OCT $BASE_IP.$R1_END;"
                fi
                if [[ $END_OCT -gt $EXC_END_OCT ]]; then
                    R2_START=$((EXC_END_OCT + 1))
                    RANGOS_DHCP="${RANGOS_DHCP}
    range $BASE_IP.$R2_START $BASE_IP.$END_OCT;"
                fi
            else
                RANGOS_DHCP="    range $DHCP_START $DHCP_END;"
            fi

            INV_DDNS=$(echo $RED_DDNS | awk -F. '{print $3"."$2"."$1}')

            if [[ "$OPCION" == "3" ]]; then
                cat >> "$CONFIG" <<EOF
zone "$DOM_DDNS" {
    type slave;
    file "/etc/bind/$CARPETA_ESCLAVOS/db.$DOM_DDNS";
    masters { $IP_MAESTRO; };
    allow-query { any; };
};

zone "$INV_DDNS.in-addr.arpa" {
    type slave;
    file "/etc/bind/$CARPETA_ESCLAVOS/db.$RED_DDNS";
    masters { $IP_MAESTRO; };
    allow-query { any; };
};
EOF
                cat >> "$DHCP_CONF" <<EOF
zone $DOM_DDNS. { primary $IP_MAESTRO; key rndc-key; }
zone $INV_DDNS.in-addr.arpa. { primary $IP_MAESTRO; key rndc-key; }
EOF
            else
                cat >> "$CONFIG" <<EOF
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
                cat >> "$DHCP_CONF" <<EOF
zone $DOM_DDNS. { primary 127.0.0.1; key rndc-key; }
zone $INV_DDNS.in-addr.arpa. { primary 127.0.0.1; key rndc-key; }
EOF
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
            fi

            cat >> "$DHCP_CONF" <<EOF
subnet $RED_DDNS.0 netmask 255.255.255.0 {
$RANGOS_DHCP
    option domain-name "$DOM_DDNS";
    option domain-name-servers $IP_LINUX_DDNS;
    option routers $IP_LINUX_DDNS;
    option broadcast-address $RED_DDNS.255;
    default-lease-time $DEFAULT_LEASE;
    max-lease-time $MAX_LEASE;
}
EOF
        done
    fi
fi

# ========================================================
# SCRIPT INSTALADOR AUTOMÁTICO PARA OPCIONES 1, 2, 3 y 4
# ========================================================
cat > "$INSTALL_SCRIPT" << EOF
#!/bin/bash

cd "\$(dirname "\$0")" || exit 1

if [ "\$EUID" -ne 0 ]; then
  echo "Usa: sudo ./instalar.sh"
  exit 1
fi

echo "0. Limpiando saltos de linea CRLF de Windows..."
sed -i 's/\r//g' named.conf.local dhcpd.conf.generado isc-dhcp-server.generado apparmor.named.generado 2>/dev/null || true

echo "1. Creando estructura de carpetas..."
mkdir -p /etc/bind/zonas
cp zonas/* /etc/bind/zonas/ 2>/dev/null || true

if [ -n "$CARPETA_ESCLAVOS" ]; then
    mkdir -p /etc/bind/$CARPETA_ESCLAVOS
    chown -R bind:bind /etc/bind/$CARPETA_ESCLAVOS
    chmod -R 775 /etc/bind/$CARPETA_ESCLAVOS
fi

echo "2. Copiando configuraciones principales..."
cp named.conf.local /etc/bind/

if [ "$OPCION" == "4" ]; then
    echo "-> Modo Esclavo Puro: Vaciando y APAGANDO el servidor DHCP para evitar conflictos..."
    echo "" > /etc/dhcp/dhcpd.conf
    systemctl stop isc-dhcp-server 2>/dev/null
    systemctl disable isc-dhcp-server 2>/dev/null
else
    cp dhcpd.conf.generado /etc/dhcp/dhcpd.conf
    cp isc-dhcp-server.generado /etc/default/isc-dhcp-server
    
    echo "3. Generando llave nativa de BIND..."
    rm -f /etc/bind/rndc.key /etc/dhcp/rndc.key
    rndc-confgen -a -c /etc/bind/rndc.key -u bind
    cp /etc/bind/rndc.key /etc/dhcp/rndc.key
    
    chmod 640 /etc/bind/rndc.key
    chown root:root /etc/dhcp/rndc.key
    chmod 640 /etc/dhcp/rndc.key

    if ! grep -q 'include "/etc/bind/rndc.key";' /etc/bind/named.conf; then
        sed -i '1iinclude "/etc/bind/rndc.key";' /etc/bind/named.conf
    fi
fi

echo "4. Configurando AppArmor..."
cp apparmor.named.generado /etc/apparmor.d/local/usr.sbin.named
chown -R bind:bind /etc/bind/zonas
chmod -R 775 /etc/bind/zonas
systemctl reload apparmor

echo "5. Reiniciando servicios..."
systemctl restart bind9
if [ "$OPCION" != "4" ]; then
    systemctl restart isc-dhcp-server
fi

echo "------------------------------------------------"
systemctl status bind9 --no-pager | grep Active
if [ "$OPCION" != "4" ]; then
    systemctl status isc-dhcp-server --no-pager | grep Active
fi
echo "------------------------------------------------"
EOF

chmod +x "$INSTALL_SCRIPT"

clear
echo "=========================================================="
echo "    CONFIGURACIÓN GENERADA CON ÉXITO"
echo "=========================================================="
echo "Para instalarla ejecuta:"
echo "  1) cd $DIR"
echo "  2) sudo ./instalar.sh"
echo "=========================================================="