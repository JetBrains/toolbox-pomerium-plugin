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
- keeps runtime defaults such as fixed agent port and agent forwarder port

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
  - optionally starts the agent forwarder
- expects the IDE backend to listen directly on `helpers-upstream:5990`

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
cd helpers/scripts
```

### Start or recreate the real stack

```bash
./manage.sh recreate
```

This starts the full local Docker stack:

- `helpers-upstream`
- `keycloak`
- `verify`
- `real-pomerium`

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

- `clientPomeriumRoute`
- `pomeriumPort`
- `pomeriumInstance`
- `displayName`
- `agentPomeriumRoute`
- `connectionKey`
- `agentAuth`
- `agentTcpListenOnPort`
- `agentForwardPort`

After the prompts it:

- updates `link-helper.defaults.real.env`
- prints the generated `jetbrains://...` link

### 3. Apply the runtime settings

If you changed `agentTcpListenOnPort` or `agentForwardPort`, recreate the stack:

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
cp ../state/remote-instance.env.example ../state/remote-instance.env
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
  - if `LOCAL_TBCLI_ARCHIVE_PATH` is empty, the script downloads that archive locally into `helpers/state/.cache`

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

## Link Shape

The generated deep link intentionally mixes two kinds of backend addressing:

- `clientPomeriumRoute`
  - top-level Pomerium route for the IDE/backend flow
  - default: `https://backend.localhost:443`
  - this is the external hostname that the plugin should use when it asks Pomerium to open the backend tunnel

- `connectionKey`
  - raw Toolbox backend connection metadata
  - default host/port prefix: `https://backend.localhost:5990#...`
  - the fragment after `#` carries the IDE attach metadata (`jt`, `p`, `fp`, `cb`, and related fields)

- `displayName`
  - optional display label shown in Toolbox

- `agentPomeriumRoute`
  - top-level Pomerium route for the Toolbox Agent
  - default: `https://agent.localhost:443`

- `agentAuth`
  - auth token emitted by the running `tbcli agent` instance

In other words:

```text
clientPomeriumRoute = backend route through Pomerium
connectionKey        = raw backend listener + IDE metadata
displayName         = optional environment label
agentPomeriumRoute   = agent route through Pomerium
agentAuth            = live agent token
```

Current local Pomerium routes are:

```text
backend.localhost:443 -> helpers-upstream:5990
agent.localhost:443   -> helpers-upstream:44000
```

## Runtime Settings

The runtime settings live in:

- [link-helper.defaults.real.env](state/link-helper.defaults.real.env)

Machine-specific settings for `manage.sh` live in:

- common helper switches: `helpers/state/manage.local.env`
- dev Toolbox settings: `helpers/state/toolbox-dev.local.env`
- local IDEA paths and overlays: `helpers/state/local-idea.local.env`
- start from [manage.local.env.example](state/manage.local.env.example)
- start from [toolbox-dev.local.env.example](state/toolbox-dev.local.env.example)
- start from [local-idea.local.env.example](state/local-idea.local.env.example)

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

### `AGENT_FORWARD_PORT`

- empty value:
  - agent forwarder is disabled
  - this only works if `tbcli agent` itself listens on `44000`

- fixed value, for example:

```bash
AGENT_FORWARD_PORT='44000'
```

Then:

- `agent-stack.sh` starts a relay:
  - `0.0.0.0:44000 -> 127.0.0.1:<tbcli agent port>`
- if the agent already listens directly on `44000`, the relay is skipped

## Recommended Values

### Agent-only testing

Use:

```bash
AGENT_TCP_LISTEN_ON_PORT='44000'
```

This is the simplest stable setup if you only need the agent connection.

### Agent + backend testing

Use:

```bash
AGENT_TCP_LISTEN_ON_PORT='44000'
```

Use this only if you really need the backend listener path too, and make sure the IDE itself listens directly on `helpers-upstream:5990`.

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
cd helpers/scripts
cp ../state/manage.local.env.example ../state/manage.local.env
./write-link-defaults.sh
./link-helper.sh
./manage.sh recreate
./manage.sh print-link
```
