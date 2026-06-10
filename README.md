# OptionsEdge Infra

Infrastructure bootstrap for the OptionsEdge remote server.

Owns:
- `/home/options-edge` directory layout
- Docker installation with data-root under `/home/options-edge/data/docker`
- k3s/Kubernetes installation with data dir under `/home/options-edge/data/k3s`
- kubectl and Helm installation
- base observability installation

Application deployment belongs in `options-edge-deploy`, not this repo.

## Remote Target

Default dev inventory:

```text
abhinav@192.168.100.252
```

Sudo password must be stored in Jenkins as a Secret Text credential. Do not commit passwords to this repo.

Default Jenkins credential id:

```text
options-edge-remote-sudo-password
```

## Safety Rule

The bootstrap job refuses to change Docker data-root on an existing Docker host unless `CONFIGURE_DOCKER_DATA_ROOT=true` is explicitly selected.

Changing Docker data-root can make existing containers/images appear missing because Docker starts using a new storage directory.
