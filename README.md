# devsecops-platform

Modulární DevSecOps platforma pro zákazníky s GitHub Enterprise Cloud s data residency (GHE.com) a EMU na Azure Sovereign Landing Zone.

- [Glosář](CONTEXT.md)
- [Rozhodnutí (ADR)](docs/adr/)
- [Příprava a akceptace referenční instance](docs/reference-instance.md)

## Struktura repozitáře

| Cesta | Obsah |
|---|---|
| `modules/<name>/` | Manifest `module.yaml`, Terraform root a README se specifikací modulu. |
| `schemas/module.schema.json` | JSON Schema Module manifest (manifest modulu). |
| `schemas/instance.schema.json` | JSON Schema konfigurace instance. |
| `tools/` | Lokální bootstrap Azure a GitHubu, průvodce přípravou referenční instance, runner modulu a generátor workflow v PowerShell 7, testy Pester. |
| `.github/workflows/` | CI zdrojového repozitáře. |
| `templates/instance/` | Šablona repozitáře instance: vygenerovaný workflow nasazení, příklad `instance.yaml`, CODEOWNERS a kontrakt bootstrapu. |

## Nástroje platformy

Nástroje vyžadují PowerShell 7.4 nebo novější. Verze modulů PowerShellu určuje `tools/requirements.psd1`. Následující příkazy spusť z kořene repozitáře v PowerShellu:

```powershell
.\tools\Install-ToolDependencies.ps1 -Development
.\tools\Test-ModuleManifests.ps1 -Verbose
.\tools\Test-InstanceConfiguration.ps1 -InstancePath .\templates\instance\instance.yaml
.\tools\Generate-DeploymentWorkflow.ps1
.\tools\Test-PowerShell.ps1
.\tools\Invoke-Tests.ps1
```

Instalační skript stáhne chybějící verze modulů z PowerShell Gallery do rozsahu `CurrentUser`. Bez `-Development` instaluje jen parser YAML pro běh nástrojů.

### Instance configuration (konfigurace instance)

`schemas/instance.schema.json` popisuje soubor `instance.yaml`. Výchozí příklad je v `templates/instance/instance.yaml`. Validátor, výběr modulů i runner používají stejné schéma. Chyba uvádí cestu k položce, například `$.instance.name` nebo `$.credentials.organizations.plan.githubApp`.

Validátor načítá pouze pevná schémata `instance.schema.json` a `module.schema.json` z adresáře `schemas/` vedle nástrojů. Před validací spojí jejich definice do jednoho schématu s lokálními odkazy. Povoluje jen `#/definitions/<name>` a `module.schema.json#/definitions/<name>` s existující definicí; odmítne jiné soubory, vzdálená URI, chybějící definice i `$id`, který by změnil význam odkazu. Nestahuje schémata podle URI z konfigurace a nezapíná `FetchExternalReference`. Tento postup zachovává kontrakt PowerShellu 7.4+ včetně 7.6. Pokud `Test-Json` odmítne data bez podrobností, validátor získá chybové cesty ze stejného schématu přes `JsonSchema.Net`, který je součástí podporovaného PowerShellu; odmítnutí dat tím nesmí změnit na úspěch.

