FROM skylyrac/blocksds:slim-latest

ENV DEBIAN_FRONTEND=noninteractive

RUN apt update && apt install -y \
    python3 ninja-build nodejs gdb-multiarch \
    build-essential curl xz-utils texinfo bison flex \
    libgmp-dev libmpfr-dev libexpat1-dev libreadline-dev zlib1g-dev \
    && (command -v node >/dev/null 2>&1 || ln -sf /usr/bin/nodejs /usr/bin/node) \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://ftp.gnu.org/gnu/gdb/gdb-17.1.tar.xz -o /tmp/gdb-17.1.tar.xz \
    && tar -xJf /tmp/gdb-17.1.tar.xz -C /tmp \
    && mkdir -p /tmp/gdb-build \
    && cd /tmp/gdb-build \
    && /tmp/gdb-17.1/configure \
      --prefix=/opt/gdb-17 \
      --target=arm-none-eabi \
      --disable-werror \
      --disable-binutils \
      --disable-gas \
      --disable-gold \
      --disable-ld \
      --disable-gprof \
      --disable-gprofng \
      --without-guile \
      --without-debuginfod \
    && make -j"$(nproc)" all-gdb \
    && make install-gdb \
    && rm -rf /tmp/gdb-17.1 /tmp/gdb-build /tmp/gdb-17.1.tar.xz

RUN set -eux; \
    wf-pacman -Sy --noconfirm; \
    for attempt in 1 2 3 4 5; do \
      if wf-pacman -S --noconfirm --needed blocksds-nflib blocksds-nitroengine; then \
        exit 0; \
      fi; \
      echo "wf-pacman install failed (attempt ${attempt}), retrying..." >&2; \
      sleep $((attempt * 2)); \
      wf-pacman -Scc --noconfirm || true; \
      wf-pacman -Sy --noconfirm || true; \
    done; \
    echo "wf-pacman install failed after retries" >&2; \
    exit 1
