# devsecops-platform

Modulární DevSecOps platforma pro zákazníky s GitHub Enterprise Cloud s data residency (GHE.com) a EMU na Azure Sovereign Landing Zone.

- [Glosář](CONTEXT.md)
- [Rozhodnutí (ADR)](docs/adr/)

## Struktura repozitáře

| Cesta | Obsah |
|---|---|
| `modules/<name>/` | Manifest `module.yaml`, Terraform root a README se specifikací modulu. |
| `schemas/module.schema.json` | JSON Schema Module manifest (manifest modulu). |
| `schemas/instance.schema.json` | JSON Schema konfigurace instance. |
| `tools/` | Runner modulu a generátor workflow v PowerShell 7, testy Pester. |
| `.github/workflows/` | CI zdrojového repozitáře. |
| `templates/instance/` | Šablona repozitáře instance: vygenerovaný workflow nasazení, workflow vendoringu, příklad `instance.yaml`. |

## Nástroje platformy

Nástroje vyžadují PowerShell 7.4 nebo novější. Verze modulů PowerShellu určuje `tools/requirements.psd1`. Následující příkazy spusť z kořene repozitáře v PowerShellu:

```powershell
.\tools\Install-ToolDependencies.ps1 -Development
.\tools\Test-ModuleManifests.ps1 -Verbose
.\tools\Generate-DeploymentWorkflow.ps1
.\tools\Test-PowerShell.ps1
.\tools\Invoke-Tests.ps1
```

Instalační skript stáhne chybějící verze modulů z PowerShell Gallery do rozsahu `CurrentUser`. Bez `-Development` instaluje jen parser YAML pro běh nástrojů.

### Module manifest (manifest modulu)

Generátor čte Module manifest v cestě `modules/<name>/module.yaml`. Hodnota `name` musí odpovídat adresáři a používat malá písmena, číslice a pomlčky; první znak musí být písmeno. Adresář bez manifestu představuje pouze specifikaci a generátor ho nezahrne do workflow.

```yaml
name: example
description: Příklad manifestu modulu.
prerequisites: []
manualSteps:
  - id: verify-access
    description: Platformní tým ověří přístup po nasazení.
permissions:
  azure:
    - role: Reader
      scope: /subscriptions/00000000-0000-0000-0000-000000000000
  microsoftGraph:
    - Group.Create
  githubApp:
    contents: read
  adminPat:
    - enterprise-rulesets
```

Všechny položky příkladu jsou povinné. Prázdné seznamy a prázdná mapa `githubApp` znamenají, že dané kroky ani oprávnění nejsou potřeba. `azure` deklaruje role a jejich rozsah, `microsoftGraph` názvy oprávnění, `githubApp` mapu oprávnění na `read` nebo `write` a `adminPat` prostředky vyžadující admin PAT. Module manifest nesmí obsahovat tokeny ani jiná secrets. Schéma odmítá neznámé položky a neplatné typy. Generátor navíc odmítá opakované identifikátory Manual step (ruční krok), neexistující Prerequisite (předpoklad) a cykly.

### Generování workflow a výběr

Generátor zapisuje `templates/instance/.github/workflows/deploy.yml`. Přepínač `-Check` pouze porovná obsah a při rozdílu skončí chybou; soubor nezmění. Výstup používá UTF-8 bez BOM a konce řádků LF. Pořadí adresářů ani pořadí Prerequisite v Module manifest nemění výstup.

```powershell
.\tools\Generate-DeploymentWorkflow.ps1 -Check
.\tools\Generate-DeploymentWorkflow.ps1 -ModulesPath .\tools\tests\fixtures\modules -OutputPath .\tools\tests\fixtures\deploy.yml
```

Mapa `modules` v Instance configuration (konfigurace instance), v souboru `instance.yaml`, přiřazuje názvu Module (modul) jeho konfiguraci:

```yaml
modules:
  application:
    parameters: {}
```

`Select-InstanceModules.ps1` vrátí seřazené JSON pole názvů vybraných Module včetně všech jejich Prerequisite. Prázdná mapa vrátí `[]`. Neznámý název nebo jiný typ konfigurace způsobí chybu s cestou `$.modules`. Volitelný `-GitHubOutputPath` připojí stejný výběr jako výstup jobu `modules`.

```powershell
.\tools\Select-InstanceModules.ps1 -ModulesPath .\tools\tests\fixtures\modules -InstancePath .\instance.yaml
```

Workflow nejprve spustí job `select`. Každý Module má vlastní job `module_<name>`, environment `<name>-plan` a `needs` pro job `select` i své přímé Prerequisite. Podmínka jobu vyžaduje úspěšný výběr, členství ve výběru a úspěšné Prerequisite. Nevybraný job se přeskočí. Selhání Prerequisite blokuje joby, které ho vyžadují, nikoli nezávislou větev grafu.

