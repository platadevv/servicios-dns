#!/bin/bash

clear

CONFIG="named.conf.local"
CONFIG_SLAVE="named.conf.local.slave"

mkdir -p zonas

echo "" > $CONFIG
echo "" > $CONFIG_SLAVE

echo "=========================================="
echo "     GENERADOR COMPLETO DNS BIND9"
echo "=========================================="

read -p "Numero de dominios: " NUM_DOM

for ((d=1; d<=NUM_DOM; d++))
do

    echo
    echo "=========== DOMINIO PRINCIPAL $d ==========="

    read -p "Dominio principal (ej: dominio.org): " DOM
    read -p "Red dominio principal (ej: 2.4.6): " RED
    read -p "Mascara CIDR (ej: 24): " MASK

    #################################################
    # MASTER DNS
    #################################################

    echo
    echo "===== MASTER DNS ====="

    read -p "Hostname master DNS: " HOST_MASTER
    read -p "Alias master DNS: " ALIAS_MASTER
    read -p "IP master DNS: " IP_MASTER

    #################################################
    # SLAVE DNS PRINCIPAL
    #################################################

    echo
    echo "===== SLAVE DNS DOMINIO PRINCIPAL ====="

    read -p "Hostname slave DNS: " HOST_SLAVE
    read -p "Alias slave DNS: " ALIAS_SLAVE
    read -p "IP slave DNS en red principal: " IP_SLAVE_MAIN

    #################################################
    # ADMIN
    #################################################

    read -p "Correo administrador (ej: master.gmail.com): " ADMIN

    INVERSA=$(echo $RED | awk -F. '{print $3"."$2"."$1}')

    #################################################
    # named.conf.local MASTER
    #################################################

    cat >> $CONFIG <<EOF

//////////////////////////////////////////////////
// DOMINIO $DOM
//////////////////////////////////////////////////

zone "$DOM"
{
    type master;
    file "/etc/bind/zonas/db.$DOM";
    allow-query { 127.0.0.1; $RED.0/$MASK; };
    allow-transfer { $IP_SLAVE_MAIN; };
    also-notify { $IP_SLAVE_MAIN; };
};

zone "$INVERSA.in-addr.arpa"
{
    type master;
    file "/etc/bind/zonas/db.$RED";
    allow-query { 127.0.0.1; $RED.0/$MASK; };
    allow-transfer { $IP_SLAVE_MAIN; };
    also-notify { $IP_SLAVE_MAIN; };
};

EOF

    #################################################
    # named.conf.local SLAVE
    #################################################

    cat >> $CONFIG_SLAVE <<EOF

//////////////////////////////////////////////////
// DOMINIO $DOM
//////////////////////////////////////////////////

zone "$DOM"
{
    type slave;
    file "/etc/bind/zonas/db.$DOM";
    masters {$IP_MASTER;};
    allow-query { 127.0.0.1; $RED.0/$MASK; };
};

zone "$INVERSA.in-addr.arpa"
{
    type slave;
    file "/etc/bind/zonas/db.$RED";
    masters {$IP_MASTER;};
    allow-query { 127.0.0.1; $RED.0/$MASK; };
};

EOF

    #################################################
    # FICHERO DIRECTO DOMINIO PRINCIPAL
    #################################################

    DIRECTO="zonas/db.$DOM"

    cat > $DIRECTO <<EOF
\$TTL 604800

@   IN  SOA $DOM. $ADMIN. (
            1
            604800
            86400
            2419200
            604800 )

@   IN  NS  $HOST_SLAVE.$DOM.

$HOST_MASTER   IN  A   $IP_MASTER
$ALIAS_MASTER  IN  CNAME $HOST_MASTER

$HOST_SLAVE    IN  A   $IP_SLAVE_MAIN
$ALIAS_SLAVE   IN  CNAME $HOST_SLAVE

EOF

    #################################################
    # HOSTS DOMINIO PRINCIPAL
    #################################################

    read -p "Numero de hosts del dominio principal: " NUM_HOSTS

    declare -a HOSTNAMES
    declare -a HOSTIPS

    for ((h=1; h<=NUM_HOSTS; h++))
    do

        echo
        echo "=========== HOST $h ==========="

        read -p "Hostname: " HOST
        read -p "Alias: " ALIAS
        read -p "IP host completa: " IPHOST

        HOSTNAMES[$h]=$HOST
        HOSTIPS[$h]=$IPHOST

        echo "$HOST IN A $IPHOST" >> $DIRECTO
        echo "$ALIAS IN CNAME $HOST" >> $DIRECTO

    done

    #################################################
    # FICHERO INVERSO DOMINIO PRINCIPAL
    #################################################

    INVERSO="zonas/db.$RED"

    cat > $INVERSO <<EOF
\$TTL 604800

@   IN  SOA $INVERSA.in-addr.arpa. $ADMIN. (
            1
            604800
            86400
            2419200
            604800 )

@   IN  NS  $HOST_SLAVE.$DOM.

