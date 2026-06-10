# OptionsEdge Infra

Infrastructure bootstrap for the OptionsEdge remote server.

Owns:
- `/home/options-edge` directory layout
- Docker installation with data-root under `/home/options-edge/data/docker`
- k3s/Kubernetes installation with data dir under `/home/options-edge/data/k3s`
- kubectl and Helm installation
- base observability installation

Application deployment belongs in `options-edge-deploy`, not this repo.
