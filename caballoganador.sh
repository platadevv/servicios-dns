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

d=1

while true; do

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

    read -p "Hostname master DNS (ej: serverdns1): " HOST_MASTER
    read -p "Alias master DNS (ej: masterdns): " ALIAS_MASTER
    read -p "IP master DNS: " IP_MASTER

    #################################################
    # SLAVE DNS PRINCIPAL
    #################################################

    echo
    echo "===== SLAVE DNS DOMINIO PRINCIPAL ====="

    read -p "Hostname slave DNS (ej: serverdns2): " HOST_SLAVE
    read -p "Alias slave DNS (ej: slavedns): " ALIAS_SLAVE
    read -p "IP slave DNS en red principal: " IP_SLAVE_MAIN

    #################################################
    # ADMIN
    #################################################
    echo
    echo "ATENCION: El correo debe llevar un punto en vez de @ y terminar en punto."
    read -p "Correo administrador (ej: master.gmail.com.): " ADMIN

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

    #################################################
    # FICHERO DIRECTO DOMINIO PRINCIPAL
    #################################################

    DIRECTO="zonas/db.$DOM"

    cat > $DIRECTO <<EOF
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

    #################################################
    # HOSTS DOMINIO PRINCIPAL
    #################################################
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

            echo "$HOST IN A $IPHOST" >> $DIRECTO
            if [[ -n "$ALIAS" ]]; then
                echo "$ALIAS IN CNAME $HOST" >> $DIRECTO
            fi
        done
    fi

    #################################################
    # FICHERO INVERSO DOMINIO PRINCIPAL
    #################################################

    INVERSO="zonas/db.$RED"

    cat > $INVERSO <<EOF
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

    #################################################
    # PTR MASTER Y SLAVE
    #################################################

    OCT_MASTER=$(echo $IP_MASTER | awk -F. '{print $4}')
    echo "$OCT_MASTER IN PTR $HOST_MASTER.$DOM." >> $INVERSO

    OCT_SLAVE=$(echo $IP_SLAVE_MAIN | awk -F. '{print $4}')
    echo "$OCT_SLAVE IN PTR $HOST_SLAVE.$DOM." >> $INVERSO

    #################################################
    # PTR HOSTS
    #################################################

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
                echo "$OCTETO IN PTR $HOST.$DOM." >> $INVERSO
            fi
        done
    fi

    #################################################
    # SUBDOMINIOS
    #################################################
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

            #################################################
            # named.conf.local MASTER SUBDOMINIO
            #################################################

            cat >> $CONFIG <<EOF

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

            #################################################
            # FICHERO DIRECTO SUBDOMINIO
            #################################################

            DIRECT_SUB="zonas/db.$SUB.$DOM"

            cat > $DIRECT_SUB <<EOF
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

            #################################################
            # HOSTS SUBDOMINIO
            #################################################

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

                    echo "$HOSTSUB IN A $IPHOSTSUB" >> $DIRECT_SUB
                    if [[ -n "$ALIASSUB" ]]; then
                        echo "$ALIASSUB IN CNAME $HOSTSUB" >> $DIRECT_SUB
                    fi
                done
            fi

            #################################################
            # FICHERO INVERSO SUBDOMINIO
            #################################################

            INV_SUB_FILE="zonas/db.$REDSUB"

            cat > $INV_SUB_FILE <<EOF
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
            echo "$OCT_SLAVE_SUB IN PTR $HOST_SLAVE.$DOM." >> $INV_SUB_FILE

            #################################################
            # PTR HOSTS SUBDOMINIO
            #################################################

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
                        echo "$OCTETO IN PTR $HOST.$SUB.$DOM." >> $INV_SUB_FILE
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

echo
echo "=========================================="
echo " CONFIGURACION GENERADA CORRECTAMENTE"
echo "=========================================="
echo "Ficheros listos para copiar."