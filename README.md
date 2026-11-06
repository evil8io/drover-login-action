<p align="left">
  <img src="https://img.shields.io/github/license/evil8io/drover-login-action"/>
  <a href="https://github.com/evil8io/drover-login-action/releases">
    <img src="https://img.shields.io/github/v/release/evil8io/drover-login-action"/>
  </a>
  <a href="https://github.com/evil8io/drover-login-action/actions/workflows/ci.yml">
    <img src="https://github.com/evil8io/drover-login-action/actions/workflows/ci.yml/badge.svg"/>
  </a>
</p>

# drover-login-action

**drover-login-action** is a GitHub Action for a workflow that deploys to a project of a cluster that Rancher manages. The action logs in to [OpenBao](https://openbao.org) with the OIDC token of the workflow. OpenBao returns a token of a ServiceAccount of the project, valid for 15 minutes by default. The action writes a kubeconfig for that token. In the later steps of the job, `kubectl` and `helm` connect to the cluster through Rancher, without a stored secret.

OpenBao is part of the chart of [drover](https://github.com/evil8io/drover), a set of tenancy extensions for Rancher.

## Requirements

- The [drover chart](https://github.com/evil8io/charts/tree/main/charts/drover) is installed in the Rancher management cluster, with `projectSync.serviceAccounts.enabled` set to `true`.
- The project has a trust statement for the repository. See [Trust statement](#trust-statement).
- The job has the permission `id-token: write`.
- The runner can connect to OpenBao and to Rancher. The runner has `bash`, `curl`, and `jq`. The GitHub-hosted runners have these tools.

## Usage

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write
    steps:
      - uses: actions/checkout@v5

      - uses: evil8io/drover-login-action@v0
        with:
          openbao-url: https://rancher-tokens.example.com
          rancher-url: https://rancher.example.com
          cluster: c-m-4x2kq7bd
          project: p-abc12
          role: project-member
          statement: deploy-main
          namespace: shop

      - run: kubectl get pods

      - run: helm upgrade --install shop ./chart
```

By default, the action sets `KUBECONFIG` for the later steps of the job. The kubeconfig contains one context: the cluster through the Rancher proxy, the token, and the namespace of the input `namespace`.

Before the release 1.0, release-please raises the minor version for a breaking change. The release workflow then moves the tag `v0` to that release. Pin a release tag or a commit when the workflow must not get such a change.

## Trust statement

In the trust annotation of the Rancher project, a project owner declares which workflows get a token. The owner also declares the project role of the token. With the statement below, OpenBao gives the workflows on the branch `main` of the repository with the ID `123456789` a token with the role `project-member`:

```json
{
  "statements": [
    {
      "name": "deploy-main",
      "jwt": {
        "issuer": "github",
        "claims": {"repository_id": "123456789", "ref": "refs/heads/main"}
      },
      "role": "project-member"
    }
  ]
}
```

- The repository ID is in the output of `gh api repos/<owner>/<repo> --jq .id`. GitHub keeps the ID when you rename the repository.
- `claims` can contain any claim of the [GitHub OIDC token](https://docs.github.com/en/actions/concepts/security/openid-connect) except `aud`, for example `environment` or `workflow_ref`. A value is a string or a list of strings. An admin of the platform sets the claims that every statement must contain. The admin can also limit the values of a claim.
- Pass the `name` of the statement in the input `statement`. Pass the `role` of the statement in the input `role`.

The format of the annotation is in the [README of the drover chart](https://github.com/evil8io/charts/tree/main/charts/drover#trust-annotation). The rules of a statement are in the [project-sync document of drover](https://github.com/evil8io/drover/blob/main/docs/project-sync.md).

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `openbao-url` | yes | | The URL of OpenBao, for example `https://rancher-tokens.example.com`. |
| `rancher-url` | yes | | The URL of Rancher, for example `https://rancher.example.com`. |
| `cluster` | yes | | The ID of the Rancher cluster, for example `c-m-4x2kq7bd`. |
| `project` | yes | | The ID of the Rancher project, for example `p-abc12`. |
| `role` | yes | | The project role of the token: `project-owner`, `project-member`, or `read-only`. |
| `statement` | yes | | The name of the statement in the trust annotation of the project. |
| `issuer` | no | `github` | The name of the JWT issuer in OpenBao. |
| `audience` | no | the OpenBao URL | The audience of the OIDC token. It must equal the audience of the login roles, `global.broker.audience` of the drover chart. With the chart default, that audience is the OpenBao URL. |
| `ttl` | no | | The lifetime of the token, for example `30m`. The default is the default lifetime of a token on the platform. |
| `namespace` | no | | The namespace of the kubeconfig context. |
| `kubeconfig` | no | a new file under `RUNNER_TEMP` | The absolute path of the kubeconfig. |
| `export-kubeconfig` | no | `true` | With `true`, the action sets `KUBECONFIG` to the path of the kubeconfig for the later steps of the job. |
| `ca-certificate` | no | | One or more PEM certificates of the private CA that signed the TLS certificates of OpenBao and Rancher. curl uses the certificates for the requests to OpenBao. The action writes the certificates into the kubeconfig for Rancher. |
| `insecure-skip-tls-verify` | no | `false` | With `true`, curl does not verify the TLS certificate of OpenBao. The action also writes `insecure-skip-tls-verify: true` into the kubeconfig, so kubectl and helm do not verify the TLS certificate of Rancher. A host between the runner and OpenBao or Rancher can then read the tokens. Do not set it together with `ca-certificate`, because kubectl and helm refuse a kubeconfig with both. |

The action does not use `ca-certificate` or `insecure-skip-tls-verify` for the OIDC token request to GitHub.

The cluster ID and the project ID are in the output of `kubectl get projects.management.cattle.io --all-namespaces` in the Rancher management cluster. They are also in the trust status annotation of the project, `managed.drover.evil8.io/trust-policy-status`, in the `login.role` of each ready statement: `<cluster ID>_<project ID>_<statement>`.

## Outputs

| Output | Description |
|---|---|
| `kubeconfig` | The path of the kubeconfig. |
| `server` | The URL of the cluster API through Rancher, `<rancher-url>/k8s/clusters/<cluster>`. |
| `token` | The ServiceAccount token. The runner masks it in the log. |
| `expires-in` | The lifetime of the token in seconds, as OpenBao reports it. |

## The token

- With the token, a client has the Kubernetes rights of the project role in every namespace of the project: `admin` for `project-owner`, `edit` for `project-member`, and `view` for `read-only`. With `project-owner` or `project-member`, the client can also create a namespace in the project.
- The default lifetime of a token on the platform is 15 minutes. When a job needs the token for longer than the default lifetime, set `ttl`, up to the maximum of the platform. You can also run the action again.
- A single token cannot be revoked before it expires. An admin of the platform can delete the ServiceAccount of the project role. Kubernetes then rejects every token of that ServiceAccount. Do not set a `ttl` above the time that the job needs.
- The runner masks the OIDC token, the OpenBao token of the login, and the ServiceAccount token in the log. The file mode of the kubeconfig is `0600`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[Apache License 2.0](LICENSE)
