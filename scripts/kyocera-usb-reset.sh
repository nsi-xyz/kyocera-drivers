#!/bin/sh
# Re-enumere l'imprimante USB Kyocera pour qu'elle reponde de nouveau apres
# une reprise de veille/hibernation, ou apres son propre endormissement.
#
# Astuce : basculer l'attribut "authorized" du peripherique USB force le noyau
# a le deconnecter puis a le re-enumerer proprement, ce qui remet le lien USB
# (et l'endpoint d'impression) dans un etat sain.
VENDOR="0482"
logger -t kyocera-usb-reset -- "running"
found=0
for dev in /sys/bus/usb/devices/*; do
    [ -f "$dev/idVendor" ] || continue
    [ "$(cat "$dev/idVendor" 2>/dev/null)" = "$VENDOR" ] || continue
    case "$(basename "$dev")" in *:*) continue ;; esac
    found=1
    name=$(basename "$dev")
    if [ -w "$dev/authorized" ]; then
        echo 0 > "$dev/authorized" 2>/dev/null
        sleep 1
        echo 1 > "$dev/authorized" 2>/dev/null
        logger -t kyocera-usb-reset -- "re-enumerated USB device $name"
    else
        logger -t kyocera-usb-reset -- "no writable 'authorized' for $name"
    fi
done
[ "$found" = 1 ] || logger -t kyocera-usb-reset -- "no Kyocera USB device found"
exit 0
