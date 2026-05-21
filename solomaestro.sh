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
echo "      GENERADOR BIND9 - MODO MAESTRO PURO (FORMATO EXACTO)"
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
        read -p "Nombre del Dominio (ej: nombre.com): " DOM
        read -p "Red de este dominio (SOLO 3 OCTETOS, ej: 10.12.14): " RED
        read -p "Hostname de ESTE servidor Maestro (ej: ubuntu): " HOST_MASTER
        read -p "IP de ESTE servidor Maestro: " IP_MASTER
        read -p "Correo del Administrador (ej: maaster.gmail.com.): " ADMIN
        
        INV_RED=$(echo $RED | awk -F. '{print $3"."$2"."$1}')
        
        read -p "¿Esta zona principal se va a transferir a un servidor Esclavo? (s/n): " TRANSF_PRINCIPAL
        
        if [[ "$TRANSF_PRINCIPAL" == "s" || "$TRANSF_PRINCIPAL" == "S" ]]; then
            read -p "¿El servidor Esclavo es Windows o Linux? (w/l): " OS_ESCLAVO
            read -p "Hostname del Esclavo (ej: windows): " HOST_SLAVE
            read -p "IP del servidor Esclavo: " IP_SLAVE
            
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
            if [[ "$OS_ESCLAVO" == "l" || "$OS_ESCLAVO" == "L" ]]; then
                cat >> "$CONFIG_SLAVE" <<EOF

// ZONA ESCLAVA: $DOM
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
            cat >> "$CONFIG" <<EOF

// ZONA PRINCIPAL: $DOM (AISLADA)
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

        # ========================================================
        # ESTRUCTURA EXACTA: FICHERO DIRECTO
        # ========================================================
        DIRECTO="$DIR/zonas/db.$DOM"
        INVERSO="$DIR/zonas/db.$RED"

        cat > "$DIRECTO" <<EOF
\$TTL 604800
@   IN   SOA   $HOST_MASTER.$DOM. $ADMIN (
                  2          ; Serial
             604800          ; Refresh
              86400          ; Retry
            2419200          ; Expire
             604800 )        ; Negative Cache TTL

; --- SERVIDORES NAMESERVERS (NS) ---
@   IN   NS   $HOST_MASTER.$DOM.
EOF
        if [[ "$TRANSF_PRINCIPAL" == "s" || "$TRANSF_PRINCIPAL" == "S" ]]; then
            echo "@   IN   NS   $HOST_SLAVE.$DOM." >> "$DIRECTO"
        fi

        cat >> "$DIRECTO" <<EOF

; --- REGISTROS IP DE LOS NAMESERVERS ---
$HOST_MASTER   IN   A   $IP_MASTER
EOF
        if [[ "$TRANSF_PRINCIPAL" == "s" || "$TRANSF_PRINCIPAL" == "S" ]]; then
            echo "$HOST_SLAVE   IN   A   $IP_SLAVE" >> "$DIRECTO"
        fi
        
        echo "" >> "$DIRECTO"
        echo "; --- OTROS HOSTS DE LA RED ---" >> "$DIRECTO"

        # ========================================================
        # ESTRUCTURA EXACTA: FICHERO INVERSO
        # ========================================================
        cat > "$INVERSO" <<EOF
\$TTL 604800
@   IN   SOA   $HOST_MASTER.$DOM. $ADMIN (
                  2          ; Serial
             604800          ; Refresh
              86400          ; Retry
            2419200          ; Expire
             604800 )        ; Negative Cache TTL

; --- SERVIDORES NAMESERVERS (NS) ---
@   IN   NS   $HOST_MASTER.$DOM.
EOF
        if [[ "$TRANSF_PRINCIPAL" == "s" || "$TRANSF_PRINCIPAL" == "S" ]]; then
            echo "@   IN   NS   $HOST_SLAVE.$DOM." >> "$INVERSO"
        fi

        cat >> "$INVERSO" <<EOF

