#!/bin/bash

clear

CONFIG="named.conf.local"
RESOLV_FILE="resolv.conf.generado"

# Crear la carpeta donde BIND guardará las zonas que descargue de Windows
mkdir -p zonas

echo "" > $CONFIG

echo "=========================================================="
echo "   GENERADOR DNS BIND9 (ESCLAVO DE WINDOWS MAESTRO)"
echo "=========================================================="

# 1. DATOS DEL WINDOWS MAESTRO Y RED
read -p "IP del Windows Server (Maestro): " IP_WINDOWS
read -p "IP de este servidor Linux (Esclavo): " IP_LINUX

d=1
SEARCH_DOMS=""
PRIMARY_DOM=""

while true; do

    echo
    echo "=========== ZONA DIRECTA INTERNIZADA $d ==========="
    read -p "Nombre de la zona/dominio creado en Windows (ej: dominio.org): " DOM
    read -p "¿Tiene este dominio una zona inversa asociada en Windows? (s/n): " TIENE_INV

    # Guardar datos para el resolv.conf
    if [[ -z "$PRIMARY_DOM" ]]; then
        PRIMARY_DOM="$DOM"
    fi
    SEARCH_DOMS="$SEARCH_DOMS $DOM"

    #################################################
    # CONFIGURACIÓN DE ZONA DIRECTA EN LINUX
    #################################################
    # Nota: Usamos /var/cache/bind/ porque BIND necesita permisos de escritura
    # para guardar el archivo que le transfiere Windows.
    cat >> $CONFIG <<EOF

//////////////////////////////////////////////////
// ESCLAVO: $DOM
//////////////////////////////////////////////////
zone "$DOM"
{
    type slave;
    file "/var/cache/bind/db.$DOM";
    masters { $IP_WINDOWS; };
    allow-query { any; };
};
EOF

    #################################################
    # CONFIGURACIÓN DE ZONA INVERSA (SI EXISTE)
    #################################################
    if [[ "$TIENE_INV" == "s" || "$TIENE_INV" == "S" ]]; then
        echo
        read -p "Red de la zona inversa en formato BIND (ej: 6.4.2 para la red 2.4.6.0): " RED_INV
        
        cat >> $CONFIG <<EOF

zone "$RED_INV.in-addr.arpa"
{
    type slave;
    file "/var/cache/bind/db.$RED_INV";
    masters { $IP_WINDOWS; };
    allow-query { any; };
};
EOF
    fi

    echo
    echo "======================================================"
    read -p "¿Deseas añadir otra zona secundaria (Subdominio u otro)? (s/n): " RESP_DOM
    if [[ "$RESP_DOM" != "s" && "$RESP_DOM" != "S" ]]; then
        break
    fi

    ((d++))
done

#################################################
# GENERAR RESOLV.CONF OPTIMIZADO
#################################################
cat > $RESOLV_FILE <<EOF
domain $PRIMARY_DOM
search$SEARCH_DOMS
nameserver 127.0.0.1
nameserver $IP_WINDOWS
nameserver $IP_LINUX
EOF

echo
echo "=========================================================="
echo "       CONFIGURACIÓN PARA EL ESCLAVO GENERADA"
echo "=========================================================="
echo "Ficheros listos:"
echo " - named.conf.local"
echo " - resolv.conf.generado"
echo
echo "PASOS EN LINUX (ESCLAVO):"
echo " 1. sudo cp named.conf.local /etc/bind/"
echo " 2. sudo cp resolv.conf.generado /etc/resolv.conf"
echo " 3. sudo chattr +i /etc/resolv.conf"
echo " 4. sudo systemctl restart named"
echo