# Kyocera FS-1220MFP sur Debian 13 (trixie)

Notes de remise en route et de développement d'un pilote libre.

Imprimante : **Kyocera FS-1220MFP** (Ecosys), laser monochrome multifonction.
Langage : **KPSL / GDI** (« host-based ») — l'imprimante ne comprend ni PCL ni
PostScript, il faut lui envoyer un flux KPSL généré sur l'hôte par le filtre
`rastertokpsl`.

Machine : Debian GNU/Linux 13 (trixie), CUPS 2.4.10, connexion USB
(`usb://Kyocera/FS-1220MFP?serial=LBW6Y04191`, ID USB `0482:04fd`).

---

## 1. Problème n°1 — plus rien ne s'imprime (dépendance manquante)

### Symptôme

La file CUPS `Kyocera_FS-1220MFP` existe et accepte les jobs, mais chaque
impression échoue. Le filtre ne démarre même pas.

### Diagnostic

```console
$ ldd /usr/lib/cups/filter/rastertokpsl
    libcupsimage.so.2 => not found
$ /usr/lib/cups/filter/rastertokpsl
/usr/lib/cups/filter/rastertokpsl: error while loading shared libraries:
libcupsimage.so.2: cannot open shared object file: No such file or directory
```

La bibliothèque `libcupsimage.so.2` n'était pas installée. Avec la transition
`time_t` 64 bits de Debian 13, le paquet a été renommé `libcupsimage2` →
**`libcupsimage2t64`**. L'ancien nom n'existe plus, donc la dépendance du
filtre Kyocera n'était plus satisfaite.

### Correctif

```sh
sudo apt install libcupsimage2t64
```

Vérification :

```console
$ ldd /usr/lib/cups/filter/rastertokpsl | grep cupsimage
    libcupsimage.so.2 => /lib/x86_64-linux-gnu/libcupsimage.so.2
```

Après ça, une page de test simple s'imprime.

---

## 2. Problème n°2 — les impressions « réelles » échouent (`Filter failed`)

### Symptôme

Une page de test courte passe, mais une impression lancée depuis une
application échoue : job bloqué, puis

```
Status: Filter failed
Alerts: cups-filter-crashed
```

dans `/var/log/cups/error_log` :

```
[Job 828] PID ... (/usr/lib/cups/filter/rastertokpsl) crashed on signal 6.
**** Error: Page drawing error occurred.
```

et parfois `signal 7 (SIGBUS)`.

### Diagnostic

Le filtre **plante selon la longueur du titre du job**. Reproduction hors CUPS,
en tant qu'utilisateur `lp` (l'utilisateur des filtres CUPS) :

```console
$ /usr/lib/cups/filter/rastertokpsl.bin 1 cent20 "$TITRE" 1 "$OPTIONS" test.rast
```

| Longueur du titre (octets) | Résultat |
|---|---|
| 4 (`test`) | OK |
| 8 à 36 | OK |
| 37 | crash `SIGBUS` |
| 60 | crash |
| 64 (en root/uid 1000) | crash `SIGABRT` — `*** buffer overflow detected ***` |

Le seuil est **identique en ASCII et en accentué** : 36 octets OK, 37 plante.
Preuve avec un titre composé uniquement d'accents (`é`, 2 octets/char) :

```
accents: 36 octets -> ok=3/3
accents: 37 octets -> ok=0/3
```

Le backtrace gdb du core dump (via `coredumpctl` / `systemd-coredump`) montre
la corruption :

```
#0  0x40c182  mov 0x0(%rbp,%rax,1),%rsi
#1  0x40c3be  cupsGetOption
#2  0x40752e
```

