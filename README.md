[![FINOS - Incubating](https://cdn.jsdelivr.net/gh/finos/contrib-toolbox@master/images/badge-incubating.svg)](https://community.finos.org/docs/governance/lifecycle-stages/incubating)

# ccc-managed-k8s

Reference Terraform blueprints for opinionated, secure-by-default managed Kubernetes clusters on Azure (AKS), AWS (EKS), and Google Cloud (GKE).

The blueprints are executable reference implementations for [Common Cloud Controls](https://github.com/finos/common-cloud-controls) (CCC), the FINOS project that defines an industry-standard set of cloud controls. They show how CCC controls for managed Kubernetes map to Terraform that builds real clusters. The goal is to work with cloud providers and the wider industry on a common baseline for secure, production-grade Kubernetes.

## Who this is for

- Platform engineering, SRE, and application teams in financial services and other regulated industries who need a consistent, secure Kubernetes baseline across clouds.
- Teams that need to show their clusters align with the CCC controls catalog.
- Cloud providers looking for the baseline controls their managed Kubernetes services need to support.

## Blueprints

| Cloud | Directory | Status |
|-------|-----------|--------|
| Azure Kubernetes Service | [`aks/`](aks) | Initial implementation |
| Amazon Elastic Kubernetes Service | `eks/` | Planned |
| Google Kubernetes Engine | `gke/` | Planned |

Each blueprint is a standard Terraform module. Callers supply a small configuration covering the cluster name, region, networking, node-pool sizing, and identity bindings, then run the blueprint with `terraform plan` and `terraform apply` or from their own CI/CD pipeline.

## Usage example

```hcl
module "aks" {
  source = "github.com/finos/ccc-managed-k8s//aks"

  name               = "example-aks"
  location           = "eastus2"
  resource_group_id  = "/subscriptions/<subscription-id>/resourceGroups/example-rg"
  kubernetes_version = "1.32"
  # Networking, identity, encryption, and node pool inputs: see aks/README.md
}
```

See the [AKS blueprint README](aks/README.md) for the enforced baseline, all inputs, and a complete example.

## Development setup

You need [Terraform](https://developer.hashicorp.com/terraform/install) 1.9 or later. Each blueprint includes native Terraform tests (`*.tftest.hcl`) that run against mocked providers, so no cloud credentials are needed:

```sh
cd aks
terraform init -backend=false
terraform fmt -check -recursive
terraform validate
terraform test
```

These tests can be combined with CCC control tests, such as Rego policies, for end-to-end compliance checks.

## Dependencies

The blueprints reference public Terraform providers by version and do not redistribute third-party source code. The AKS blueprint uses:

- [`Azure/azapi`](https://registry.terraform.io/providers/Azure/azapi/latest) (MPL-2.0)

## Roadmap

1. AKS blueprint: initial implementation (this release).
2. Map each blueprint setting to the CCC controls catalog.
3. Add the EKS and GKE blueprints.
4. Pair the Terraform tests with CCC control tests for end-to-end compliance checks.

## Contributing

For questions, bugs, or feature requests, please open an [issue](https://github.com/finos/ccc-managed-k8s/issues). For broader discussion of the controls themselves, see the [Common Cloud Controls](https://github.com/finos/common-cloud-controls) project.

To submit a contribution:

1. Fork it (<https://github.com/finos/ccc-managed-k8s/fork>)
2. Create your feature branch (`git checkout -b feature/fooBar`)
3. Read our [contribution guidelines](CONTRIBUTING.md) and [Community Code of Conduct](https://www.finos.org/code-of-conduct)
4. Commit your changes (`git commit -am 'Add some fooBar'`)
5. Push to the branch (`git push origin feature/fooBar`)
6. Create a new Pull Request

_NOTE:_ Pull requests must follow this repository’s contribution policy. FINOS projects typically use **DCO** (signed commits) and/or **CLA** via [EasyCLA](https://community.finos.org/docs/governance/Software-Projects/easycla), depending on configuration. Read [FINOS Contribution Requirements](https://community.finos.org/docs/governance/Software-Projects/contribution-compliance-requirements) and the [Technical Charter](technical-charter.pdf) example referenced from [CONTRIBUTING.md](CONTRIBUTING.md) before contributing.

*Questions about CLA, DCO, or EasyCLA? Email [help@finos.org](mailto:help@finos.org)*

## License

Copyright 2026 FINOS

Distributed under the [Apache License, Version 2.0](http://www.apache.org/licenses/LICENSE-2.0).

SPDX-License-Identifier: [Apache-2.0](https://spdx.org/licenses/Apache-2.0)
