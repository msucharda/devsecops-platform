# devsecops-platform

Modulární DevSecOps platforma pro zákazníky s GitHub Enterprise Cloud s data residency (GHE.com) a EMU na Azure Sovereign Landing Zone.

- [Glosář](CONTEXT.md)
- [Rozhodnutí (ADR)](docs/adr/)
- [Příprava a akceptace referenční instance](docs/reference-instance.md)

## Struktura repozitáře

| Cesta | Obsah |
|---|---|
| `modules/<name>/` | Manifest `module.yaml`, schéma parametrů `parameters.schema.json`, Terraform root a README se specifikací modulu. |
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

Parser YAML patří do releasu a nástroje ho načítají z `tools/vendor/` bez PSGallery. Bez `-Development` skript pouze ověří přibalené runtime závislosti. S `-Development` stáhne vývojové moduly do `tools/.dependencies/`, ověří SHA256 balíčků podle pinu a porovná obsah `Save-Module` s ověřeným archivem. Podrobnosti a postup aktualizace uvádí [provenience závislostí](tools/vendor/PROVENANCE.md).

### Retry volání GitHub REST API

External programy modulů `actions-catalog`, `enterprise-baseline`, `organization-rulesets` a `organizations` opakují GET nejvýše dvakrát: celkem provedou 3 pokusy s prodlevami 5 a 10 s. Stejná politika platí pro DELETE revokace job tokenu v `tools/Remove-PlatformGitHubToken.ps1`. Retry zpracuje jen HTTP 502, 503, 504 a chybu spojení, TLS nebo timeout. HTTP 4xx včetně 429, ostatní chyby a POST, PATCH, PUT ani jiné DELETE neopakuje. Každá stránka výpisu má vlastní limit pokusů.