| Položka | Kontrakt |
|---|---|
| `instance.name` | Povinných 2–8 malých písmen nebo číslic; první znak musí být písmeno. |
| `regions.primary`, `regions.secondary` | Primární region je povinný, sekundární volitelný. Hodnoty používají názvy lokací Azure, například `westeurope`. |
| `teams.platform`, `teams.security` | Povinné neprázdné seznamy jedinečných UPN. |
| `modules` | Povinná mapa vybraných modulů. Prázdná mapa je platná. `parameters` předává jmenné proměnné Terraformu; předpoklady se doplní automaticky. |
| `customPatterns` | Volitelný seznam položek s `name` a `secretRegex`; `beforeSecret` a `afterSecret` jsou volitelné řetězce. |
| `manualSteps` | Volitelná mapa `<module>: {<step-id>: true nebo false}`. Validátor odmítne neznámý modul nebo identifikátor kroku. |
| `manualPrerequisites` | Volitelná mapa ručních potvrzení před bootstrapem. Chybějící potvrzení znamená nepotvrzený předpoklad. |
| `bootstrap` | Pro lokální bootstrap povinné identifikátory tenantu, management subscription, všech použitých subscriptions, enterprise aplikace EMU a enterprise na GHE.com. [Provozní postup](docs/bootstrap.md) popisuje položky a oprávnění. |
| `githubApps` | Volitelná mapa aliasů enterprise-owned Apps. Položka obsahuje `appId`, `installationId`, slug `enterprise`, skutečná `permissions` a skutečné `resources`. Oba identifikátory jsou kladná desetinná čísla zapsaná jako řetězce. |
| `credentials` | Volitelné vazby modulů na `plan`, `apply` a případně `rulesetPlan`. Každá vazba obsahuje `environment` a volitelný alias `githubApp`. Pokud modul vazby deklaruje, musí uvést `plan` i `apply`. |
| `teardown.allowed` | Volitelný boolean s výchozí hodnotou `false`. Runner s touto hodnotou odmítne `destroy`. |

Schéma nepovoluje privátní klíče ani tokeny v záznamech Apps a credentialů. Parametry nesmějí obsahovat credential položky, například `token`, `clientSecret` nebo `privateKey`, ani rozpoznané formáty privátních klíčů a tokenů GitHubu. Doplňující validace kontroluje tyto položky i ve vnořených mapách a seznamech; PowerShell `Test-Json` neumí zde použitou rekurzi přes `additionalProperties` vyhodnotit. Tato kontrola nerozpozná libovolný secret pod obecným názvem. Secrets patří do chráněných environmentů, nikoli do konfigurace. Názvy parametrů `instance` a `prerequisites` jsou rezervované bez ohledu na velikost písmen.

Příklad vazeb pro spustitelný modul `organizations`:

```yaml
modules:
  organizations:
    parameters:
      target_organizations: [demo-actions, demo-workloads]
githubApps:
  governance-reader:
    appId: '101'
    installationId: '201'
    enterprise: example
    permissions:
      organization_administration: read
    resources:
      organizations: [demo-actions, demo-workloads]
  governance-writer:
    appId: '102'
    installationId: '202'
    enterprise: example
    permissions:
      organization_administration: write
    resources:
      organizations: [demo-actions, demo-workloads]
credentials:
  organizations:
    plan:
      environment: organizations-plan
      githubApp: governance-reader
    apply:
      environment: organizations-apply
      githubApp: governance-writer
```

Alias musí existovat v `githubApps`. Validátor doplní výchozí environmenty `<module>-plan`, `<module>-apply` a pro deklarovanou výjimku `<module>-ruleset-plan`. Vybraný modul s deklarací App fáze musí mít její alias. Každý environment včetně odvozených variant `<environment>-drift` smí patřit jen jednomu modulu a jedné fázi. Názvy `pr-authorization`, `approve-apply`, `approve-teardown-platform` a `teardown` jsou rezervované pro společné gate joby.

Validátor porovná oprávnění aliasu s manifestem a rozsah prostředků s parametry modulu. Stejné `appId` lze sdílet jen při shodné fázi, enterprise, oprávněních a prostředcích, i když má App více aliasů či klíčů. Běžný plan odmítne App s libovolným write oprávněním, nikoli pouze široký token. `resources.organizations` uvádí přesné slugy všech instalací App. Volitelná mapa `resources.repositories` omezí danou organizaci na přesný seznam repozitářů; bez její položky musí instalace pokrývat všechny repozitáře organizace. `installationId` identifikuje jednu z deklarovaných instalací; job ověří i ostatní a vydá token pro každou cílovou organizaci.

**Manual prerequisites (ruční předpoklady):** lokální bootstrap vyžaduje `true` pro všechna potvrzení: `tenant`, `enterpriseOidc`, `enterpriseScim`, `enterpriseOwner`, `subscriptions`, `licenses`, `privateInternalForksDisabled`, `emuUserNamespacesRestricted`, `fineGrainedPatApprovalRequired`, `patMaxLifetime90Days` a `githubAppAvailabilityVerified`. Runner vyžaduje stejná potvrzení při volání modulu `bootstrap` s akcí `plan` nebo `apply`; chybějící nebo nepravdivá hodnota ho zastaví před Terraformem. Potvrzení dostupnosti Apps musí vycházet z ručního ověření na konkrétní instanci GHE.com, ne pouze z veřejné dokumentace.

