# syntax=docker/dockerfile:1.2
#FROM rust:bullseye AS libafl
FROM ubuntu:20.04 AS libafl

ENV DEBIAN_FRONTEND=noninteractive
ENV PROMPT_COMMAND=""

RUN apt-get update && apt-get upgrade -y && apt-get install -y \
    automake \
    autotools-dev \
    build-essential \
    curl \
    git \
    python3 \
    python3-pip \
    wget \
    libmpfr-dev

# Hack to get libmpfr v6 to show up as it it's v4 _ do we need this with 20.04?
#RUN ln -s /usr/lib/x86_64-linux-gnu/libmpfr.so.6 /usr/lib/x86_64-linux-gnu/libmpfr.so.4
RUN curl https://sh.rustup.rs -sSf | sh -s -- -y --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"
RUN rustup toolchain install nightly --allow-downgrade --profile minimal # Now install nightly
RUN rustup override set nightly # and switch to it


LABEL "maintainer"="afl++ team <afl@aflplus.plus>"
LABEL "about"="LibAFL Docker image"

RUN apt-get update && apt-get install -y libssl-dev
RUN apt-get update && apt-get install -y pkg-config
# install sccache to cache subsequent builds of dependencies
RUN cargo install sccache

ENV HOME=/root
ENV SCCACHE_CACHE_SIZE="1G"
ENV RUSTC_WRAPPER="/root/.cargo/bin/sccache"
ENV IS_DOCKER="1"
RUN sh -c 'echo set encoding=utf-8 > /root/.vimrc' \
    echo "export PS1='"'[LibAFL \h] \w$(__git_ps1) \$ '"'" >> ~/.bashrc && \
    mkdir -p ~/.cargo && \
    echo "[build]\nrustc-wrapper = \"${RUSTC_WRAPPER}\"" >> ~/.cargo/config

RUN rustup component add rustfmt clippy

# Install clang 11, common build tools
RUN apt update && apt install -y build-essential gdb git wget clang clang-tools libc++-11-dev libc++abi-11-dev llvm

RUN apt-get update && apt-get upgrade -y && apt-get install -y wget libglib2.0-dev

# Qemu dependencies - just grab packages list from PANDA: base + build
RUN apt-get -qq update && \
    apt-get -qq install -y --no-install-recommends $(wget 'https://raw.githubusercontent.com/panda-re/panda/dev/panda/dependencies/ubuntu%3A20.04_base.txt' -O- | grep -o '^[^#]*') && \
    apt-get -qq install -y --no-install-recommends $(wget 'https://raw.githubusercontent.com/panda-re/panda/dev/panda/dependencies/ubuntu%3A20.04_build.txt' -O- | grep -o '^[^#]*')

# Copy a dummy.rs and Cargo.toml first, so that dependencies are cached
WORKDIR /libafl
COPY Cargo.toml README.md ./

COPY libafl_derive/Cargo.toml libafl_derive/Cargo.toml
COPY scripts/dummy.rs libafl_derive/src/lib.rs

COPY libafl/Cargo.toml libafl/build.rs libafl/
COPY libafl/examples libafl/examples
COPY scripts/dummy.rs libafl/src/lib.rs

COPY libafl_frida/Cargo.toml libafl_frida/build.rs libafl_frida/
COPY scripts/dummy.rs libafl_frida/src/lib.rs
COPY libafl_frida/src/gettls.c libafl_frida/src/gettls.c

COPY libafl_qemu/Cargo.toml libafl_qemu/
COPY scripts/dummy.rs libafl_qemu/src/lib.rs

COPY libafl_qemu/libafl_qemu_build/Cargo.toml libafl_qemu/libafl_qemu_build/
COPY scripts/dummy.rs libafl_qemu/libafl_qemu_build/src/lib.rs

COPY libafl_qemu/libafl_qemu_sys/Cargo.toml libafl_qemu/libafl_qemu_sys/
COPY scripts/dummy.rs libafl_qemu/libafl_qemu_sys/src/lib.rs

COPY libafl_sugar/Cargo.toml libafl_sugar/
COPY scripts/dummy.rs libafl_sugar/src/lib.rs

COPY libafl_cc/Cargo.toml libafl_cc/Cargo.toml
COPY libafl_cc/build.rs libafl_cc/build.rs
COPY libafl_cc/src libafl_cc/src
COPY scripts/dummy.rs libafl_cc/src/lib.rs

COPY libafl_targets/Cargo.toml libafl_targets/build.rs libafl_targets/
COPY libafl_targets/src libafl_targets/src
COPY scripts/dummy.rs libafl_targets/src/lib.rs

COPY libafl_concolic/test/dump_constraints/Cargo.toml libafl_concolic/test/dump_constraints/
COPY scripts/dummy.rs libafl_concolic/test/dump_constraints/src/lib.rs

COPY libafl_concolic/test/runtime_test/Cargo.toml libafl_concolic/test/runtime_test/
COPY scripts/dummy.rs libafl_concolic/test/runtime_test/src/lib.rs

COPY libafl_concolic/symcc_runtime/Cargo.toml libafl_concolic/symcc_runtime/build.rs libafl_concolic/symcc_runtime/
COPY scripts/dummy.rs libafl_concolic/symcc_runtime/src/lib.rs

COPY libafl_concolic/symcc_libafl/Cargo.toml libafl_concolic/symcc_libafl/
COPY scripts/dummy.rs libafl_concolic/symcc_libafl/src/lib.rs

