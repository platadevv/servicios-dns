#!/bin/bash

clear

# ========================================================
# 1. PREPARACIÓN INICIAL
# ========================================================
DIR="despliegue_ddns"
mkdir -p "$DIR/zonas"

CONFIG="$DIR/named.conf.local"
CONFIG_SLAVE="$DIR/named.conf.local.slave"
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
echo "  5) Limpieza Total: Resetear Servidor (Borrar rastros)"
echo "  6) Modo Estático: Generador DNS Clásico Master/Slave (TU SCRIPT)"
echo "  7) Salir"
echo "=========================================================="
read -p "Opción [1-7]: " OPCION

if [[ "$OPCION" == "7" ]]; then
    echo "Saliendo del asistente..."
    rm -rf "$DIR"
    exit 0
fi

if [[ ! "$OPCION" =~ ^[1-6]$ ]]; then
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

echo "3. Eliminando llaves de seguridad..."
rm -f /etc/bind/rndc.key /etc/dhcp/rndc.key
sed -i '/rndc.key/d' /etc/bind/named.conf

echo "4. Borrando carpetas de zonas..."
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
# OPCIÓN 6: GENERADOR DNS ESTÁTICO (TU SCRIPT INTEGRADO)
# ========================================================
if [[ "$OPCION" == "6" ]]; then
    echo "" > "$CONFIG_SLAVE"
    echo "=========================================="
    echo "     GENERADOR COMPLETO DNS BIND9"
    echo "=========================================="

    d=1
    while true; do
        echo
        echo "=========== DOMINIO PRINCIPAL $d ==========="
        read -p "Dominio principal (ej: dominio.org): " DOM
        read -p "Red dominio principal (ej: 2.4.6): " RED
        read -p "Mascara CIDR (ej: 24): " MASK

        echo
        echo "===== MASTER DNS ====="
        read -p "Hostname master DNS (ej: serverdns1): " HOST_MASTER
        read -p "Alias master DNS (ej: masterdns): " ALIAS_MASTER
        read -p "IP master DNS: " IP_MASTER

        echo
        echo "===== SLAVE DNS DOMINIO PRINCIPAL ====="
        read -p "Hostname slave DNS (ej: serverdns2): " HOST_SLAVE
        read -p "Alias slave DNS (ej: slavedns): " ALIAS_SLAVE
        read -p "IP slave DNS en red principal: " IP_SLAVE_MAIN

        echo
        echo "ATENCION: El correo debe llevar un punto en vez de @ y terminar en punto."
        read -p "Correo administrador (ej: master.gmail.com.): " ADMIN

        INVERSA=$(echo $RED | awk -F. '{print $3"."$2"."$1}')

        # named.conf.local MASTER
        cat >> "$CONFIG" <<EOF

//////////////////////////////////////////////////
// DOMINIO $DOM
//////////////////////////////////////////////////

zone "$DOM"
{
    type master;
    file "/etc/bind/zonas/db.$DOM";
    allow-query { any; }; 
    allow-transfer { $IP_SLAVE_MAIN; };
    also-notify { $IP_SLAVE_MAIN; };
    notify yes;
};

zone "$INVERSA.in-addr.arpa"
{
    type master;
    file "/etc/bind/zonas/db.$RED";
    allow-query { any; };
    allow-transfer { $IP_SLAVE_MAIN; };
    also-notify { $IP_SLAVE_MAIN; };
    notify yes;
};
EOF

        # named.conf.local SLAVE
        cat >> "$CONFIG_SLAVE" <<EOF

//////////////////////////////////////////////////
// DOMINIO $DOM
//////////////////////////////////////////////////

zone "$DOM"
{
    type slave;
    file "/etc/bind/zonas/db.$DOM";
    masters { $IP_MASTER; };
    allow-query { any; };
};