EOF

    #################################################
    # PTR MASTER
    #################################################

    OCT_MASTER=$(echo $IP_MASTER | awk -F. '{print $4}')

    echo "$OCT_MASTER IN PTR $HOST_MASTER.$DOM." >> $INVERSO

    #################################################
    # PTR SLAVE
    #################################################

    OCT_SLAVE=$(echo $IP_SLAVE_MAIN | awk -F. '{print $4}')

    echo "$OCT_SLAVE IN PTR $HOST_SLAVE.$DOM." >> $INVERSO

    #################################################
    # PTR HOSTS
    #################################################

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
            echo "$OCTETO IN PTR $HOST.$DOM." >> $INVERSO
        fi

    done

    #################################################
    # SUBDOMINIOS
    #################################################

    read -p "Numero de subdominios: " NUM_SUB

    for ((s=1; s<=NUM_SUB; s++))
    do

        echo
        echo "=========== SUBDOMINIO $s ==========="

        read -p "Nombre subdominio: " SUB
        read -p "Red subdominio (ej: 1.3.5): " REDSUB
        read -p "Mascara subdominio: " MASKSUB

        #################################################
        # IP DEL SLAVE EN ESTA RED
        #################################################

        read -p "IP del slave DNS en esta red: " IP_SLAVE_SUB

        INV_SUB=$(echo $REDSUB | awk -F. '{print $3"."$2"."$1}')

        #################################################
        # named.conf.local MASTER SUBDOMINIO
        #################################################

        cat >> $CONFIG <<EOF

zone "$SUB.$DOM"
{
    type master;
    file "/etc/bind/zonas/db.$SUB.$DOM";
    allow-query { 127.0.0.1; $REDSUB.0/$MASKSUB; };
    allow-transfer { $IP_SLAVE_MAIN; };
    also-notify { $IP_SLAVE_MAIN; };
};

zone "$INV_SUB.in-addr.arpa"
{
    type master;
    file "/etc/bind/zonas/db.$REDSUB";
    allow-query { 127.0.0.1; $REDSUB.0/$MASKSUB; };
    allow-transfer { $IP_SLAVE_MAIN; };
    also-notify { $IP_SLAVE_MAIN; };
};

EOF

        #################################################
        # named.conf.local SLAVE SUBDOMINIO
        #################################################

        cat >> $CONFIG_SLAVE <<EOF

//////////////////////////////////////////////////
// SUBDOMINIO $SUB.$DOM
//////////////////////////////////////////////////

zone "$SUB.$DOM"
{
    type slave;
    file "/etc/bind/zonas/db.$SUB.$DOM";
    masters {$IP_MASTER;};
    allow-query { 127.0.0.1; $REDSUB.0/$MASKSUB; };
};

zone "$INV_SUB.in-addr.arpa"
{
    type slave;
    file "/etc/bind/zonas/db.$REDSUB";
    masters {$IP_MASTER;};
    allow-query { 127.0.0.1; $REDSUB.0/$MASKSUB; };
};

EOF

        #################################################
        # FICHERO DIRECTO SUBDOMINIO
        #################################################

        DIRECT_SUB="zonas/db.$SUB.$DOM"

        cat > $DIRECT_SUB <<EOF
\$TTL 604800

@   IN  SOA $SUB.$DOM. $ADMIN. (
            1
            604800
            86400
            2419200
            604800 )

@   IN  NS  $HOST_SLAVE.$SUB.$DOM.

$HOST_SLAVE    IN  A   $IP_SLAVE_SUB
$ALIAS_SLAVE   IN  CNAME $HOST_SLAVE

EOF

        #################################################
        # HOSTS SUBDOMINIO
        #################################################

        read -p "Numero de hosts del subdominio: " NUM_HOST_SUB

        declare -a SUBHOSTNAMES
        declare -a SUBHOSTIPS

        for ((hs=1; hs<=NUM_HOST_SUB; hs++))
        do

            echo
            echo "=========== HOST SUBDOMINIO $hs ==========="

            read -p "Hostname: " HOSTSUB
            read -p "Alias: " ALIASSUB
            read -p "IP host completa: " IPHOSTSUB

            SUBHOSTNAMES[$hs]=$HOSTSUB
            SUBHOSTIPS[$hs]=$IPHOSTSUB

            echo "$HOSTSUB IN A $IPHOSTSUB" >> $DIRECT_SUB
            echo "$ALIASSUB IN CNAME $HOSTSUB" >> $DIRECT_SUB

        done

        #################################################
        # FICHERO INVERSO SUBDOMINIO
        #################################################

        INV_SUB_FILE="zonas/db.$REDSUB"

        cat > $INV_SUB_FILE <<EOF
\$TTL 604800

@   IN  SOA $INV_SUB.in-addr.arpa. $ADMIN. (
            1
            604800
            86400
            2419200
            604800 )

@   IN  NS  $HOST_SLAVE.$SUB.$DOM.

EOF

        #################################################
        # PTR SLAVE SUBDOMINIO
        #################################################

        OCT_SLAVE_SUB=$(echo $IP_SLAVE_SUB | awk -F. '{print $4}')

        echo "$OCT_SLAVE_SUB IN PTR $HOST_SLAVE.$SUB.$DOM." >> $INV_SUB_FILE

        #################################################
        # PTR HOSTS SUBDOMINIO
        #################################################

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
                echo "$OCTETO IN PTR $HOST.$SUB.$DOM." >> $INV_SUB_FILE
            fi

        done

    done

done

echo
echo "=========================================="
echo " CONFIGURACION GENERADA CORRECTAMENTE"
echo "=========================================="
echo
echo "Ficheros generados:"
echo
echo " - named.conf.local"
echo " - named.conf.local.slave"
echo " - carpeta zonas/"
echo
echo "Copiar MASTER:"
echo
echo "sudo mkdir -p /etc/bind/zonas"
echo "sudo cp named.conf.local /etc/bind/"
echo "sudo cp zonas/* /etc/bind/zonas/"
echo
echo "Copiar SLAVE:"
echo
echo "sudo cp named.conf.local.slave /etc/bind/named.conf.local"
echo
echo "Verificar:"
echo
echo "sudo named-checkconf"
echo "sudo systemctl restart bind9"