**Současný rozsah:** produkční adresáře zatím obsahují jen specifikace. Commitnutá šablona proto obsahuje jen job `select`; úplný graf ověřuje fixture workflow v `tools/tests/fixtures/deploy.yml`. Generátor připravuje ručně spouštěný workflow pro `plan` a očekává vendorovaný Release (release) v `platform/`. Runner `platform/tools/Invoke-Module.ps1` a úplné schéma Instance configuration dodá [#8](https://github.com/msucharda/devsecops-platform/issues/8). Autentizaci, přenos výstupů, triggery PR a apply a pravidla schválení dodá [#9](https://github.com/msucharda/devsecops-platform/issues/9). Bootstrap zůstává lokálním krokem; jeho zapojení do finální šablony určí tyto navazující issues.

### Testy a CI

Testy Pester volají veřejné skripty generátoru a výběru Module. Kontrolují výsledné YAML, JSON a chyby pomocí fixture bez cloudu. Jeden soubor můžeš spustit přímo:

```powershell
Import-Module Pester -RequiredVersion 5.7.1
Invoke-Pester -Path .\tools\tests\WorkflowGenerator.Tests.ps1 -Output Detailed
```

Workflow `Source CI` spouští Pester, syntaktickou a statickou kontrolu PowerShellu, validaci Module manifest a kontrolu aktuálnosti obou commitnutých workflow. `Get-TerraformRoots.ps1` vyhledá v repozitáři každý adresář se soubory `.tf` nebo `.tf.json`, včetně fixture; vynechá `.git`, `.terraform` a symbolické adresáře. CI na každém nalezeném rootu spustí `terraform fmt -check`, `terraform init -backend=false`, `terraform validate`, tflint a Trivy. Nález Trivy úrovně `HIGH` nebo `CRITICAL` způsobí chybu CI. Pokud repozitář nemá žádný Terraform root, CI tuto část přeskočí.

Stejné kontroly Terraformu můžeš spustit lokálně s nainstalovanými nástroji `terraform`, `tflint` a `trivy`:

```powershell
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$roots = .\tools\Get-TerraformRoots.ps1 | ConvertFrom-Json
foreach ($root in $roots) {
    terraform "-chdir=$root" fmt -check -diff
    terraform "-chdir=$root" init -backend=false -input=false
    terraform "-chdir=$root" validate
    tflint "--chdir=$root" --init
    tflint "--chdir=$root"
    trivy config --exit-code 1 --severity HIGH,CRITICAL $root
}
```

## Moduly

| Modul | Schopnost | Předpoklady |
|---|---|---|
| `bootstrap` | State backend, identity modulů pro plan a apply, organizace platformy, repozitář instance, dvě GitHub App. Člen platformního týmu ho spustí jednou lokálně. | – |
| `emu-identity` | Skupiny a přiřazení aplikací v Entra ID: platformní tým (Enterprise Owner), security tým (security manager ve všech organizacích), uživatelé Copilotu (licence). Servisnímu uživateli přiřadí roli Enterprise Owner. SCIM ze skupin vytvoří enterprise týmy. | `bootstrap` |
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
- JSON Schema z release validuje `instance.yaml`. Z manifestů modulů vygeneruje CI zdrojového repozitáře workflow s jobem pro každý modul (ADR 0014).
- State backend je storage account v management subscription. Má zapnutý versioning, soft delete a lock. Každý modul má vlastní kontejner.
- Každý modul má vlastní managed identity pro plan a pro apply (ADR 0015).
- Workflow zapíše nepotvrzené ruční kroky do job summary jako varování. Platformní tým potvrdí ruční krok v `instance.yaml` přes PR.
- Po merge PR schválí platformní tým jednou celý běh apply. Běh modulu `enterprise-baseline` navíc schvaluje security tým.
- Každou noc proběhne plan všech modulů na větvi `main`. Pokud plan najde drift, workflow otevře nebo aktualizuje issue v repozitáři instance.

## Regiony

- `regions.primary` je povinný, `regions.secondary` volitelný.
- Ve verzi 1 obsahuje sekundární region jen druhý hub s Azure Firewall, propojený s primárním hubem peeringem. Politika SLZ povolí obě lokace.
- Management a sdílená aplikační landing zone jsou jen v primárním regionu.

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
- Teardown vrátí politiky enterprise na výchozí hodnoty GitHubu a smaže enterprise rulesety, code security configurations a custom patterns. Enterprise jako ruční předpoklad zůstane.

## Testování release

- CI ve zdrojovém repozitáři spouští `terraform fmt`, `terraform validate`, tflint, Trivy, validaci JSON Schema a kontrolu cyklů v předpokladech.
- Každý release candidate se nasadí celý na referenční instanci.
- Před každým minor release proběhne teardown referenční instance a její nové nasazení.
