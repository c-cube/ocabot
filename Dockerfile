ARG ALPINE_VERSION=3.22
ARG OCAML_VERSION=5.4.1
ARG OPAM_REPO_COMMIT=71db03cadcdabc5e83d5e7e099517788be32bce1
ARG CALCULON_COMMIT=cfd7ebfe97110d1fc628aecfa76f357351482739
ARG IRKY_COMMIT=5b5645a8eb1ae8a3575688881a913654963c1eeb

FROM alpine:${ALPINE_VERSION} AS build
ARG OCAML_VERSION
ARG OPAM_REPO_COMMIT
ARG CALCULON_COMMIT
ARG IRKY_COMMIT
RUN apk add --no-cache ca-certificates curl git unzip build-base pkgconf m4 \
      opam sqlite-dev openssl-dev gmp-dev liburing-dev linux-headers
ENV OPAMROOT=/root/.opam OPAMSWITCH=/root/w OPAMYES=1 OPAMCONFIRMLEVEL=unsafe-yes
# deterministically setup switch from a commit of opam-repo
RUN git init /tmp/opam-repo && cd /tmp/opam-repo && \
    git remote add origin https://github.com/ocaml/opam-repository.git && \
    git fetch --depth 1 origin $OPAM_REPO_COMMIT && \
    git checkout FETCH_HEAD && \
    opam init --disable-sandboxing --bare --no-setup -k local /tmp/opam-repo && \
    opam switch create /root/w --packages=ocaml-base-compiler.$OCAML_VERSION
# pin calculon >= 1.0 and irky from their git repos at fixed commits
RUN git init /tmp/irky && cd /tmp/irky && \
    git remote add origin https://github.com/c-cube/irky.git && \
    git fetch --depth 1 origin $IRKY_COMMIT && \
    git checkout FETCH_HEAD && \
    git init /tmp/calculon && cd /tmp/calculon && \
    git remote add origin https://github.com/c-cube/calculon.git && \
    git fetch --depth 1 origin $CALCULON_COMMIT && \
    git checkout FETCH_HEAD && \
    opam pin add -y -n --no-depexts /tmp/irky && \
    opam pin add -y -n --no-depexts /tmp/calculon && \
    opam install --no-depexts dune calculon eio_posix && \
    rm -rf /tmp/opam-repo /tmp/irky /tmp/calculon

WORKDIR /src
COPY . .
RUN opam exec -- dune build --profile=release src/ocabot.exe && \
    strip _build/default/src/ocabot.exe

FROM alpine:${ALPINE_VERSION} AS prod
RUN apk add --no-cache sqlite-libs libssl3 gmp liburing ca-certificates python3 curl
COPY --from=build /src/_build/default/src/ocabot.exe /usr/local/bin/ocabot
COPY tools/import_changelog.py /usr/local/lib/ocabot/import_changelog.py
COPY docker/entrypoint.sh /usr/local/bin/docker-entrypoint.sh
WORKDIR /data
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