; --- REGISTROS INVERSOS (PTR) ---
EOF
        OCT_MASTER=$(echo $IP_MASTER | awk -F. '{print $4}')
        echo "$OCT_MASTER   IN   PTR   $HOST_MASTER.$DOM." >> "$INVERSO"
        
        if [[ "$TRANSF_PRINCIPAL" == "s" || "$TRANSF_PRINCIPAL" == "S" ]]; then
            OCT_SLAVE=$(echo $IP_SLAVE | awk -F. '{print $4}')
            echo "$OCT_SLAVE   IN   PTR   $HOST_SLAVE.$DOM." >> "$INVERSO"
        fi

        # ========================================================
        # AÑADIR HOSTS A LA ESTRUCTURA
        # ========================================================
        echo
        read -p "¿Cuántos hosts extra vas a configurar en $DOM? (0 si ninguno): " NUM_HOSTS
        if [[ $NUM_HOSTS -gt 0 ]]; then
            for ((h=1; h<=NUM_HOSTS; h++))
            do
                echo "--- HOST $h ($DOM) ---"
                read -p "Hostname (sin dominio, ej: windows10): " H_NAME
                read -p "Alias CNAME (deja vacío si no tiene): " H_ALIAS
                read -p "IP completa del host: " H_IP
                
                echo "$H_NAME   IN   A   $H_IP" >> "$DIRECTO"
                if [[ -n "$H_ALIAS" ]]; then
                    echo "$H_ALIAS   IN   CNAME   $H_NAME" >> "$DIRECTO"
                fi
                
                OCT_H=$(echo $H_IP | awk -F. '{print $4}')
                read -p "¿Añadir PTR a la inversa para $H_NAME? (s/n): " ADD_PTR
                if [[ "$ADD_PTR" == "s" || "$ADD_PTR" == "S" ]]; then
                    echo "$OCT_H   IN   PTR   $H_NAME.$DOM." >> "$INVERSO"
                fi
            done
        fi
    fi

    # ========================================================
    # DOMINIOS/ZONAS EXTRA PARA TRANSFERIR
    # ========================================================
    echo
    echo "--- OTROS DOMINIOS / SUBDOMINIOS A TRANSFERIR ---"
    read -p "¿Cuántas zonas extra vas a crear y transferir? (0 si ninguna): " NUM_EXTRA
    
    if [[ $NUM_EXTRA -gt 0 ]]; then
        for ((e=1; e<=NUM_EXTRA; e++))
        do
            echo
            echo "=== ZONA EXTRA $e ==="
            read -p "Nombre COMPLETO del dominio (ej: sub.nombre.com): " EDOM
            read -p "Red de este dominio (SOLO 3 OCTETOS, ej: 10.0.0): " ERED
            read -p "Hostname de ESTE Maestro para esta zona (ej: ubuntu): " EHOST_MASTER
            read -p "IP de ESTE servidor Maestro: " EIP_MASTER
            read -p "¿Esclavo de destino es Windows o Linux? (w/l): " EOS_ESCLAVO
            read -p "Hostname del Esclavo destino (ej: windows): " EHOST_SLAVE
            read -p "IP del Esclavo destino: " EIP_SLAVE
            read -p "Correo del Administrador: " EADMIN
            
            EINV_RED=$(echo $ERED | awk -F. '{print $3"."$2"."$1}')

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
            if [[ "$EOS_ESCLAVO" == "l" || "$EOS_ESCLAVO" == "L" ]]; then
                cat >> "$CONFIG_SLAVE" <<EOF

// ZONA ESCLAVA EXTRA: $EDOM
zone "$EDOM" {
    type slave;
    file "/var/cache/bind/db.$EDOM";
    masters { $EIP_MASTER; };
    allow-query { any; };
};

zone "$EINV_RED.in-addr.arpa" {
    type slave;
    file "/var/cache/bind/db.$ERED";
    masters { $EIP_MASTER; };
    allow-query { any; };
};
EOF
            fi

            EDIRECTO="$DIR/zonas/db.$EDOM"
            EINVERSO="$DIR/zonas/db.$ERED"

            # ========================================================
            # ESTRUCTURA EXACTA PARA ZONAS EXTRA
            # ========================================================
            cat > "$EDIRECTO" <<EOF
