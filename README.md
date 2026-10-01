# kyber-docker-desktop

Un bureau Linux (XFCE) en 1920x1080 dans un conteneur Docker, accessible à
distance avec [Kyber](https://gitlab.com/kyber/kyber), la solution de contrôle à
distance à très faible latence créée par l'équipe de VLC (FFmpeg, QUIC,
WebTransport). Steam est disponible en option, avec Proton, rendu par le GPU de
l'hôte.

Le serveur Linux de Kyber et son client web sont compilés depuis les sources ;
deux patchs les adaptent à un écran virtuel dans un conteneur (voir
[Écarts avec Kyber](#écarts-avec-kyber)).

Projet personnel, non officiel, sans lien avec Kyber SAS.

## Fonctionnalités

- Bureau XFCE sur un écran virtuel Xvfb : image, son, clavier et souris, ces
  derniers injectés dans le seul écran virtuel.
- Flux H.264 jusqu'à 60 images par seconde, débit adaptatif.
- Accès depuis un navigateur (client web intégré) ou depuis le client natif de
  Kyber.
- Connexion par identifiants, ou via un fournisseur OIDC.
- Steam en option : jeux Linux natifs et jeux Windows via Proton, rendus par
  le GPU de l'hôte (testé avec un Intel UHD 630).
- Rien de privilégié : aucune capacité ajoutée au conteneur, et le bureau
  tourne avec un utilisateur non root.

## Architecture

```
client --(HTTPS, TCP)--> kycontroller : page web, connexion, contrôle
       <--(QUIC, UDP)--> kycontroller : image, son, clavier, souris
                              |
              kyavserver : capture de Xvfb et encodage (txproto, FFmpeg)
              kynputserver : clavier et souris (XTest)
                              |
              Xvfb + XFCE + PulseAudio (+ Steam)
```

## Installation

Prérequis : Docker. Le premier build compile FFmpeg, x264 et Kyber, comptez 20
à 40 minutes.

```bash
git clone https://github.com/apierrr/kyber-docker-desktop.git
cd kyber-docker-desktop
cp .env.example .env      # puis renseigner au moins KYBER_USER et KYBER_PASSWORD
docker compose up -d --build
```

## Clients

- Navigateur : `https://<machine>:8090/webclient/`, dans Chrome, Chromium,
  Brave ou Edge (WebTransport et WebCodecs ; Firefox et Safari ne sont pas
  pris en charge par le client web de Kyber). Le certificat est auto-signé :
  accepter l'avertissement une fois.
- Client natif de Kyber (installeur Windows dans
  [kyber-installer](https://gitlab.com/kyber/apps/kyber-installer), à compiler
  pour Linux et macOS) : il s'installe sur la machine cliente et se connecte au
  même port, avec `--username` pour les
  identifiants et `--tls-tofu` pour retenir le certificat auto-signé à la
  première connexion.

## Réglages (`.env`)

| Variable | Défaut | Rôle |
|---|---|---|
| `KYBER_USER`, `KYBER_PASSWORD` | vide | Identifiants de connexion |
| `KYBER_BASIC_AUTH` | `true` | Connexion par identifiants (`false` si OIDC seul) |
| `KYBER_OIDC_*` | vide | Connexion OIDC, voir [Connexion](#connexion) |
| `KYBER_PORT` | `8090` | Port de la page (TCP) et du flux (UDP) |
| `SCREEN_RESOLUTION` | `1920x1080` | Taille de l'écran virtuel |
| `KYBER_ENCODER` | `x264` | Encodeur vidéo (`vaapi` est expérimental dans Kyber) |
| `KEYBOARD_LAYOUT` | `fr` | Disposition du clavier dans le bureau |
| `KEYBOARD_VARIANT` | vide | Variante, par exemple `mac` |
| `LOCALE` | `fr_FR.UTF-8` | Langue du bureau, appliquée au build |
| `TZ` | `Europe/Paris` | Fuseau horaire |
| `CPUS` | `4` | Cœurs maximum pour le conteneur |
| `KYBER_TLS_SAN` | `IP:127.0.0.1` | Adresses et noms couverts par le certificat |

Après modification : `docker compose up -d`. Après un changement de
`KYBER_TLS_SAN`, supprimer `data/home/.config/kyber/tls/` pour régénérer le
certificat.

Le dossier personnel du bureau est conservé dans `data/home/` : il contient
les sessions ouvertes dans le bureau (Steam, navigateur...), ne pas le
partager.

En session, environ un cœur sert à l'encodage (x264, 1080p) ; sans client
connecté, le conteneur ne consomme presque rien.

## Connexion

Par défaut, la connexion se fait par identifiants (méthode Basic). Kyber ne
limite pas les tentatives : un mot de passe long et aléatoire s'impose, et un
accès protégé par mot de passe seul ne devrait pas être exposé sur Internet.

Kyber gère aussi OIDC : la connexion est déléguée à un fournisseur d'identité,
et seules les adresses mail autorisées ouvrent une session.

```bash
KYBER_OIDC_ISSUER=https://<fournisseur>/realms/<realm>
KYBER_OIDC_CLIENT_ID=<client_id>
KYBER_OIDC_ALLOWED_EMAILS=vous@example.com
```

Côté fournisseur : un client public avec PKCE, sans secret, dont l'adresse de
retour est l'URL de la page, `/webclient/` compris. Dans le client web,
choisir la méthode OIDC ; une fois la connexion validée, `KYBER_BASIC_AUTH=false`
désactive les identifiants.

Le client web fait l'échange de jetons depuis le navigateur : le fournisseur
doit accepter les requêtes CORS sur son token endpoint. C'est le cas de
Keycloak ou d'Authentik, pas de Cloudflare Access, qui n'envoie aucun en-tête
CORS et demande un relais (voir [docs/NOTES.md](docs/NOTES.md#connexion)).

## Accès à distance

Le flux passe en UDP sur le même port que la page : un tunnel HTTP (Cloudflare
Tunnel, reverse proxy) ne transporte que la page et l'image ne passe pas. Il
faut un VPN (Tailscale, WireGuard), un tunnel qui relaie TCP et UDP sur le
même port public, sans PROXY protocol, ou une redirection de ce port. Ajouter
l'adresse utilisée à `KYBER_TLS_SAN`.

## Durcissement

Exposé sur Internet, le bureau est aussi solide que Kyber lui-même. Pour
qu'une compromission reste dans le conteneur, il est conseillé de l'isoler du
réseau local : réseau Docker dédié, règles `DOCKER-USER` qui ne le laissent
joindre qu'Internet, et DNS public (celui de la box devient injoignable).
Seules les connexions qu'il initie sont concernées, pas celles des clients.

## Steam

Steam s'ajoute avec `docker-compose.steam.yml`. Il faut un GPU accessible via
`/dev/dri` (Mesa : Intel ou AMD) et un hôte avec AppArmor (Ubuntu, Debian).

Proton lance chaque jeu dans un bac à sable (bwrap) qui crée des user
namespaces et monte des systèmes de fichiers, ce que Docker interdit par
défaut. Trois réglages l'autorisent pour ce seul conteneur, sans capacité
ajoutée :

- `security/seccomp-steam.json` : le profil seccomp de Docker, plus `unshare`,
  `clone`, `mount`, `umount2`, `pivot_root` et `setns`. Il se régénère avec
  `security/make-seccomp.sh` ;
- `security/apparmor-kyber-steam` : le profil AppArmor de Docker, plus les
  montages et les user namespaces. `/proc/kcore`, `/proc/sysrq-trigger`,
  `/sys/firmware` et l'écriture dans `/proc/sys` restent interdits ;
- `systempaths=unconfined` : sans lui, le noyau refuse de monter un `/proc`
  neuf dans le bac à sable.

Ces réglages élargissent la surface d'attaque du noyau : avec Steam, le
durcissement ci-dessus et un noyau à jour comptent d'autant plus.

Mise en place :

```bash
sudo cp security/apparmor-kyber-steam /etc/apparmor.d/kyber-steam
sudo apparmor_parser -r -W /etc/apparmor.d/kyber-steam
getent group video render      # reporter les numéros dans VIDEO_GID et RENDER_GID
```

Puis dans `.env`, décommenter `COMPOSE_FILE=docker-compose.yml:docker-compose.steam.yml`
et lancer `docker compose up -d --build`. Avec `COMPOSE_FILE`, un
`docker-compose.override.yml` n'est plus chargé automatiquement : s'il existe,
l'ajouter à la fin de la liste. Steam est dans le menu Applications,
Jeux. Pour installer les jeux hors du conteneur, ajouter `/home/kyber/SteamLibrary`
dans Steam > Paramètres > Stockage et le définir par défaut.

Limites : pas de manette (elles passent par `/dev/uinput`, absent du
conteneur), et chaque image passe par la mémoire du processeur (Xvfb n'a pas
d'accès direct au GPU). Avec un GPU intégré, viser des jeux légers.

## Écarts avec Kyber

Deux patchs, appliqués au build, dans [patches/](patches/) :

- `kynput-xtest.patch` : sous Linux, Kyber injecte clavier et clics par
  `/dev/uinput`, c'est-à-dire dans le noyau de l'hôte. Ils passent ici par
  XTest, dans le seul écran virtuel du conteneur.
- `txproto-xvfb-rate.patch` : Xvfb annonce un mode d'affichage sans horloge, ce
  qui donnait une fréquence de 0 image par seconde. Elle reste alors à 60.

Le client natif (basé sur VLC) et le filigrane ne sont pas compilés dans
l'image, qui ne contient que le serveur et le client web. L'authentification
JWT de Kyber, active par défaut avec une clé de développement publique, est
désactivée, et le certificat de test livré par Kyber n'est pas utilisé.

Notes techniques et pièges rencontrés : [docs/NOTES.md](docs/NOTES.md).

## Licence

AGPL-3.0-or-later, voir [LICENSE](LICENSE), comme Kyber, dont ce projet
modifie le code. `security/seccomp-steam.json` dérive du profil par défaut de
Docker (moby, Apache-2.0).
