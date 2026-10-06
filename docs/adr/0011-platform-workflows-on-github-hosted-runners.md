# Workflow platformy běží na GitHub-hosted runnerech

Workflow platformy běží na GitHub-hosted runnerech. Moduly, které potřebují privátní data plane (například API AKS nebo Key Vault s privátním endpointem), běží na samostatné runner group z modulu `runner-pool`. Workflow tak nasadí SLZ od nuly bez sítě v Azure.

## Considered Options

- Všechny workflow na `runner-pool`. Zamítnuto: `runner-pool` vyžaduje SLZ, takže bootstrap by musel nasadit SLZ lokálně.
- GitHub-hosted runnery s Azure private networking. Odloženo: Podpora na GHE.com není ověřená.

## Consequences

- State backend je storage account v management subscription s veřejným endpointem, protože k němu přistupují GitHub-hosted runnery. Přístup je jen přes Entra ID a shared key je vypnutý.
- Moduly s privátním data plane vyžadují `runner-pool` jako předpoklad.
