# Notes techniques

Pièges rencontrés en faisant tourner Kyber 0.28.0 dans un conteneur, et
raisons des choix du Dockerfile.

## Build

- Kyber ne publie pas de binaire Linux : tout part des sources de
  `gitlab.com/kyber`. Le serveur n'a besoin que de `kysdk` ; les sous-modules
  VLC et libvlcjni (client natif) ne sont pas récupérés.
- `kymedia` exige meson 1.10 ou plus, installé avec `uv`.
- Sans le filigrane (`-Dbuild_watermark=disabled`), la pile Vulkan des
  sous-projets n'est plus construite, mais FFmpeg reste configuré avec
  `--enable-vulkan` sous Linux : il faut `libvulkan-dev` du système.
  `kyavserver` se compile alors avec `--no-default-features`.
- Le client web se compile en WebAssembly (`wasm-bindgen-cli` 0.2.100, la
  version du `Cargo.lock`) ; `wasm-opt` vient du paquet `binaryen`.

## Écran virtuel

- Xvfb déclare un mode RandR sans horloge (`dot_clock`, `htotal` et `vtotal` à
  0) et refuse `xrandr --newmode`. txproto en tirait une fréquence de 0/0 :
  d'où `txproto-xvfb-rate.patch`.
- Clavier et souris : Kyber écrit dans `/dev/uinput` pour les touches, les
  boutons et la molette, et n'utilise XTest que pour la position absolue de la
  souris. Dans un conteneur, uinput crée des périphériques dans le noyau de
  l'hôte : les frappes atteindraient la console de l'hôte (Ctrl+Alt+Suppr y
  redémarre la machine), jamais l'écran virtuel. `kynput-xtest.patch` passe
  tout par XTest ; les codes evdev deviennent des codes X en ajoutant 8.
- Les manettes restent sur uinput, donc inactives sans `/dev/uinput`.
- Le client se connecte au port de la page, en TCP pour la page et en UDP pour
  le flux : le port doit être identique dans le conteneur et à l'extérieur.
- Un `docker restart` garde le système de fichiers du conteneur, dont le pid de
  PulseAudio : l'entrypoint repart d'un `XDG_RUNTIME_DIR` vide.

## Connexion

- L'authentification JWT est active par défaut avec la clé
  `kyber-authentication-development-key` : n'importe qui pourrait signer un
  jeton. Elle est désactivée. Le message "JWT backend initialized" apparaît
  quand même dans les logs : le constructeur est évalué avant d'être écarté.
- En OIDC, le client web fait l'échange de code lui-même (PKCE, client public)
  puis envoie le jeton d'accès à kycontroller, qui en vérifie la signature,
  l'émetteur et l'adresse mail. Cloudflare Access ne répond pas aux requêtes
  CORS sur son token endpoint (404 sur le preflight, aucun en-tête sur la
  réponse) : il faut un relais qui ajoute les en-têtes. Un Worker Cloudflare
  de quelques lignes suffit : il transmet le POST au token endpoint et renvoie
  la réponse avec `Access-Control-Allow-Origin` pour l'origine de la page (à
  restreindre aux adresses de la page), et répond aux requêtes OPTIONS. L'adresse du token
  endpoint est lue une seule fois, dans `buildAuthSession`
  (`html/oidc/core.js` de kyber-web), puis réutilisée pour l'échange et le
  renouvellement : c'est là qu'il faut la remplacer par celle du relais.
  Pour garder ce patch hors du dépôt, sans modifier ses fichiers : ajouter
  une étape au-dessus de la cible `web` qui applique le patch et relance
  `./build-wasm.sh`, puis une étape au-dessus de `steam` (ou `desktop`) qui
  y recopie `/src/kyber-web/html` dans `/opt/kyber/webclient`. Docker n'ayant
  pas d'inclusion de Dockerfile, on concatène `Dockerfile` et ces étapes dans
  un fichier non versionné, construit avec `docker build -f`.

## Steam et GPU

- Xvfb n'a ni DRI3 ni accélération. Vulkan (Mesa) refuse alors de présenter
  sur le GPU et retombe sur llvmpipe ; `MESA_VK_WSI_DEBUG=sw` force une
  présentation par copie en mémoire, le rendu restant sur le GPU.
- Hors Steam, OpenGL passe par VirtualGL, avec le back-end EGL sur
  `/dev/dri/card0` (`renderD128` est refusé : "Invalid EGL device").
- Les jeux Linux natifs lancés par Steam tournent dans pressure-vessel (Steam
  Linux Runtime). `vglrun` y échoue ("libXv.so.1: cannot open shared object
  file") et, sans rien, le jeu tourne en llvmpipe. Zink fait passer leur
  OpenGL par Vulkan, donc par le GPU ; options de lancement :
  `LIBGL_KOPPER_DRI2=1 MESA_LOADER_DRIVER_OVERRIDE=zink %command%`.
  Sans `LIBGL_KOPPER_DRI2=1`, Zink ne trouve aucun visuel GLX sous Xvfb.
- Ne pas lancer Steam sous VirtualGL : son interface (steamwebhelper) tourne
  dans le conteneur pressure-vessel, où le faker de VirtualGL ne trouve pas ses
  extensions et la fait planter en boucle.
- Le bac à sable de Proton a buté sur trois verrous successifs :
  - seccomp : le profil de Docker n'autorise `unshare`, `clone` avec
    namespaces, `mount`, `umount2` et `setns` qu'avec CAP_SYS_ADMIN, et jamais
    `pivot_root` ;
  - AppArmor : `docker-default` interdit `mount`. Désactiver AppArmor ne marche
    pas sur Ubuntu (`apparmor_restrict_unprivileged_userns=1` : écriture de
    `uid_map` refusée) ; il faut un profil qui autorise `userns`, en ABI 4.0,
    sinon la règle est ignorée et le montage échoue en EACCES sans trace dans
    les logs ;
  - `/proc` : Docker masque des chemins de `/proc`, et le noyau refuse alors
    d'y monter un `/proc` neuf ("Can't mount proc on /proc") ;
    `systempaths=unconfined` lève ce masquage.
- La version Debian de Steam s'installe dans `~/.steam/debian-installation`,
  et non `~/.local/share/Steam`.
- Avec `/dev/dri` présent, txproto cherche aussi à capturer l'écran physique
  par DRM et journalise "failed to get CAP_SYS_ADMIN permission" chaque
  seconde, sans conséquence : les logs du conteneur sont plafonnés.
