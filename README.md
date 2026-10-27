# avd-power-platform

Part of [avd-ops](https://avd-ops.dev/), the open toolkit for Azure Virtual Desktop.

> [!WARNING]
> **Personal project. Research and learning only. Not for production. No warranty.**
>
> - This is my own personal project, built on my own time **for research and learning**. It is **not affiliated with, endorsed by or supported by my employer**, Liquidware or Microsoft, and it does not represent their views, products or guidance.
> - **Do not run any of it in production** or against subscriptions and tenants that matter. Test it first in a dedicated lab subscription and tenant.
> - It is provided **"as is", without warranty of any kind**, under the [MIT License](LICENSE). You use it at your own risk.
> - **Contributions and forks are welcome and encouraged.** See [Contributing](#contributing).

## Role in avd-ops

Day-2 Power Platform and Power Automate workflow control plane (`avd-power-platform`), orchestrated by [avd-landing-zone](https://github.com/avd-ops/avd-landing-zone) ([decision 0009](https://avd-ops.dev/docs/decisions/0009-split-landing-zone-into-five-control-planes.html)).

## What it does

- Deploys dedicated Power Platform environments, strict DLP policies, and Bicep `Microsoft.PowerPlatform/enterprisePolicies` for VNet injection.
- Ships source-controlled, unpacked Power Automate solutions wired to `avd-azure` host pools and `avd-entra` groups.
- Automates self-service desktop and pool access requests in Microsoft Teams with manager approval gates.
- Automates approval-gated session-host drain, restart, personal desktop start-on-demand, and stale FSLogix profile alerts.
- Driven headlessly via Bicep, PowerShell 7, Bash, Python and the Power Platform CLI (`pac`) / Web API.

## Contracts

Consumes `entra-manifest.json` and `azure-outputs.json` and produces `power-platform-manifest.json` (environment ID, DLP policy state, and active workflow solution versions).

## Contributing

Fork it, open an issue or a pull request. Follow the family guardrails in [AGENTS.md](AGENTS.md): no tenant IDs, secrets, domains or customer names, and propose changes via pull request only. Contributions are accepted under the [MIT License](LICENSE).

## License and disclaimer

[MIT](LICENSE). Personal project, not for production, provided as is, not affiliated with the author's employer, Liquidware or Microsoft.
