#!/bin/bash

clear

DIR="despliegue_master"
mkdir -p "$DIR/zonas"

CONFIG="$DIR/named.conf.local.master"
CONFIG_SLAVE="$DIR/named.conf.local.slave"
INSTALL_SCRIPT="$DIR/instalar_master.sh"

echo "" > "$CONFIG"
echo "" > "$CONFIG_SLAVE"

echo "=========================================================="
echo "        GENERADOR BIND9 - MODO MAESTRO PURO"
echo "=========================================================="

# Bucle Principal de Redes/Zonas Maestras
ZONA_NUM=1
while true; do
    echo
    echo "=========================================================="
    echo "               NUEVA RED / ZONA PRINCIPAL $ZONA_NUM"
    echo "=========================================================="
    
    read -p "¿Vas a configurar una Zona Principal ahora mismo? (s/n): " CONF_PRINCIPAL
    
    if [[ "$CONF_PRINCIPAL" == "s" || "$CONF_PRINCIPAL" == "S" ]]; then
        read -p "Nombre del Dominio (ej: principal.com): " DOM
        read -p "Red de este dominio (SOLO 3 OCTETOS, ej: 192.168.1): " RED
        read -p "Hostname de ESTE servidor Maestro (ej: ns1 o master): " HOST_MASTER
        read -p "IP de ESTE servidor Maestro: " IP_MASTER
        read -p "Correo del Administrador (ej: admin.principal.com.): " ADMIN
        
        INV_RED=$(echo $RED | awk -F. '{print $3"."$2"."$1}')
        
        # Opciones de Transferencia para la Zona Principal
        read -p "¿Esta zona principal se va a transferir a un servidor Esclavo? (s/n): " TRANSF_PRINCIPAL
        
        if [[ "$TRANSF_PRINCIPAL" == "s" || "$TRANSF_PRINCIPAL" == "S" ]]; then
            read -p "¿El servidor Esclavo es Windows o Linux? (w/l): " OS_ESCLAVO
            read -p "IP del servidor Esclavo: " IP_SLAVE
            read -p "Hostname del Esclavo (ej: ns2 o slave): " HOST_SLAVE
            
            # Bloque Maestro CON Transferencia
            cat >> "$CONFIG" <<EOF

// ZONA PRINCIPAL: $DOM (CON TRANSFERENCIA A $IP_SLAVE)
zone "$DOM" {
    type master;
    file "/etc/bind/zonas/db.$DOM";
    allow-query { any; };
    allow-transfer { $IP_SLAVE; };
    also-notify { $IP_SLAVE; };
    notify yes;
};

zone "$INV_RED.in-addr.arpa" {
    type master;
    file "/etc/bind/zonas/db.$RED";
    allow-query { any; };
    allow-transfer { $IP_SLAVE; };
    also-notify { $IP_SLAVE; };
    notify yes;
};
EOF
            
            # Generar config Esclava SOLO si es Linux
            if [[ "$OS_ESCLAVO" == "l" || "$OS_ESCLAVO" == "L" ]]; then
                cat >> "$CONFIG_SLAVE" <<EOF

// ZONA ESCLAVA: $DOM (DESDE MAESTRO $IP_MASTER)
zone "$DOM" {
    type slave;
    file "/var/cache/bind/db.$DOM";
    masters { $IP_MASTER; };
    allow-query { any; };
};

zone "$INV_RED.in-addr.arpa" {
    type slave;
    file "/var/cache/bind/db.$RED";
    masters { $IP_MASTER; };
    allow-query { any; };
};
EOF
            fi
        else
            # Bloque Maestro SIN Transferencia (Aislado)
            cat >> "$CONFIG" <<EOF

// ZONA PRINCIPAL: $DOM (AISLADA - SIN TRANSFERENCIA)
zone "$DOM" {
    type master;
    file "/etc/bind/zonas/db.$DOM";
    allow-query { any; };
};

zone "$INV_RED.in-addr.arpa" {
    type master;
    file "/etc/bind/zonas/db.$RED";
    allow-query { any; };
};
EOF
        fi

        # Crear los ficheros de Zona Base
        DIRECTO="$DIR/zonas/db.$DOM"
        INVERSO="$DIR/zonas/db.$RED"

        cat > "$DIRECTO" <<EOF
\$TTL 604800
@   IN  SOA $DOM. $ADMIN ( 2 604800 86400 2419200 604800 )
@   IN  NS  $HOST_MASTER.$DOM.
EOF
        cat > "$INVERSO" <<EOF
