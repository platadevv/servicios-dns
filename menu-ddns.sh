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
echo "/etc/bind/zonas/** rw," > "$APPARMOR_FILE"
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
echo "  3) Modo Delegado: Esclavo de TODAS las zonas + DHCP actualiza al Maestro"
echo "  4) Salir"
echo "=========================================================="
read -p "Opción [1-4]: " OPCION

if [[ "$OPCION" == "4" ]]; then
    echo "Saliendo del asistente..."
    rm -rf "$DIR"
    exit 0
fi

if [[ "$OPCION" != "1" && "$OPCION" != "2" && "$OPCION" != "3" ]]; then
    echo "Opción no válida. Saliendo."
    exit 1
fi

cat >> "$DHCP_CONF" <<EOF
ddns-updates on;
ddns-update-style interim;
update-static-leases on;
ignore client-updates;
authoritative;
include "/etc/dhcp/rndc.key";
EOF

echo
echo "--- CONFIGURACIÓN DE RED ---"
echo "Tus redes internas (ejemplo: ens19, ens20)."
read -p "Escribe las interfaces para DHCP: " INTERFAZ_DHCP

cat > "$DHCP_DEFAULT" <<EOF
INTERFACESv4="$INTERFAZ_DHCP"
INTERFACESv6=""
EOF

# ========================================================
# BLOQUE ESCLAVO (OPCIONES 1 Y 3 COMPARTEN ESTO)
# ========================================================
if [[ "$OPCION" == "1" || "$OPCION" == "3" ]]; then
    echo
    echo "--- CONFIGURACIÓN DE LA ZONA PRINCIPAL (NO DDNS) ---"
    read -p "IP del servidor Maestro (Windows o Linux) (ej: 192.168.1.10): " IP_MAESTRO
    read -p "Nombre del dominio principal (ej: principal.com): " DOM_SLAVE
    read -p "Red de la zona inversa del maestro (SOLO 3 OCTETOS) (ej: 192.168.1): " RED_INV_MASTER
    
    INV_MASTER_ARPA=$(echo $RED_INV_MASTER | awk -F. '{print $3"."$2"."$1}')
    
    echo
    echo "Vamos a crear una carpeta dentro de /etc/bind/ para guardar las zonas esclavas."
    read -p "Nombre de la carpeta (ejemplo: esclavos): " CARPETA_ESCLAVOS
    
    if [[ -z "$CARPETA_ESCLAVOS" ]]; then
        CARPETA_ESCLAVOS="esclavos"
    fi

    echo "/etc/bind/$CARPETA_ESCLAVOS/** rw," >> "$APPARMOR_FILE"

    cat >> "$CONFIG" <<EOF

// ====================================================
// ZONA PRINCIPAL ESCLAVA (ESTÁTICA, NO DDNS)
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
# CONFIGURACIÓN DDNS Y RANGOS DHCP (OPCIONES 1, 2 Y 3)
# ========================================================
echo
echo "--- ZONAS DDNS Y DHCP ---"
read -p "¿Para cuántas subredes vas a configurar DHCP con DDNS? (Pon un numero, ej: 1): " NUM_DDNS

if [[ $NUM_DDNS -gt 0 ]]; then
    for ((d=1; d<=NUM_DDNS; d++))
    do
        echo
        echo "=== CONFIGURANDO RED DDNS $d ==="
        read -p "1. Nombre del dominio dinamico (ej: subred1.local): " DOM_DDNS
        read -p "2. Red (SOLO LOS 3 PRIMEROS OCTETOS) (ej: 1.3.5): " RED_DDNS
        read -p "3. IP ESTÁTICA de este Linux en esta red (ej: 1.3.5.4): " IP_LINUX_DDNS
        
        # Tiempos DHCP
        echo
        echo "--- TIEMPOS DEL DHCP (En segundos) ---"
        read -p "Tiempo de concesión por defecto (Enter para 600s/10min): " DEFAULT_LEASE
        DEFAULT_LEASE=${DEFAULT_LEASE:-600}
        
        read -p "Tiempo máximo de concesión (Enter para 7200s/2horas): " MAX_LEASE
        MAX_LEASE=${MAX_LEASE:-7200}

        # Rangos y Exclusiones
        echo
        echo "--- RANGO DE IPs Y EXCLUSIONES ---"
        read -p "Primera IP que dara el DHCP (ej: 1.3.5.50): " DHCP_START
        read -p "Ultima IP que dara el DHCP (ej: 1.3.5.100): " DHCP_END

        read -p "¿Deseas excluir un bloque de IPs dentro de ese rango? (1=Si, 0=No): " TIENE_EXCLUSION
        
        RANGOS_DHCP=""
        if [[ "$TIENE_EXCLUSION" == "1" ]]; then
            read -p "   - Escribe la PRIMERA IP de la exclusión (ej: 1.3.5.70): " EXC_START
            read -p "   - Escribe la ÚLTIMA IP de la exclusión (ej: 1.3.5.80): " EXC_END
            
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

        # ====================================================
        # INYECCIÓN DIFERENCIADA SEGÚN LA OPCIÓN
        # ====================================================
        if [[ "$OPCION" == "3" ]]; then
            # MODO 3: ESCLAVO DE TODO. DHCP ACTUALIZA AL MAESTRO EXTERNO
            cat >> "$CONFIG" <<EOF