`rbp` (pointeur vers le tableau d'options) contient du texte UTF-16 au lieu
d'une adresse : le buffer de pile du **titre** déborde sur les variables
voisines. C'est donc un **débordement de buffer de pile** dans le binaire
propriétaire.

> Réponse à « buffer overflow ou accents ? » : **buffer overflow**, déclenché
> par la **longueur en octets** du titre. Les accents ne sont pas la cause ; ils
> consomment simplement 2 octets par caractère, donc le plafond est atteint avec
> moins de caractères visibles. (Le projet `rastertokpsl-re` mentionne en plus un
> bug distinct sur l'encodage non-ASCII des noms, mais notre crash est bien la
> longueur.)

### Correctif (pansement)

Le binaire est fermé et ne peut pas être corrigé proprement. On intercale un
**wrapper** `/usr/lib/cups/filter/rastertokpsl` (script shell) qui tronque titre
et nom d'utilisateur à **28 octets** (marge sous le seuil de 36) sur une
frontière UTF-8 valide, puis appelle le binaire réel conservé sous
`/usr/lib/cups/filter/rastertokpsl.bin`.

Wrapper installé :

```sh
#!/bin/sh
orig="/usr/lib/cups/filter/rastertokpsl.bin"
max=28
trunc() { printf '%s' "$1" | head -c "$max" | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null; }
if [ "$#" -ge 3 ]; then
    jobid="$1"; user="$2"; title="$3"; shift 3
    title=$(trunc "$title"); [ -z "$title" ] && title="job"
    user=$(trunc "$user");   [ -z "$user" ]  && user="user"
    exec "$orig" "$jobid" "$user" "$title" "$@"
fi
exec "$orig" "$@"
```

Ce correctif est **fragile** (band-aid) : il reste des bugs mémoire possibles
dans le binaire (une corruption de tas `malloc(): corrupted top size` a été
observée sur un raster). → voir la partie « Pilote libre » (§4).

### Restauration

```sh
sudo cp -a /usr/lib/cups/filter/rastertokpsl.bin /usr/lib/cups/filter/rastertokpsl
```

---

## 3. Mise en veille / hibernation

Le problème de veille est **indépendant** des correctifs ci-dessus.

État matériel constaté :
- autosuspend USB de l'imprimante : déjà désactivé (`power/control=on`) ;
- l'imprimante **ne supporte pas le remote wakeup** (elle ne peut pas réveiller
  le PC).

Un **hook de reprise** ré-énumère l'imprimante USB après un réveil :

- `/usr/local/sbin/kyocera-usb-reset.sh` : bascule `authorized` à 0 puis 1 sur le
  périphérique USB Kyocera (ID vendeur `0482`) pour forcer une ré-énumération ;
- `/usr/lib/systemd/system-sleep/kyocera-usb-reset` : l'appelle sur l'événement
  `post` (juste après le réveil).

Testé à la main : le noyau ré-autorise bien le périphérique. **À confirmer par
une vraie hibernation.**

---

## 4. Pilote libre — `rastertokpsl-re`

Le filtre propriétaire étant *memory-unsafe*, on utilise une réimplémentation
libre du filtre KPSL : **`rastertokpsl-re`** (licence Apache-2.0), qui lit le
même flux *CUPS raster* et produit du KPSL.

Dépôt : https://github.com/sv99/rastertokpsl-re (à cloner séparément, voir §4.3).

### 4.1 Dépendances de compilation

```sh
sudo apt install cmake libcups2-dev libcupsimage2-dev
```

### 4.2 Deux correctifs nécessaires (code de 2015)

Le projet ne compile pas tel quel sur Debian 13 / glibc 2.41. Deux patches
minimes ont été appliqués :

1. **`sigset` n'existe plus** (extension BSD retirée des en-têtes) — dans
   `src/rastertokpsl.c` :

   ```diff
   -        sigset(SIGTERM, CancelJob);
   +        signal(SIGTERM, CancelJob);
   ```

   2. **Lien manquant vers libm** (le code utilise `ceil`) — dans
   `src/CMakeLists.txt` :

   ```diff
   -target_link_libraries(rastertokpsl-re ${CUPS_LIB} ${CUPSIMAGE_LIB})
   +target_link_libraries(rastertokpsl-re ${CUPS_LIB} ${CUPSIMAGE_LIB} m)
   ```

Ces deux correctifs sont aussi regroupés dans le fichier
`rastertokpsl-re-debian13.patch` (à appliquer avec `git apply` depuis le dépôt).

### 4.3 Compilation

```sh
cd rastertokpsl-re
mkdir -p build && cd build
cmake ..
make rastertokpsl-re
# -> bin/rastertokpsl-re
```

### 4.4 Installation

```sh
# le filtre (depuis la racine du dépôt rastertokpsl-re)
sudo install -o root -g root -m 755 \
    rastertokpsl-re/bin/rastertokpsl-re \
    /usr/lib/cups/filter/rastertokpsl-re

# un PPD dérivé du PPD d'origine, pointant vers le filtre libre
# ppd/Kyocera_FS-1220MFPGDI_RE.ppd
#   *cupsFilter: "application/vnd.cups-raster 0 /usr/lib/cups/filter/rastertokpsl-re"

# une file de test
sudo lpadmin -p Kyocera_RE -E \
    -v 'usb://Kyocera/FS-1220MFP?serial=LBW6Y04191' \
    -P ppd/Kyocera_FS-1220MFPGDI_RE.ppd \
    -D 'Kyocera FS-1220MFP (RE libre)'
```

Un script tout-en-un est fourni : `scripts/install-rastertokpsl-re.sh`.

### 4.5 Validation