\$TTL 604800
@   IN  SOA $INV_RED.in-addr.arpa. $ADMIN ( 2 604800 86400 2419200 604800 )
@   IN  NS  $HOST_MASTER.$DOM.
EOF
        
        # Añadir Registros del Maestro (y Esclavo si existe)
        echo "$HOST_MASTER IN A $IP_MASTER" >> "$DIRECTO"
        OCT_MASTER=$(echo $IP_MASTER | awk -F. '{print $4}')
        echo "$OCT_MASTER IN PTR $HOST_MASTER.$DOM." >> "$INVERSO"

        if [[ "$TRANSF_PRINCIPAL" == "s" || "$TRANSF_PRINCIPAL" == "S" ]]; then
            echo "@   IN  NS  $HOST_SLAVE.$DOM." >> "$DIRECTO"
            echo "@   IN  NS  $HOST_SLAVE.$DOM." >> "$INVERSO"
            echo "$HOST_SLAVE IN A $IP_SLAVE" >> "$DIRECTO"
            OCT_SLAVE=$(echo $IP_SLAVE | awk -F. '{print $4}')
            echo "$OCT_SLAVE IN PTR $HOST_SLAVE.$DOM." >> "$INVERSO"
        fi

        # Hosts Adicionales de la Zona Principal
        echo
        read -p "¿Cuántos hosts extra vas a configurar en $DOM? (0 si ninguno): " NUM_HOSTS
        if [[ $NUM_HOSTS -gt 0 ]]; then
            for ((h=1; h<=NUM_HOSTS; h++))
            do
                echo "--- HOST $h ($DOM) ---"
                read -p "Hostname (sin dominio, ej: pc01): " H_NAME
                read -p "Alias CNAME (deja vacío si no tiene): " H_ALIAS
                read -p "IP completa del host: " H_IP
                
                echo "$H_NAME IN A $H_IP" >> "$DIRECTO"
                if [[ -n "$H_ALIAS" ]]; then
                    echo "$H_ALIAS IN CNAME $H_NAME" >> "$DIRECTO"
                fi
                
                OCT_H=$(echo $H_IP | awk -F. '{print $4}')
                read -p "¿Añadir PTR a la inversa para $H_NAME? (s/n): " ADD_PTR
                if [[ "$ADD_PTR" == "s" || "$ADD_PTR" == "S" ]]; then
                    echo "$OCT_H IN PTR $H_NAME.$DOM." >> "$INVERSO"
                fi
            done
        fi
    fi

    # ========================================================
    # DOMINIOS/ZONAS EXTRA PARA TRANSFERIR
    # ========================================================
    echo
    echo "--- OTROS DOMINIOS / SUBDOMINIOS A TRANSFERIR ---"
    echo "NOTA: Debes escribir el nombre del dominio completo a mano."
    read -p "¿Cuántas zonas extra vas a crear y transferir? (0 si ninguna): " NUM_EXTRA
    
    if [[ $NUM_EXTRA -gt 0 ]]; then
        for ((e=1; e<=NUM_EXTRA; e++))
        do
            echo
            echo "=== ZONA EXTRA $e ==="
            read -p "Nombre COMPLETO del dominio (ej: sub.dominio.org o otro.com): " EDOM
            read -p "Red de este dominio (SOLO 3 OCTETOS, ej: 10.0.0): " ERED
            read -p "¿Esclavo de destino es Windows o Linux? (w/l): " EOS_ESCLAVO
            read -p "IP del Esclavo destino: " EIP_SLAVE
            read -p "Correo del Administrador: " EADMIN
            
            EINV_RED=$(echo $ERED | awk -F. '{print $3"."$2"."$1}')

            # Maestro de la Zona Extra
            cat >> "$CONFIG" <<EOF

// ZONA EXTRA: $EDOM
zone "$EDOM" {
    type master;
    file "/etc/bind/zonas/db.$EDOM";
    allow-query { any; };
    allow-transfer { $EIP_SLAVE; };
    also-notify { $EIP_SLAVE; };
    notify yes;
};

zone "$EINV_RED.in-addr.arpa" {
    type master;
    file "/etc/bind/zonas/db.$ERED";
    allow-query { any; };
    allow-transfer { $EIP_SLAVE; };
    also-notify { $EIP_SLAVE; };
    notify yes;
};
EOF
            # Esclavo de la Zona Extra (Solo si es Linux)
            if [[ "$EOS_ESCLAVO" == "l" || "$EOS_ESCLAVO" == "L" ]]; then
                cat >> "$CONFIG_SLAVE" <<EOF

