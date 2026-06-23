# Toolbox Pomerium Plugin

## Build and Install

### Local install into Toolbox
Use:

```bash
./gradlew installPlugin
```

`installPlugin` builds and installs:
- fat plugin jar from `shadowJar`
- generated `extension.json`
- `src/main/resources/dependencies.json`
- `src/main/resources/icon.svg`

Target plugin directory is resolved by OS and plugin id (`jetbrains.toolbox.pomerium`):
- Windows: `%LOCALAPPDATA%/JetBrains/Toolbox/cache/plugins/jetbrains.toolbox.pomerium`
- macOS: `~/Library/Caches/JetBrains/Toolbox/plugins/jetbrains.toolbox.pomerium`
- Linux: `${XDG_DATA_HOME:-~/.local/share}/JetBrains/Toolbox/plugins/jetbrains.toolbox.pomerium`

### Build distributable zip
Use:

```bash
./gradlew pluginZip
```

## Custom URL Handling

The plugin handles Toolbox remote-dev URLs in `handleUri(...)`.

Expected URL shape:

```text
jetbrains://remote-dev/jetbrains.toolbox.pomerium/new-environment#<params>
```

Parameters can be passed in fragment (`#...`) or query (`?...`), fragment is preferred.

Required top-level params:
- `clientPomeriumRoute` (example: `tcp://backend.localhost:443`, URL-encoded in link; this is the backend route through Pomerium)
- `connectionKey` (raw Toolbox backend endpoint + fragment metadata, for example `tcp://0.0.0.0:5990#...`)
- `agentConnectionUrl` (HTTPS URL for agent connection through Pomerium)
- `agentAuth` (agent auth token)

Optional top-level params:
- `pomeriumPort` (defaults to `443`)
- `pomeriumInstance`
- `displayName`
- `projectPath`

Example:

```text
jetbrains://remote-dev/jetbrains.toolbox.pomerium/new-environment#clientPomeriumRoute=https%3A%2F%2Fbackend.localhost%3A443&connectionKey=https%3A%2F%2Fbackend.localhost%3A5990%23jt%3Dabc%26p%3DIU%26cb%3D261.24374.151&displayName=My%20Dev%20Env&projectPath=/home/dev/projects/test_project&agentConnectionUrl=https%3A%2F%2Fagent.localhost%3A443&agentAuth=token
```

`connectionKey` format:

```text
tcp://<host>:<port>#jt=<id>&p=<productCode>&fp=<fingerprint>&cb=<build>&newUi=<bool>&jb=<jbr>&remoteId=<id>
```

The plugin parses metadata from `connectionKey` fragment and uses it to initiate IDE attach flow.

## Toolbox IDE Discovery File

Toolbox can be pointed at an IDE distribution by writing an `environment.json`
file into the Toolbox data directory inside the upstream container. In the
Docker helper this is usually:

```text
/home/dev/.local/share/JetBrains/Toolbox/environment.json
```

Example file:

```json
{
  "tools": {
    "location": [
      {
        "path": "/opt/idea-dist"
      }
    ]
  }
}
```

For the helper stack, generate this interactively with:

```bash
cd helpers
./scripts/generate-toolbox-environment.sh
```

When prompted for the IDE path, use the path as seen from the upstream
container, for example `/opt/idea-dist`.

## Localization

Generate localization template:

```bash
./gradlew gettext
```

Then add `*.po` files to `src/main/resources/localization` using `<languageTag>.po` filenames.