Comparaison de la sortie KPSL produite par le filtre d'origine
(`rastertokpsl.bin`) et par le filtre libre, sur les mêmes rasters
(outil `kpslcmp.pl`, qui ignore utilisateur/titre/timestamp) :

| Raster | Taille origine | Taille RE | Diff |
|---|---|---|---|
| page de test 1 page | 5196 o | 5196 o | identique sauf ~288 o en fin de flux |
| PDF Gmail 2 pages | 724116 o | 724116 o | identique sauf ~3,2 ko en fin de flux |

Les flux ont **exactement la même taille** et le même en-tête ; seule une
petite zone terminale (fin de trame / commande de fin de section) diffère.
En pratique le filtre libre **imprime correctement** (job `Kyocera_RE-831` sorti
sans erreur, y compris avec un titre de 79 caractères qui faisait planter le
filtre propriétaire).

### 4.6 Basculer la file principale sur le filtre libre

Une fois le rendu validé visuellement sur la file `Kyocera_RE`, on peut faire
pointer la file principale dessus :

```sh
sudo lpadmin -p Kyocera_FS-1220MFP \
    -P ppd/Kyocera_FS-1220MFPGDI_RE.ppd
```

Cela rend inutile le wrapper anti-débordement du §2 (on peut alors restaurer
`rastertokpsl` d'origine, ou le laisser en place sans conséquence).

> **Fait** : le 2026-09-20, la file `Kyocera_FS-1220MFP` a été basculée sur le
> filtre libre (`lpadmin -p Kyocera_FS-1220MFP -P .../Kyocera_FS-1220MFPGDI_RE.ppd`).
> Test final : job `Kyocera_FS-1220MFP-832` avec un titre de 79 caractères,
> terminé sans erreur. Le wrapper du §2 n'est plus sollicité (conservé comme
> garde-fou si l'on revient un jour au PPD d'origine).

---

## 5. Partage réseau — impression depuis un Chromebook