zone "$INVERSA.in-addr.arpa"
{
    type slave;
    file "/etc/bind/zonas/db.$RED";
    masters { $IP_MASTER; };
    allow-query { any; };
};
EOF

        # FICHERO DIRECTO DOMINIO PRINCIPAL
        DIRECTO="$DIR/zonas/db.$DOM"

        cat > "$DIRECTO" <<EOF
\$TTL 604800
@   IN  SOA $DOM. $ADMIN (
            2          ; Serial
            604800     ; Refresh
            86400      ; Retry
            2419200    ; Expire
            604800 )   ; Negative Cache TTL

; Name Servers
@   IN  NS  $HOST_MASTER.$DOM.
@   IN  NS  $HOST_SLAVE.$DOM.

; Resolucion del dominio base
@   IN  A   $IP_MASTER

; Registros A
$HOST_MASTER   IN  A   $IP_MASTER
$HOST_SLAVE    IN  A   $IP_SLAVE_MAIN

; Alias CNAME
$ALIAS_MASTER  IN  CNAME $HOST_MASTER
$ALIAS_SLAVE   IN  CNAME $HOST_SLAVE

EOF

        # HOSTS DOMINIO PRINCIPAL
        echo
        read -p "Numero de hosts extra del dominio principal (0 si no hay): " NUM_HOSTS

        declare -a HOSTNAMES
        declare -a HOSTIPS

        if [[ $NUM_HOSTS -gt 0 ]]; then
            for ((h=1; h<=NUM_HOSTS; h++))
            do
                echo "=========== HOST $h ==========="
                read -p "Hostname (sin dominio): " HOST
                read -p "Alias (opcional, enter para saltar): " ALIAS
                read -p "IP host completa: " IPHOST

                HOSTNAMES[$h]=$HOST
                HOSTIPS[$h]=$IPHOST

                echo "$HOST IN A $IPHOST" >> "$DIRECTO"
                if [[ -n "$ALIAS" ]]; then
                    echo "$ALIAS IN CNAME $HOST" >> "$DIRECTO"
                fi
            done
        fi

        # FICHERO INVERSO DOMINIO PRINCIPAL
        INVERSO="$DIR/zonas/db.$RED"

        cat > "$INVERSO" <<EOF
\$TTL 604800
@   IN  SOA $INVERSA.in-addr.arpa. $ADMIN (
            2
            604800
            86400
            2419200
            604800 )

@   IN  NS  $HOST_MASTER.$DOM.
@   IN  NS  $HOST_SLAVE.$DOM.

EOF

        # PTR MASTER Y SLAVE
        OCT_MASTER=$(echo $IP_MASTER | awk -F. '{print $4}')
        echo "$OCT_MASTER IN PTR $HOST_MASTER.$DOM." >> "$INVERSO"

        OCT_SLAVE=$(echo $IP_SLAVE_MAIN | awk -F. '{print $4}')
        echo "$OCT_SLAVE IN PTR $HOST_SLAVE.$DOM." >> "$INVERSO"

        # PTR HOSTS
        if [[ $NUM_HOSTS -gt 0 ]]; then
            for ((h=1; h<=NUM_HOSTS; h++))
            do
                HOST=${HOSTNAMES[$h]}
                IP=${HOSTIPS[$h]}
                OCTETO=$(echo $IP | awk -F. '{print $4}')

                echo
                echo "PTR detectado:"
                echo "$OCTETO -> $HOST.$DOM."
                read -p "¿Añadir PTR? (s/n): " RESP

                if [[ $RESP == "s" || $RESP == "S" ]]; then
                    echo "$OCTETO IN PTR $HOST.$DOM." >> "$INVERSO"
                fi
            done
        fi

        # SUBDOMINIOS
        echo
        read -p "Numero de subdominios para $DOM (0 si no hay): " NUM_SUB

        if [[ $NUM_SUB -gt 0 ]]; then
            for ((s=1; s<=NUM_SUB; s++))
            do
                echo
                echo "=========== SUBDOMINIO $s ==========="
                read -p "Nombre subdominio (ej: subdominio1): " SUB
                read -p "Red subdominio (ej: 1.3.5): " REDSUB
                read -p "Mascara subdominio (ej: 24): " MASKSUB
                read -p "IP del slave DNS en esta red: " IP_SLAVE_SUB

                INV_SUB=$(echo $REDSUB | awk -F. '{print $3"."$2"."$1}')

                # named.conf.local MASTER SUBDOMINIO
                cat >> "$CONFIG" <<EOF

