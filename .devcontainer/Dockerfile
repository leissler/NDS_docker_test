FROM skylyrac/blocksds:slim-latest

ENV DEBIAN_FRONTEND=noninteractive

RUN apt update && apt install -y python3 ninja-build \
    && rm -rf /var/lib/apt/lists/*

RUN wf-pacman -S --noconfirm blocksds-nflib blocksds-nitroengine