// ====================================================
// ZONAS DDNS (ESCLAVAS): $DOM_DDNS
// ====================================================
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

# DDNS PARA: $DOM_DDNS (ACTUALIZA AL MAESTRO REMOTO)
zone $DOM_DDNS. {
    primary $IP_MAESTRO;
    key rndc-key;
}

zone $INV_DDNS.in-addr.arpa. {
    primary $IP_MAESTRO;
    key rndc-key;
}
EOF
        else
            # MODO 1 Y 2: MAESTRO LOCAL DE DDNS. DHCP ACTUALIZA A SÍ MISMO
            cat >> "$CONFIG" <<EOF

// ====================================================
// ZONAS DDNS (MAESTRAS LOCALES): $DOM_DDNS
// ====================================================
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

# DDNS PARA: $DOM_DDNS (ACTUALIZA LOCAL)
zone $DOM_DDNS. {
    primary 127.0.0.1;
    key rndc-key;
}

zone $INV_DDNS.in-addr.arpa. {
    primary 127.0.0.1;
    key rndc-key;
}
EOF

            # Solo en los modos 1 y 2 creamos las plantillas locales
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

        # Agregar la subred al DHCP (Común a todas las opciones)
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

# ========================================================
# SCRIPT INSTALADOR AUTOMÁTICO
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

echo "1. Creando la estructura de carpetas en /etc/bind..."
mkdir -p /etc/bind/zonas
cp zonas/* /etc/bind/zonas/ 2>/dev/null || true

if [ -n "$CARPETA_ESCLAVOS" ]; then
    mkdir -p /etc/bind/$CARPETA_ESCLAVOS
    chown -R bind:bind /etc/bind/$CARPETA_ESCLAVOS
    chmod -R 775 /etc/bind/$CARPETA_ESCLAVOS
    echo "   -> Carpeta /etc/bind/$CARPETA_ESCLAVOS preparada."
fi

echo "2. Copiando configuraciones principales..."
cp named.conf.local /etc/bind/
cp dhcpd.conf.generado /etc/dhcp/dhcpd.conf
cp isc-dhcp-server.generado /etc/default/isc-dhcp-server

echo "3. Generando llave nativa de BIND..."
rm -f /etc/bind/rndc.key /etc/dhcp/rndc.key
rndc-confgen -a -c /etc/bind/rndc.key -u bind
cp /etc/bind/rndc.key /etc/dhcp/rndc.key

echo "4. Inyectando la llave en el named.conf principal..."
if ! grep -q 'include "/etc/bind/rndc.key";' /etc/bind/named.conf; then
    sed -i '1iinclude "/etc/bind/rndc.key";' /etc/bind/named.conf
fi

echo "5. Configurando seguridad AppArmor..."
cp apparmor.named.generado /etc/apparmor.d/local/usr.sbin.named

echo "6. Ajustando propietarios y permisos..."
chmod 640 /etc/bind/rndc.key
chown root:root /etc/dhcp/rndc.key
chmod 640 /etc/dhcp/rndc.key
chown -R bind:bind /etc/bind/zonas
chmod -R 775 /etc/bind/zonas

echo "7. Reiniciando servicios..."
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
echo "=========================================================="
echo "    MEGA SCRIPT GENERADO CON ÉXITO"
echo "=========================================================="
echo "Configuracion generada en la carpeta: $DIR"
echo "Para instalarla ejecuta:"
echo "  1) cd $DIR"
echo "  2) sudo ./instalar.sh"
echo "=========================================================="