zone "$SUB.$DOM"
{
    type master;
    file "/etc/bind/zonas/db.$SUB.$DOM";
    allow-query { any; };
    allow-transfer { $IP_SLAVE_MAIN; };
    also-notify { $IP_SLAVE_MAIN; };
    notify yes;
};

zone "$INV_SUB.in-addr.arpa"
{
    type master;
    file "/etc/bind/zonas/db.$REDSUB";
    allow-query { any; };
    allow-transfer { $IP_SLAVE_MAIN; };
    also-notify { $IP_SLAVE_MAIN; };
    notify yes;
};
EOF

                # named.conf.local SLAVE SUBDOMINIO
                cat >> "$CONFIG_SLAVE" <<EOF

//////////////////////////////////////////////////
// SUBDOMINIO $SUB.$DOM
//////////////////////////////////////////////////

zone "$SUB.$DOM"
{
    type slave;
    file "/etc/bind/zonas/db.$SUB.$DOM";
    masters { $IP_MASTER; };
    allow-query { any; };
};

zone "$INV_SUB.in-addr.arpa"
{
    type slave;
    file "/etc/bind/zonas/db.$REDSUB";
    masters { $IP_MASTER; };
    allow-query { any; };
};
EOF

                # FICHERO DIRECTO SUBDOMINIO
                DIRECT_SUB="$DIR/zonas/db.$SUB.$DOM"

                cat > "$DIRECT_SUB" <<EOF
\$TTL 604800
@   IN  SOA $SUB.$DOM. $ADMIN (
            2
            604800
            86400
            2419200
            604800 )

@   IN  NS  $HOST_MASTER.$DOM.
@   IN  NS  $HOST_SLAVE.$DOM.

@   IN  A   $IP_MASTER

$HOST_SLAVE    IN  A   $IP_SLAVE_SUB
$ALIAS_SLAVE   IN  CNAME $HOST_SLAVE

EOF

                # HOSTS SUBDOMINIO
                echo
                read -p "Numero de hosts del subdominio $SUB (0 si no hay): " NUM_HOST_SUB

                declare -a SUBHOSTNAMES
                declare -a SUBHOSTIPS

                if [[ $NUM_HOST_SUB -gt 0 ]]; then
                    for ((hs=1; hs<=NUM_HOST_SUB; hs++))
                    do
                        echo "=========== HOST SUBDOMINIO $hs ==========="
                        read -p "Hostname (sin dominio): " HOSTSUB
                        read -p "Alias (opcional): " ALIASSUB
                        read -p "IP host completa: " IPHOSTSUB

                        SUBHOSTNAMES[$hs]=$HOSTSUB
                        SUBHOSTIPS[$hs]=$IPHOSTSUB

                        echo "$HOSTSUB IN A $IPHOSTSUB" >> "$DIRECT_SUB"
                        if [[ -n "$ALIASSUB" ]]; then
                            echo "$ALIASSUB IN CNAME $HOSTSUB" >> "$DIRECT_SUB"
                        fi
                    done
                fi

                # FICHERO INVERSO SUBDOMINIO
                INV_SUB_FILE="$DIR/zonas/db.$REDSUB"

                cat > "$INV_SUB_FILE" <<EOF
\$TTL 604800
@   IN  SOA $INV_SUB.in-addr.arpa. $ADMIN (
            2
            604800
            86400
            2419200
            604800 )

@   IN  NS  $HOST_MASTER.$DOM.
@   IN  NS  $HOST_SLAVE.$DOM.

