# Bureau Linux (XFCE) dans le navigateur avec Kyber (https://gitlab.com/kyber) :
# serveur Linux X11 et client web compilés depuis les sources, sur un écran
# virtuel Xvfb.
#
# Cibles : "desktop" (le bureau seul) et "steam" (le bureau avec Steam).
ARG KYBER_VERSION=0.28.0

# ---------------------------------------------------------------------------
# Chaîne de compilation (reprise de kyber/ops/docker-images/debian-trixie)
# ---------------------------------------------------------------------------
FROM debian:trixie-slim AS toolchain

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates git curl wget zip unzip \
        build-essential cmake ninja-build pkg-config \
        llvm-dev libclang-dev clang libssl-dev \
        autoconf automake libtool \
        python3 python3-setuptools python3-mako python3-venv python3-jinja2 \
        lua5.4 liblua5.4-dev \
        autopoint gettext bison flex nasm ragel help2man \
        libdrm-dev libgbm-dev liblcms2-dev \
        libegl-dev libgl-dev libva-dev libgles-dev libvdpau-dev \
        libxcb1-dev libxcb-shm0-dev libxcb-composite0-dev libxcb-randr0-dev \
        libxcb-render0-dev libxcb-xkb-dev libxkbcommon-dev libxcb-xtest0-dev \
        libxcb-shape0-dev libxcb-xfixes0-dev libx11-dev libx11-xcb-dev \
        libwayland-dev wayland-protocols \
        libpulse-dev libasound2-dev \
        libxext-dev libudev-dev libinput-dev libevdev-dev libdbus-1-dev \
        libcap-dev libopengl-dev libxfixes-dev libxrandr-dev libv4l-dev \
    && rm -rf /var/lib/apt/lists/*

# meson >= 1.10 exigé par kymedia (celui de trixie est trop ancien)
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh \
    && UV_TOOL_BIN_DIR=/usr/local/bin uv tool install meson==1.10.0 --with jinja2

ENV CARGO_HOME=/cargo RUSTUP_HOME=/rustup PATH=/cargo/bin:$PATH
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain 1.89.0 \
    && cargo install --locked cargo-c@0.10.15

# ---------------------------------------------------------------------------
# Serveur : kycontroller, kyavserver, kynputserver
# ---------------------------------------------------------------------------
FROM toolchain AS server
ARG KYBER_VERSION

# FFmpeg est configuré avec --enable-vulkan sous Linux ; la pile Vulkan des
# sous-projets n'étant pas construite (filigrane désactivé), on prend celle
# du système
RUN apt-get update && apt-get install -y --no-install-recommends libvulkan-dev \
    && rm -rf /var/lib/apt/lists/*

# kysdk seul suffit au serveur ; VLC et libvlcjni (client natif) sont ignorés
WORKDIR /src
RUN git clone --depth 1 --branch ${KYBER_VERSION} https://gitlab.com/kyber/core/kysdk.git \
    && cd kysdk \
    && git submodule update --init --depth 1 \
    && git -C kymedia config submodule.subprojects/vlc.update none \
    && git -C kymedia config submodule.subprojects/libvlcjni.update none \
    && git submodule update --init --recursive --depth 1

# Voir docs/NOTES.md pour le détail des patchs
COPY patches/kynput-xtest.patch patches/txproto-xvfb-rate.patch /tmp/patches/
RUN git -C /src/kysdk/kynput apply /tmp/patches/kynput-xtest.patch \
    && git -C /src/kysdk/kymedia/subprojects/txproto apply /tmp/patches/txproto-xvfb-rate.patch

ENV OUT_DIR=/opt/kyber
ENV PATH=$OUT_DIR/bin:$PATH \
    LD_LIBRARY_PATH=$OUT_DIR/lib:$OUT_DIR/lib/x86_64-linux-gnu:$OUT_DIR/lib64 \
    PKG_CONFIG_PATH=$OUT_DIR/lib/pkgconfig:$OUT_DIR/lib/x86_64-linux-gnu/pkgconfig:$OUT_DIR/lib64/pkgconfig

# Dépendances natives (FFmpeg, x264, opus, txproto, libavconv...) sans le
# client VLC ni le filigrane (pile Vulkan et libplacebo), inutiles ici
WORKDIR /src/kysdk/kymedia
RUN sed -i 's/"-Dbuild_server=enabled")/"-Dbuild_server=enabled" "-Dbuild_client=disabled" "-Dbuild_watermark=disabled")/' build-linux.sh \
    && grep -q build_watermark=disabled build-linux.sh \
    && ./build-linux.sh -d -o $OUT_DIR

RUN AVCONV_INCLUDE_DIR=$OUT_DIR/include AVCONV_LIB_DIR=$OUT_DIR/lib \
    cargo build -p kyavserver --release --no-default-features \
    && cp target/release/kyavserver $OUT_DIR/bin/

WORKDIR /src/kysdk/kynput
RUN ./build-linux.sh -o $OUT_DIR

WORKDIR /src/kysdk/kyctl
RUN ./build-linux.sh -s -o $OUT_DIR build-kycontroller

# ---------------------------------------------------------------------------
# Client web (Rust compilé en WebAssembly), servi par kycontroller
# ---------------------------------------------------------------------------
FROM toolchain AS web
ARG KYBER_VERSION

RUN apt-get update && apt-get install -y --no-install-recommends nodejs npm binaryen \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g pnpm@10.33.4 \
    && rustup target add wasm32-unknown-unknown \
    && cargo install --locked wasm-bindgen-cli@0.2.100

WORKDIR /src
RUN git clone --depth 1 --branch ${KYBER_VERSION} https://gitlab.com/kyber/apps/kyber-web.git \
    && cd kyber-web \
    && git submodule update --init --depth 1 \
    && git -C kysdk submodule update --init --depth 1 \
    && git -C kysdk/kymedia config submodule.subprojects/vlc.update none \
    && git -C kysdk/kymedia config submodule.subprojects/libvlcjni.update none \
    && git -C kysdk submodule update --init --recursive --depth 1

WORKDIR /src/kyber-web
RUN ./build-wasm.sh

# ---------------------------------------------------------------------------
# Bureau : Xvfb, XFCE, PulseAudio et Kyber
# ---------------------------------------------------------------------------
FROM debian:trixie-slim AS desktop

# Langue du bureau. L'image slim exclut les traductions : on garde celles
# de cette langue.
ARG LOCALE=fr_FR.UTF-8
RUN lang="${LOCALE%%_*}" \
    && echo "path-include /usr/share/locale/${lang}/*" > /etc/dpkg/dpkg.cfg.d/zz-locale \
    && apt-get update && apt-get install -y --no-install-recommends \
        tini ca-certificates openssl locales tzdata \
        xvfb xauth x11-xkb-utils x11-xserver-utils \
        dbus dbus-x11 \
        xfce4-session xfwm4 xfce4-panel xfdesktop4 xfdesktop4-data xfce4-settings xfconf \
        xfce4-terminal thunar adwaita-icon-theme fonts-dejavu \
        pulseaudio pulseaudio-utils \
        libxcb1 libxcb-shm0 libxcb-xfixes0 libxcb-xtest0 libxcb-randr0 \
        libxcb-shape0 libxcb-render0 libxcb-xkb1 libxkbcommon0 libx11-6 \
        libpulse0 libdrm2 libgbm1 libva2 libva-drm2 libva-x11-2 libvdpau1 \
        libssl3t64 libudev1 libinput10 libevdev2 libdbus-1-3 liblua5.4-0 \
        libegl1 libgl1 libgles2 libopengl0 libv4l-0t64 libasound2t64 libvulkan1 \
    && sed -i -e "s/^# *\(${LOCALE}\)/\1/" -e 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

COPY --from=server /opt/kyber /opt/kyber
COPY --from=web /src/kyber-web/html /opt/kyber/webclient

RUN useradd -m -u 1000 -s /bin/bash kyber \
    && install -d -o kyber -g kyber /run/kyber \
    && rm -f /opt/kyber/bin/kyber_config.toml \
    && ln -s /run/kyber/kyber_config.toml /opt/kyber/bin/kyber_config.toml

COPY entrypoint.sh /usr/local/bin/entrypoint.sh

ENV PATH=/opt/kyber/bin:$PATH \
    LD_LIBRARY_PATH=/opt/kyber/lib:/opt/kyber/lib/x86_64-linux-gnu:/opt/kyber/lib64 \
    KYBER_CONFIG=/run/kyber/kyber_config.toml \
    DISPLAY=:0 LANG=${LOCALE}

# L'entrypoint démarre en root puis passe sur l'utilisateur kyber (setpriv)
WORKDIR /home/kyber
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]

# ---------------------------------------------------------------------------
# Steam : client 32 bits (dépôt contrib), pilotes Mesa OpenGL et Vulkan en
# 64 et 32 bits, VirtualGL pour les applications OpenGL hors Steam
# ---------------------------------------------------------------------------
FROM desktop AS steam
USER root

ARG VIRTUALGL_VERSION=3.1.5
ADD https://github.com/VirtualGL/virtualgl/releases/download/${VIRTUALGL_VERSION}/virtualgl_${VIRTUALGL_VERSION}_amd64.deb \
    https://github.com/VirtualGL/virtualgl/releases/download/${VIRTUALGL_VERSION}/virtualgl32_${VIRTUALGL_VERSION}_amd64.deb \
    /tmp/vgl/
RUN dpkg --add-architecture i386 \
    && sed -i 's/^Components: main$/Components: main contrib non-free non-free-firmware/' /etc/apt/sources.list.d/debian.sources \
    && apt-get update && apt-get install -y --no-install-recommends \
        steam-installer zenity xdg-utils \
        mesa-vulkan-drivers mesa-vulkan-drivers:i386 \
        libgl1-mesa-dri libgl1-mesa-dri:i386 libgl1:i386 libglx-mesa0:i386 \
        libegl1:i386 libegl-mesa0:i386 \
        vulkan-tools mesa-utils \
        /tmp/vgl/*.deb \
    && rm -rf /var/lib/apt/lists/* /tmp/vgl

COPY steam.sh /usr/local/bin/steam
RUN chmod 755 /usr/local/bin/steam \
    && sed -i 's|^Exec=/usr/games/steam|Exec=/usr/local/bin/steam|' /usr/share/applications/steam.desktop

# Xvfb n'a pas DRI3 : sans ce réglage, Vulkan retombe sur le rendu logiciel
ENV MESA_VK_WSI_DEBUG=sw