COPY libafl_nyx/Cargo.toml libafl_nyx/build.rs libafl_nyx/
COPY scripts/dummy.rs libafl_nyx/src/lib.rs

COPY libafl_tinyinst/Cargo.toml libafl_tinyinst/
COPY scripts/dummy.rs libafl_tinyinst/src/lib.rs

COPY utils utils

# Build dummy libafl packages (with sccache), this gets our deps cached
RUN cargo build --release

# Let's copy in libafl_qemu_sys
COPY libafl_qemu/libafl_qemu_sys/Cargo.toml libafl_qemu/libafl_qemu_sys/
COPY scripts/dummy.rs libafl_qemu/libafl_qemu_sys/src/main.rs

# Let's copy in libafl_qemu 
COPY libafl_qemu/Cargo.toml libafl_qemu/
COPY scripts/dummy.rs libafl_qemu/src/main.rs
#RUN cd libafl_qemu/ && sed -i '/libafl_qemu_sys =/d' Cargo.toml && cargo build --release -F "systemmode mips be"
RUN cd libafl_qemu/ && cargo build --release -F "systemmode mips be"

# WSF isn't built as a part of libafl. Let's copy it in with dummy files and build it to get deps
# Note we have to drop the libafl_qemu dependency for this cached-build because we'll be building that later
COPY fuzzers/wsf/Cargo.toml fuzzers/wsf/
COPY scripts/dummy.rs fuzzers/wsf/src/main.rs
RUN cd fuzzers/wsf && sed -i '/libafl_qemu/d' Cargo.toml && cargo build --release

# Would be nice to also build libafl_qemu here with a dummy package but it doesn't seem to work
COPY libafl_qemu/Cargo.toml libafl_qemu
COPY scripts/dummy.rs libafl_qemu/src/lib.rs
RUN cd libafl_qemu && cargo build --release

COPY scripts scripts
COPY docs docs

# Pre-build dependencies for a few common fuzzers

# Dep chain:
# libafl_cc (independent)
# libafl_derive -> libafl
# libafl -> libafl_targets
# libafl_targets -> libafl_frida

# Build once without source
COPY libafl_cc/src libafl_cc/src
RUN touch libafl_cc/src/lib.rs
COPY libafl_derive/src libafl_derive/src
RUN touch libafl_derive/src/lib.rs
COPY libafl/src libafl/src
RUN touch libafl/src/lib.rs
COPY libafl_targets/src libafl_targets/src
RUN touch libafl_targets/src/lib.rs
COPY libafl_frida/src libafl_frida/src
RUN touch libafl_qemu/libafl_qemu_build/src/lib.rs
COPY libafl_qemu/build_linux.rs libafl_qemu/build.rs libafl_qemu/
COPY libafl_qemu/libafl_qemu_build/src libafl_qemu/libafl_qemu_build/src
RUN touch libafl_qemu/libafl_qemu_sys/src/lib.rs
COPY libafl_qemu/libafl_qemu_sys/build_linux.rs libafl_qemu/libafl_qemu_sys/build.rs libafl_qemu/libafl_qemu_sys/
COPY libafl_qemu/libafl_qemu_sys/src libafl_qemu/libafl_qemu_sys/src
RUN touch libafl_qemu/src/lib.rs
COPY libafl_qemu/src libafl_qemu/src
RUN touch libafl_frida/src/lib.rs
COPY libafl_concolic/symcc_libafl libafl_concolic/symcc_libafl
COPY libafl_concolic/symcc_runtime libafl_concolic/symcc_runtime
COPY libafl_concolic/test libafl_concolic/test
COPY libafl_nyx/src libafl_nyx/src
RUN touch libafl_nyx/src/lib.rs



# Now copy in qemu??
COPY qemu /root/libafl_qemu

# Build qemu
RUN /root/libafl_qemu/setup.sh build mips-softmmu --as-shared-lib

# Build libafl_qemu from our custom qemu dir
RUN cd libafl_qemu && \
     CUSTOM_QEMU_DIR=/root/libafl_qemu \
     CUSTOM_QEMU_NO_CONFIGURE=1 \
     CUSTOM_QEMU_NO_BUILD=1 \
     NUM_JOBS=$(nproc) \
       cargo build --release -F "systemmode mips be"

# Build libafl (should reuse our libafl_qemu crate)
RUN cargo build --release

# Rebuild WSF with no source but real cargo.toml
COPY fuzzers/wsf/Cargo.toml fuzzers/wsf/
COPY fuzzers/wsf/.cargo/config fuzzers/wsf/.cargo/
RUN cd fuzzers/wsf && \
     CUSTOM_QEMU_DIR=/root/libafl_qemu \
     CUSTOM_QEMU_NO_CONFIGURE=1 \
     CUSTOM_QEMU_NO_BUILD=1 \
     NUM_JOBS=$(nproc) \
    cargo build

# Copy WSF fuzzer
COPY fuzzers fuzzers

RUN cd fuzzers/wsf && \
     CUSTOM_QEMU_DIR=/root/libafl_qemu \
     CUSTOM_QEMU_NO_CONFIGURE=1 \
     CUSTOM_QEMU_NO_BUILD=1 \
     NUM_JOBS=$(nproc) \
    cargo build

## Build WSF (should use already-built libafl_qemu and libafl crates)
#RUN cd fuzzers/wsf && \
#   cargo build --release

# RUN ./scripts/test_all_fuzzers.sh --no-fmt

ENTRYPOINT [ "/bin/bash" ]