EOF

                OCT_SLAVE_SUB=$(echo $IP_SLAVE_SUB | awk -F. '{print $4}')
                echo "$OCT_SLAVE_SUB IN PTR $HOST_SLAVE.$DOM." >> "$INV_SUB_FILE"

                # PTR HOSTS SUBDOMINIO
                if [[ $NUM_HOST_SUB -gt 0 ]]; then
                    for ((ps=1; ps<=NUM_HOST_SUB; ps++))
                    do
                        HOST=${SUBHOSTNAMES[$ps]}
                        IP=${SUBHOSTIPS[$ps]}
                        OCTETO=$(echo $IP | awk -F. '{print $4}')

                        echo
                        echo "PTR detectado:"
                        echo "$OCTETO -> $HOST.$SUB.$DOM."
                        read -p "¿Añadir PTR? (s/n): " RESP

                        if [[ $RESP == "s" || $RESP == "S" ]]; then
                            echo "$OCTETO IN PTR $HOST.$SUB.$DOM." >> "$INV_SUB_FILE"
                        fi
                    done
                fi

            done
        fi

        echo
        echo "======================================================"
        read -p "¿Deseas añadir otro dominio principal? (s/n): " RESP_DOM
        if [[ "$RESP_DOM" != "s" && "$RESP_DOM" != "S" ]]; then
            break
        fi

        ((d++))
    done

    # INSTALADOR EXCLUSIVO PARA LA OPCION 6 (Estático Múltiple)
    cat > "$INSTALL_SCRIPT" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")" || exit 1

if [ "$EUID" -ne 0 ]; then
  echo "Usa: sudo ./instalar.sh"
  exit 1
fi

echo "0. Limpiando saltos de linea CRLF de Windows..."
sed -i 's/\r//g' named.conf.local named.conf.local.slave 2>/dev/null || true

echo "================================================="
echo "   INSTALADOR DE DNS ESTÁTICO (BIND9)"
echo "================================================="
echo "¿Qué rol va a tener esta máquina en la red?"
echo "  1) Servidor Maestro (Copia zonas locales y conf maestra)"
echo "  2) Servidor Esclavo (Copia solo la conf esclava)"
read -p "Elige [1-2]: " ROL_MAQUINA

echo "1. Deteniendo DHCP local para evitar conflictos..."
systemctl stop isc-dhcp-server 2>/dev/null
systemctl disable isc-dhcp-server 2>/dev/null

echo "2. Creando estructura de carpetas de zonas..."
mkdir -p /etc/bind/zonas

