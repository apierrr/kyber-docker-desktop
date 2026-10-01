#!/bin/sh
# Lanceur de Steam. Ne pas le faire passer par VirtualGL : l'interface de Steam
# (steamwebhelper) tourne dans le conteneur pressure-vessel, où VirtualGL la
# fait planter en boucle. Les jeux Proton utilisent Vulkan, rendu par le GPU
# grâce à MESA_VK_WSI_DEBUG=sw. Pour un jeu Linux natif en OpenGL, ajouter
# dans ses options de lancement Steam :
#   /opt/VirtualGL/bin/vglrun -d /dev/dri/card0 %command%
exec /usr/games/steam "$@"
