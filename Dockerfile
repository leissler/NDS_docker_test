FROM skylyrac/blocksds:slim-latest AS builder

RUN apt update && apt install python3 ninja-build -y
RUN wf-pacman -S blocksds-nflib blocksds-nitroengine --noconfirm

WORKDIR /test
COPY . .

RUN python3 build.py

FROM scratch AS export-stage
COPY --from=builder /test/*.nds /game.nds