\$TTL 604800
@   IN   SOA   $EHOST_MASTER.$EDOM. $EADMIN (
                  2          ; Serial
             604800          ; Refresh
              86400          ; Retry
            2419200          ; Expire
             604800 )        ; Negative Cache TTL

; --- SERVIDORES NAMESERVERS (NS) ---
@   IN   NS   $EHOST_MASTER.$EDOM.
@   IN   NS   $EHOST_SLAVE.$EDOM.

; --- REGISTROS IP DE LOS NAMESERVERS ---
$EHOST_MASTER   IN   A   $EIP_MASTER
$EHOST_SLAVE   IN   A   $EIP_SLAVE

; --- OTROS HOSTS DE LA RED ---
EOF

            cat > "$EINVERSO" <<EOF
\$TTL 604800
@   IN   SOA   $EHOST_MASTER.$EDOM. $EADMIN (
                  2          ; Serial
             604800          ; Refresh
              86400          ; Retry
            2419200          ; Expire
             604800 )        ; Negative Cache TTL

; --- SERVIDORES NAMESERVERS (NS) ---
@   IN   NS   $EHOST_MASTER.$EDOM.
@   IN   NS   $EHOST_SLAVE.$EDOM.

; --- REGISTROS INVERSOS (PTR) ---
EOF
            EOCT_MASTER=$(echo $EIP_MASTER | awk -F. '{print $4}')
            echo "$EOCT_MASTER   IN   PTR   $EHOST_MASTER.$EDOM." >> "$EINVERSO"
            
            EOCT_SLAVE=$(echo $EIP_SLAVE | awk -F. '{print $4}')
            echo "$EOCT_SLAVE   IN   PTR   $EHOST_SLAVE.$EDOM." >> "$EINVERSO"
            
            echo
            read -p "¿Cuántos hosts vas a crear en $EDOM? (0 si ninguno): " ENUM_HOSTS
            if [[ $ENUM_HOSTS -gt 0 ]]; then
                for ((eh=1; eh<=ENUM_HOSTS; eh++))
                do
                    echo "--- HOST $eh ($EDOM) ---"
                    read -p "Hostname (sin dominio): " EH_NAME
                    read -p "Alias CNAME (deja vacío si no tiene): " EH_ALIAS
                    read -p "IP completa del host: " EH_IP
                    
                    echo "$EH_NAME   IN   A   $EH_IP" >> "$EDIRECTO"
                    if [[ -n "$EH_ALIAS" ]]; then
                        echo "$EH_ALIAS   IN   CNAME   $EH_NAME" >> "$EDIRECTO"
                    fi
                    
                    EOCT_H=$(echo $EH_IP | awk -F. '{print $4}')
                    read -p "¿Añadir PTR a la inversa para $EH_NAME? (s/n): " EADD_PTR
                    if [[ "$EADD_PTR" == "s" || "$EADD_PTR" == "S" ]]; then
                        echo "$EOCT_H   IN   PTR   $EH_NAME.$EDOM." >> "$EINVERSO"
                    fi
                done
            fi
        done
    fi

    echo
    echo "=========================================================="
    read -p "¿Deseas configurar OTRA Zona Principal en una red distinta? (s/n): " OTRA_RED
    if [[ "$OTRA_RED" != "s" && "$OTRA_RED" != "S" ]]; then
        break
    fi
    ((ZONA_NUM++))
done

# ========================================================
# CREAR INSTALADOR 
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
echo "   SCRIPT DE DNS MAESTRO (ESTRUCTURA EXACTA) GENERADO"
echo "=========================================================="
echo "ARCHIVOS GENERADOS EN: $DIR/"
echo "Para instalar en ESTA máquina ejecuta:"
echo "  cd $DIR && sudo ./instalar_master.sh"
echo "=========================================================="