Sdílený helper `modules/shared/scripts/GitHubRetry.ps1` patří do releasu vedle modulů, včetně akceptačního kandidáta a jeho schválených hashů. Log retry zapisuje na stderr, aby stdout external programu obsahoval jen JSON. Log obsahuje jen metodu, cestu bez query, status a číslo neúspěšného pokusu; neobsahuje token, hlavičky ani text chyby transportu. Vyčerpání pokusů neznamená úspěch. Každý pokus revokace má timeout 60 s a nenásleduje přesměrování. Revokace vyžaduje HTTP 204 podle [kontraktu DELETE /installation/token](https://docs.github.com/en/rest/apps/installations?apiVersion=2026-03-10#revoke-an-installation-access-token), verze API `2026-03-10`. Pokud server token odvolá, ale odpověď se ztratí, opakovaný DELETE může vrátit 401. Skript takový výsledek hlásí jako nepotvrzenou revokaci, nikoli jako úspěch; token dál nepoužívej. Ostatní revokační a akceptační nástroje tato politika nemění.

### Instance configuration (konfigurace instance)

`schemas/instance.schema.json` popisuje soubor `instance.yaml`. Výchozí příklad je v `templates/instance/instance.yaml`. Validátor, výběr modulů i runner používají stejné schéma. Chyba uvádí cestu k položce, například `$.instance.name` nebo `$.credentials.organizations.plan.githubApp`.

Validátor načítá pevná schémata `instance.schema.json` a `module.schema.json` z adresáře `schemas/` vedle nástrojů. Před validací spojí jejich definice do jednoho schématu s lokálními odkazy. Povoluje jen `#/definitions/<name>` a `module.schema.json#/definitions/<name>` s existující definicí; odmítne jiné soubory, vzdálená URI, chybějící definice i `$id`, který by změnil význam odkazu. Schémata parametrů přebírá pouze z pevné cesty `parameters.schema.json` vedle načteného manifestu modulu. V těchto schématech nepovoluje `$ref`, `$id`, `$anchor`, `$dynamicRef` ani `$recursiveRef`. Nestahuje schémata podle URI z konfigurace a nezapíná `FetchExternalReference`. Tento postup zachovává kontrakt PowerShellu 7.4+ včetně 7.6. Pokud `Test-Json` odmítne data bez podrobností, validátor získá chybové cesty ze stejného schématu přes `JsonSchema.Net`, který je součástí podporovaného PowerShellu; odmítnutí dat tím nesmí změnit na úspěch.

Každý modul s `variables.tf` musí mít `parameters.schema.json` ve formátu JSON Schema draft-07. Schéma deklaruje objekt, `additionalProperties: false`, typy v `properties` a povinné parametry v `required`. Offline validace odmítne neznámý parametr, chybějící povinný parametr a chybný typ včetně vnořených položek ještě před planem. Povinné parametry musí mít i předpoklady doplněné výběrem modulů, nejen výslovně vybrané moduly. Výchozí hodnoty dál doplňuje Terraform; validátor je nezapisuje do konfigurace. Explicitní `vendoring_catalog_path: null` u `actions-catalog` zůstává platný.

Schéma obsahuje pouze parametry z `modules.<name>.parameters`. Runner doplňuje `instance`, `prerequisites` a interní checkpoint `ruleset_destroy_started`; konfigurace je nesmí přepisovat. U parametrů z `organizationParameters` schéma popisuje mapu hodnot podle organizace, zatímco Terraform dostane hodnotu pro jednu organizaci. Test `tools/tests/ModuleParameters.Tests.ps1` porovnává názvy, povinnost a rekurzivní typy s `variables.tf` všech rootů modulu včetně deployment phases a `rulesets/`. Přitom zohledňuje toto zúžení mapy. Nepřečtenou deklaraci, například jednořádkový blok, odmítne; nesmí ji tiše vynechat. Terraform validace hodnot a preconditions zůstávají zachované; schéma je nenahrazuje.

Při porovnání chráněných bindings pro PR validuje `Select-InstanceModules.ps1` kandidáta proti kandidátním modulům a důvěryhodnou konfiguraci proti modulům jejího release. Parametr `-TrustedModulesPath` má výchozí hodnotu `modules/` vedle běžící kopie nástrojů; alternativní cestu musí volající určit výslovně. Změna názvu parametru mezi releasy proto neblokuje platnou aktualizaci konfigurace. Porovnávací kopie `credentials` dostanou společné výchozí hodnoty obou grafů, aby přidání nevybraného modulu nebo deklarace `rulesetPlan` nevypadalo jako změna bindings. Tento krok nepřepisuje výslovně zadané hodnoty ani nemění validované konfigurace. Kontrola shody `credentials` a `githubApps` zůstává zachovaná.

| Položka | Kontrakt |
|---|---|
| `instance.name` | Povinných 2–8 malých písmen nebo číslic; první znak musí být písmeno. |
| `regions.primary`, `regions.secondary` | Primární region je povinný, sekundární volitelný. Hodnoty používají názvy lokací Azure, například `westeurope`. |
| `teams.platform`, `teams.security` | Povinné neprázdné seznamy jedinečných UPN. |
| `modules` | Povinná mapa vybraných modulů. Prázdná mapa je platná. `parameters` předává jmenné proměnné Terraformu; předpoklady se doplní automaticky. |
| `customPatterns` | Volitelný seznam položek s `name` a `secretRegex`; `beforeSecret` a `afterSecret` jsou volitelné řetězce. |
| `manualSteps` | Volitelná mapa `<module>: {<step-id>: true nebo false}`. Validátor odmítne neznámý modul nebo identifikátor kroku. |
| `manualPrerequisites` | Volitelná mapa ručních potvrzení. Bootstrap a moduly vyžadují své deklarované předpoklady. Chybějící potvrzení znamená nepotvrzený předpoklad. |
| `bootstrap` | Pro lokální bootstrap povinné identifikátory tenantu, management subscription, všech použitých subscriptions, enterprise aplikace EMU a enterprise na GHE.com. [Provozní postup](docs/bootstrap.md) popisuje položky a oprávnění. |
| `githubApps` | Volitelná mapa aliasů enterprise-owned Apps. Položka obsahuje `appId`, `installationId`, slug `enterprise`, skutečná `permissions` a skutečné `resources`. Oba identifikátory jsou kladná desetinná čísla zapsaná jako řetězce. |
| `credentials` | Volitelné vazby modulů na `plan`, `apply` a případně `rulesetPlan`. Každá vazba obsahuje `environment` a volitelný alias `githubApp`. Pokud modul vazby deklaruje, musí uvést `plan` i `apply`. |
| `teardown.allowed` | Volitelný boolean s výchozí hodnotou `false`. Runner s touto hodnotou odmítne `destroy`. |

Schéma nepovoluje privátní klíče ani tokeny v záznamech Apps a credentialů. Parametry nesmějí obsahovat credential položky, například `token`, `clientSecret` nebo `privateKey`, ani rozpoznané formáty privátních klíčů a tokenů GitHubu. Doplňující validace kontroluje tyto položky i ve vnořených mapách a seznamech; PowerShell `Test-Json` neumí zde použitou rekurzi přes `additionalProperties` vyhodnotit. Tato kontrola nerozpozná libovolný secret pod obecným názvem. Secrets patří do chráněných environmentů, nikoli do konfigurace. Názvy parametrů `instance` a `prerequisites` jsou rezervované bez ohledu na velikost písmen.

Příklad vazeb pro modul `organizations` s enterprise installation:

```yaml
modules:
  organizations:
    parameters:
      admin_logins: [msucharda]
      billing_email: billing@example.test
githubApps:
  organizations-reader:
    appId: '101'
    installationId: '201'
    enterprise: example
    permissions:
      enterprise_organization_installations: read
    resources:
      enterprise: true
  organizations-writer:
    appId: '102'
    installationId: '202'
    enterprise: example
    permissions:
      enterprise_organization_installations: write
      enterprise_organizations: write
    resources:
      enterprise: true
credentials:
  organizations:
    plan:
      environment: organizations-plan
      githubApp: organizations-reader
    apply:
      environment: organizations-apply
      githubApp: organizations-writer
```

Alias musí existovat v `githubApps`. Validátor doplní výchozí environmenty `<module>-plan`, `<module>-apply` a pro deklarovanou výjimku `<module>-ruleset-plan`. Vybraný modul s deklarací App fáze musí mít její alias. Každý environment včetně odvozených variant `<environment>-drift` smí patřit jen jednomu modulu a jedné fázi. Názvy `pr-authorization`, `approve-apply`, `approve-teardown-platform`, `teardown` a `drift-report` jsou rezervované pro společné gate joby.

Validátor porovná oprávnění aliasu s manifestem a rozsah prostředků s parametry modulu. Stejné `appId` lze sdílet jen při shodné fázi, enterprise, oprávněních a prostředcích, i když má App více aliasů či klíčů. Běžný plan odmítne App s libovolným write oprávněním, nikoli pouze široký token. `resources.organizations` uvádí přesné slugy všech instalací App. Volitelná mapa `resources.repositories` omezí danou organizaci na přesný seznam repozitářů; bez její položky musí instalace pokrývat všechny repozitáře organizace. `installationId` identifikuje jednu z deklarovaných instalací; job ověří i ostatní a vydá token pro každou cílovou organizaci.

Enterprise installation deklaruj v manifestu fáze i v `githubApps.<alias>` jako `resources: { enterprise: true }`. Tato varianta nesmí obsahovat `organizations` ani `repositories`; cílový enterprise určuje existující pole `githubApps.<alias>.enterprise`, nikoli parametr modulu. Issuer vyžaduje právě jednu aktivní instalaci typu `Enterprise`, shodu jejího App ID, installation ID, enterprise slugu a ID s vlastníkem App a přesná oprávnění App, instalace i vydaného tokenu. Další instalace odmítne. Token vydá bez parametru `permissions`, protože enterprise token nelze zúžit a nemá přístup k repozitářům. Uloží ho pod klíčem `enterprise` v `PLATFORM_GITHUB_TOKENS` a `TF_VAR_github_tokens`; při jediném tokenu nastaví i `GH_TOKEN`. Existující revokační skript obslouží tento klíč stejně jako organizační tokeny.

Enterprise scope podporují jen fáze `plan` a `apply`; plan musí dál používat samostatnou App bez write oprávnění. Kombinovaný enterprise/organizační scope ani chybějící organizační instalace tato změna nepovoluje. Dostupnost na GHE.com a minimální oprávnění pro vytvoření organizace zůstávají podmínkou nasazení podle [runbooku C3](docs/runbooks/organizations-c3.md).

**Manual prerequisites (ruční předpoklady):** lokální bootstrap vyžaduje `true` pro všechna potvrzení: `tenant`, `enterpriseOidc`, `enterpriseScim`, `enterpriseOwner`, `subscriptions`, `licenses`, `privateInternalForksDisabled`, `repositoryManagementPoliciesEnforced`, `emuUserNamespacesRestricted`, `fineGrainedPatApprovalRequired`, `patMaxLifetime90Days` a `githubAppAvailabilityVerified`. Runner vyžaduje stejná potvrzení při volání modulu `bootstrap` s akcí `plan` nebo `apply`; chybějící nebo nepravdivá hodnota ho zastaví před Terraformem. Příznak `liveWorkflowsPromoted` platformní tým potvrdí až po povýšení živých workflow, proto ho bootstrap nevyžaduje. Modul může v manifestu deklarovat `manualPrerequisites`; runner pak tato potvrzení stejně vyžaduje před jeho plan a apply. Potvrzení dostupnosti Apps musí vycházet z ručního ověření na konkrétní instanci GHE.com, ne pouze z veřejné dokumentace.

Ruční potvrzení není automaticky ověřený stav. Runner nevolá API k ověření enterprise politik ani ručních kroků. Lokální `Invoke-Bootstrap.ps1` navíc ověří tenant, subscriptions, aktivní SCIM job, přímé přiřazení Enterprise Owner, vlastnictví enterprise uživatelem OAuth a licenci Entra ID P1 nebo P2. `Test-BootstrapPrerequisites.ps1` spustí tyto kontroly bez změny a vypíše výsledek každé z nich ([preflight](docs/bootstrap.md#preflight-předběžná-kontrola)). OIDC launch mode ověří, pokud ho Graph vrátí; při `null` výslovně varuje a používá povinné ruční potvrzení `enterpriseOidc`, nikoli tvrzení o automatickém ověření. Enterprise politiky a ostatní licence zůstávají ručně potvrzené. Ostatní moduly nepotvrzený ruční krok nezastaví; job summary uvádí varování, vlastníka a omezení planu, driftu a teardownu. Potvrzený krok zůstává označený jako ruční deklarace. Runner při teardownu nemění konfiguraci ani ruční předpoklady.

Modul [organization-roles](modules/organization-roles/README.md) vyžaduje `organizationSecurityTeamsLinked` až při svém planu a apply, nikoli při prvním bootstrapu. Před potvrzením vytvoř security tým v každé ze tří organizací a ručně ověř jeho propojení se skupinou Entra ID. Plan a drift skutečný IdP link neověřují. Modul spravuje pouze přiřazení role `security_manager`; týmy ani členství nespravuje.

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

Prázdné seznamy a prázdná mapa `githubApp` znamenají, že dané kroky ani oprávnění nejsou potřeba. `azure` deklaruje názvy rolí, jejich absolutní ARM scope a volitelnou `phase` (`plan` nebo `apply`); bez fáze přidělí bootstrap roli jen apply. `microsoftGraph` přijímá název oprávnění pro apply nebo objekt `permission` a `phase`. Plan musí deklarovat vlastní oprávnění ke čtení; bootstrap odmítne zápisová oprávnění. Volitelné pole `entraDirectoryRoles` deklaruje nejvýše jednu vlastní roli Entra pro každou fázi. Položka obsahuje `phase`, `scope: enterpriseApplication` a seznam `actions` s prefixem `microsoft.directory/servicePrincipals/`. Bootstrap vytvoří roli `platform-<instance>-<module>-<phase>` a přiřadí ji jen se scope na service principal enterprise aplikace GHE. Role planu smí obsahovat jen akce končící `/read`. Obě identity mají navíc `Storage Blob Data Contributor` jen na vlastním kontejneru, protože i Terraform plan používá lease a může zapsat state. Pole `adminPat` musí být `[]`; schéma odmítne jakýkoli PAT požadavek. Module manifest nesmí obsahovat tokeny ani jiná secrets. Schéma odmítá neznámé položky a neplatné typy. Generátor navíc odmítá opakované identifikátory Manual step (ruční krok), neexistující Prerequisite (předpoklad) a cykly.

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

Manifest fáze může deklarovat `resources.installationSelection: none` nebo `all`. Hodnota `none` vyžaduje instalace bez přístupu k repozitářům a alias s `resources.repositories: {}`. GitHub REST ji vrací jako `repository_selection: selected` s prázdným seznamem repozitářů; hodnota API `all` nesmí projít ani při aktuálně prázdné organizaci. Hodnota manifestu `all` vyžaduje instalace na všechny repozitáře; alias pole `repositories` nesmí obsahovat. Explicitní výběr nelze kombinovat s parametrem `resources.repositories` ani s enterprise scope. App, která má jinak pouze organizační oprávnění a potřebuje `all`, deklaruje také `metadata: read`. Instalace navazujících modulů provádí člověk podle checklistu odvozeného z manifestů. Token issuer při každém planu ověří přesné organizace a přístup k repozitářům; nesoulad zastaví běh.

Checklist vypíše požadované instalace a ruční kroky security týmů. Stav GitHubu neověřuje. Apps, které ještě nemají bindings v konfiguraci, označí `registrationRequired: true`. Bez `bootstrap.githubHost` musíš předat `-GitHubHost`.

```powershell
.\tools\Get-GitHubAppInstallationChecklist.ps1 -InstancePath .\instance.yaml -GitHubHost example.ghe.com
```

### Generování workflow a výběr

Generátor zapisuje `templates/instance/.github/workflows/deploy.yml` a vedle něj noční `drift.yml`. Volitelný `-DriftOutputPath` cestu `drift.yml` změní. Přepínač `-Check` pouze porovná oba soubory a při rozdílu skončí chybou; soubory nezmění. Výstup používá UTF-8 bez BOM a konce řádků LF. Pořadí adresářů ani pořadí Prerequisite v Module manifest nemění výstup.

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

Workflow `deploy.yml` reaguje na `pull_request_target` proti `main`, push do `main` a ruční spuštění z `main`. Noční plan patří do samostatného workflow `drift.yml` (viz [Detekce driftu](#detekce-driftu)). Job `authorize` načte jen nástroje z neměnného base commitu. Nejprve odmítne forky, App autory a draft PR bez načtení App klíče. Pro ostatní PR ověří aktivní členství autora v platformním týmu přes samostatnou App s `members: read`. Tento job nikdy nenačte kód z PR a nedostane credential modulu.

Job `validate` bez environmentu, OIDC a cloudových secrets ověří `instance.yaml` schématem vendorovaného release. Autorizovaný job `select` používá trusted nástroje a před zveřejněním environmentů porovná App metadata i credential vazby PR s base konfigurací. Jejich změna vyžaduje review a merge; cloudový plan pak poběží z chráněné `main`.

Každý Module má plan job `module_<name>` a apply job `apply_<name>` s přímými Prerequisite stejné fáze. Deklarovaná výjimka přidá `ruleset_plan_<name>` ve vlastním environmentu; čeká i na běžný plan modulu. Závislý plan čeká na běžný i deklarovaný ruleset plan předpokladu, než dostane credentials a stáhne jeho výstupy. Podmínky všech těchto jobů vyžadují autorizaci, úspěšný výběr a úspěšné předpoklady. Nevybraný job se přeskočí. Selhání předpokladu blokuje jen jeho závislé joby.

Job se přihlásí do Azure přes OIDC identity svého environmentu. Trusted token issuer ověří enterprise vlastníka App, její skutečná oprávnění a úplný rozsah všech instalací, nikoli jen užší požadovaný token. Odlišná skutečná oprávnění či prostředky zastaví job. Tokeny předá přes environment `PLATFORM_GITHUB_TOKENS` a `TF_VAR_github_tokens`; při jediném tokenu nastaví `GH_TOKEN`. Modul s `organizationScoped: true` používá společný runner: pro každou organizaci spustí samostatný Terraform proces se singleton `target_organizations` a pouze jejím tokenem v `REST_API_BEARER`, `GITHUB_TOKEN`, `GH_TOKEN` a obou tokenových mapách. Ostatní moduly s více organizacemi musí přijmout mapu `github_tokens`; root s providerem `Mastercard/restapi` bez organization-scoped deklarace nadále odmítne více než jednu organizaci. Job tokeny maskuje a v závěru je odvolá; nikdy je nenahraje jako artifact.

Proměnná Terraformu `github_tokens` musí mít `type = map(string)` a `sensitive = true`. Modul nesmí tokeny vložit do veřejných výstupů.

Job stáhne výstupy každého přímého předpokladu ze stejné fáze. Publikuje jen `<module>.json` jako `plan-outputs-<module>` nebo `apply-outputs-<module>`, s retencí jeden den. Ruleset plan publikuje oddělený `<module>.rulesets.json`. Plan, proměnné a state se nenahrávají. Chybějící artifact nebo selhání runneru zastaví větev.

Job `plan_complete` výslovně označí neautorizovaný PR plan jako `NOT PERFORMED`. Pro autorizovaný běh vyžaduje úspěch všech vybraných planů včetně rulesetů; chybějící job zastaví stale workflow. Teprve na `main` následuje jediné schválení platformním týmem v `approve-apply`. Apply joby poté běží ve svých environmentech; `enterprise-baseline-apply` a `organization-rulesets-apply` navíc vyžadují security tým. Pravidla environmentů nastaví `tools/Invoke-GitHubBootstrap.ps1`; [runbook](docs/bootstrap.md#github-část-bootstrapu) popisuje přípravu, ověření Apps, OIDC vazby a rotaci klíčů. Kontrakt environmentů popisuje [šablona](templates/instance/README.md).

**Současný rozsah:** manifest a Terraform mají z produkčních modulů `emu-identity`, `organizations`, `organization-roles`, `organization-rulesets`, `actions-catalog` a `enterprise-baseline`. Ostatní produkční adresáře obsahují jen specifikace. Produkční šablona proto obsahuje autorizaci, validaci, výběr, plan a apply těchto modulů včetně ruleset jobu `organization-rulesets` a reportování. Ruleset root `organization-rulesets` spravuje ruleset `platform-default-branch` ve všech organizacích instance ([#98](https://github.com/msucharda/devsecops-platform/issues/98)); `actions-catalog` nadále míří jen do organizace akcí. Šablona očekává release v `platform/`; CODEOWNERS určuje platformní tým a bootstrap nahradí jeho ukázkový slug. Průvodce `tools\Start-InstanceSetup.ps1 -GitHubAcceptance` ověří bootstrap, read-only API a OIDC na izolovaném kandidátovi pro [#11](https://github.com/msucharda/devsecops-platform/issues/11). První produkční modul `emu-identity` ověří [#12](https://github.com/msucharda/devsecops-platform/issues/12). Produkční operace `enterprise-baseline` ověří jeho vlastní issues, počínaje [#17](https://github.com/msucharda/devsecops-platform/issues/17); probe manifesty je nenahrazují.

### Detekce driftu

Workflow `drift.yml` spouští plan všech vybraných modulů denně v 02:17 UTC a ručně přes `workflow_dispatch`, jen z `main`. Nikdy neodemkne apply. Používá vlastní concurrency skupinu `drift-instance-main`, aby čekající noční běh nezrušil čekající nasazení z `main`.

- Joby `authorize`, `validate` a `select` ověří `main` a 40znakový SHA revize stejně jako `deploy.yml`, bez App klíče.
- Běžný plan běží v environmentu `<plan-environment>-drift` a ruleset plan v `<ruleset-plan-environment>-drift`. Ruleset klíč a token nedostane žádný jiný job.
- Ruleset plan navíc spustí `Test-RulesetBypassVisibility.ps1`. Skript vyžaduje u každého lokálního organizačního rulesetu pole `bypass_actors`; chybějící pole není „bez bypassu“, ale chyba. Zděděné enterprise rulesety skript spočítá a report je uvede jako nepokryté.
- Job `report_drift` v environmentu `drift-report` vyhodnotí výsledky všech jobů skriptem `Get-DriftReport.ps1` bez credentials. Chybějící, neúspěšný nebo nečitelný výsledek označí běh jako neúplný (fail-closed); job pak skončí chybou.
- Pokud report obsahuje drift nebo neúplný běh, job vydá izolovaný installation token s právě `issues: write` pro repozitář instance a `Publish-DriftIssue.ps1` otevře nebo aktualizuje jedno issue s markerem `<!-- platform-drift-report -->` od této App. Bez driftu existující issue nemění.
- Report vždy vypíše oblasti mimo automatickou detekci: ruční enterprise předpoklady, ruční kroky vybraných modulů s jejich omezením driftu a zděděné enterprise rulesety.

App pro issue drift registruje platformní tým ručně a předá ji bootstrapu přes `-DriftReportApp` ([runbook](docs/bootstrap.md#environmenty-noční-plan-a-teardown)).

### Runner modulu

`tools/Invoke-Module.ps1` provede jednu akci `plan`, `apply`, `destroy`, `output` nebo `state` jednoho vybraného modulu či jeho Prerequisite. Terraform běží v `modules/<name>/`. Root musí deklarovat backend odpovídající parametru `-Backend`; runner odmítne implicitní lokální backend.

Produkční backend `azurerm` používá kontejner s názvem modulu, klíč `terraform.tfstate` a autentizaci Entra ID (`use_azuread_auth=true`). Organization-scoped modul má pro každou organizaci vlastní klíč `organizations/<login>/terraform.tfstate`. Název modulu musí mít nejméně tři znaky. Storage account a resource group určí `-StorageAccountName` a `-ResourceGroupName`, nebo proměnné `PLATFORM_STATE_STORAGE_ACCOUNT` a `PLATFORM_STATE_RESOURCE_GROUP`. Credentialy Azure a GitHubu připravuje volající; runner nevydává tokeny, neprovádí přihlášení a nepřechází na PAT. Terraform workspace je `default`; pracovní adresář Terraformu se izoluje pro každý běh.

Root deklaruje standardní proměnné `instance` a `prerequisites`. `instance` obsahuje `name`, `regions`, `teams` a `customPatterns`. Položky `modules.<name>.parameters` jsou další jmenné proměnné Terraformu. `prerequisites` obsahuje mapu přímých předpokladů na jejich necitlivé výstupy, například `var.prerequisites.foundation.foundation_name`. Runner čte soubory `<prerequisite>.json` v `-PrerequisiteOutputsPath`, nikdy state jiného modulu.

`plan` vrací známé hodnoty z uloženého planu, ne staré výstupy state. Terraform exit code `2` znamená změny, nikoli chybu. Neznámý nebo částečně neznámý výstup způsobí chybu; před dalším planem musíš nasadit daný předpoklad. Runner ho nenahradí hodnotou `null`, starým state ani prázdným výsledkem. `apply` a `destroy` provedou uložený plan a pak načtou aktuální výstupy. `destroy` vyžaduje `teardown.allowed: true`; pořadí odstranění více modulů a schválení běhu musí zajistit volající workflow. `destroy` s prázdným state neplánuje a vrátí `HasChanges: false`, takže opakovaný teardown nevyžaduje výstupy už odstraněných předpokladů. `output` načte výstupy z aktuálního state bez planu a bez výstupů předpokladů; workflow teardown je předá závislým modulům. `state` vrátí `Empty: true`, jen když state rootu neobsahuje žádný prostředek ani deposed objekt. Nečte výstupy předpokladů, nevyžaduje token GitHubu ani ruční potvrzení a nemění state ani výstupní artefakt.

Read-only `plan` používá `-lock=false`, aby nevyžadoval oprávnění k zápisu lease ve state backendu. Může souběžně číst state; apply si po schválení vytvoří nový plan se zamykáním. Workflow nepřenáší uložený PR plan do apply.

Přepínač `-Rulesets` vyžaduje deklaraci `rulesetPlan` a spustí celý root `modules/<name>/rulesets/`. Použije stejný kontejner modulu, ale key `terraform.rulesets.tfstate`; u organization-scoped modulu `organizations/<login>/terraform.rulesets.tfstate`. Lokální backend bez této deklarace používá `<module>.rulesets.tfstate`; s ní `<module>/organizations/<login>/terraform.rulesets.tfstate`. Výstup uloží do `<module>.rulesets.json`. Apply workflow provede oba rooty ve všech organizacích před publikací běžných výstupů. Teardown nejdřív odstraní ruleset rooty, potom běžné rooty.

### Organization-scoped moduly

Manifest deklaruje `organizationScoped: true`. Všechny jeho App fáze musí používat `resources.organizations: target_organizations`. Seznam v konfiguraci instance musí odpovídat přesně platformní organizaci, organizaci akcí a workloadů z `Get-PlatformInstanceOrganization`. Runner i token issuer odmítnou podmnožinu, nadmnožinu a jinou velikost písmen. Apps se instalují ručně podle manifestu; plan ověří jejich skutečný rozsah.

Volitelné `organizationParameters: [<parametr>]` označí parametry, jejichž konfigurace má tvar mapy `<login>: <hodnota>`. Mapa musí mít přesně všechny organizační klíče. Terraform proces dostane jen hodnotu vlastní organizace. Například `enterprise-baseline` tak odděluje organizační ID bypass reviewerů. Původní seznam zůstává rozhraním singleton Terraform rootu, nikoli společným seznamem pro všechny organizace.

Job a environment zůstávají společné pro modul a fázi; ruleset plan má vlastní job a credential podle ADR 0017. Runner provede organizace v pořadí platforma → akce → workloady. Veřejný aggregate artifact `<module>.json` obsahuje `organizations` a mapu `organization_outputs`; vytvoří ho až po úspěchu všech organizací. Soubory jednotlivých organizací jsou v `organizations/<login>/<module>[.rulesets].json`. Chyba druhé organizace zachová state první, ale nesmí zveřejnit částečný prerequisite artifact. Opakovaný běh naváže na tytéž state keys.

Drift job zveřejní stav a změny každé organizace. Report označí chybějící, selhanou nebo nečitelnou organizaci jako neúplné ověření, i když ostatní prošly. Teardown čte všechny organizační state bez GitHub tokenů a odstraní moduly v obráceném pořadí předpokladů. Staré společné state keys runner nepřebírá ani nemigruje; upgrade mezi RC release není podporovaný.

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
.\tools\Invoke-Tests.ps1 -Path .\tools\tests\ModuleRunner.Tests.ps1
.\tools\Invoke-Tests.ps1 -Path .\tools\tests\Bootstrap.Tests.ps1
```

Harness přerušení spustíš přes `.\tools\Invoke-Tests.ps1 -Tag Interruption`; cílený běh přijímá i `-Path`. Vedle bootstrapu GitHubu pokrývá Azure backend, phase identities a jejich grants, přípravu acceptance rulesetu a workflow dispatch. Samostatné matice ověřují odstranění bootstrapu a životní cyklus Code Security configuration a custom pattern. Každý zapisující krok ověřuje před zápisem i po ztrátě odpovědi, s dokončením `catch`/`finally` i se simulací náhlého ukončení. Workflow dispatch po ztrátě odpovědi hledá původní run podle uloženého identifikátoru. Pokud požadavek nedorazil, test simuluje předepsané potvrzení člověka, že žádný run neexistuje; nedokazuje automatické zotavení bez tohoto potvrzení. Offline harness nenahrazuje živou akceptaci ani nemění povinnost checků v rulesetu.

`EnterpriseBaseline.Tests.ps1` vytváří pro každý test vlastní TCP listener, server job a stav API stubu; po testu je ukončí i při selhání. Při chybě Terraformu výstup `[terraform-test]` uvádí root, příkaz, exit code Terraformu, nahlášený exit status nebo signál child procesu, cestu a verzi `pwsh`, verzi .NET, `PSModulePath`, `PSModuleAnalysisCachePath` a `XDG_CACHE_HOME`. Původní výstup Terraformu včetně stderr child procesu zůstává součástí chyby. Zjištěný pád runtime test ukončí hned, aby ho nezakryla kontrola nespotřebovaného stubu nebo další apply. Běžné chyby API zůstávají dostupné testům obnovy po ztrátě odpovědi.

Regresní scénáře spustíš přes `.\tools\Invoke-Tests.ps1 -Path .\tools\tests\EnterpriseBaseline.Tests.ps1 -Tag ChildProcessIsolation,ChildProcessCrash,ChildProcessDiagnostic`. Testy mění jen dočasnou kopii skriptu; text signálu přehrávají bez skutečného pádu procesu a bez core dumpu. Ověřují také zachování hexadecimálního exit statusu, okamžité ukončení testu při fatálním statusu Windows, běh bez fixture předchozího testu a uzavření listeneru po neúplném HTTP požadavku. Tyto testy ověřují diagnostiku a izolaci, nikoli odstranění dosud neprokázané příčiny pádu runtime v #158.

Před lokálním gate obnov moduly a ověřený actionlint do worktree cache:

```powershell
.\tools\Install-ToolDependencies.ps1 -Development -Binary Actionlint
.\tools\Invoke-LocalCi.ps1 -Changed
```

`-Changed` nevyžaduje Go ani Terraform. `-Full` s vybranými Terraform rooty nejdřív ověří spuštění `pwsh` přes skutečný Terraform external provider. Sonda používá soukromý TEMP a verzi i hashe provideru z `modules/organizations/.terraform.lock.hcl`. Nefunkční alias Microsoft Store ukončí gate s exit 2; nastav procesový PATH na funkční PowerShell. Actionlint používá pinované archivy pro Windows a Linux amd64; globální instalace není nutná.

CI spouští skutečnou pozitivní a negativní sondu jen v Terraform jobu pro `modules/organizations`. `tools/Test-LocalCiRuntimeProbe.ps1` sestaví offline filesystem mirror z provideru, který už nainstaloval `terraform init`. Sonda provider znovu nestahuje; Pester zůstává offline.

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
| `emu-identity` | Skupiny a přiřazení app rolí v enterprise aplikaci GHE: platformní tým (Enterprise Owner), security tým (User) a uživatelé Copilotu (User). SCIM ze skupin zřídí IdP skupiny. Propojení týmů a enterprise tým s licencí Copilot jsou ruční kroky. | `bootstrap` |
| `organizations` | Organizace akcí a organizace workloadů. | `emu-identity` |
| `organization-roles` | Role `security_manager` pro existující security tým ve všech třech organizacích; bez správy týmu a členství. | `organizations` |
| `organization-rulesets` | Organizační ruleset výchozí větve s review od CODEOWNERS a bez bypassu. | `organizations` |
| `actions-catalog` | Vendorované akce v organizaci akcí. | `organization-rulesets` |
| `enterprise-baseline` | Code security configurations, politika akcí a custom patterns. Neautomatizované enterprise kontroly jsou ruční předpoklad. | `actions-catalog` |
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

1. GitHub governance: `bootstrap`, `emu-identity`, `organizations`, `organization-roles`, `organization-rulesets`, `actions-catalog`, `enterprise-baseline`. Přírůstek končí testem teardownu.
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
- Po merge PR schválí platformní tým jednou celý běh apply. Běhy modulů `enterprise-baseline` a `organization-rulesets` navíc schvaluje security tým.
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
- Release vzniká pushem tagu `vMAJOR.MINOR.PATCH` na commit z `main`. Tag `vMAJOR.MINOR.PATCH-rc.N` vydá release candidate jako prerelease. Workflow `.github/workflows/release.yml` sestaví asset `platform-<tag>.zip`, vytvoří k němu build provenance attestaci a publikuje release. Publikovaný release se nemění; oprava vyžaduje nový tag.
- Upgrade z release candidate není podporovaný. Release candidate se nasazuje na novou instanci nebo po teardownu.- Jeden opakovaně použitelný workflow vendoringu importuje release platformy, akce i skilly. Workflow stáhne zdroj podle tagu, ověří attestaci a otevře PR s diffem. Import release vyžaduje ověřenou attestaci z `release.yml` tohoto repozitáře.
- Repozitář instance spustí import workflowem `import-release.yml` se vstupem `tag`. PR mění jen `platform/`.
- PR otevírá installation token s oprávněními k cílovému repozitáři. Pokud privátní zdroj release není dostupný installation tokenem enterprise-owned App, import zůstává ruční do jeho zpřístupnění; workflow nepoužije osobní PAT ani OAuth token.

### Přechod z upstream akcí na katalogové kopie

Živé workflow instance po bootstrapu používají upstream akce připnuté na SHA. Přechod na kopie v organizaci akcí probíhá v tomto pořadí:

1. Platformní tým importuje každou akci workflowem vendoringu (`kind: action`) do organizace akcí a security tým schválí PR (#15).
2. Platformní tým zapíše SHA schválených merge commitů do `vendoring/actions.json`.
3. Import release přepíše `uses` v šablonách pod `platform/` na katalogové kopie.
4. Platformní tým samostatným PR povýší přepsané šablony z `platform/templates/instance/.github/workflows/` do `.github/workflows/`. Security tým schválí diff. Postup popisuje [Vendoring](docs/vendoring.md#ruční-povýšení-živých-workflow-v-16).

## Teardown

Teardown má dvě fáze. Workflow `teardown` v repozitáři instance odstraní moduly. Lokální skript `tools/Remove-Bootstrap.ps1` potom odstraní prostředky bootstrapu. Tenant, enterprise s OIDC a SCIM, subscriptions, licence a ručně nastavené enterprise kontroly zůstanou beze změny, takže instanci jde nasadit znovu.

### Ruční krok před teardownem

Ruční krok `emu-identity` po prvním nasazení odebral prvnímu enterprise ownerovi přímé přiřazení app role Enterprise Owner. Destroy modulu `emu-identity` odstraní skupinu platformního týmu. Bez přímého přiřazení by platformní tým ztratil roli Enterprise Owner a lokální skript by nemohl odstranit organizaci.

Před spuštěním teardownu proto administrátor Entra ID přiřadí aspoň jednomu členovi `teams.platform` app roli Enterprise Owner na enterprise aplikaci přímo, ne přes skupinu. Workflow přiřazení ověří před prvním destroy. Přiřazení přes skupinu nestačí.

### Workflow `teardown`

Generátor `tools/Generate-TeardownWorkflow.ps1` vytvoří `.github/workflows/teardown.yml` z vybraných modulů. CI selže, pokud se commitnutý workflow liší od výstupu generátoru.

1. Workflow spustíš ručně (`workflow_dispatch`) na větvi `main`. Vstup `instance` musí přesně odpovídat `name` z `instance.yaml`.
2. Job `select` odmítne běh, pokud `teardown.allowed` není `true` nebo instance nevybírá modul `emu-identity`. Výchozí hodnota `teardown.allowed` je `false`.
3. Environment `approve-teardown-platform` vyžaduje schválení platformním týmem. Potom environment `teardown` vyžaduje schválení security týmem.
4. Job `enterprise_owner` v plan environmentu `emu-identity` ověří přes Graph přímé přiřazení Enterprise Owner. Pokud chybí, skončí chybou s popisem ručního kroku.
5. Joby `outputs_<module>` načtou ze state výstupy modulů, na kterých závisí jiné moduly.
6. Joby `destroy_<module>` běží v apply environmentu modulu v obráceném pořadí předpokladů. Destroy `emu-identity` běží jako poslední, až po úspěchu nebo přeskočení destroy ostatních modulů, protože odstraní týmy, jejichž schválení vyžadují apply environmenty ostatních modulů. Každý job použije installation token App modulu pro apply, ne PAT. Modul s ruleset rootem odstraní nejdřív ruleset root. Opakovaný destroy modulu s prázdným state skončí bez změny a nevyžaduje výstupy předpokladů. Modul s tokenem App omezeným na organizace (`resources.organizations`) nejdřív přečte state všech svých rootů akcí `state`. Pokud jsou všechny prázdné, job nevydá token ani nespustí destroy, protože smazané organizace už instalaci App nemají. Jiný nebo chybějící výsledek kontroly destroy nepřeskočí.
7. Těsně před každým destroy krokem skript `Assert-TeardownMainCommit.ps1` přečte přes [Get a reference](https://docs.github.com/en/enterprise-cloud@latest/rest/git/refs#get-a-reference) ref `main`. Pokud `main` neukazuje na commit spuštěného běhu, job skončí chybou bez destroy. Merge během čekání na schválení, například `teardown.allowed: false`, proto zastaví teardown. Teardown pak spusť znovu z aktuální `main`.
Teardown sdílí concurrency skupinu `deploy-instance-main` s nasazením z `main`. Noční `drift.yml` má vlastní skupinu a může běžet souběžně. Pokud drift plan drží zámek state, destroy modulu skončí chybou a teardown spusť znovu. Drift po teardownu může otevřít issue s chybějícími zdroji.

Workflow neodstraní `bootstrap`. Organizační politiky, rulesety, code security configurations a custom patterns odstraní destroy modulů, které je spravují.

### Lokální odstranění bootstrapu

Skript spusť až po úspěšném workflow `teardown`. Potřebuje inventory `bootstrap-resources.json` z bootstrapu, OAuth login `gh auth login --hostname <enterprise>.ghe.com` se scope `delete_repo` a `az login --tenant <tenantId>` uživatele platformního týmu s přímou rolí Enterprise Owner. Login z bootstrapu scope `delete_repo` nemá; doplň ho příkazem `gh auth refresh --hostname <enterprise>.ghe.com --scopes delete_repo`:

```powershell
.\tools\Remove-Bootstrap.ps1 -InstancePath .\instance.yaml -InventoryPath ..\secure\bootstrap-resources.json -ConfirmInstanceName demo
```

- Skript odmítne `GH_TOKEN`, `GITHUB_TOKEN`, `GH_ENTERPRISE_TOKEN`, `GITHUB_ENTERPRISE_TOKEN` a jiný GitHub token než OAuth token (`gho_`). Odmítne inventory uvnitř source checkoutu.
- Před prvním zápisem ověří scope `delete_repo` v hlavičce `X-OAuth-Scopes` odpovědi `GET /user`. Chybějící hlavičku nebo scope odmítne, protože smazání repozitáře by selhalo až po vypnutí Actions.
- Před prvním krokem zapíše do inventory ID přihlášeného uživatele GitHub (`GET /user`). Obnovený běh jiného uživatele odmítne, protože GitHub skrývá prostředky bez přístupu odpovědí 404. Inventory se zahájenými kroky bez ID uživatele odmítne.
- Před smazáním repozitáře ověří, že poslední běh `teardown.yml` na `main` skončil úspěchem a v repozitáři neběží ani nečeká žádný workflow run. Ověří také, že se po vytvoření (dispatch) posledního běhu teardownu nezměnil žádný běh `deploy.yml` na žádné větvi. Porovnává `updated_at` běhu deploy s `created_at` běhu teardown. Opakovaný běh (rerun) teardownu zachová `created_at` a přeskočí joby, které uspěly před nasazením. Po nasazení proto skript vyžaduje nový dispatch teardownu, rerun nestačí. Apps zůstanou, dokud běží workflow, která je potřebují.
- Potom zapíše krok `started`, vypne GitHub Actions v repozitáři instance a kontrolu zopakuje. Nový workflow run proto nemůže začít mezi kontrolou a smazáním. Pokud druhá kontrola selže, Actions zůstanou vypnuté; před novým spuštěním workflow `teardown` je zapni.
- Prostředek GitHubu, který inventory neeviduje, skript ověří podle deterministického názvu. Bootstrap vytváří organizaci a repozitář před jejich zápisem do inventory. Existující neevidovaný prostředek zastaví běh: spusť znovu bootstrap se stejným inventory, nebo ověř vlastnictví a smaž ho ručně.
- Skript odstraní v tomto pořadí: repozitář instance, organizaci platformy, Azure role assignments identit modulů mimo resource group bootstrapu, vlastní Entra directory roles a jejich přiřazení, lock state storage a resource group bootstrapu s identitami a state backendem.
- Před každým smazáním ověří vlastnictví: popis a viditelnost repozitáře, záznam organizace v inventory, ownership tags v Azure a název, popis a příznak `isBuiltIn` directory role. Nesouhlas nebo nečitelná odpověď zastaví běh bez smazání.
- Smazání organizace a resource group probíhá asynchronně. Skript čeká, dokud API nevrátí 404; jinak krok zůstane `started` a další běh čekání obnoví.
- Před prvním smazáním skript zapíše do inventory `principalId` managed identit v resource group bootstrapu. Nové nasazení vytvoří identity s novými `principalId`. Každý další krok v Azure, včetně obnoveného běhu, proto ověří shodu s uloženou sadou a jinou sadu odmítne. Během mazání resource group smí identity jen ubývat.
- Před každým vzdáleným smazáním skript zapíše do inventory stav kroku `started`, po něm `done`. Po přerušení oprav příčinu a spusť stejný příkaz; skript dokončí rozpracovaný krok a hotové kroky přeskočí. Chybějící prostředek, jehož odstranění nezačalo, zastaví běh; rozhodnutí patří platformnímu týmu.
- `-WhatIf` vypíše cíl bez změny. Potvrzení `-Confirm` se týká celého odstranění; jednotlivé kroky se znovu nepotvrzují.

Skript vrátí ruční kroky, které API nepokrývá. Při akceptaci je musíš potvrdit:

- Smaž každou GitHub App instance podle App ID z inventory, včetně dřívějších App IDs. GitHub nemá API pro smazání App.
- Smaž lokální privátní klíče Apps.
- Archivuj inventory.
- Přímé přiřazení Enterprise Owner ponech, pokud chceš instanci nasadit znovu.

## Testování release

- CI ve zdrojovém repozitáři spouští `terraform fmt`, `terraform validate`, tflint, Trivy, validaci JSON Schema a kontrolu cyklů v předpokladech.
- Každý release candidate se nasadí celý na referenční instanci.
- Akceptace ověří skutečný rozsah oprávnění každého jobu, úplné čtení bypass konfigurace, odmítnutí credentials pro neautorizované PR a zachování ručních enterprise předpokladů při teardownu.
- Před každým minor release proběhne teardown referenční instance a její nové nasazení.
- Kroky platformního týmu na referenční instanci popisuje [Příprava a akceptace referenční instance](docs/reference-instance.md). Ruční předpoklady připraví a ověří průvodce `tools/Start-InstanceSetup.ps1`; přepínač `-GitHubAcceptance` přidá akceptaci bootstrapu #11 s potvrzovanými cloudovými změnami a lokálními důkazy.
