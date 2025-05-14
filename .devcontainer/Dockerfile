# [Choice] alpine,...
ARG VARIANT="alpine"
FROM erlang:${VARIANT}

ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=1001
ARG GRPNAME=vscodegrp

ENV DEBIAN_FRONTEND=noninteractive

RUN apk update

RUN apk add make
RUN apk add git
RUN apk add curl

RUN apk add htop
RUN apk add file

RUN apk add gcompat

RUN apk add --no-cache bash
RUN apk add --no-cache openssh

RUN wget -O - https://github.com/WhatsApp/erlang-language-platform/releases/download/2025-05-13/elp-linux-x86_64-unknown-linux-gnu-otp-27.1.tar.gz | tar -xz -C /usr/bin

RUN addgroup -g $USER_GID $GRPNAME \
    && adduser -u $USER_UID -g $GRPNAME -D $USERNAME
USER $USERNAME
