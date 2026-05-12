FROM eclipse-temurin:21-jre-jammy

ARG TBCLI_VERSION=3.5.0.73530
ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000

ENV DEBIAN_FRONTEND=noninteractive
ENV TBCLI_VERSION=${TBCLI_VERSION}
ENV USERNAME=${USERNAME}
ENV USER_UID=${USER_UID}
ENV USER_GID=${USER_GID}
ENV TOOLBOX_HOME=/home/${USERNAME}
ENV TOOLBOX_DATA_DIR=/home/${USERNAME}/.local/share/JetBrains/Toolbox
ENV TOOLBOX_CACHE_DIR=/home/${USERNAME}/.cache/JetBrains/Toolbox-CLI-dist

RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server \
    curl \
    ca-certificates \
    iproute2 \
    python3 \
    tar \
    procps \
  && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid "${USER_GID}" "${USERNAME}" \
  && useradd --uid "${USER_UID}" --gid "${USER_GID}" --create-home --shell /bin/bash "${USERNAME}" \
  && mkdir -p /var/run/sshd "${TOOLBOX_DATA_DIR}" "${TOOLBOX_CACHE_DIR}" \
  && chown -R "${USERNAME}:${USERNAME}" "${TOOLBOX_HOME}"

RUN mkdir -p /opt/helpers/docker /opt/helpers/state

COPY docker/entrypoint.sh /opt/helpers/docker/entrypoint.sh
COPY docker/bridge.py /opt/helpers/docker/bridge.py
COPY docker/agent-stack.sh /opt/helpers/docker/agent-stack.sh
COPY docker/watch_port.py /opt/helpers/docker/watch_port.py

RUN chmod +x /opt/helpers/docker/entrypoint.sh /opt/helpers/docker/bridge.py /opt/helpers/docker/agent-stack.sh /opt/helpers/docker/watch_port.py \
  && ssh-keygen -A \
  && printf '%s\n' \
    'Port 22' \
    'PermitRootLogin no' \
    'PasswordAuthentication yes' \
    'PubkeyAuthentication yes' \
    'UsePAM no' \
    > /etc/ssh/sshd_config

EXPOSE 22 5990 44000

ENTRYPOINT ["/opt/helpers/docker/entrypoint.sh"]