// ZONA ESCLAVA EXTRA: $EDOM
zone "$EDOM" {
    type slave;
    file "/var/cache/bind/db.$EDOM";
    masters { $IP_MASTER; };
    allow-query { any; };
};

zone "$EINV_RED.in-addr.arpa" {
    type slave;
    file "/var/cache/bind/db.$ERED";
    masters { $IP_MASTER; };
    allow-query { any; };
};
EOF
            fi

            # Archivos Directo e Inverso de la Zona Extra
            EDIRECTO="$DIR/zonas/db.$EDOM"
            EINVERSO="$DIR/zonas/db.$ERED"

            cat > "$EDIRECTO" <<EOF
\$TTL 604800
@   IN  SOA $EDOM. $EADMIN ( 2 604800 86400 2419200 604800 )
@   IN  NS  $HOST_MASTER.$DOM.
EOF
            cat > "$EINVERSO" <<EOF
\$TTL 604800
@   IN  SOA $EINV_RED.in-addr.arpa. $EADMIN ( 2 604800 86400 2419200 604800 )
@   IN  NS  $HOST_MASTER.$DOM.
EOF
            
            # Hosts de la Zona Extra
            echo
            read -p "¿Cuántos hosts vas a crear en $EDOM? (0 si ninguno): " ENUM_HOSTS
            if [[ $ENUM_HOSTS -gt 0 ]]; then
                for ((eh=1; eh<=ENUM_HOSTS; eh++))
                do
                    echo "--- HOST $eh ($EDOM) ---"
                    read -p "Hostname (sin dominio): " EH_NAME
                    read -p "Alias CNAME (deja vacío si no tiene): " EH_ALIAS
                    read -p "IP completa del host: " EH_IP
                    
                    echo "$EH_NAME IN A $EH_IP" >> "$EDIRECTO"
                    if [[ -n "$EH_ALIAS" ]]; then
                        echo "$EH_ALIAS IN CNAME $EH_NAME" >> "$EDIRECTO"
                    fi
                    
                    EOCT_H=$(echo $EH_IP | awk -F. '{print $4}')
                    read -p "¿Añadir PTR a la inversa para $EH_NAME? (s/n): " EADD_PTR
                    if [[ "$EADD_PTR" == "s" || "$EADD_PTR" == "S" ]]; then
                        echo "$EOCT_H IN PTR $EH_NAME.$EDOM." >> "$EINVERSO"
                    fi
                done
            fi
        done
    fi

    # ========================================================
    # PREGUNTAR POR OTRA RED / ZONA PRINCIPAL
    # ========================================================
    echo
    echo "=========================================================="
    read -p "¿Deseas configurar OTRA Zona Principal en una red distinta? (s/n): " OTRA_RED
    if [[ "$OTRA_RED" != "s" && "$OTRA_RED" != "S" ]]; then
        break
    fi
    ((ZONA_NUM++))
done

# ========================================================
# CREAR INSTALADOR (SOLO PARA EL MAESTRO)
# ========================================================
cat > "$INSTALL_SCRIPT" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")" || exit 1

if [ "$EUID" -ne 0 ]; then
  echo "ERROR: Ejecuta con sudo ./instalar_master.sh"
  exit 1
fi

echo "0. Limpiando caracteres CRLF..."
sed -i 's/\r//g' named.conf.local.master named.conf.local.slave 2>/dev/null || true

echo "1. Configurando el Servidor DNS Maestro..."
mkdir -p /etc/bind/zonas
cp named.conf.local.master /etc/bind/named.conf.local
cp zonas/* /etc/bind/zonas/ 2>/dev/null || true

echo "2. Ajustando Permisos..."
chown -R bind:bind /etc/bind/zonas
chmod -R 775 /etc/bind/zonas

echo "3. Reiniciando BIND9..."
systemctl restart bind9

echo "------------------------------------------------"
systemctl status bind9 --no-pager | grep Active
echo "------------------------------------------------"
EOF
chmod +x "$INSTALL_SCRIPT"

clear
echo "=========================================================="
echo "    SCRIPT DE DNS MAESTRO GENERADO CON ÉXITO"
echo "=========================================================="
echo "ARCHIVOS GENERADOS EN: $DIR/"
echo "Para instalar en ESTA máquina ejecuta:"
echo "  cd $DIR && sudo ./instalar_master.sh"
echo ""
echo "Si configuraste un esclavo LINUX, llévate el archivo:"
echo "  $DIR/named.conf.local.slave"
echo "al servidor Esclavo e inclúyelo en su configuración."
echo "=========================================================="