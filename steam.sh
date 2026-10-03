#!/bin/sh
# Lanceur de Steam. Ne pas le faire passer par VirtualGL : l'interface de Steam
# (steamwebhelper) tourne dans le conteneur pressure-vessel, où VirtualGL la
# fait planter en boucle. Les jeux Proton utilisent Vulkan, rendu par le GPU
# grâce à MESA_VK_WSI_DEBUG=sw. Un jeu Linux natif en OpenGL tourne lui aussi
# dans pressure-vessel, où vglrun échoue ; pour le rendre sur le GPU (Zink,
# OpenGL sur Vulkan), ajouter dans ses options de lancement Steam :
#   LIBGL_KOPPER_DRI2=1 MESA_LOADER_DRIVER_OVERRIDE=zink %command%
exec /usr/games/steam "$@"
