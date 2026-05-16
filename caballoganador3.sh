#!/bin/bash

NAMED_CONF="/etc/bind/named.conf.local"

echo "========================================"
echo " Configuración DDNS BIND "
echo "========================================"
echo

read -rp "¿Va a dejar de ser maestro o esclavo? [s/n]: " RESPUESTA

case "$RESPUESTA" in

    s|S|si|SI|Si)

        read -rp "¿Cuál de los dos es? [maestro/esclavo]: " TIPO

        case "$TIPO" in

            maestro|Maestro)

                echo
                echo "Eliminando configuración de MAESTRO..."

                # Eliminar líneas existentes
                sed -i '/^[[:space:]]*allow-transfer/d' "$NAMED_CONF"
                sed -i '/^[[:space:]]*also-notify/d' "$NAMED_CONF"

                # Añadir nuevas líneas debajo de type master;
                sed -i '/type master;/a\
    allow-update { key "rndc-key"; };\
    notify yes;
' "$NAMED_CONF"

                echo "Configuración aplicada."
                ;;

            esclavo|Esclavo)

                echo
                echo "Eliminando configuración de ESCLAVO..."

                # Eliminar líneas masters
                sed -i '/^[[:space:]]*masters/d' "$NAMED_CONF"

                # Añadir nuevas líneas debajo de type slave;
                sed -i '/type slave;/a\
    allow-update { key "rndc-key"; };\
    notify yes;
' "$NAMED_CONF"

                echo "Configuración aplicada."
                ;;

            *)
                echo "Opción inválida."
                exit 1
                ;;
        esac
        ;;

    n|N|no|NO|No)

        echo
        echo "Añadiendo configuración DDNS..."

        # Añadir debajo de cada allow-query
        sed -i '/allow-query/a\
    allow-update { key "rndc-key"; };\
    notify yes;
' "$NAMED_CONF"

        echo "Configuración añadida."
        ;;

    *)

        echo "Opción inválida."
        exit 1
        ;;
esac

chmod -R 775 /etc/bind
chown -R bind:bind /etc/bind/zonas
