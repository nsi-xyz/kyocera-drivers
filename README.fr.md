# Kyocera FS-1220MFP sous Linux moderne — correctif du pilote et partage réseau

*Read this in [English](README.md).*

**Objectif :** faire réimprimer la **Kyocera FS-1220MFP** (une imprimante laser
« hôte » / GDI qui ne parle que le langage **KPSL** de Kyocera) sur un système
Linux moderne (testé sous **Debian 13 / trixie**, CUPS 2.4.10), et la partager
sur le réseau local pour que Chromebooks, PC Windows, Android et iPhone/iPad
puissent aussi imprimer.

> Ce dépôt **n'est pas affilié à Kyocera**. « Kyocera » et « ECOSYS » sont des
> marques de leurs propriétaires respectifs. Le pilote constructeur est ancien,
> fermé et non maintenu ; ce projet documente comment le faire revivre et
> comment remplacer sa partie défaillante par du logiciel libre.

---

## Ce qui était cassé (et pourquoi)

Deux problèmes indépendants, tous deux reproduits et diagnostiqués :

1. **Bibliothèque manquante.** Le filtre CUPS `rastertokpsl` ne démarrait même
   pas car `libcupsimage.so.2` était absente. Sous Debian 13, le paquet a été
   renommé lors de la transition `time_t` 64 bits : `libcupsimage2` →
   **`libcupsimage2t64`**. Symptôme : chaque job échouait, le filtre ne
   s'exécutait jamais.

2. **Débordement de buffer de pile dans le filtre fermé.** `rastertokpsl`
   recopie le *titre du job* dans un petit buffer de pile. Dès que le titre
   dépasse ~36 octets, il écrase la mémoire voisine et abandonne (`SIGBUS` /
   `*** buffer overflow detected ***` / `malloc(): corrupted top size`). Les
   noms de fichiers longs (courants après export PDF/e-mail) faisaient échouer
   toute impression « réelle », tandis qu'une page de test courte passait.

Détails complets de l'investigation (`ldd`, piles `coredumpctl`/`gdb`, mesures
de seuil) dans [`docs/debugging.fr.md`](docs/debugging.fr.md) (version
[anglaise ici](docs/debugging.en.md)).

## Le correctif

- **Dépendance :** installer `libcupsimage2t64`.
- **Débordement :** le binaire fermé étant impossible à patcher, un petit
  **wrapper** ([`filters/rastertokpsl-wrapper.sh`](filters/rastertokpsl-wrapper.sh))
  tronque titre et nom d'utilisateur à 28 octets (UTF-8 valide), puis `exec` le
  binaire d'origine conservé en `rastertokpsl.bin`.
