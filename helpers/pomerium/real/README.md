`helpers/pomerium/real` contains the real Pomerium stack assets used by the local helpers setup, adapted to point at the local `helpers-upstream` service.

Files:
- `config.yaml`: real Pomerium Core config for the `real` profile
- `certs/`: local TLS certs used by Pomerium and verify
- `keycloak/realm-export.json`: local OIDC realm bootstrap