L'imprimante est GDI/KPSL : un Chromebook ne peut pas la piloter directement
(ChromeOS ne gère que l'IPP *driverless*). La solution : le Chromebook envoie
le job en IPP à CUPS sur cette machine, qui convertit en KPSL et imprime en USB.

### 5.1 Configuration CUPS

`/etc/cups/cupsd.conf` (sauvegarde : `/etc/cups/cupsd.conf.bak-2026-09-20`) :

- écoute réseau : `Listen 0.0.0.0:631` (au lieu de `Listen localhost:631`) ;
- accès local autorisé dans `<Location />` : `Allow @LOCAL` ;
- les files sont déjà `printer-is-shared=true`, `Browsing Yes`,
  `BrowseLocalProtocols dnssd` (avahi actif).

Note : CUPS ne peut pas empiler `Listen localhost:631` et
`Listen 0.0.0.0:631` (conflit `Address already in use` sur 127.0.0.1) ; on
remplace donc la ligne loopback par l'écoute globale.

Application :

```sh
sudo cp -a /etc/cups/cupsd.conf /etc/cups/cupsd.conf.bak
sudo install -o root -g root -m 644 cupsd.conf /etc/cups/cupsd.conf
sudo systemctl restart cups
```

Vérification :

```console
$ ss -ltnp | grep 631
LISTEN 0 4096 0.0.0.0:631 0.0.0.0:* users:(("cupsd",...))
```

### 5.2 Côté Chromebook

*Paramètres → Imprimantes → Ajouter une imprimante* (ajout manuel, adresse IPP) :

```
ipp://192.168.42.120:631/printers/Kyocera_FS-1220MFP
```

(ou `ipp://um560.local:631/printers/Kyocera_FS-1220MFP`). L'auto-découverte
mDNS/Avahi peut aussi proposer l'imprimante.

Test validé : job `Kyocera_FS-1220MFP-834` soumis en IPP via l'IP du LAN.
L'annonce mDNS/Avahi est active : l'imprimante apparaît comme
« Kyocera FS-1220MFP @ um560 » (TXT `pdl=...pdf,...urf`,
`mopria-certified=1.3`), donc l'auto-découverte Chromebook devrait aussi
fonctionner.

Un guide utilisateur (Chromebook / Windows / Android / iPhone-iPad) est fourni :
`Guide_impression_um560.html` et sa version imprimable
`Guide_impression_um560.pdf`.

### 5.3 Limites

- Cette machine doit être **allumée et éveillée** pour imprimer depuis le
  Chromebook (c'est elle le serveur ; l'imprimante est en USB dessus).
- IP fixe mise en place le 2026-09-20 : **`192.168.42.120`** (hors plage DHCP
  `.10`–`.109`). Configurée côté PC via NetworkManager (`ipv4.method manual`,
  MAC `58:47:ca:70:30:c8`) ; côté routeur Cudy, *Sécurité → Liaison IP/MAC*
  (ARP statique) `192.168.42.120 ↔ 58:47:CA:70:30:C8`. Côté Chromebook, on peut
  aussi utiliser `ipp://um560.local:631/printers/Kyocera_FS-1220MFP` (nom mDNS)
  pour ne pas dépendre de l'IP.
- CUPS est exposé au LAN (`Allow @LOCAL`) ; l'administration reste réservée au
  localhost.

Retour arrière éventuel :

```sh
sudo cp -a /etc/cups/cupsd.conf.bak-2026-09-20 /etc/cups/cupsd.conf
sudo systemctl restart cups
```

---

## 5b. Scanner (SANE)

Le scanner est la seconde interface USB du MFP (classe *vendor specific*),
indépendante de l'interface d'impression. SANE en amont ne fournit aucun backend
pour cet appareil. Kyocera propose un pilote SANE Linux (v2.2.1511) dont le
backend `kyocera` liste déjà l'USB ID `0x0482 0x04FD` (la FS-1220MFP).

Étapes (automatisées par
[`../scripts/install-kyocera-sane.sh`](../scripts/install-kyocera-sane.sh)) :

1. Télécharger le ZIP du pilote SANE chez Kyocera (voir [`../CREDITS.md`](../CREDITS.md))
   et installer `kyocera-sane_2.2.1511_amd64.deb`.
2. Le `.deb` dépend du nom de paquet `libsane`, qui n'existe plus sur les Debian
   modernes (la bibliothèque est dans `libsane1`). Installer un paquet factice
   `libsane` dépendant de `libsane1` maintient `apt` cohérent (préférable à
   `dpkg --force-depends`, qui casse `apt`).
3. Le pilote installe une règle udev accordant `MODE:="0666"` à presque tous les
   périphériques USB. La remplacer par
   [`../udev/40-scanner-permissions.rules`](../udev/40-scanner-permissions.rules)
   (vendeur Kyocera `0482` uniquement, groupe `scanner`), puis recharger udev.

Vérifié sur la machine de test :

```console
$ scanimage -L
device `kyocera:libusb:001:009' is a Kyocera FS-1220 multi-functional device
$ scanimage --resolution 200 --mode Gray -o scan.png   # OK (gris)
$ scanimage --resolution 200 --mode Color -o scan.pnm  # OK (couleur)
$ ls -l /dev/bus/usb/001/009
crw-rw---- 1 root scanner 189, 8 ... /dev/bus/usb/001/009
```

Remarque : le backend **arrondit** la résolution demandée (ex. 100/150 → 200 dpi).
Une interface graphique (`simple-scan`, `skanlite`, `xsane`, `gscan2pdf`)
fonctionne par-dessus.

La touche **[Numériser]** du panneau est une fonction *push* (« Numérisation
directe » / « Numérisation rapide ») qui nécessite le **Client Tool** de Kyocera
(Windows uniquement) ; elle ne fonctionne pas avec SANE, qui est *pull*. La
touche **[Copier]** du panneau, elle, fonctionne de façon autonome.

## 6. Récapitulatif des modifications système

| Élément | Action |
|---|---|
| `libcupsimage2t64` | installé (dépendance manquante) |
| `/usr/lib/cups/filter/rastertokpsl` | remplacé par le wrapper anti-dépassement |
| `/usr/lib/cups/filter/rastertokpsl.bin` | binaire Kyocera d'origine (sauvegarde) |
| `/usr/local/sbin/kyocera-usb-reset.sh` | reset USB à la reprise |
| `/usr/lib/systemd/system-sleep/kyocera-usb-reset` | hook systemd-sleep |
| `kyocera-sane` + factice `libsane` | pilote scanner et calage `apt` |
| `/etc/udev/rules.d/40-scanner-permissions.rules` | règle scanner resserrée (Kyocera) |
| `/usr/lib/cups/filter/rastertokpsl-re` | filtre KPSL libre (remplace le proprio) |
| `Kyocera_FS-1220MFP.ppd` | PPD `_RE` (filtre libre) — file principale |
| `Kyocera_RE` | file de test du filtre libre — **supprimée** après validation |
| `/etc/cups/cupsd.conf` | `Listen 0.0.0.0:631` + `Allow @LOCAL` (partage LAN) |
| `/etc/cups/cupsd.conf.bak-2026-09-20` | sauvegarde config CUPS d'origine |

File CUPS : `Kyocera_FS-1220MFP`, PPD
`Kyocera_FS-1220MFPGDI_RE.ppd` (dérivé du PPD d'origine, filtre libre), fourni
dans `ppd/`.
