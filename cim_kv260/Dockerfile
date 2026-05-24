FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV SHELL=/bin/bash
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
    iproute2 gawk gcc g++ git make net-tools dnsutils \
    libncurses5-dev libtinfo5 libncurses5 zlib1g-dev libssl-dev \
    flex bison libselinux1 gnupg wget diffstat chrpath socat \
    xterm autoconf libtool tar unzip texinfo gcc-multilib \
    build-essential libtool-bin screen pax libsdl1.2-dev \
    xvfb cpio python3 python3-pip python3-pexpect python3-git \
    python3-jinja2 xz-utils debianutils iputils-ping libegl1-mesa \
    libsdl1.2-dev file rsync bc less lsb-release python3-yaml \
    locales \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
