# Real Pomerium Setup

This directory contains the current `real`-only workflow for the local Pomerium + Toolbox Agent setup.

There is no mode switching in the user-facing scripts anymore. The scripts below assume the real Pomerium stack.

There are two supported operational paths:

- Docker-based local stack
- SSH-based real instance flow

## Files

- `manage.sh`
  - starts the real stack
  - restarts the agent
  - prints live metadata from the running container
  - checks Pomerium routes

- `write-link-defaults.sh`
  - reads live agent data from the running container
  - updates `link-helper.defaults.real.env`
  - keeps runtime defaults such as fixed agent port and backend relay port

- `link-helper.sh`
  - reads `link-helper.defaults.real.env`
  - asks for link fields interactively
  - writes updated defaults back to the same file
  - generates the final `jetbrains://...` link locally

- `link-helper.defaults.real.env`
  - shared source of truth for helper defaults and runtime settings
  - mounted into `helpers-upstream` as `/opt/helpers/state/link-helper.defaults.real.env`

- `agent-stack.sh`
  - starts `tbcli agent`
  - reads runtime settings from the mounted defaults file
  - optionally fixes the agent TCP port
  - optionally starts the backend relay

- `install-tbcli-remote.sh`
  - connects to a real machine over SSH
  - installs `tbcli` there if it is missing
  - verifies that `tbcli --version` works

- `write-link-defaults-remote.sh`
  - connects to a real machine over SSH
  - starts or restarts `tbcli agent` there
  - reads live `agentAuth`
  - tries to read a live join link
  - updates `link-helper.defaults.real.env`

- `remote-instance.env.example`
  - example SSH config for the remote-instance flow

## Local Pomerium Secrets and Certs

Generate local-only dev secrets, `config.yaml`, and mkcert-based certs:

```bash
./prepare-dev-pomerium-assets.sh
```

This script writes:

- `helpers/pomerium/real/config.yaml`
- `helpers/pomerium/real/certs/*.pem`
- `helpers/state/pomerium-real.local.env`

These files are intended to stay out of git.

## Main Commands

Run from:

```bash
cd /Users/Alisa.Afonina/work/toolbox/toolbox-pomerium-plugin/helpers/scripts
```

### Start or recreate the real stack

```bash
./manage.sh recreate
```

### Restart only the Toolbox Agent

```bash
./manage.sh restart-agent
```

### Show recent logs

```bash
./manage.sh logs
```

### Print current live link from the container

```bash
./manage.sh print-link
```

### Print current live JSON metadata from the container

```bash
./manage.sh print-json
```

### Check the agent route through real Pomerium

```bash
./manage.sh check-connect agent
```

### Check the backend route through real Pomerium

```bash
./manage.sh check-connect backend
```

## Recommended Workflow

### Docker-based local stack

### 1. Refresh defaults from the running container

This keeps `agentAuth` in sync with the current live agent:

```bash
./write-link-defaults.sh
```

### 2. Edit or confirm the link and runtime settings

```bash
./link-helper.sh
```

The helper asks for:

- `pomeriumRoute`
- `pomeriumPort`
- `pomeriumInstance`
- `agentConnectionUrl`
- `connectionKey`
- `agentAuth`
- `agentTcpListenOnPort`
- `backendRelayPort`

After the prompts it:

- updates `link-helper.defaults.real.env`
- prints the generated `jetbrains://...` link

### 3. Apply the runtime settings

If you changed `agentTcpListenOnPort` or `backendRelayPort`, recreate the stack:

```bash
./manage.sh recreate
```

### 4. Print the current live link if needed

```bash
./manage.sh print-link
```

### SSH-based real instance flow

1. Create the SSH config file:

```bash
cp /Users/Alisa.Afonina/work/toolbox/toolbox-pomerium-plugin/helpers/state/remote-instance.env.example \
   /Users/Alisa.Afonina/work/toolbox/toolbox-pomerium-plugin/helpers/state/remote-instance.env
```

2. Fill in:

- `SSH_HOST`
- `SSH_PORT`
- `SSH_USER`
- optionally `SSH_KEY_PATH`
- optionally `REMOTE_HAS_INTERNET`
- optionally `LOCAL_TBCLI_ARCHIVE_PATH`
- optionally `TB_JAVA_HOME`
- optionally `REMOTE_JOIN_LINK_COMMAND`

Internet behavior:

- default:
  - `REMOTE_HAS_INTERNET='yes'`
  - the remote host downloads `tbcli` itself
- offline remote host:
  - `REMOTE_HAS_INTERNET='no'`
  - the script uploads a local `tbcli-<version>.tar.gz` archive to the remote host
  - if `LOCAL_TBCLI_ARCHIVE_PATH` is empty, the script downloads that archive locally into `helpers/.cache`

3. Install `tbcli` on the remote machine:

```bash
./install-tbcli-remote.sh
```

4. Refresh local defaults from the remote machine:

```bash
./write-link-defaults-remote.sh
```

5. Edit or confirm the link locally:

```bash
./link-helper.sh
```

## Runtime Settings

The runtime settings live in:

- [link-helper.defaults.real.env](/Users/Alisa.Afonina/work/toolbox/toolbox-pomerium-plugin/helpers/state/link-helper.defaults.real.env)

### `AGENT_TCP_LISTEN_ON_PORT`

- empty value:
  - `tbcli agent` chooses a random free loopback port
  - `agent-stack.sh` starts a bridge on `44000`

- fixed value, for example:

```bash
AGENT_TCP_LISTEN_ON_PORT='44000'
```

Then:

- `tbcli agent` starts directly on `44000`
- the `44000` bridge is skipped

### `BACKEND_FORWARD_PORT`

- empty value:
  - backend relay is disabled

- fixed value, for example:

```bash
BACKEND_FORWARD_PORT='5990'
```

Then:

- `agent-stack.sh` starts a relay:
  - `container_ip:5990 -> 127.0.0.1:5990`

## Recommended Values

### Agent-only testing

Use:

```bash
AGENT_TCP_LISTEN_ON_PORT='44000'
BACKEND_FORWARD_PORT=''
```

This is the simplest stable setup if you only need the agent connection.

### Agent + backend testing

Use:

```bash
AGENT_TCP_LISTEN_ON_PORT='44000'
BACKEND_FORWARD_PORT='5990'
```

Use this only if you really need the backend listener path too.

## Link Model

The intended external addresses are:

- agent:
  - `https://agent.localhost:443`

- backend:
  - `https://backend.localhost:443`

The intended internal targets are:

- agent:
  - `helpers-upstream:44000`

- backend:
  - `helpers-upstream:5990`

That means:

- external `443` belongs to Pomerium
- internal `44000` and `5990` belong to `helpers-upstream`

## Troubleshooting

### Re-read live agent auth into defaults

```bash
./write-link-defaults.sh
```

### Check whether Pomerium route matches

```bash
./manage.sh check-connect agent
./manage.sh check-connect backend
```

Typical meanings:

- `200 OK`
  - route matched and tunnel opened

- `302 Found`
  - route matched, but auth/session is required

- `404 Not Found`
  - route does not match current Pomerium config

### See current agent listen port

```bash
./manage.sh print-json
```

Look at:

- `agent_listen_on`
- `agent_port`

### Enter the container

```bash
./manage.sh shell
```

## Minimal Working Sequence

If you just want the setup running again:

```bash
cd /Users/Alisa.Afonina/work/toolbox/toolbox-pomerium-plugin/helpers/scripts
./write-link-defaults.sh
./link-helper.sh
./manage.sh recreate
./manage.sh print-link
```