Ruční potvrzení není automaticky ověřený stav. Runner nevolá API k ověření enterprise politik ani ručních kroků. Lokální `Invoke-Bootstrap.ps1` navíc ověří tenant, subscriptions, aktivní SCIM job, přímé přiřazení Enterprise Owner, vlastnictví enterprise uživatelem OAuth a licenci Entra ID P1 nebo P2. `Test-BootstrapPrerequisites.ps1` spustí tyto kontroly bez změny a vypíše výsledek každé z nich ([preflight](docs/bootstrap.md#preflight-předběžná-kontrola)). OIDC launch mode ověří, pokud ho Graph vrátí; při `null` výslovně varuje a používá povinné ruční potvrzení `enterpriseOidc`, nikoli tvrzení o automatickém ověření. Enterprise politiky a ostatní licence zůstávají ručně potvrzené. Ostatní moduly nepotvrzený ruční krok nezastaví; job summary uvádí varování, vlastníka a omezení planu, driftu a teardownu. Potvrzený krok zůstává označený jako ruční deklarace. Runner při teardownu nemění konfiguraci ani ruční předpoklady.

### Module manifest (manifest modulu)

Generátor čte Module manifest v cestě `modules/<name>/module.yaml`. Hodnota `name` musí odpovídat adresáři a používat malá písmena, číslice a pomlčky; první znak musí být písmeno. Adresář bez manifestu představuje pouze specifikaci a generátor ho nezahrne do workflow.

```yaml
name: example
description: Příklad manifestu modulu.
prerequisites: []
manualSteps:
  - id: verify-access
    description: Platformní tým ověří přístup po nasazení.
    owner: platform
    limitations:
      plan: Terraform nastavení přístupu neověří.
      drift: Platformní tým kontroluje přístup ručně.
      teardown: Platformní tým odebere přístup ručně.
permissions:
  azure:
    - role: Reader
      scope: /subscriptions/00000000-0000-0000-0000-000000000000
      phase: plan
  microsoftGraph:
    - Group.Create
    - permission: Group.Read.All
      phase: plan
  githubApp: {}
  adminPat: []
```

Povinné jsou `name`, `description`, `prerequisites`, `manualSteps`, `permissions` a všechny kategorie oprávnění. Ruční krok vyžaduje `id` a `description`. Volitelný `owner` vybírá tým `platform` nebo `security`; výchozí vlastník je platformní tým. Volitelné `limitations` musí uvést všechny tři položky `plan`, `drift` a `teardown`. Bez nich runner přizná, že ruční stav automaticky neověří, nezachytí jeho drift ani ho nevrátí při teardownu.

Prázdné seznamy a prázdná mapa `githubApp` znamenají, že dané kroky ani oprávnění nejsou potřeba. `azure` deklaruje názvy rolí, jejich absolutní ARM scope a volitelnou `phase` (`plan` nebo `apply`); bez fáze přidělí bootstrap roli jen apply. `microsoftGraph` přijímá název oprávnění pro apply nebo objekt `permission` a `phase`. Plan musí deklarovat vlastní oprávnění ke čtení; bootstrap odmítne zápisová oprávnění. Obě identity mají navíc `Storage Blob Data Contributor` jen na vlastním kontejneru, protože i Terraform plan používá lease a může zapsat state. Pole `adminPat` musí být `[]`; schéma odmítne jakýkoli PAT požadavek. Module manifest nesmí obsahovat tokeny ani jiná secrets. Schéma odmítá neznámé položky a neplatné typy. Generátor navíc odmítá opakované identifikátory Manual step (ruční krok), neexistující Prerequisite (předpoklad) a cykly.

Neprázdná mapa `githubApp` deklaruje `plan`, `apply` a volitelně `rulesetPlan`. Každá fáze obsahuje mapu `permissions` na `read` nebo `write` a `resources`. Hodnoty `resources.organizations` a volitelné `resources.repositories` jsou názvy parametrů modulu, ze kterých validátor získá skutečné cíle. Tím může vendorovaný manifest fungovat v různých instancích:

```yaml
githubApp:
  plan:
    permissions: {organization_administration: read}
    resources: {organizations: target_organizations}
  apply:
    permissions: {organization_administration: write}
    resources: {organizations: target_organizations}
  rulesetPlan:
    permissions: {organization_administration: write}
    resources: {organizations: target_organizations}
    purpose: organization-rulesets-full-read
```

Plan nesmí deklarovat write. Výjimka `rulesetPlan` musí deklarovat právě `organization_administration: write`, cílové organizace a uvedený účel; nesmí přidat jiná oprávnění ani repozitářový rozsah. Apply musí mít oprávnění k zápisu organizačních rulesetů. Modul umístí kompletní ruleset prostředky včetně bypass konfigurace do rootu `rulesets/` podle ADR 0017. Běžný root tyto prostředky nesmí obsahovat; workflow plánuje celý ruleset root, nepoužívá `-target` ani náhradu neověřeného bypassu prázdnou hodnotou.

### Generování workflow a výběr

Generátor zapisuje `templates/instance/.github/workflows/deploy.yml`. Přepínač `-Check` pouze porovná obsah a při rozdílu skončí chybou; soubor nezmění. Výstup používá UTF-8 bez BOM a konce řádků LF. Pořadí adresářů ani pořadí Prerequisite v Module manifest nemění výstup.

```powershell
.\tools\Generate-DeploymentWorkflow.ps1 -Check
.\tools\Generate-DeploymentWorkflow.ps1 -ModulesPath .\tools\tests\fixtures\modules -OutputPath .\tools\tests\fixtures\deploy.yml
```

Mapa `modules` v Instance configuration přiřazuje názvu Module (modul) jeho konfiguraci. Minimální platný příklad pro fixture:

```yaml
instance:
  name: demo
regions:
  primary: westeurope
teams:
  platform: [platform@example.test]
  security: [security@example.test]
modules:
  application:
    parameters: {}
```

`Select-InstanceModules.ps1` validuje celou konfiguraci a vrátí seřazené JSON pole názvů vybraných Module včetně všech jejich Prerequisite. Prázdná mapa vrátí `[]`. Neznámý název nebo jiný typ konfigurace způsobí chybu s cestou `$.modules`. Volitelný `-GitHubOutputPath` připojí `modules`, mapy `environments`, `applyEnvironments`, `rulesetEnvironments` a seznam deklarovaných `rulesetModules`. Reportování tím rozpozná i chybějící ruleset job zastaralého workflow.

```powershell
.\tools\Select-InstanceModules.ps1 -ModulesPath .\tools\tests\fixtures\modules -InstancePath .\instance.yaml
```

Workflow reaguje na `pull_request_target` proti `main`, push do `main`, ruční spuštění z `main` a schedule denně v 02:17 UTC. Schedule používá environmenty `<plan-environment>-drift` a `<ruleset-plan-environment>-drift` a nikdy neodemkne apply. Job `authorize` načte jen nástroje z neměnného base commitu. Nejprve odmítne forky, App autory a draft PR bez načtení App klíče. Pro ostatní PR ověří aktivní členství autora v platformním týmu přes samostatnou App s `members: read`. Tento job nikdy nenačte kód z PR a nedostane credential modulu.

Job `validate` bez environmentu, OIDC a cloudových secrets ověří `instance.yaml` schématem vendorovaného release. Autorizovaný job `select` používá trusted nástroje a před zveřejněním environmentů porovná App metadata i credential vazby PR s base konfigurací. Jejich změna vyžaduje review a merge; cloudový plan pak poběží z chráněné `main`.

Každý Module má plan job `module_<name>` a apply job `apply_<name>` s přímými Prerequisite stejné fáze. Deklarovaná výjimka přidá `ruleset_plan_<name>` ve vlastním environmentu; čeká i na běžný plan modulu. Závislý plan čeká na běžný i deklarovaný ruleset plan předpokladu, než dostane credentials a stáhne jeho výstupy. Podmínky všech těchto jobů vyžadují autorizaci, úspěšný výběr a úspěšné předpoklady. Nevybraný job se přeskočí. Selhání předpokladu blokuje jen jeho závislé joby.

Job se přihlásí do Azure přes OIDC identity svého environmentu. Trusted token issuer ověří enterprise vlastníka App, její skutečná oprávnění a úplný rozsah všech instalací, nikoli jen užší požadovaný token. Odlišná skutečná oprávnění či prostředky zastaví job. Tokeny předá přes environment `PLATFORM_GITHUB_TOKENS` a `TF_VAR_github_tokens`; pro jednu organizaci také jako `GITHUB_TOKEN` a `GH_TOKEN`. Terraform root s více organizacemi musí přijmout mapu `github_tokens`. Job tokeny maskuje a v závěru je odvolá; nikdy je nenahraje jako artifact.

Proměnná Terraformu `github_tokens` musí mít `type = map(string)` a `sensitive = true`. Modul nesmí tokeny vložit do veřejných výstupů.

Job stáhne výstupy každého přímého předpokladu ze stejné fáze. Publikuje jen `<module>.json` jako `plan-outputs-<module>` nebo `apply-outputs-<module>`, s retencí jeden den. Ruleset plan publikuje oddělený `<module>.rulesets.json`. Plan, proměnné a state se nenahrávají. Chybějící artifact nebo selhání runneru zastaví větev.

Job `plan_complete` výslovně označí neautorizovaný PR plan jako `NOT PERFORMED`. Pro autorizovaný běh vyžaduje úspěch všech vybraných planů včetně rulesetů; chybějící job zastaví stale workflow. Teprve na `main`, mimo schedule, následuje jediné schválení platformním týmem v `approve-apply`. Apply joby poté běží ve svých environmentech; `enterprise-baseline-apply` navíc vyžaduje security tým. Pravidla environmentů nastaví `tools/Invoke-GitHubBootstrap.ps1`; [runbook](docs/bootstrap.md#github-část-bootstrapu) popisuje přípravu, ověření Apps, OIDC vazby a rotaci klíčů. Kontrakt environmentů popisuje [šablona](templates/instance/README.md).

**Současný rozsah:** produkční adresáře obsahují jen specifikace, bez manifestů. Produkční šablona proto obsahuje autorizaci, validaci, výběr a reportování prázdného grafu. Úplný plan/apply graf včetně `enterprise-baseline` ověřuje fixture workflow. Šablona očekává release v `platform/`; CODEOWNERS určuje platformní tým a bootstrap nahradí jeho ukázkový slug. Průvodce `tools\Start-InstanceSetup.ps1 -GitHubAcceptance` ověří bootstrap, read-only API a OIDC na izolovaném kandidátovi pro [#11](https://github.com/msucharda/devsecops-platform/issues/11). První produkční modul `emu-identity` ověří [#12](https://github.com/msucharda/devsecops-platform/issues/12). Produkční operace `enterprise-baseline` ověří jeho vlastní issues, počínaje [#17](https://github.com/msucharda/devsecops-platform/issues/17); probe manifesty je nenahrazují.

### Runner modulu

`tools/Invoke-Module.ps1` provede jednu akci `plan`, `apply` nebo `destroy` jednoho vybraného modulu či jeho Prerequisite. Terraform běží v `modules/<name>/`. Root musí deklarovat backend odpovídající parametru `-Backend`; runner odmítne implicitní lokální backend.

Produkční backend `azurerm` používá kontejner s názvem modulu, klíč `terraform.tfstate` a autentizaci Entra ID (`use_azuread_auth=true`). Název modulu musí mít nejméně tři znaky. Storage account a resource group určí `-StorageAccountName` a `-ResourceGroupName`, nebo proměnné `PLATFORM_STATE_STORAGE_ACCOUNT` a `PLATFORM_STATE_RESOURCE_GROUP`. Credentialy Azure a GitHubu připravuje volající; runner nevydává tokeny, neprovádí přihlášení a nepřechází na PAT. Terraform workspace je `default`; pracovní adresář Terraformu se izoluje pro každý běh.

Root deklaruje standardní proměnné `instance` a `prerequisites`. `instance` obsahuje `name`, `regions`, `teams` a `customPatterns`. Položky `modules.<name>.parameters` jsou další jmenné proměnné Terraformu. `prerequisites` obsahuje mapu přímých předpokladů na jejich necitlivé výstupy, například `var.prerequisites.foundation.foundation_name`. Runner čte soubory `<prerequisite>.json` v `-PrerequisiteOutputsPath`, nikdy state jiného modulu.

`plan` vrací známé hodnoty z uloženého planu, ne staré výstupy state. Terraform exit code `2` znamená změny, nikoli chybu. Neznámý nebo částečně neznámý výstup způsobí chybu; před dalším planem musíš nasadit daný předpoklad. Runner ho nenahradí hodnotou `null`, starým state ani prázdným výsledkem. `apply` a `destroy` provedou uložený plan a pak načtou aktuální výstupy. `destroy` vyžaduje `teardown.allowed: true`; pořadí odstranění více modulů a schválení běhu musí zajistit volající workflow.

Read-only `plan` používá `-lock=false`, aby nevyžadoval oprávnění k zápisu lease ve state backendu. Může souběžně číst state; apply si po schválení vytvoří nový plan se zamykáním. Workflow nepřenáší uložený PR plan do apply.

Přepínač `-Rulesets` vyžaduje deklaraci `rulesetPlan` a spustí celý root `modules/<name>/rulesets/`. Použije stejný kontejner modulu, ale key `terraform.rulesets.tfstate`; lokální fixture používá `<module>.rulesets.tfstate`. Výstup uloží do `<module>.rulesets.json`. Apply workflow provede oba rooty před publikací běžných výstupů. Volající teardown musí odstranit ruleset root i běžný root.

Runner odmítne výstup s Terraform příznakem `sensitive`. Za správnou deklaraci citlivosti odpovídá autor modulu. Při chybě nepublikuje žádné nové výstupy; před během odstraní i svůj starý výstupní soubor. Dočasné proměnné, plan a pracovní data odstraní v `finally`. Necitlivé hodnoty uloží jako JSON objekt bez obálky Terraformu do `-ArtifactsPath/<module>.json`.

Veřejný výsledek skriptu obsahuje `Module`, `Action`, `HasChanges`, `OutputsPath` a `ManualSteps`. Každý ruční krok obsahuje `Confirmed`, `Verified: false`, vlastníka a omezení. `-JobSummaryPath` určuje soubor summary; výchozí hodnota je `GITHUB_STEP_SUMMARY`. Bez souboru runner vypíše summary do informačního proudu a nepotvrzené kroky jako varování.

Offline příklad používá lokální backend. `-StatePath` je adresář; runner v něm vytvoří vlastní soubor `<module>.tfstate`. Fixture konfigurace povoluje teardown, produkční šablona ho zakazuje:

```powershell
$arguments = @{
    InstancePath = '.\tools\tests\fixtures\runner-instance.yaml'
    ModulesPath = '.\tools\tests\fixtures\runner-modules'
    Backend = 'local'
    StatePath = '.\artifacts\state'
    ArtifactsPath = '.\artifacts\module-outputs'
    JobSummaryPath = '.\artifacts\summary.md'
}
.\tools\Invoke-Module.ps1 -Module foundation -Action plan @arguments
$arguments.PrerequisiteOutputsPath = $arguments.ArtifactsPath
.\tools\Invoke-Module.ps1 -Module application -Action apply @arguments
.\tools\Invoke-Module.ps1 -Module application -Action destroy @arguments
```

### Testy a CI

Workflow vendoringu, katalogový kontrakt, oddělené App identity a deklarovaný ruční import popisuje [Vendoring](docs/vendoring.md). Automatický import release mění jen `platform/`; povýšení přepsaných šablon do živých workflow zůstává schváleným ručním krokem #16 bez rozšíření App oprávnění.

Testy Pester volají veřejné skripty bootstrapu, generátoru, výběru, validátorů, token issueru, reportování a runneru. Kontrolují výsledné YAML, JSON, summary, environmenty, pořadí jobů, PR původ, členství autora a oddělení skutečných App oprávnění. GitHub API testy nahrazují jen HTTP hranici; nevolají cloud. Testy bootstrapu nahrazují jen GitHub CLI, Azure CLI a HTTP API; ověřují potvrzení před změnou, preflight bez zápisu, ochrany backendu, scope identit, oddělení fází, opakovaný běh a dokončení přerušeného běhu. Testy runneru vyžadují Terraform; CI ho instaluje před Pesterem. Používají skutečný lokální backend a vestavěný provider `terraform_data`, včetně úplných pravidel a bypass driftu izolovaného ruleset rootu. Jeden regresní test na hranici procesu Terraformu upraví JSON planu, aby ověřil odmítnutí neznámého výstupu, který chybí v `planned_values`. Jeden soubor můžeš spustit přímo:

```powershell
Import-Module Pester -RequiredVersion 5.7.1
Invoke-Pester -Path .\tools\tests\ModuleRunner.Tests.ps1 -Output Detailed
Invoke-Pester -Path .\tools\tests\Bootstrap.Tests.ps1 -Output Detailed
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
| `bootstrap` | State backend, identity modulů pro plan a apply, organizace platformy, repozitář instance a zapojení enterprise-owned GitHub Apps. Člen platformního týmu ho spustí jednou lokálně; registrace Apps a vložení klíčů mohou být ruční. | – |
| `emu-identity` | Skupiny a přiřazení aplikací v Entra ID: platformní tým (Enterprise Owner), security tým (security manager ve všech organizacích), uživatelé Copilotu (licence). SCIM ze skupin vytvoří enterprise týmy. | `bootstrap` |
| `organizations` | Organizace akcí a organizace workloadů. | `emu-identity` |
| `actions-catalog` | Vendorované akce v organizaci akcí. | `organizations` |
| `enterprise-baseline` | Organizační rulesety, code security configurations, politika akcí a custom patterns. Neautomatizované enterprise kontroly jsou ruční předpoklad. | `actions-catalog` |
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
- Pro správu GitHubu workflow používají GitHub App installation tokeny. GitHub App identity lze sdílet jen při shodných oprávněních, prostředcích a fázi (ADR 0016).
- Automatický PR plan s přihlašovacími údaji smí běžet jen pro PR platformního týmu v repozitáři instance. Forky, jiní autoři ani PR vytvořené App je automaticky nedostanou. Po review a merge PR importu proběhne plan na chráněné větvi `main` před apply.
- Běžný plan je read-only. Plan organizačních rulesetů běží v samostatném jobu s výslovnou výjimkou `Organization Administration: write`; toto oprávnění nesmějí dostat ostatní plan joby.
- Workflow zapíše nepotvrzené ruční kroky do job summary jako varování. Platformní tým potvrdí ruční krok v `instance.yaml` přes PR.
- Po merge PR schválí platformní tým jednou celý běh apply. Běh modulu `enterprise-baseline` navíc schvaluje security tým.
- Každou noc proběhne plan všech modulů na větvi `main`. Pokud plan najde drift, workflow otevře nebo aktualizuje issue v repozitáři instance.
- Issue driftu zapisuje samostatný reporting job s installation tokenem pro potřebný zápis v repozitáři instance. Plan joby kvůli němu nezískají oprávnění k zápisu.

### Ruční předpoklady a přihlašovací údaje

- Neautomatizované enterprise kontroly musí platit před bootstrapem: zákaz private a internal forků, omezení repozitářů v EMU user namespaces, schvalování fine-grained PAT a maximální platnost PAT 90 dní. O omezení classic PAT zatím není rozhodnuto.
- Organization owners patří jen do platformního týmu; workload týmy mají nejvýše `Maintain` na svých repozitářích. Organizační kontroly chrání proti workload týmům, ne proti důvěryhodnému ownerovi.
- Platformní tým spravuje enterprise-owned Apps. Změny jejich oprávnění schvaluje security tým přes PR.
- Privátní klíče jsou environment secrets oddělené podle modulu a fáze. Klíče neexpirují automaticky; platformní tým je rotuje nejpozději po 90 dnech a při podezření na kompromitaci. Nejprve ověří nový klíč, potom odvolá starý.
- Běžná workflow si installation tokeny vydávají bez člověka. Lokální bootstrap může použít OAuth token spouštějícího člověka; registrace Apps a vložení klíčů mohou být ruční.
- Dostupnost enterprise-owned Apps, zvolených API, oprávnění a tokenové akce na GHE.com se musí ověřit před nasazením. Chyba nesmí vést k automatickému přechodu na PAT ani k rozšíření oprávnění.
- Nepodporované operace jsou deklarované ruční kroky s popsaným omezením planu, driftu a odstranění. Ruční krok se nesmí vykázat jako automaticky ověřená kontrola.

## Regiony

- `regions.primary` je povinný, `regions.secondary` volitelný.
- Ve verzi 1 obsahuje sekundární region jen druhý hub s Azure Firewall, propojený s primárním hubem peeringem. Politika SLZ povolí obě lokace.
- Management a sdílená aplikační landing zone jsou jen v primárním regionu.

## Názvy

- `instance.name` má 2–8 znaků. Organizace se jmenují `{name}-{deployment}-platform`, `{name}-{deployment}-actions` a `{name}-{deployment}-workloads`; `{deployment}` je identifikátor nasazení podle ADR 0008. Bootstrap ho uloží v inventory (`docs/bootstrap.md`). Inventory z doby před identifikátorem zachová organizaci platformy `{name}-platform`.
- Prostředky v Azure používají zkratky typů prostředků podle CAF.
- Identifikátor nasazení je jen v názvech podle ADR 0008.

## Release a upgrade

- Release má jednu verzi SemVer pro všechny moduly (ADR 0013).
- Jeden opakovaně použitelný workflow vendoringu importuje release platformy, akce i skilly. Workflow stáhne zdroj podle tagu, ověří attestaci, pokud existuje, a otevře PR s diffem.
- PR otevírá installation token s oprávněními k cílovému repozitáři. Pokud privátní zdroj release není dostupný installation tokenem enterprise-owned App, import zůstává ruční do jeho zpřístupnění; workflow nepoužije osobní PAT ani OAuth token.

## Teardown

- Workflow `teardown` odstraní moduly v obráceném pořadí předpokladů, kromě `bootstrap`. Modul `bootstrap` odstraní lokální skript.
- Workflow se spustí jen při `teardown.allowed: true` v `instance.yaml`. Výchozí hodnota je `false`.
- Environment `teardown` vyžaduje schválení od platformního týmu i od security týmu.
- Teardown vrátí spravované organizační politiky na výchozí hodnoty GitHubu a smaže organizační rulesety, code security configurations a custom patterns. Enterprise a jeho ruční předpoklady zůstanou beze změny.
- Lokální odstranění bootstrapu odstraní i Apps založené pro instanci a jejich credentials, případně vyžádá deklarovaný ruční krok. Apps nesmějí být odstraněné dřív, než skončí workflow, která je potřebují.

## Testování release

- CI ve zdrojovém repozitáři spouští `terraform fmt`, `terraform validate`, tflint, Trivy, validaci JSON Schema a kontrolu cyklů v předpokladech.
- Každý release candidate se nasadí celý na referenční instanci.
- Akceptace ověří skutečný rozsah oprávnění každého jobu, úplné čtení bypass konfigurace, odmítnutí credentials pro neautorizované PR a zachování ručních enterprise předpokladů při teardownu.
- Před každým minor release proběhne teardown referenční instance a její nové nasazení.
- Kroky platformního týmu na referenční instanci popisuje [Příprava a akceptace referenční instance](docs/reference-instance.md). Ruční předpoklady připraví a ověří průvodce `tools/Start-InstanceSetup.ps1`; přepínač `-GitHubAcceptance` přidá akceptaci bootstrapu #11 s potvrzovanými cloudovými změnami a lokálními důkazy.
