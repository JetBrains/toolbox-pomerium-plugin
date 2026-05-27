# Helpers

This directory contains the current real Pomerium + Toolbox Agent local setup.

There are now two ways to work with it:

- Docker-based local stack
- SSH-based real instance flow

Link shape:

- `clientPomeriumRoute` = backend route through Pomerium, usually `tcp://backend.localhost:443`
- `connectionKey` = raw backend listener plus IDE metadata, usually `tcp://0.0.0.0:5990#...`
- `displayName` = optional label shown in Toolbox
- `agentConnectionUrl` = agent route through Pomerium, usually `https://agent.localhost:443`
- `agentAuth` = live token from `tbcli agent`

Start here:

- [SETUP.md](SETUP.md)

Most common commands:

```bash
cd helpers/scripts
cp ../state/manage.local.env.example ../state/manage.local.env
./write-link-defaults.sh
./link-helper.sh
./manage.sh recreate
./manage.sh print-link
```

SSH / real instance flow:

```bash
cd helpers/scripts
cp ../state/remote-instance.env.example ../state/remote-instance.env
./install-tbcli-remote.sh
./write-link-defaults-remote.sh
./link-helper.sh
```

If the remote host has no internet, set this in `../state/remote-instance.env`:

```bash
REMOTE_HAS_INTERNET='no'
```

Then `install-tbcli-remote.sh` will upload a local `tbcli` archive instead of downloading on the remote host.

Generate local dev Pomerium secrets and certs:

```bash
./prepare-dev-pomerium-assets.sh
```

Main scripts:

- [manage.sh](scripts/manage.sh)
- [write-link-defaults.sh](scripts/write-link-defaults.sh)
- [link-helper.sh](scripts/link-helper.sh)
- [link-helper.defaults.real.env](state/link-helper.defaults.real.env)
- [manage.local.env.example](state/manage.local.env.example)
- [remote-instance.env.example](state/remote-instance.env.example)
- [install-tbcli-remote.sh](scripts/install-tbcli-remote.sh)
- [write-link-defaults-remote.sh](scripts/write-link-defaults-remote.sh)
