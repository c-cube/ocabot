ARG ALPINE_VERSION=3.22
ARG OCAML_VERSION=5.4.1
ARG OPAM_REPO_COMMIT=71db03cadcdabc5e83d5e7e099517788be32bce1

FROM alpine:${ALPINE_VERSION} AS build
ARG OCAML_VERSION
ARG OPAM_REPO_COMMIT
RUN apk add --no-cache ca-certificates curl git unzip rsync build-base pkgconf m4 \
      opam sqlite-dev openssl-dev gmp-dev liburing-dev linux-headers curl-dev
ENV OPAMROOT=/root/.opam OPAMSWITCH=/root/w OPAMYES=1 OPAMCONFIRMLEVEL=unsafe-yes
# deterministically setup switch from a commit of opam-repo
RUN git init /tmp/opam-repo && cd /tmp/opam-repo && \
    git remote add origin https://github.com/ocaml/opam-repository.git && \
    git fetch --depth 1 origin $OPAM_REPO_COMMIT && \
    git checkout FETCH_HEAD && \
    opam init --disable-sandboxing --bare --no-setup -k local /tmp/opam-repo && \
    opam switch create /root/w --packages=ocaml-base-compiler.$OCAML_VERSION
# pin calculon and irky from the vendored copies (git submodules)
COPY vendor/calculon /tmp/calculon
COPY vendor/irky /tmp/irky
RUN opam pin add -y -n --no-depexts /tmp/calculon && \
    opam pin add -y -n --no-depexts /tmp/irky && \
    opam install --no-depexts dune calculon eio_posix ezcurl sha && \
    rm -rf /tmp/opam-repo /tmp/irky /tmp/calculon

WORKDIR /src
COPY . .
RUN opam exec -- dune build --profile=release src/ocabot.exe && \
    strip _build/default/src/ocabot.exe

FROM alpine:${ALPINE_VERSION} AS prod
RUN apk add --no-cache sqlite-libs libssl3 gmp liburing ca-certificates libcurl
COPY --from=build /src/_build/default/src/ocabot.exe /usr/local/bin/ocabot
WORKDIR /data
ENTRYPOINT ["/usr/local/bin/ocabot"]
