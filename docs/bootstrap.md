# Lokální bootstrap Azure a GitHubu

`tools/Invoke-Bootstrap.ps1` vytvoří state backend a identity vybraných modulů včetně jejich předpokladů. Spouští ho člen týmu Platform team (platformní tým) z vendorovaného release. Nástroj nevyžaduje PAT, nemění konfiguraci instance a nevytváří prostředky GitHubu.

Navazující `tools/Invoke-GitHubBootstrap.ps1` vytvoří organizaci platformy, repozitář instance, týmy, environmenty a federated credentials. Ověří enterprise-owned Apps a vloží jejich klíče do environment secrets. Oba skripty běží lokálně; běžná workflow pak používají jen installation tokeny Apps a Azure OIDC.

## Konfigurace a přihlášení

Instance repository (repozitář instance) je repozitář v organizaci platformy s vendorovaným release v `platform/`, souborem `instance.yaml` a workflow nasazení. Vytvoří ho GitHub část bootstrapu. Lokální bootstrap Azure proto poprvé běží dřív, než repozitář instance existuje.

Platform team (platformní tým) zapíše skutečné identifikátory do `instance.yaml` v repozitáři instance. Dokud repozitář instance neexistuje, leží konfigurace mimo checkout zdrojového repozitáře. Pro referenční instanci ji vygeneruje průvodce `tools/Start-InstanceSetup.ps1` v kroku B1 [runbooku referenční instance](reference-instance.md). Hodnoty a jejich původ uvádí stejný krok. Pro jinou instanci platformní tým zkopíruje šablonu `templates/instance/instance.yaml` mimo checkout a vyplní kopii. Zdrojový repozitář nesmí obsahovat data instance, například ID tenantu, ID subscriptions nebo název enterprise (ADR 0012). Šablona proto zůstává s nulovými identifikátory. Formát všech položek popisuje [README](../README.md#instance-configuration-konfigurace-instance).

Kopie konfigurace obsahuje tyto položky:

| Položka `bootstrap` | Hodnota |
|---|---|
| `tenantId` | ID tenantu Entra ID. |
| `managementSubscriptionId` | ID subscription pro state backend a identity. |
| `subscriptionIds` | Všechny subscriptions instance, včetně management subscription a subscriptions ze scope oprávnění modulů. |
| `enterpriseApplicationObjectId` | Object ID service principal enterprise aplikace **GitHub Enterprise Managed User (OIDC)**, nikoli její application/client ID. |
| `githubHost` | Host enterprise, například `example.ghe.com`. |
| `enterprise` | Slug enterprise, například `example`; musí odpovídat hostu. |

Bootstrap vyžaduje PowerShell 7.4+, parser YAML z `tools/requirements.psd1`, Azure CLI a GitHub CLI. Člověk provede interaktivní přihlášení:

```powershell
.\tools\Install-ToolDependencies.ps1
az login --tenant '<tenant-id>'
gh auth login --hostname example.ghe.com --web --scopes read:enterprise
```

Parser YAML je přibalený v `tools/vendor/`. Instalační skript bez `-Development` pouze ověří jeho integritu; bootstrap ani deploy nestahují moduly z PSGallery. Přepínač `-Development` stáhne vývojové moduly do izolované cache a ověří SHA256 i obsah před importem. Stahování balíčku opakuje nejvýše čtyřikrát (`-MaxAttempts 4`) s prodlevami 15, 30 a 45 sekund (`-RetryDelaySeconds 15`). Neshodu hashe nesmí opakovat ani obejít. Postup aktualizace uvádí [provenience závislostí](../tools/vendor/PROVENANCE.md).

Bootstrap čte uložený token pomocí `gh auth token --hostname`. Přijme jen OAuth token `gho_`; odmítne classic i fine-grained PAT. Proměnné `GH_TOKEN`, `GITHUB_TOKEN`, `GH_ENTERPRISE_TOKEN` a `GITHUB_ENTERPRISE_TOKEN` musí být v procesu bootstrapu prázdné. Bootstrap token nevypisuje, neukládá do souboru ani nepředává jako argument dalšího procesu.

Uživatel Azure musí patřit do `teams.platform`. Administrátor Entra ID mu musí **přímo** přiřadit app roli Enterprise Owner v aplikaci EMU. Přiřazení přes skupinu nestačí. Uživatel přihlášený přes `gh` musí být owner stejného enterprise; oba účty musí podle ručního potvrzení patřit spouštějícímu člověku.

Uživatel Azure potřebuje oprávnění vytvářet resource group, storage account, blob service, containers, lock a user-assigned managed identity v management subscription. Potřebuje také `Microsoft.Authorization/roleAssignments/read` a `write` na všech deklarovaných scope a čtení role definitions. Bootstrap nesmí sám rozšířit oprávnění spouštějícího uživatele.

Audit identit navíc vyžaduje čtení hierarchie management groups přes `Microsoft.Management/getEntities/action` a čtení role assignments na všech předcích deklarovaných subscriptions, včetně tenant root group. Chybějící oprávnění nebo neúplný řetězec předků zastaví bootstrap před první změnou.

Delegovaný token Microsoft Graph musí umožnit čtení uživatele, enterprise aplikace a jejích app role assignments, synchronization jobs, subscribed SKUs, Graph application permissions a oprávnění managed identities. Přidělení application permissions vyžaduje administrátorský souhlas a oprávnění pro app role assignment; pro Microsoft Graph ho typicky provádí Privileged Role Administrator nebo Global Administrator. Tato pravomoc patří člověku pro bootstrap, **nikoli** identitě `emu-identity`. Pokud token Azure CLI nebo role uživatele nestačí, API vrátí konkrétní chybu; bootstrap nevytváří další credential ani nepřechází na PAT.

## Manual prerequisites (ruční předpoklady)

Platform team (platformní tým) nastaví `true` až po ověření každé položky. Pro referenční instanci příznaky nastaví průvodce `tools/Start-InstanceSetup.ps1`, až když prošly kroky, které příznak potvrzují ([runbook referenční instance](reference-instance.md#průvodce)). Chybějící nebo nepravdivé potvrzení zastaví bootstrap před přihlášením a před první změnou.

| Potvrzení | Co musí člověk ověřit |
|---|---|
| `tenant` | Instance používá určený tenant Entra ID. |
| `enterpriseOidc` | Enterprise EMU na GHE.com má OIDC SSO v tomto tenantu. |
| `enterpriseScim` | SCIM provisioning míří na tuto enterprise instanci a úspěšně provisionoval spouštějícího uživatele. |
| `enterpriseOwner` | Spouštějící člověk má přímo přiřazenou roli Enterprise Owner a odpovídající účet ownera v GitHubu. |
| `subscriptions` | Všechny subscriptions instance existují, patří do tenantu a mají potřebné resource providers a oprávnění. |
| `licenses` | Instance má Entra ID P1 nebo P2, GitHub Enterprise, Copilot a security licence potřebné pro vybrané moduly. |
| `privateInternalForksDisabled` | Enterprise zakazuje private **i** internal forky. |
| `repositoryManagementPoliciesEnforced` | Enterprise zakazuje členům zakládat repozitáře, měnit jejich viditelnost a mazat nebo přenášet repozitáře. |
| `emuUserNamespacesRestricted` | Enterprise omezuje repozitáře v EMU user namespaces podle ADR 0016. |
| `fineGrainedPatApprovalRequired` | Enterprise vyžaduje schválení fine-grained PAT. |
| `patMaxLifetime90Days` | Enterprise omezuje maximální platnost PAT na 90 dní. |
| `githubAppAvailabilityVerified` | Člověk ověřil dostupnost enterprise-owned Apps, potřebných API, oprávnění a tokenové akce na této GHE.com instanci. |

O omezení classic PAT zatím není rozhodnuto. Bootstrap žádnou takovou politiku nezavádí.

Bootstrap navíc přes API ověří tenant tokenů, členství uživatele v `teams.platform`, přímé přiřazení Enterprise Owner, aktivní SCIM job bez quarantine, aktivní licenci Entra ID P1/P2, tenant a stav všech subscriptions a roli ownera pro účet OAuth v GitHubu. Pokud Graph vrátí OIDC launch mode, bootstrap odmítne jiný režim než `oidc`. Graph může u platné OIDC aplikace vrátit `null`; v tom případě bootstrap výslovně varuje a používá povinné ruční potvrzení `enterpriseOidc`. Výsledek `OidcModeVerified: false` přizná, že API režim neověřilo. Enterprise politiky, správnost cíle a mapování SCIM a ostatní licence ověří člověk. Potvrzení není automatická detekce Drift (driftu).

## Preflight (předběžná kontrola)

`tools/Test-BootstrapPrerequisites.ps1` spustí stejné kontroly jako bootstrap a nic nezmění. Nezastaví se na první chybě. Pro každou kontrolu vrátí objekt s vlastnostmi `Area`, `Check`, `Status` a `Detail`:

```powershell
.\tools\Test-BootstrapPrerequisites.ps1 -InstancePath '<path>\instance.yaml' | Format-Table -Wrap
```

Preflight nevyžaduje potvrzené příznaky `manualPrerequisites`. Každý příznak vypíše jako řádek se stavem `Confirmed` nebo `Manual`. Chybná konfigurace nebo schéma ukončí preflight chybou stejně jako bootstrap.

Při prvním běhu Apps ještě nejsou registrované. Použij veřejný přepínač `-AllowUnboundApps` v preflightu i Azure bootstrapu:

```powershell
.\tools\Test-BootstrapPrerequisites.ps1 -InstancePath $cfg -AllowUnboundApps | Format-Table -Wrap
$azure = .\tools\Invoke-Bootstrap.ps1 -InstancePath $cfg -AllowUnboundApps
```

Přepínač dovolí pouze chybějící vazby `credentials.<module>.<phase>.githubApp`. Neobejde validaci deklarované App, oprávnění, scope ani ručních předpokladů bootstrapu. Azure část žádný klíč GitHub App nepoužívá. Jakmile platformní tým Apps zaregistruje a doplní vazby, spouštěj další preflight i Azure bootstrap **bez** přepínače. Chybějící povinná vazba pak skončí chybou před změnou prostředků.

| `Status` | Význam |
|---|---|
| `Pass` | API potvrdilo podmínku. |
| `Fail` | Bootstrap by se na této kontrole zastavil. `Detail` uvádí příčinu. |
| `Skip` | Kontrola neproběhla, protože selhala kontrola, na které závisí. |
| `Manual` | API podmínku neověří, nebo příznak `manualPrerequisites` není `true`. |
| `Confirmed` | Příznak `manualPrerequisites` je `true`. |

Kromě kontrol bootstrapu preflight ověří:

- Resource providers `Microsoft.Storage` a `Microsoft.ManagedIdentity` jsou v management subscription registrované.
- Efektivní akce uživatele v management subscription umožní všechny zápisy bootstrapu včetně locku a role assignments.
- Existující resource group a storage account state backendu mají ownership tags této instance. Pokud storage account neexistuje, jeho název je dostupný.
- Uživatel smí zapsat role assignments na všech scope oprávnění modulů. Scope management group vrátí `Manual`, protože Azure pro ni efektivní oprávnění nevrací.

Kontrola efektivních akcí nevyhodnocuje ABAC podmínky ani deny assignments. `Pass` proto neznamená, že zápis určitě projde. `Detail` může obsahovat ID subscriptions a scope. Výstup patří do issue jen bez těchto údajů (ADR 0012).

Bootstrap spusť, až žádný řádek nemá `Fail` ani `Skip`, všechny příznaky mají `Confirmed` a každý jiný řádek `Manual` člověk ověřil.

## Spuštění a výstup

Po vzniku repozitáře instance (#11) spusť z jeho kořene:

```powershell
$bootstrap = .\platform\tools\Invoke-Bootstrap.ps1 -InstancePath .\instance.yaml
$bootstrap | ConvertTo-Json -Depth 10
```

Dokud repozitář instance neexistuje, spusť ze zdrojového repozitáře `.\tools\Invoke-Bootstrap.ps1` a v `-InstancePath` uveď cestu ke kopii konfigurace mimo checkout. Parametr `-ModulesPath` může určit jiný adresář manifestů.

Výsledek obsahuje `TenantId`, `SubscriptionId`, `ResourceGroupName`, `StorageAccountName`, `OidcModeVerified`, `Modules` a `HasChanges`. Každý modul má `Name`, `ContainerName` a záznamy `Plan` a `Apply` s `ResourceId`, `PrincipalId` a `ClientId`. Výstup neobsahuje tokeny. Navazující bootstrap GitHubu použije tyto identity pro federated credentials environmentů.

Runner modulu používá stejný název kontejneru a key `terraform.tfstate`. Název backendu mu můžeš předat přímo:

```powershell
$env:PLATFORM_STATE_STORAGE_ACCOUNT = $bootstrap.StorageAccountName
$env:PLATFORM_STATE_RESOURCE_GROUP = $bootstrap.ResourceGroupName
```

Azure část bootstrapu nevytváří federated credentials ani workflow. GitHub část je vytvoří podle následujícího postupu; sama moduly nenasazuje.

## GitHub část bootstrapu

Pro samostatnou akceptaci #11 použij `tools\Start-InstanceSetup.ps1 -GitHubAcceptance` podle [runbooku](reference-instance.md#akceptace-github-části-bootstrapu-11). Průvodce naváže na ověřené vstupy #10, připraví schválený izolovaný kandidát s probe manifesty a ponechá produkční `deploy.yml` vypnuté. Příznak `-AcceptanceOnly` smí `Invoke-GitHubBootstrap.ps1` použít jen s takto označeným kandidátem; běžný release ho odmítne. Bootstrap-only akceptace nesmí čekat na implementaci modulů blokovaných #11 a nenahrazuje jejich produkční API a deployment akceptaci.

Platform team (platformní tým) musí použít schválený Release (release). `-ReleasePath` určuje jeho rozbalený adresář a `-ReleaseVersion` verzi SemVer bez prefixu `v`. Skript musí pocházet ze stejného release. Pro Git checkout musí `HEAD` odpovídat tagu `v<verze>` a checkout nesmí mít změněné ani nesledované soubory. U rozbaleného archivu člověk předem ověří původ a attestaci podle procesu release; samotný parametr verze není důkaz původu. Skript ověří shodu vygenerovaného workflow s manifesty a zapíše SHA-256 každého vendorovaného souboru do `.platform-bootstrap.json`.

OAuth login potřebuje scopes `admin:enterprise`, `admin:org`, `repo` a `workflow`. Člověk je schválí při přihlášení; skript je sám nerozšiřuje. Azure login musí umožnit číst identity a vytvářet federated credentials na identitách z výstupu Azure bootstrapu.

```powershell
gh auth login --hostname example.ghe.com --web --scopes admin:enterprise,admin:org,repo,workflow
$azure = .\tools\Invoke-Bootstrap.ps1 -InstancePath $cfg -AllowUnboundApps
$arguments = @{
    InstancePath = $cfg
    AzureBootstrap = $azure
    ReleasePath = (Get-Location).Path
    ReleaseVersion = '<schvalena-verze>'
    InventoryPath = '<pracovni-adresar>\bootstrap-resources.json'
}
.\tools\Invoke-GitHubBootstrap.ps1 @arguments -ResourcesOnly
```

`-AzureBootstrap` přijme objekt skriptu nebo JSON načtený přes `ConvertFrom-Json -AsHashtable`. Skript porovná tenant, subscription, názvy prostředků, resource IDs, client IDs a skutečné ownership tags identit.

### Příprava registrace Apps

`-ResourcesOnly` vytvoří organizaci platformy `{name}-{deployment}-platform`, soukromý repozitář `instance`, týmy `platform` a `security`, environmenty a OIDC vazby. Spouštějící managed user musí být enterprise owner; při inicializaci ho bootstrap přidá do obou týmů. Toto členství nahradí propojení se skupinami Entra ID. Propojení provede platformní tým v ručním kroku `link-organization-teams` modulu `emu-identity`. Po publikaci instance bootstrap přímé členství znovu neobnovuje.

`{deployment}` je Deployment identifier (identifikátor nasazení) podle [ADR 0008](adr/0008-deployment-identifier-in-retained-names.md). Bootstrap ho vytvoří při prvním běhu bez inventory: 6 náhodných znaků `[a-z0-9]`. Hodnotu uloží do pole `deploymentIdentifier` v `bootstrap-resources.json` před požadavkem na vytvoření organizace. Další běh se stejným inventory použije stejný identifikátor, i když předchozí běh skončil před potvrzením organizace. Identifikátor není v `instance.yaml`. Nejdelší název organizace má 25 znaků (`instance.name` má nejvýše 8 znaků), limit GitHubu je 39 znaků.

Pokud inventory eviduje organizaci platformy a organizace už neexistuje, bootstrap skončí chybou bez zápisu. GHE.com název smazané organizace neuvolní. Nové nasazení proto začíná s novým inventory a dostane nový identifikátor.

Inventory vytvořené před zavedením identifikátoru nemá pole `deploymentIdentifier`. Bootstrap pro něj zachová název `{name}-platform` a pole nedoplní. Existující instance tak zůstane beze změny a bez migrace. Nový identifikátor dostane až nové nasazení s novým inventory.

Repozitář zatím obsahuje jen inicializační commit GitHubu, bez workflow instance, a má vypnuté Actions. Bootstrap uloží `initializationPending=true` před požadavkem na vytvoření repozitáře. Pokud GitHub repozitář vytvoří, ale odpověď se ztratí, další běh se stejným inventory převezme tento repozitář, vypne Actions a načte jeho seed commit; neposílá další create request. Pokud vypnutí Actions selže, další běh ho zopakuje před pokračováním inicializace. Výsledek má `CredentialsConfigured: false`; příprava není dokončený bootstrap. V této fázi může chybět alias App u vybraného modulu. Plná validace a dokončení ho vyžadují. Po vzniku organizace může GitHub vyžadovat nové SSO přihlášení a obnovení `gh auth login`; skript vrátí chybu a další běh pokračuje se stejným inventory. U již dokončené instance `-ResourcesOnly` nevypíná Actions ani neodstraňuje credentials.

Platformní tým potom v **Enterprise settings → GitHub Apps** ručně registruje Apps a nainstaluje je do přesně deklarovaných organizací:

| App | Oprávnění a rozsah |
|---|---|
| Autorizační App | Jen `members: read`, pouze organizace platformy, žádné repozitáře. Samostatná identita; nesmí ji sdílet modul. |
| App fáze modulu | Přesně `permissions` a `resources` manifestu a aliasu v `instance.yaml`. Plan a apply používají odlišné identity. |
| App běžného planu `enterprise-baseline` | `organization_administration: read`, `administration: read` a `metadata: read`, všechny repozitáře ve všech cílových organizacích. Repository Administration umožní číst přímý stav Code Security přes `security_and_analysis`; platí i pro noční drift. |
| App ruleset planu | Jen `organization_administration: write`, přesně cílové organizace. Oddělená od běžného planu i apply. |
| App importu release | Přesně `contents: write` a `pull_requests: write`, selected installation pouze na `instance` v organizaci platformy. Samostatná identita pro `vendoring-release-import`. |
| App importu akcí | Přesně `contents: write` a `pull_requests: write`, selected installation na katalogové repozitáře pouze v organizaci akcí. Samostatná identita pro `vendoring-action-import`. |
| App privátního zdroje | Volitelná, přesně `contents: read` a `attestations: read`, selected installation na jediný deklarovaný zdroj. Samostatná identita pro `vendoring-source`. Veřejný import ji nepoužije. |

Instalace navazujících modulů připrav podle [checklistu odvozeného z manifestů](../README.md#module-manifest-manifest-modulu). `resources.installationSelection: none` vyžaduje instalaci bez repozitářů; `all` vyžaduje všechny repozitáře cílové organizace. App s jinak pouze organizačními oprávněními musí pro `all` deklarovat také `metadata: read`. Týká se to příslušných fází `actions-catalog` a `enterprise-baseline`; oprávnění kopíruj z manifestu, nepřidávej je ostatním Apps. Token issuer odmítne jinou organizaci nebo jiný výběr repozitářů i při aktuálně prázdné organizaci.

Nové `administration: read` patří jen běžnému planu `enterprise-baseline`, který počítá Code Security coverage. Apply, oddělený ruleset plan ani plan `organization-rulesets` ho nepotřebují. App tohoto planu proto nesmí sdílet alias s planem, jehož manifest požaduje jinou sadu oprávnění. Chybějící přímý stav zůstává `unverified`, nikdy compliant; vynucená konfigurace sama přímý stav nedokazuje.

Pokud cílové organizace ještě neexistují, nejprve nasaď `organizations`. Pak připrav konfiguraci druhé etapy, ručně nainstaluj její Apps, doplň bindings a znovu ověř bootstrap. Změnu `githubApps` nebo `credentials` existující instance předlož přes PR podle [postupu pro chráněné vazby](#pr-se-změnou-githubapps-nebo-credentials). Pro `organization-roles` navíc vytvoř a propoj security týmy podle [README modulu](../modules/organization-roles/README.md#nasazení-ve-dvou-etapách). Modul instalace, týmy ani SCIM linky nevytváří.

### Nový živý krok: časná Code Security fáze před prvním úplným deploy

Rozhodnutí koordinátora: První nasazení má pořadí `code-security` → `catalog` → import a povýšení workflow → `full`. Pro oba staged běhy otevři v repozitáři instance **Actions → Deploy instance → Run workflow** na chráněné větvi `main`. Jde o dva nové živé uživatelské kroky. Výchozí volba `full` spouští běžný deploy; `push` a PR dál používají úplný graf. Nepodporovanou, prázdnou nebo jinak velkými písmeny zapsanou hodnotu dispatch odmítne první job bez credentials ještě před autorizací.

**Doporučená příprava custom patterns před prvním `deployment: code-security`.** Pokud `customPatterns` v `instance.yaml` není prázdné, operátor by měl ručně vytvořit a publikovat každý uvedený pattern ve všech organizacích z `target_organizations` modulu `enterprise-baseline`. Pokud organizace ještě neexistují, nejprve nasaď `organizations` podle předchozího postupu. Apply časné fáze postupuje po organizacích a skončí u první chyby; bez přípravy může vytvořit nepublikovaný pattern jen v první organizaci a k dalším se nedostat.

**Předpoklad dry run:** Publikace vyžaduje dokončený dry run. Ten potřebuje alespoň jeden repozitář se zapnutým secret scanningem v dané organizaci. Pokud cílová organizace nemá repozitář, nejprve v ní vytvoř dočasný **privátní** repozitář a inicializuj ho commitem, například vytvořením README. Zapni v něm secret scanning. Pro [aktualizaci repozitáře přes REST API](https://docs.github.com/en/rest/repos/repos?apiVersion=2026-03-10#update-a-repository) použij `PATCH /repos/{owner}/{repo}`, hlavičku `X-GitHub-Api-Version: 2026-03-10` a tělo:

```json
{
  "security_and_analysis": {
    "secret_scanning": {
      "status": "enabled"
    }
  }
}
```

Operátor nesmí v tomto požadavku poslat pole `advanced_security`; při živém ověření nahlášeném uživatelem GitHub požadavek s tímto polem odmítl HTTP 422. Po publikaci všech nakonfigurovaných patterns v organizaci můžeš dočasný repozitář smazat. Operátor nesmí v rámci tohoto kroku smazat jiné repozitáře ani repozitář instance.

Ruční přípravu proveď takto:

1. V nastavení každé cílové organizace otevři **Security → Advanced Security → Global settings → Custom patterns**.
2. Pro každý záznam v `customPatterns` otevři existující pattern se stejným názvem, nebo zvol **New pattern**. Do **Pattern name** zkopíruj `name` přesně, včetně velikosti písmen. Do **Secret format** zkopíruj `secretRegex`. V **More options** nastav oddělovače podle `beforeSecret` a `afterSecret`; chybějící nebo prázdné hodnoty znamenají `\A|[^0-9A-Za-z]` a `\z|[^0-9A-Za-z]`. Další podmínky `must_match` a `must_not_match` ponech prázdné.
3. Do povinného pole **Test string** vlož smyšlený řetězec, který odpovídá regexu, ne skutečný secret. Pro formát `PLATFORMTEST_[A-Z0-9]{20}` sestav hodnotu z prefixu `PLATFORMTEST_` a přesně 20 velkých písmen `A-Z` nebo číslic `0-9`. Hotovou hodnotu neukládej do souborů repozitáře; push protection by ji zablokovala. Test string není součást konfigurace a plan ho neporovnává.
4. U nepublikovaného patternu nejprve dokonči dry run: zvol **Save and dry run**, vyber repozitář se zapnutým secret scanningem a spusť **Run**. Po dokončení zkontroluj výsledky a zvol **Publish pattern**. Pokud již dry run proběhl a tlačítko je aktivní, můžeš pattern rovnou publikovat. Regex ani oddělovače neměň kvůli zpřístupnění publikace; plan je porovnává s konfigurací. Postup GitHubu popisuje [vytvoření custom patternu pro organizaci](https://docs.github.com/en/code-security/how-tos/secure-your-secrets/customize-leak-detection/define-custom-patterns#defining-a-custom-pattern-for-an-organization).
5. Ověř stav `published` pro každý nakonfigurovaný pattern ve všech cílových organizacích. Push protection ručně nezapínej; zapne ji apply. Modul převezme existující pattern podle přesného názvu a nevytvoří duplikát. Rozdílný obsah upraví přes PATCH, proto musí ruční příprava odpovídat konfiguraci.

Publikace je plánovaný ruční krok: REST API custom patterns nemá operaci pro změnu stavu `published`/`unpublished`. Stejnou přípravu proveď pro každý nový záznam v `customPatterns` před dalším apply časné fáze a po teardownu a opětovném nasazení.

Při prvním běhu vyber `deployment: code-security`. Běh vybere pouze `enterprise-baseline:code-security` a jeho skutečné předpoklady, včetně `organizations`. Nespouští pozdní `enterprise-baseline`, `organization-rulesets` ani `actions-catalog`. Konfigurace `instance.modules.enterprise-baseline.parameters` musí obsahovat `target_organizations` a hodnoty `secret_scanning_bypass_reviewers` po jednotlivých organizacích; App bindings odpovídají manifestům. Autorizační preflight, validace instance z publikovaného release, plan všech vybraných rootů, společná brána `approve_apply` a původní plan/apply environmenty zůstávají stejné. Job používá standardní `Invoke-Module.ps1 -DeploymentPhase code-security`, stávající App, Azure identity a tokenová oprávnění. Nevzniká další credential binding ani instance config. Artifact `organizations.json` přebírá plan i apply z odpovídajícího úspěšného jobu stejného běhu; navržený Terraform state není důkaz vzdáleného stavu.

**Záložní postup po selhání apply:** První apply chybějící pattern vytvoří. Pokud ho GitHub vytvoří jako `unpublished`, apply selže, protože push protection vyžaduje publikovaný pattern. Pattern uvedený v chybě už existuje: v UI ho jen otevři, dokonči dry run a publikuj. Operátor nesmí pro stejný záznam založit nový pattern. Pokud organizace nemá vhodný repozitář pro dry run, nejprve splň předpoklad výše. Zkontroluj i ostatní cílové organizace: chybějící patterns vytvoř a nepublikované publikuj před opakováním apply. Jinak může další běh skončit u následující organizace nebo patternu. V **Actions → Deploy instance** zopakuj neúspěšné joby (**Re-run failed jobs**), nebo na stejné chráněné větvi spusť **Run workflow** se stejnou hodnotou `deployment` jako v neúspěšném běhu (`code-security`, `catalog` nebo `full`). Pokud neúspěšný běh spustil `push`, vyber `full`, aby proběhly i navazující apply joby. Apply převezme existující patterns a zapne push protection; pokračuj až po úspěšném apply.

Po úspěšném apply musí být `platform-baseline` výchozí pro nové repozitáře ve všech organizacích a připojená ke všem existujícím repozitářům včetně `instance`. Pak na `main` vyber `deployment: catalog`. Tento běh vybere časnou fázi, její předpoklady, `organization-rulesets` včetně odděleného ruleset planu a `actions-catalog`. Nevybere pozdní root `enterprise-baseline`, takže před importem a povýšením workflow nevyžaduje `liveWorkflowsPromoted` ani katalogový workflow preflight. Ruleset plan bez existující vzdálené konfigurace musí selhat, i když existuje plan časné fáze; nejdřív musí projít `code-security` apply. Oba staged běhy zachovávají autorizaci, společnou validaci konfigurace, úplný plan vybraných rootů, společnou bránu schválení a stávající environmenty. Po úspěšném `catalog` apply proveď schválený import a povýšení živých workflow. Teprve potom na `main` spusť `deployment: full` a potvrď `liveWorkflowsPromoted`. Pozdní root dál vyžaduje tento marker i katalogový workflow preflight; `full` je nesmí obejít.

Všechny tři volby mají stejnou autorizační a validační cestu jako dosavadní `full`; omezený výběr ji nesmí obejít. Ověření schváleného release při bootstrapu zůstává beze změny. Deploy zatím samostatně neověřuje release marker ani provenance (původ release); tuto společnou hranici pro všechny volby řeší [#157](https://github.com/msucharda/devsecops-platform/issues/157). Nejde o novou záruku staged deploye.

Pokud starý state modulu `enterprise-baseline` ještě eviduje Code Security objekty, staged běh je převezme podle názvu do samostatného state. Následující `full` běh čtyři původní adresy ve starém state pouze zapomene pomocí deklarací `removed` s `destroy = false`. Runner před zapomenutím ověří převzetí každé identity. Starý pattern musí zůstat v `customPatterns` pod původním názvem; změněný nebo chybějící název blokuje pozdní plan i apply. Při blokované migraci obnov původní název, zopakuj `deployment: code-security` a dokonči `deployment: full`. Až potom pattern přejmenuj nebo odeber a spusť běžné nasazení; časný root provede odpovídající změnu nebo odstranění. Pozdní root nesmí spustit staré destroy provisionery ani odstranit převzatou konfiguraci nebo patterns. Při přerušení mezi oběma běhy zopakuj staged běh a potom úplný deploy; skripty dohledají již převzaté objekty. Tento konkrétní nedestruktivní přechod nepovoluje jiné migrace RC state.

Vlož metadata do `githubApps` a vazby do `credentials` v pracovní kopii konfigurace. Autorizační alias, například `authorization`, patří také do `githubApps`; skriptu ho předáš přes `-AuthorizationApp`. Privátní klíče a jejich lokální manifest **nesmějí** ležet v release ani ve zdrojovém repozitáři.

Lokální `keys.json` obsahuje položku pro každý používaný alias. `createdAt` musí odpovídat skutečnému vytvoření klíče, nikoli dni spuštění bootstrapu:

```json
{
  "authorization": {
    "privateKeyPath": "C:\\instance-work\\keys\\authorization.pem",
    "owner": "platform",
    "createdAt": "2026-10-12T08:00:00Z",
    "rotateBy": "2027-01-10T08:00:00Z"
  }
}
```

### Ověření credentials a dokončení

```powershell
.\tools\Invoke-GitHubBootstrap.ps1 @arguments `
    -AuthorizationApp authorization `
    -AppKeysPath '<pracovni-adresar>\keys.json'
```

Před vložením prvního klíče skript pomocí stejného token issueru jako workflow ověří enterprise vlastníka, skutečná oprávnění celé App, všechny instalace, jejich aktivní stav a přesný rozsah repozitářů. Pro každou instalaci vydá zkušební installation token a odvolá ho i při chybě následné kontroly. Autorizačním tokenem ověří organizační API týmů. Pro App s `organization_administration` ověří čtení Actions permissions, code security configurations a jejich defaults. Ruleset credential navíc ověří seznam organizačních rulesetů a úplné bypass konfigurace existujících rulesetů. Neexistující ruleset nenahradí důkazem o dostupnosti detailového API; tento případ musí pokrýt referenční test s vytvořeným rulesetem.

Tyto kontroly nejsou úplným testem všech operací modulů. Povinné potvrzení `manualPrerequisites.githubAppAvailabilityVerified` smí být `true` až po ověření všech potřebných API vybraných modulů a token issueru na referenční instanci. Patří sem také custom patterns a operace vytváření či změny prostředků, které bootstrap zkušebně neprovádí. Pokud ověření chybí nebo endpoint není podporovaný, potvrzení nezadávej a moduly nenasazuj. `CredentialsConfigured: true` popisuje zapojení credentials, nikoli dokončenou referenční akceptaci.

Po ověření všech Apps skript vytvoří jeden commit se šablonou, konečnou konfigurací a přesnou kopií release v `platform/`. Vlastníkem v CODEOWNERS je `@<organizace platformy>/platform`. Ruleset chrání `main` před přímými změnami, force push a smazáním, bez bypass aktérů. Vyžaduje platformní CODEOWNER review. Pro `instance.yaml`, `platform/**` a `.github/**` navíc vyžaduje review security týmu. Pole API `required_reviewers` je beta; pokud ho GHE.com nepodporuje nebo nepotvrdí požadovaný stav, bootstrap skončí chybou a Actions nezapne. CODEOWNERS ani schválení apply tento požadavek nenahrazují.

Při opakovaném běhu bootstrap porovná lokální `instance.yaml` s konfigurací chráněné `main` po stejné validaci a normalizaci. Pořadí `githubApps.<alias>.resources.organizations` ani seznamů `githubApps.<alias>.resources.repositories.<org>` nemá význam. Jejich normalizace a řazení klíčů kanonického JSON používají ordinální porovnání, nezávislé na kultuře procesu. Pořadí ostatních seznamů se nemění. Skutečnou změnu konfigurace musí platformní tým dál schválit přes PR.

Přechod z kulturně závislého řazení může změnit pořadí při novém uložení normalizované konfigurace nebo inventory. Existující `instance.yaml` kvůli porovnání přepisovat nemusíš. Mohou se však změnit odvozené hashe kanonického JSON, například source approval digest (otisk schvalovaného zdroje). Po aktualizaci release proto znovu ověř kandidáta a potvrď jeho aktuální digest; původní schválení na nový otisk nepřenášej. Hash jednotlivého souboru ani kontrola přesné sady souborů releasu se nemění.

`gh secret set --no-store` zašifruje klíč pomocí libsodium; plaintext dostane jen přes stdin. Bootstrap uloží šifrovanou hodnotu jako environment secret `PLATFORM_APP_PRIVATE_KEY`. Odmítne stejnojmenný repository nebo organization secret, aby environment bez klíče nemohl zdědit širší credential. Environment variables obsahují App metadata, veřejný fingerprint klíče, identitu Azure a adresu backendu podle [kontraktu šablony](../templates/instance/README.md).

Teprve po dokončení skript zapne Actions a vrátí `CredentialsConfigured: true`. `Organization`, `Repository`, `ReleaseVersion`, `InventoryPath` a `HasChanges` neobsahují credentials. První plan spusť ručně z chráněné `main`; zapnutí Actions zpětně nespustí push workflow inicializačního commitu.

### PR se změnou githubApps nebo credentials

Změny sekcí `githubApps` a `credentials` v `instance.yaml` existující instance musí projít PR a požadovaným review. Cloudový plan nesmí použít změněná App metadata ani credential vazby před merge. Guard v `tools/Select-InstanceModules.ps1` proto porovná obě sekce kandidáta s důvěryhodnou konfigurací z base commitu `main`. I autorizovaný PR platformního autora s platnou konfigurací při změně těchto sekcí záměrně skončí dvěma červenými checky:

| Check | Text, podle kterého reviewer pozná záměrné selhání |
|---|---|
| `Select instance modules with trusted tools` | `PR changes protected githubApps bindings. Cloud plan must run from main after review and merge.` nebo `PR changes protected credentials bindings. Cloud plan must run from main after review and merge.` |
| `Report complete or explicitly unperformed cloud plan` | `Cloud plan NOT PERFORMED: configuration validation or trusted module selection failed.` |

Reviewer musí zároveň ověřit, že check `Validate configuration against the vendored release` prošel a diff skutečně mění `githubApps` nebo `credentials`. Samotný text `Cloud plan NOT PERFORMED` nedokazuje záměrné selhání guardu: stejný souhrn hlásí i chybu validace nebo jinou chybu výběru modulů. Jiné chyby vyřeš před merge; neoznačuj je za očekávaný výsledek tohoto postupu.

Ruleset `platform-instance-main`, který vytváří `tools/Invoke-GitHubBootstrap.ps1`, neobsahuje pravidlo `required_status_checks`. Tyto dva červené checky tedy samy o sobě podle tohoto rulesetu merge neblokují. Nadále platí platformní CODEOWNER review, security review změny `instance.yaml` a ostatní pravidla review. Před merge ověř i další aktivní pravidla repozitáře a zděděné rulesety; bootstrapový ruleset nedokazuje, že merge dovolí celá instance. Tento postup neopravňuje k bypassu ani k vypnutí ochran.

Po review a merge proběhne nový cloudový plan z chráněné `main` před schválením apply. PR validace tento plan nenahrazuje. Pokud změna vyžaduje zapojení nových Apps nebo environmentů opakovaným bootstrapem, dokonči příslušný postup níže s konfigurací shodnou s `main`; neúspěšný plan z `main` nesmíš považovat za očekávané selhání PR guardu.

### Zapojení vendoringu po nasazení katalogu

Bootstrap vždy vytvoří `vendoring-source`, `vendoring-action-import` a `vendoring-release-import`. Všechny omezí na `main`; oba writer environmenty navíc vyžadují platformní tým a zakazují administrátorský bypass. Žádný z nich nemá Azure identitu ani federated credential. Bootstrap odmítne neznámý secret nebo variable v těchto environmentech. Klíč bez App vazby také odmítne.

Parametry `-VendoringReleaseApp`, `-VendoringActionApp` a `-VendoringSourceApp` vybírají aliasy z `githubApps`. Writer Apps nejsou podmínkou dokončení bootstrapu. Bez vazby zůstane environment prázdný a bootstrap vypíše varování. Import bez writer credentials skončí konkrétní chybou před vydáním prvního tokenu. `CredentialsConfigured: true` proto neznamená připravený vendoring ani živě ověřený import.

Release writer lze zapojit při prvním dokončení GitHub bootstrapu. Action writer zapoj až po apply modulů `organizations` a `actions-catalog`, kdy existuje organizace akcí i cílové repozitáře. Každá App musí mít jinou identitu než autorizační App, moduly, drift reporter i ostatní vendoring Apps. Klíče přidej do stejného externího manifestu `keys.json`; platí stejná rotace do 90 dní.

1. Zaregistruj a nainstaluj App s oprávněními a selected scope z tabulky. Veřejný import nepotřebuje source App.
2. Pokud už instance existuje, doplň App metadata do `instance.yaml` přes PR a review security týmem. Dva záměrně červené checky rozpoznej podle [postupu pro chráněné vazby](#pr-se-změnou-githubapps-nebo-credentials); cloudový plan proběhne až z `main` po merge. Po merge použij lokální kopii konfigurace shodnou s chráněnou `main`; bootstrap konfiguraci nepřepíše.
3. Zopakuj bootstrap ze stejného schváleného release se stejným inventory, výstupem Azure bootstrapu a všemi již používanými App parametry:

```powershell
.\tools\Invoke-GitHubBootstrap.ps1 @arguments `
    -AuthorizationApp authorization `
    -AppKeysPath '<pracovni-adresar>\keys.json' `
    -VendoringReleaseApp release-import `
    -VendoringActionApp action-import
```

Pro privátní zdroj přidej `-VendoringSourceApp source-import -VendoringSourceRepository owner/repo`. `-VendoringSourceApiUrl` musí odpovídat API hostu instance; bootstrap jiný host odmítne. Ověří source App v témže enterprise jmenném prostoru a zapíše chráněné `SOURCE_REPOSITORY` a `SOURCE_API_URL`. Veřejný import z github.com source App nepotřebuje. Privátní zdroj na jiném hostu vyžaduje deklarovaný ruční import podle [vendoringu](vendoring.md), nikoli širší credential.

Po zapojení spusť `import-action.yml` a poté `import-release.yml`. Workflow ani environmenty ručně neupravuj. První import release přepíše upstream akce ve vendorovaných šablonách podle katalogu; povýšení živých workflow zůstává samostatný schválený PR podle #16.

### Environmenty, noční plan a teardown

Bootstrap omezí každý environment na větev `main`. `pull_request_target` používá base ref `main`; kontrola autora PR zůstává v trusted autorizačním jobu. Běžný plan, ruleset plan a jejich varianty `<environment>-drift` nemají reviewery. Workflow `drift.yml` spouští plan denně v **02:17 UTC**, s oddělenými environmenty běžného a ruleset planu; nikdy neotevře apply gate.

Bootstrap vytvoří environment `drift-report` bez reviewerů, jen z `main`. Issue driftu zapisuje samostatná App, kterou platformní tým ručně registruje a nainstaluje jen do repozitáře `instance`:

| App | Oprávnění a rozsah |
|---|---|
| App reportu driftu | Právě `issues: write`, jen repozitář `instance` organizace platformy. Samostatná identita; nesmí ji sdílet autorizace ani žádná fáze modulu. |

Alias App patří do `githubApps` a klíč do `keys.json`. U existující instance doplň alias přes PR a požadované review podle [postupu pro chráněné vazby](#pr-se-změnou-githubapps-nebo-credentials): dva checky záměrně skončí červeně a cloudový plan proběhne až z `main` po merge. Bootstrapu pak předej konfiguraci shodnou s `main` a alias přes `-DriftReportApp`:

```powershell
.\tools\Invoke-GitHubBootstrap.ps1 @arguments `
    -AuthorizationApp authorization `
    -DriftReportApp drift-report `
    -AppKeysPath '<pracovni-adresar>\keys.json'
```

Bootstrap ověří kontrakt App stejným token issuerem jako workflow a uloží klíč a variables do `drift-report`. Bez `-DriftReportApp` bootstrap vypíše varování; noční běh pak drift issue neotevře a job `report_drift` selže. Pokud `drift-report` obsahuje klíč a parametr chybí, bootstrap skončí chybou.

Plan identita má federated credentials jen pro plan environmenty daného modulu včetně ruleset planu a nočních variant. Apply identita má právě vazbu na apply environment modulu. Issuer pro GHE.com je `https://token.actions.<githubHost>` a audience `api://AzureADTokenExchange`.

Bootstrap načte skutečný [OIDC subject kontrakt repozitáře](https://docs.github.com/en/rest/actions/oidc#get-the-customization-template-for-an-oidc-subject-claim-for-a-repository). Vyžaduje `use_default: true`, boolean `use_immutable_subject` a `sub_claim_prefix`, který odpovídá ověřené identitě repozitáře. Při immutable režimu sestaví subject `repo:<organizace>@<owner-id>/instance@<repository-id>:environment:<environment>` ze skutečných kladných číselných IDs odpovědi GitHub API. Při výslovně potvrzeném legacy režimu zachová `repo:<organizace>/instance:environment:<environment>`. Chybějící nebo neshodný kontrakt zastaví běh před zápisem federated credentials. Skript režim neodhaduje podle data vytvoření, nemění OIDC template a nepoužívá wildcard. Custom template vyžaduje samostatně schválenou změnu trust kontraktu.

Podle [GitHub kontraktu immutable subject claims](https://docs.github.com/en/actions/reference/security/oidc#immutable-subject-claims) používají nové repozitáře od 15. 7. 2026 immutable režim; starší repozitáře mohou zachovat legacy režim. Změna režimu mění subject i odvozený název federated credential. Neočekávaná existující federated credential zastaví skript; bootstrap ji automaticky neodstraní. Migrace musí při vypnutých Actions schváleně nahradit konkrétní staré vazby a ověřit jejich nové subjects, issuer, audience a oddělení environmentů. Opakovaný bootstrap ani oprava zdrojového kódu nejsou souhlasem s touto změnou přístupu.

`approve-apply` vyžaduje platformní tým. Apply modulu `enterprise-baseline` navíc vyžaduje security tým. GitHub v jednom environmentu vyžaduje schválení pouze jednoho z uvedených reviewerů. Teardown proto používá dva navazující gate environmenty: `approve-teardown-platform` vyžaduje platformní tým a `teardown` security tým. Oba nemají secrets, variables ani federated credentials. Workflow `teardown` spustí druhý gate až po úspěchu prvního. Joby destroy čerpají credentials v apply environmentech modulů, mimo oba gate environmenty.

Brána `approve_apply` vyžaduje úspěšné joby `authorize`, `select` a `plan_complete`, povolenou autorizaci a neprázdný výběr modulů na `main` mimo PR. Přeskočené joby nevybraných modulů schválení neblokují. Zrušený běh schválení nenabídne. Každý apply job navíc vyžaduje úspěšnou společnou bránu, vlastní plan a apply svých předpokladů.

### Opakování, evidence a rotace

Bootstrap zachová `bootstrap-resources.json` mimo source release i checkout spouštěného skriptu. Inventory eviduje identifikátor nasazení, identifikátory potvrzených prostředků, deklarované a ověřené Apps, instalace, veřejné fingerprinty, vlastníka, termíny rotace a povinnost odstranění. Deklarace Apps uloží ještě před cloudovými změnami a ověřením klíčů; zachová i dřívější deklarace a App IDs při změně aliasu. Chyba ověření proto neztratí evidenci ruční registrace. Neobsahuje tokeny ani privátní klíče. Soubor musíš zachovat i při přerušení a předat skriptu `tools/Remove-Bootstrap.ps1`. Skript do něj zapisuje stav odstranění. Ručně registrované Apps jsou prostředky bootstrapu, nikoli zachovávané enterprise předpoklady.

Opakovaný běh se stejným release, konfigurací a klíči neprovádí zápisy prostředků a vrátí `HasChanges: false`. Zkušební installation tokeny znovu vydá a odvolá; nejde o změnu nasazených prostředků. Inventory jiné verze lze použít jen pro popsaný upgrade GitHub bootstrapu. Chybějící cloudové oprávnění, nepodporované API nebo jiné oprávnění App skončí explicitní chybou. Skript nemá PAT fallback, rozšíření oprávnění ani automatický rollback. Po chybě oprav příčinu a spusť stejný příkaz se stejným inventory. Po inicializaci nesmí bootstrap přepsat konfiguraci nebo release na `main`; další obsahové změny vyžadují PR.

#### Upgrade GitHub bootstrapu

Podporovaný přechod inventory vede z `0.1.0-rc.5` nebo novějšího release řady `0.1.0` na striktně novější spuštěný release stejné řady. Podporované formáty jsou `0.1.0-rc.N` (kladné celé `N` bez úvodních nul) a stabilní `0.1.0`, který následuje po všech rc verzích. Čísla rc bootstrap porovnává číselně, nezávisle na culture. Přechod vyžaduje inicializované inventory a výslovný příznak `-UpgradeInventory`. Stejnou verzi, downgrade, zdroj starší než rc.5, jinou řadu a neplatný formát bootstrap odmítne před prvním požadavkem na GitHub API. Běžné opakování se stejnou verzí příznak nepoužívá.

Platformní tým musí nejdřív otevřít a sloučit PR, který aktualizuje vendoring i marker na `main` na cílový schválený release. PR musí zachovat `instance.yaml`, pokud tým samostatně neschválil jeho změnu.

Vendoring aktualizuje `platform/**`, nikoli `.platform-bootstrap.json`. Marker vytvoř v lokálním checkoutu **větve tohoto PR**. `$release` musí označovat původní schválený release, `$releaseVersion` jeho přesnou verzi bez prefixu `v`, `$cfg` ověřený `instance.yaml` a `$instanceCheckout` checkout repozitáře instance. Nehashuj vendorovanou kopii: vendoring přepisuje odkazy na akce ve workflow šablonách, ale marker používá původní bytes release.

```powershell
# Generate the marker from the original approved release, not its vendored copy.
$release = (Resolve-Path -LiteralPath $release).Path
Import-Module (Join-Path $release 'tools\PlatformTools.psm1')
$configuration = Get-PlatformYaml -Path $cfg
$hashes = @{}
Get-ChildItem -LiteralPath $release -Recurse -Force -File |
    Where-Object {
        $_.FullName -notmatch '[\\/](\.git|\.terraform|artifacts|node_modules)[\\/]' -and
        (Test-PlatformReleaseFile -RelativePath ([IO.Path]::GetRelativePath($release, $_.FullName)))
    } |
    ForEach-Object {
        $relative = [IO.Path]::GetRelativePath($release, $_.FullName).Replace('\', '/')
        $hashes[$relative] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
$marker = @{
    instance = $configuration['instance']['name']
    releaseVersion = $releaseVersion
    files = $hashes
}
[IO.File]::WriteAllText(
    (Join-Path $instanceCheckout '.platform-bootstrap.json'),
    (ConvertTo-PlatformCanonicalJson $marker) + "`n",
    [Text.UTF8Encoding]::new($false))
```

Commit markeru přidej do stejného PR. Po review a merge použij stejný release, inventory, výstup Azure bootstrapu a konfiguraci shodnou s `main`.

Do `$arguments` převezmi **všechny** parametry posledního úspěšného bootstrapu, včetně těch, které byly předané samostatně. Povinné `AuthorizationApp` a `AppKeysPath` musí zachovat původní alias a externí manifest klíčů. Pokud byly použité `DriftReportApp`, `VendoringActionApp`, `VendoringReleaseApp`, `VendoringSourceApp`, `VendoringSourceRepository` nebo `VendoringSourceApiUrl`, ponech je se stejnými hodnotami. Jejich vynechání není způsob, jak App odpojit.

```powershell
$upgradeArguments = @{} + $arguments
$upgradeArguments.ReleasePath = $release
$upgradeArguments.ReleaseVersion = $releaseVersion
foreach ($name in @('AuthorizationApp', 'AppKeysPath')) {
    if (-not $upgradeArguments.ContainsKey($name) -or
        [string]::IsNullOrWhiteSpace($upgradeArguments[$name])) {
        throw "Reuse the previously used $name in the complete bootstrap argument set."
    }
}
& (Join-Path $release 'tools\Invoke-GitHubBootstrap.ps1') @upgradeArguments -NoChanges
& (Join-Path $release 'tools\Invoke-GitHubBootstrap.ps1') @upgradeArguments -UpgradeInventory
```

Před prvním reconcile requestem bootstrap ověří vazbu inventory na repozitář a enterprise, aktuální `main`, přesný marker schváleného release a konfiguraci shodnou s lokálním `instance.yaml`. Větev musí vrátit commit SHA o 40 hexadecimálních znacích. Bootstrap připne čtení markeru i konfigurace k této SHA. Přes Git commit načte kořenový Git tree a pro obě cesty vyžaduje právě jeden běžný soubor (`blob`, mode `100644` nebo `100755`). Neúplný tree odmítne. Samotné `type=file` z Contents API nestačí: API může vrátit obsah cíle symbolického odkazu.

Před každým GitHub zápisem, Azure zápisem federated credential i potvrzením nové verze inventory bootstrap ověří, že `main` stále ukazuje na stejný commit. Obsah API musí mít typ `file` a kódování `base64`; bootstrap odmítne adresáře, symbolické odkazy i submoduly. Bootstrap odmítne chybějící větev `main`, nepodporovanou dvojici verzí, neplatnou SHA, nesoulad markeru, změnu konfigurace i pohyb větve během ověřování. Při chybě markeru nebo konfigurace nejdřív oprav stav přes review PR; nepoužívej přímý zápis bootstrapu do `main`.

Před uložením inventory a prvním reconcile requestem bootstrap read-only ověří také existující security tým a aktivní ruleset `platform-instance-main`: přesný rozsah `main`, zákaz smazání a force push, požadovaná PR schválení včetně security týmu a prázdný bypass. Chybějící, vypnutou, oslabenou nebo nečitelnou ochranu odmítne i s `-ResourcesOnly`; během upgradu ji neopravuje. Platformní tým musí ochranu obnovit samostatně schváleným postupem.

Po ověření chráněného `main` bootstrap uloží aktualizované deklarace Apps ještě před prvním reconcile requestem. Zachová původní App IDs v historii a zatím nezmění verzi inventory. Přerušení tak neztratí evidenci ručně registrované App.

Po úspěšném provisioningu bootstrap zapíše novou `releaseVersion` do stejného inventory. Do té doby ponechá zaznamenanou verzi. Zachová identifikátor nasazení, záznamy prostředků, Apps, otisky klíčů, termíny rotace a historii klíčů. Pokud běh selže, oprav příčinu a spusť znovu bootstrap se stejným inventory a release. `-NoChanges` zůstává read-only: ověřuje inventory stejné verze nebo podporovaný přechod podle pravidla výše proti markeru, Git tree a konfiguraci na `main`, ale inventory ani prostředky nemění. Chybějící, prázdnou či nepodporovanou verzi inventory odmítne před prvním GitHub API požadavkem.

`-NoChanges` nelze kombinovat s `-UpgradeInventory`; slouží pouze k ověření bez zápisů.

#### Upgrade oprávnění Code Security reader App

U existující instance nestačí aktualizovat release ani inventory. Platformní tým musí schválit změnu oprávnění App a každé její instalace:

1. Připrav PR s cílovým release, markerem a změnou `githubApps.<alias>.permissions.administration` na `read` pro běžný plan `enterprise-baseline`. Zachovej `organization_administration: read`, `metadata: read` a všechny cílové organizace s výběrem `all`. Pokud stejnou App používá jiný plan s užším kontraktem, nejdřív pro `enterprise-baseline` připrav samostatnou App a v PR změň také jeho `credentials` binding. Ostatním planům, ruleset planům ani apply oprávnění nepřidávej.
2. Získej review platformního a security týmu podle [postupu pro chráněné vazby](#pr-se-změnou-githubapps-nebo-credentials). Dva záměrně červené checky nejsou cloudový plan. Po merge používej konfiguraci shodnou s chráněnou `main`. Běh `Deploy instance` vyvolaný mergem může selhat při vydání tokenu, dokud App nebo některá instalace nemá nový grant. Toto selhání není očekávaný PR guard; po dokončení bootstrapu obnov nasazení podle kroku 5.
3. V **Enterprise settings → GitHub Apps → příslušná App → Permissions & events → Repository permissions** nastav **Administration: Read-only**. V každé cílové organizaci otevři instalaci této App a schval požadovaná nová oprávnění. Schválení jen v organizaci platformy nestačí, pokud coverage běží i v organizaci akcí nebo workloadů.
4. Ze stejného schváleného release zachovej úplné původní argumenty a inventory. Pokud zůstává stejná App i klíč, spusť bootstrap nejdřív s `-NoChanges`, potom s `-UpgradeInventory`. Pokud oddělení vyžaduje novou App nebo klíč, doplň nejdřív externí manifest klíčů se skutečným `createdAt` a `rotateBy`; proveď schválený `-UpgradeInventory` a až potom `-NoChanges`. Úvodní `-NoChanges` by v tomto případě odmítl vložení nového klíče, i kdyby oprávnění byla správná. `-NoChanges` ověří skutečná oprávnění App i všech instalací, ale nic neopraví; `-UpgradeInventory` oprávnění App ani souhlas instalace také neuděluje. Při chybě oprav konkrétní App nebo instalaci a zopakuj kontrolu.
5. Po úspěšném bootstrapu ověř úplné nasazení z chráněné `main`. Pokud běh vyvolaný mergem selhal nebo úplné nasazení neproběhlo, v **Actions → Deploy instance → Run workflow** na `main` zvol `deployment: full`. Spusť celý nový běh včetně planu a standardního schválení apply; bootstrap původní běh neobnoví. Pokračuj až po úspěšném úplném nasazení.
6. Potom spusť ručně `drift.yml` z chráněné `main`. Ověř přímý stav `enabled` u všech repozitářů a úspěšný run bez `INCOMPLETE`. Offline testy ani úspěšný bootstrap živou čitelnost `security_and_analysis` nenahrazují.

Tento postup popisuje živé kroky, nikoli souhlas s jejich provedením. U referenční instance je provede koordinátor s uživatelem.

**Vlastník rotace je platformní tým.** `rotateBy` musí ležet nejpozději 90 dní po `createdAt` a nesmí být v minulosti. Nezměněnému klíči nesmíš posunout evidované datum vytvoření ani termín rotace. Při podezření na kompromitaci tým rotuje klíč okamžitě. Nejdřív vytvoří nový klíč stejné App, upraví lokální manifest a znovu spustí bootstrap. Pak v každém dotčeném environmentu ověří skutečné vydání tokenu workflow a teprve potom starý klíč odvolá v enterprise App settings. Inventory uchová v `previousKeys` původní App ID, fingerprint, `createdAt` a `rotateBy` s `revocationRequired: true`; zachová také starší historii. Po ručním odvolání tým eviduje datum a nastaví příznak na `false`. Běžná workflow vydávají hodinové installation tokeny bez člověka.

## Prostředky a oprávnění

Bootstrap používá Primary region (primární region) a zkratky CAF: resource group `rg-<name>-bootstrap`, storage account `st<name>tfstate` a identity `id-<name>-<module>-plan` a `id-<name>-<module>-apply`. Názvy zůstávají stabilní; tyto prostředky nevyžadují Deployment identifier (identifikátor nasazení) podle ADR 0008. Kolize globálního názvu storage account způsobí chybu, ne náhodné přejmenování.

Storage account typu `StorageV2`, SKU `Standard_LRS` má HTTPS, TLS 1.2, encryption, vypnutý shared key a public blob access. Nepovoluje HNS, NFS, SFTP ani local users. Autentizace používá Entra ID. Blob service má versioning a soft delete blobů i kontejnerů po 30 dní. Lock `CanNotDelete` chrání účet, ne jednotlivé změny state; změny a lease musí Terraform provádět.

Každý vybraný modul včetně předpokladů má vlastní kontejner a dvě identity. Identity získají `Storage Blob Data Contributor` **jen** na kontejneru svého modulu. Tuto roli potřebuje i plan kvůli lease a možnému zápisu state; nejde o oprávnění měnit prostředky jiných modulů.

Manifest deklaruje Azure role názvem, absolutním ARM scope a volitelnou `phase`. Výchozí fáze je `apply`. Graph oprávnění zapsané jako řetězec patří jen apply; objekt `permission` a `phase` deklaruje fázi výslovně. Bootstrap planu nepřiděluje oprávnění apply a neodvozuje z nich širší oprávnění. Plan přijme Azure role obsahující jen `*/read` a Graph názvy s operací `Read` nebo `ReadBasic`; zápisová oprávnění odmítne.

Bootstrap před první změnou vyhodnotí oprávnění všech vybraných modulů. Odmítne neexistující role a Graph application permissions, neověřené subscriptions a scope na vlastních prostředcích bootstrapu. Zápisová role na management subscription nebo nadřazené management group by umožnila změnit state backend; bootstrap ji odmítne. Manifest musí zvolit scope mimo bootstrap. `emu-identity` nesmí dostat `AppRoleAssignment.ReadWrite.All`. Entra akce nepatří do pole Graph application permissions; pro přiřazování app rolí v GHE test C1 ověřil scoped roli bez těchto application permissions.

Manifest deklaruje vlastní role Entra v poli `entraDirectoryRoles`, nejvýše jednu pro každou fázi. Bootstrap je zpracuje takto:

- Před první změnou odmítne roli planu s akcí, která nekončí `/read`.
- Najde definici role `platform-<instance>-<module>-<phase>`. Odmítne built-in roli se stejným názvem a více definic se stejným názvem.
- Chybějící definici vytvoří. Rozdílné akce nebo vypnutou definici opraví v existující definici.
- Roli přiřadí identitě dané fáze jen se scope `/<enterpriseApplicationObjectId>`.
- Odmítne každé jiné přiřazení role Entra u identity modulu. Nadbytečné přiřazení neodstraňuje.

Modul `emu-identity` používá pro apply akce `appRoleAssignedTo/update`, `appRoleAssignedTo/read` a `standard/read` podle [ADR 0015](adr/0015-least-privilege-identity-per-module.md). Plan dostane jen obě read akce. Vytvoření vlastní role a jejího přiřazení vyžaduje u bootstrap uživatele roli Privileged Role Administrator nebo Global Administrator a licenci Entra ID P1.

Apply identita `emu-identity` dostane Graph application permissions `Group.Create`, `GroupMember.Read.All` a `User.Read.All`. `GroupMember.Read.All` je podle rozhodnutí D-119-1 nejmenší společné oprávnění pro čtení `owners`, `members` a `memberOf`, které provider azuread 3.10.0 provádí přes Graph beta. Čte členství a základní vlastnosti všech skupin tenantu, nejen skupin instance; nedává zápis do cizích skupin. Plan si zachovává `Group.Read.All` a `User.Read.All`; apply nedostává `Group.Read.All`, `Group.ReadWrite.All` ani `AppRoleAssignment.ReadWrite.All`. Zdroje a návrh obnovy existujících skupin po 403 jsou v [README modulu](../modules/emu-identity/README.md#proč-apply-potřebuje-čtení-skupin).

Bootstrap odmítne také read-only roli, jejíž `dataActions` umožňují čtení blobů na scope zahrnujícím state backend. Širší čtení by zpřístupnilo state ostatních modulů i bez oprávnění k zápisu. Při vyhodnocení wildcard oprávnění respektuje `notDataActions` v každém permission setu. Read-only role bez přístupu ke state a datová oprávnění na scope mimo bootstrap zůstávají povolené.

## Opakování, chyby a odstranění

Bootstrap porovnává požadovaný stav se skutečnými prostředky. Druhý běh při nezměněné konfiguraci neprovádí žádný cloudový zápis a vrátí `HasChanges: false`. Pokud Storage API vynechá vypnuté volitelné vlastnosti public blob access, HNS, NFS, SFTP a local users, porovnání je vyhodnotí jako `false`. Pro shared key, HTTPS ani TLS tuto normalizaci nepoužívá. Role assignments mají deterministické identifikátory; existující stejné přiřazení s jiným ID se neduplikuje.

Požadované Azure role musí platit bez ABAC podmínky. Bootstrap odmítne existující přiřazení s neprázdnou `condition`, i když má požadovaný scope a roli. Podmínka by mohla zablokovat čtení nebo lease `terraform.tfstate`; bootstrap ji sám neodstraňuje ani neobchází dalším grantem.

Před první změnou bootstrap zkontroluje všechny existující identity vybraných modulů. Odmítne dodatečné Azure nebo application permissions; nadbytečné oprávnění neodstraňuje bez schválené změny přístupu. Kontrola Azure zahrnuje všechny deklarované subscriptions, všechny jejich předky v management groups včetně tenant root group a scope management groups z manifestů. Subscription API nevrací přiřazení z management groups, proto bootstrap dotazuje tyto scope samostatně. Stejnou kontrolu provede i po vytvoření nové identity. Oprávnění mimo tento rozsah musí ověřit administrátor.

Bootstrap odmítne převzít prostředek se shodným názvem bez odpovídajících ownership tags. Čeká na dokončení storage account a omezeně opakuje požadavky při replikaci managed identity, HTTP 429 a 503. Ostatní chyby vrací s operací, URI a HTTP stavem. Po přerušeném běhu oprav příčinu a spusť stejný příkaz; existující identity i dokončené prostředky zůstanou zachované. Bootstrap nemá automatický rollback.

Požadavky s HTTP 429 nebo 503 bootstrap opakuje podle stavového kódu, i když odpověď obsahuje prostý text nebo HTML místo JSON. Provede nejvýše 12 pokusů s prodlevou 5 sekund. Po vyčerpání pokusů vrátí chybu s HTTP stavem a tělem poslední odpovědi. Ostatní odpovědi musí splnit původní požadavky na JSON.

Nástroj sám nic neodstraňuje. Moduly odstraní workflow `teardown` a prostředky bootstrapu skript `tools/Remove-Bootstrap.ps1` ([Teardown](../README.md#teardown)). Skript navíc vyžaduje OAuth scope `delete_repo`, který login bootstrapu nemá. Oba zachovají tenant, enterprise, OIDC, SCIM, subscriptions, licence a enterprise kontroly. Před teardownem administrátor obnoví přímé přiřazení Enterprise Owner, které po prvním nasazení odebral ruční krok `emu-identity`. Lock odstraní až `Remove-Bootstrap.ps1` po úspěšném workflow `teardown`.

## Ověření na Reference instance (referenční instanci)

Offline testy Pester ověřují veřejný skript proti náhradám cloudových API. Neprokazují přístup ani dostupnost API na skutečné instanci.

Platform team (platformní tým) musí před uzavřením #10 spustit bootstrap na určené Reference instance (referenční instanci), zkontrolovat ochrany backendu, dvě identity každého vybraného modulu a jejich scope. Musí ověřit, že identita přečte a zamkne vlastní state a dostane HTTP 403 pro state jiného modulu. Druhý běh musí vrátit `HasChanges: false`. Přerušený běh musí další spuštění dokončit bez výměny identit. Výsledek včetně data patří do #10. Komentář nesmí obsahovat ID tenantu, subscriptions ani objektů a název enterprise (ADR 0012). Ověření není součástí dosud provedených offline testů.

Postup krok za krokem včetně důvodů popisuje [Příprava a akceptace referenční instance](reference-instance.md).

## Zdroje

- [ADR 0005](adr/0005-own-bootstrap-instead-of-alz-accelerator.md), [ADR 0008](adr/0008-deployment-identifier-in-retained-names.md), [ADR 0015](adr/0015-least-privilege-identity-per-module.md) a [ADR 0016](adr/0016-github-app-installation-tokens-for-instance-workflows.md).
- [EMU OIDC provisioning](https://learn.microsoft.com/en-us/entra/identity/saas-apps/github-enterprise-managed-user-oidc-provisioning-tutorial) a [synchronization API](https://learn.microsoft.com/en-us/graph/api/resources/synchronization-overview).
- [Storage account REST API](https://learn.microsoft.com/en-us/rest/api/storagerp/storage-accounts/create?view=rest-storagerp-2023-05-01) a [role assignments](https://learn.microsoft.com/en-us/rest/api/authorization/role-assignments/list-for-subscription?view=rest-authorization-2022-04-01).
- [Management groups: Entities List](https://learn.microsoft.com/en-us/rest/api/managementgroups/entities/list?view=rest-managementgroups-2020-05-01).
- [Environment secrets](https://docs.github.com/en/rest/actions/secrets), [environment variables](https://docs.github.com/en/rest/actions/variables), [repository rulesets](https://docs.github.com/en/rest/repos/rules) a [odlišnosti GHE.com včetně OIDC issueru](https://docs.github.com/en/enterprise-cloud@latest/admin/data-residency/feature-overview-for-github-enterprise-cloud-with-data-residency).
