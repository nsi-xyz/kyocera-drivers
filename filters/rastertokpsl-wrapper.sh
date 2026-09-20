#!/bin/sh
# Wrapper pour le filtre proprietaire Kyocera rastertokpsl (Debian 13).
#
# Le binaire original (/usr/lib/cups/filter/rastertokpsl.bin) recopie le titre
# du job (et le nom d'utilisateur) dans un petit buffer de pile. Des que le
# titre depasse ~36 octets, il ecrase des variables adjacentes et meurt
# (SIGBUS/SIGABRT : "Bus error", "buffer overflow", "malloc(): corrupted
# top size"), ce qui fait echouer le job CUPS.
#
# On tronque donc titre et utilisateur a 28 octets max, sur une frontiere
# UTF-8 valide, avant d'appeler le binaire reel.
orig="/usr/lib/cups/filter/rastertokpsl.bin"
max=28

trunc() {
    printf '%s' "$1" | head -c "$max" | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null
}

if [ "$#" -ge 3 ]; then
    jobid="$1"
    user="$2"
    title="$3"
    shift 3
    title=$(trunc "$title"); [ -z "$title" ] && title="job"
    user=$(trunc "$user");   [ -z "$user" ]  && user="user"
    exec "$orig" "$jobid" "$user" "$title" "$@"
fi

exec "$orig" "$@"