if [ "$ROL_MAQUINA" == "1" ]; then
    echo "3. Copiando configuracion MAESTRA..."
    cp named.conf.local /etc/bind/
    cp zonas/* /etc/bind/zonas/ 2>/dev/null || true
elif [ "$ROL_MAQUINA" == "2" ]; then
    echo "3. Copiando configuracion ESCLAVA..."
    cp named.conf.local.slave /etc/bind/named.conf.local
fi

echo "4. Ajustando permisos..."
chown -R bind:bind /etc/bind/zonas
chmod -R 775 /etc/bind/zonas

echo "5. Reiniciando BIND9..."
systemctl restart bind9

echo "------------------------------------------------"
systemctl status bind9 --no-pager | grep Active
echo "------------------------------------------------"
EOF
    chmod +x "$INSTALL_SCRIPT"

    clear
    echo "=========================================================="
    echo " CONFIGURACION GENERADA CORRECTAMENTE (MODO ESTÁTICO)"
    echo "=========================================================="
    echo "Puedes llevar la carpeta '$DIR' a tus dos maquinas."
    echo "Al ejecutar 'sudo ./instalar.sh' podras elegir si"
    echo "instalar la parte Maestra o la parte Esclava."
    echo "=========================================================="
    exit 0
fi

# ========================================================
# FLUJO NORMAL (OPCIONES 1 a 4) - ¡INTOUCHABLES!
# ========================================================
if [[ "$OPCION" != "4" ]]; then
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
# BLOQUE DE ZONAS ESCLAVAS (MODIFICADO PARA BUCLE)
# ========================================================
if [[ "$OPCION" == "1" || "$OPCION" == "3" || "$OPCION" == "4" ]]; then
    echo
    echo "--- CONFIGURACIÓN DE ZONAS ESCLAVAS ---"
    read -p "¿Cuántas zonas vas a transferir del Maestro? (ej: 1): " NUM_SLAVES
    
    if [[ $NUM_SLAVES -gt 0 ]]; then
        read -p "IP del servidor Maestro (Windows o Linux) (ej: 192.168.1.10): " IP_MAESTRO
        read -p "Nombre de la carpeta para guardar estas zonas en /etc/bind/ (ej: esclavos): " CARPETA_ESCLAVOS
        CARPETA_ESCLAVOS=${CARPETA_ESCLAVOS:-esclavos}

        echo "/etc/bind/$CARPETA_ESCLAVOS/** rw," >> "$APPARMOR_FILE"

        for ((s=1; s<=NUM_SLAVES; s++))
        do
            echo
            echo "=== ZONA ESCLAVA $s ==="
            read -p "Nombre del dominio (ej: principal.com): " DOM_SLAVE
            read -p "Red de la zona inversa (SOLO 3 OCTETOS, deja vacio si no tiene): " RED_INV_MASTER
            
            cat >> "$CONFIG" <<EOF
// ====================================================
// ZONA ESCLAVA: $DOM_SLAVE
// ====================================================
zone "$DOM_SLAVE" {
    type slave;
    file "/etc/bind/$CARPETA_ESCLAVOS/db.$DOM_SLAVE";
    masters { $IP_MAESTRO; };
    allow-query { any; };
};
EOF
            if [[ -n "$RED_INV_MASTER" ]]; then
                INV_MASTER_ARPA=$(echo $RED_INV_MASTER | awk -F. '{print $3"."$2"."$1}')
                cat >> "$CONFIG" <<EOF

zone "$INV_MASTER_ARPA.in-addr.arpa" {
    type slave;
    file "/etc/bind/$CARPETA_ESCLAVOS/db.$RED_INV_MASTER";
    masters { $IP_MAESTRO; };
    allow-query { any; };
};
EOF
            fi
        done
    fi
fi

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
            read -p "4. Nombre de host de ESTE servidor DNS (Enter para 'ns1'): " HOSTNAME_DNS
            HOSTNAME_DNS=${HOSTNAME_DNS:-ns1}
            
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
@   IN  SOA $HOSTNAME_DNS.$DOM_DDNS. admin.$DOM_DDNS. ( 1 3600 1800 604800 86400 )
@   IN  NS  $HOSTNAME_DNS.$DOM_DDNS.
$HOSTNAME_DNS IN  A   $IP_LINUX_DDNS
EOF
                cat > "$DIR/zonas/db.$RED_DDNS" <<EOF
\$ORIGIN $INV_DDNS.in-addr.arpa.
\$TTL 86400
@   IN  SOA $HOSTNAME_DNS.$DOM_DDNS. admin.$DOM_DDNS. ( 1 3600 1800 604800 86400 )
@   IN  NS  $HOSTNAME_DNS.$DOM_DDNS.
EOF
                OCT_LINUX=$(echo $IP_LINUX_DDNS | awk -F. '{print $4}')
                echo "$OCT_LINUX   IN  PTR $HOSTNAME_DNS.$DOM_DDNS." >> "$DIR/zonas/db.$RED_DDNS"
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
# SCRIPT INSTALADOR AUTOMÁTICO PARA OPCIONES 1 A 4
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
    echo "-> Modo Esclavo Puro: Vaciando y APAGANDO el servidor DHCP..."
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
echo "    MEGA SCRIPT (V6.1) GENERADO CON ÉXITO"
echo "=========================================================="
echo "Configuracion generada en la carpeta: $DIR"
echo "Para instalarla ejecuta:"
echo "  1) cd $DIR"
echo "  2) sudo ./instalar.sh"
echo "=========================================================="