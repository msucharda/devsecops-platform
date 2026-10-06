# devsecops-platform

Modulární DevSecOps platforma pro zákazníky s GitHub Enterprise Cloud s data residency (GHE.com) a EMU na Azure Sovereign Landing Zone.

- [Glosář](CONTEXT.md)
- [Rozhodnutí (ADR)](docs/adr/)

## Moduly

| Modul | Schopnost | Předpoklady |
|---|---|---|
| `bootstrap` | State backend, identity pro plan a apply, organizace platformy, repozitář instance, dvě GitHub App. Člen platformního týmu ho spustí jednou lokálně. | – |
| `emu-identity` | Skupiny a přiřazení aplikací v Entra ID: platformní tým (Enterprise Owner), security tým (security manager ve všech organizacích), uživatelé Copilotu (licence) a servisní uživatel pro PAT. SCIM ze skupin vytvoří enterprise týmy. | `bootstrap` |
| `organizations` | Organizace akcí a organizace workloadů. | `emu-identity` |
| `actions-catalog` | Vendorované akce v organizaci akcí. | `organizations` |
| `enterprise-baseline` | Enterprise rulesety, code security configurations, politika akcí, custom patterns. | `actions-catalog` |
| `required-workflows` | Povinná workflow vynucená rulesetem. | `enterprise-baseline` |
| `copilot-catalog` | Vendorované skilly a agenti pro Copilot. | `organizations` |
| `copilot-workstation` | Copilot app a spravovaná nastavení přes Intune. | `emu-identity` |
| `slz-core` | Hierarchie management groups a politiky SLZ. | `bootstrap` |
| `slz-management` | Log Analytics a monitoring platformy. | `slz-core` |
| `audit-streaming` | Streamování audit logu enterprise do Event Hubs. | `slz-management` |
| `slz-connectivity` | Hub VNet s Azure Firewall. | `slz-core` |
| `shared-app-lz` | Spoke, privátní AKS, ACR pro staging a prod, Key Vault, Defender for Containers. | `slz-connectivity`, `slz-management` |
| `runner-pool` | Self-hosted runnery na ACA s managed identity v privátní síti. | `shared-app-lz`, `actions-catalog` |
| `image-promotion` | Povýšení image ze staging do prod po skenu. | `runner-pool`, `required-workflows` |
| `workload-onboarding` | Repozitář, skupina týmu workloadu, namespace a identita pro nový workload. | `image-promotion` |

Modul `lz-vending` (subscription pro workload) přijde později.

## Pořadí implementace

1. GitHub governance: `bootstrap`, `emu-identity`, `organizations`, `actions-catalog`, `enterprise-baseline`. Přírůstek končí testem teardownu.
2. SLZ: `slz-core`, `slz-management`, `slz-connectivity`, `audit-streaming`.
3. Dodávka: `shared-app-lz`, `runner-pool`, `required-workflows`, `image-promotion`, `workload-onboarding`.
4. Copilot: `copilot-catalog`, `copilot-workstation`.

Návrh přírůstků 2–4 se upřesní na začátku každého přírůstku.

## Nasazení instance

- Repozitář instance obsahuje adresář `platform/` s vendorovaným release, soubor `instance.yaml` a workflow. Adresář `platform/` mění jen PR importu release.
- JSON Schema z release validuje `instance.yaml`. Workflow určí pořadí modulů z manifestů modulů.
- State backend je storage account v management subscription. Má zapnutý versioning, soft delete a lock. Každý modul má vlastní kontejner.
- Workflow zapíše nepotvrzené ruční kroky do job summary jako varování. Platformní tým potvrdí ruční krok v `instance.yaml` přes PR.
- Po merge PR schválí platformní tým jednou celý běh apply. Běh modulu `enterprise-baseline` navíc schvaluje security tým.
- Každou noc proběhne plan všech modulů na větvi `main`. Pokud plan najde drift, workflow otevře nebo aktualizuje issue v repozitáři instance.

## Názvy

- `instance.name` má 2–8 znaků. Organizace se jmenují `{name}-platform`, `{name}-actions` a `{name}-workloads`.
- Prostředky v Azure používají zkratky typů prostředků podle CAF.
- Identifikátor nasazení je jen v názvech podle ADR 0008.

## Release a upgrade

- Release má jednu verzi SemVer pro všechny moduly (ADR 0013).
- Jeden opakovaně použitelný workflow vendoringu importuje release platformy, akce i skilly. Workflow stáhne zdroj podle tagu, ověří attestaci, pokud existuje, a otevře PR s diffem.

## Teardown

- Workflow `teardown` odstraní moduly v obráceném pořadí předpokladů, kromě `bootstrap`. Modul `bootstrap` odstraní lokální skript.
- Workflow se spustí jen při `teardown.allowed: true` v `instance.yaml`. Výchozí hodnota je `false`.
- Environment `teardown` vyžaduje schválení od platformního týmu i od security týmu.

## Testování release

- CI ve zdrojovém repozitáři spouští `terraform fmt`, `terraform validate`, tflint, Trivy, validaci JSON Schema a kontrolu cyklů v předpokladech.
- Každý release candidate se nasadí celý na referenční instanci.
- Před každým minor release proběhne teardown referenční instance a její nové nasazení.