- **Alternative libre / durable :** compiler et installer
  **`rastertokpsl-re`** (réimplémentation Apache-2.0 reverse-engineered par
  [@sv99](https://github.com/sv99/rastertokpsl-re)), qui n'a pas le
  débordement. Deux micro-patchs de portabilité pour glibc moderne sont fournis
  dans [`patches/`](patches/rastertokpsl-re-debian13.patch).
- **Partage réseau :** exposer la file CUPS sur le LAN
  (`Listen 0.0.0.0:631` + `Allow @LOCAL`) pour tout client IPP/AirPrint/Mopria.
- **Veille/hibernation :** un hook systemd-sleep ré-énumère l'imprimante USB au
  réveil.

## Testé — quoi, comment, pourquoi

Par honnêteté, le tableau distingue ce qui est **vérifié physiquement** de ce
qui est **documenté / attendu**.

| Domaine | Testé | Comment | Statut |
|---|---|---|---|
| Debian 13, CUPS 2.4.10 | `rastertokpsl` ne se charge pas (`libcupsimage.so.2` absente) | `ldd`, `cupsfilter`, `error_log` CUPS | ✅ vérifié |
| Correctif dépendance | `libcupsimage2t64`, le filtre se charge | `ldd`, impression test | ✅ vérifié |
| Débordement du titre | seuil de plantage mesuré | `rastertokpsl.bin` en tant qu'utilisateur `lp` via `runuser`, balayage octet par octet | ✅ vérifié (36 o OK / 37 o crash sous `lp`) |
| Wrapper | la troncature évite le crash | même balayage via le wrapper | ✅ vérifié |
| Compilation filtre libre | `rastertokpsl-re` compile sur glibc 2.41 | `cmake` + `make` ; `sigset`→`signal`, édition de liens `-lm` | ✅ vérifié |
| Parité KPSL | filtre libre vs constructeur | `kpslcmp.pl` sur des rasters identiques (tailles identiques ; seule une petite zone terminale diffère) | ✅ vérifié |
| Impression USB | page texte, PDF 2 pages, titre de 79 car. | `lp` + sortie papier | ✅ vérifié |
| LAN / IPP | CUPS écoute `0.0.0.0:631`, IPP répond, mDNS annonce, job envoyé via l'IP LAN | `ss`, `curl`, `avahi-browse`, `lp -h <ip>` | ✅ vérifié |
| Scanner (SANE) | appareil détecté, scans **gris et couleur** produits | `scanimage -L`, `scanimage` (PNG + PNM) | ✅ vérifié |
| Scanner udev | règle constructeur (mode 0666 sur *tous* les USB) remplacée par une règle Kyocera + groupe `scanner` ; scan toujours fonctionnel | `ls -l /dev/bus/usb/...`, `scanimage` | ✅ vérifié |
| Frontend scanner | `simple-scan` installé | `apt`, SANE | ✅ installé (GUI non automatisée) |
| Chromebook | ajout via IPP / auto-découverte | étapes documentées | ⚠️ documenté, non testé sur appareil |
| Windows 10/11 | ajout de l'imprimante partagée par URL | étapes documentées | ⚠️ documenté, non testé sur appareil |
| Android / iOS | découverte Mopria / AirPrint | étapes documentées | ⚠️ documenté, non testé sur appareil |
| Reprise de veille | hook de ré-énumération USB | installé, invoqué à la main ; **pas** validé par un vrai cycle d'hibernation | ⚠️ partiellement vérifié |

Environnement : Debian 13 (trixie), CUPS 2.4.10, Ghostscript 10.05,
`libcupsimage2t64 2.4.10`, imprimante en USB (`0482:04fd`, série `LBW6Y04191`).

## Pourquoi ça marche comme ça ?

La FS-1220MFP est une imprimante **hôte (GDI)** : aucun interpréteur PostScript
ni PCL. L'hôte doit rastériser la page et envoyer un flux **KPSL** propriétaire.
D'où l'impossibilité d'utiliser un pilote générique, et le caractère vital du
filtre constructeur — **figé en février 2013** (ère Windows 8, cf.
`docs/debugging.fr.md`). CUPS supporte encore ce modèle « PPD + filtre » mais le
déprécie : garder un filtre libre et maintenable est donc la voie durable.

## Arborescence

```
ppd/        PPD Kyocera d'origine (MIT) + PPD modifié pour rastertokpsl-re
filters/    wrapper anti-débordement pour le binaire propriétaire
patches/    patch de portabilité pour rastertokpsl-re (glibc moderne)
scripts/    scripts d'installation / désinstallation / reset USB / SANE Kyocera
udev/       règle udev resserrée pour l'accès scanner (groupe scanner)
systemd/    hook systemd-sleep (ré-énumération USB au réveil)
examples/   guide utilisateur « comment imprimer » (HTML + PDF)
docs/       investigations complètes (FR + EN)
```

## Démarrage rapide

Prérequis : Debian 12/13, CUPS, et (pour le filtre libre) `cmake`,
`libcups2-dev`, `libcupsimage2-dev`.

```sh
# 1) la bibliothèque CUPS manquante
sudo apt install libcupsimage2t64

# 2) filtre libre + PPD + file
git clone https://github.com/sv99/rastertokpsl-re
cd rastertokpsl-re && git apply ../patches/rastertokpsl-re-debian13.patch
./../scripts/install-rastertokpsl-re.sh    # compile, installe le filtre, crée la file

# 3) test
lp -d Kyocera_RE /etc/hostname
```

Procédure manuelle complète et solution de repli (wrapper constructeur) dans
[`docs/debugging.fr.md`](docs/debugging.fr.md).

## Partage réseau (Chromebook / Windows / Android / iOS)

Sur l'hôte CUPS, éditer `/etc/cups/cupsd.conf` :

```
Listen 0.0.0.0:631
...
<Location />
  Order allow,deny
  Allow @LOCAL
</Location>
```

puis `sudo systemctl restart cups`. Les clients du même réseau utilisent :

```
ipp://<ip-hote>:631/printers/Kyocera_FS-1220MFP
ipp://<nom-hote>.local:631/printers/Kyocera_FS-1220MFP
```

Un guide utilisateur prêt à imprimer se trouve dans
[`examples/guide-print-sharing.pdf`](examples/guide-print-sharing.pdf).

**Important :** l'hôte Linux doit rester allumé et éveillé — l'imprimante y est
branchée en USB. Il joue le rôle de serveur d'impression.

## Numérisation (SANE) — oui, ça marche aussi

La partie scanner du MFP est une interface USB distincte (classe *vendor
specific*) ; elle n'est **pas** gérée par les backends SANE livrés avec Debian.
Kyocera fournit un pilote SANE Linux (**v2.2.1511**, 2025, avec un `.deb`
`amd64` natif) qui gère ce modèle d'emblée (`kyocera.conf` liste l'USB ID
`0x0482 0x04FD`, soit la FS-1220MFP).

```sh
sudo ./scripts/install-kyocera-sane.sh     # télécharge chez Kyocera, installe, sécurise udev
scanimage -L                               # -> kyocera:libusb:... Kyocera FS-1220 ...
scanimage --resolution 300 --mode Gray -o scan.png
```

Ou simplement une interface graphique : `simple-scan` (recommandé), `skanlite`,
`xsane`, `gscan2pdf`.

Deux écueils, tous deux gérés par le script :

1. Le `.deb` Kyocera dépend d'un paquet nommé `libsane`, qui n'existe plus sur
   les Debian modernes (la bibliothèque est dans `libsane1`). Le script installe
   un paquet factice pour que `apt` reste cohérent.
2. Le pilote embarque une **règle udev dangereuse** qui met `MODE:="0666"` sur
   *presque tous les périphériques USB*. Le script la remplace par une règle
   limitée aux appareils Kyocera (vendeur `0482`) et au groupe `scanner`.

Le pilote SANE Kyocera est **propriétaire, gratuit, et non redistribué ici** —
le script le télécharge depuis le site de support Kyocera. Voir
[`CREDITS.md`](CREDITS.md).

**Limite — le bouton [Numériser] du panneau ne marche pas sous Linux.** Sur ce
modèle, la touche déclenche une numérisation *push* (« Numérisation directe » /
« Numérisation rapide » : vers PDF, e-mail ou dossier) pilotée par le
**KYOCERA Client Tool**, un utilitaire **Windows**. Le backend SANE est *pull*
(on lance le scan depuis le PC) ; appuyer sur [Numériser] sur la machine n'a donc
aucun effet sans ce logiciel Windows. La touche **[Copier]** du panneau, elle,
fonctionne de façon autonome.

## Applicable à d'autres modèles ?

Oui, la **méthode** se généralise à de nombreux modèles Kyocera GDI/KPSL
abandonnés (et à d'autres imprimantes « hôte » d'autres marques) :

1. Identifier le protocole/PDL (ici KPSL) et vérifier qu'une réimplémentation
   libre existe.
2. Reproduire les pannes **hors ligne** avec `cupsfilter` et le filtre
   directement, en tant qu'utilisateur réel de CUPS (`lp`) — beaucoup de bugs
   dépendent du layout/l'environnement.
3. Utiliser `coredumpctl`/`gdb` sur le filtre plutôt que deviner.
4. Comparer les sorties octet par octet (`kpslcmp.pl`) avant de faire confiance
   à une réimplémentation.
5. Garder le binaire constructeur en secours derrière un wrapper ; préférer le
   filtre libre une fois la parité jugée suffisante.

## Sources et licences

Tous les projets tiers, leurs licences et les sources consultées sont listés
dans [`CREDITS.md`](CREDITS.md). Le contenu propre de ce dépôt est publié sous
licence MIT (voir [`LICENSE`](LICENSE)) ; le PPD Kyocera embarqué est MIT comme
indiqué dans son propre en-tête ; `rastertokpsl-re` en amont est Apache-2.0.

## Discussion

- X : https://x.com/nsi_xyz/status/2101553295814783005
- Bluesky : https://bsky.app/profile/nsi.xyz/post/3mvwvbmgdkc2z
- Mastodon : https://mathstodon.xyz/@nsi_xyz/117301859263724242

## Note sur le coût

Toute la session de diagnostic + réécriture + documentation a été menée avec un
assistant IA (DeepSeek V4.1 Flash) pour environ **0,24 $US** — rappel utile que
la moitié « logicielle » de l'obsolescence programmée est souvent peu coûteuse à
réparer, pour peu que quelqu'un s'en donne la peine.
