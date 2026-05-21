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

- [SETUP.md](/Users/Alisa.Afonina/work/toolbox/toolbox-pomerium-plugin/helpers/SETUP.md)

Most common commands:

```bash
cd helpers/scripts
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

- [manage.sh](/Users/Alisa.Afonina/work/toolbox/toolbox-pomerium-plugin/helpers/scripts/manage.sh)
- [write-link-defaults.sh](/Users/Alisa.Afonina/work/toolbox/toolbox-pomerium-plugin/helpers/scripts/write-link-defaults.sh)
- [link-helper.sh](/Users/Alisa.Afonina/work/toolbox/toolbox-pomerium-plugin/helpers/scripts/link-helper.sh)
- [link-helper.defaults.real.env](/Users/Alisa.Afonina/work/toolbox/toolbox-pomerium-plugin/helpers/state/link-helper.defaults.real.env)
- [remote-instance.env.example](/Users/Alisa.Afonina/work/toolbox/toolbox-pomerium-plugin/helpers/state/remote-instance.env.example)
- [install-tbcli-remote.sh](/Users/Alisa.Afonina/work/toolbox/toolbox-pomerium-plugin/helpers/scripts/install-tbcli-remote.sh)
- [write-link-defaults-remote.sh](/Users/Alisa.Afonina/work/toolbox/toolbox-pomerium-plugin/helpers/scripts/write-link-defaults-remote.sh)
