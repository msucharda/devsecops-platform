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

Platform team (platformní tým) musí použít schválený Release (release). `-ReleasePath` určuje jeho rozbalený adresář a `-ReleaseVersion` verzi SemVer bez prefixu `v`. Skript musí pocházet ze stejného release. Pro Git checkout musí `HEAD` odpovídat tagu `v<verze>` a checkout nesmí mít změněné ani nesledované soubory. U rozbaleného archivu člověk předem ověří původ a attestaci podle procesu release; samotný parametr verze není důkaz původu. Skript ověří shodu vygenerovaného workflow s manifesty a zapíše SHA-256 každého vendorovaného souboru do `.platform-bootstrap.json`.

OAuth login potřebuje scopes `admin:enterprise`, `admin:org`, `repo` a `workflow`. Člověk je schválí při přihlášení; skript je sám nerozšiřuje. Azure login musí umožnit číst identity a vytvářet federated credentials na identitách z výstupu Azure bootstrapu.

```powershell
gh auth login --hostname example.ghe.com --web --scopes admin:enterprise,admin:org,repo,workflow
$azure = .\tools\Invoke-Bootstrap.ps1 -InstancePath $cfg
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

`-ResourcesOnly` vytvoří `{name}-platform`, soukromý repozitář `instance`, týmy `platform` a `security`, environmenty a OIDC vazby. Spouštějící managed user musí být enterprise owner; při inicializaci ho bootstrap přidá do obou týmů. Toto členství nahradí propojení se skupinami Entra ID v `emu-identity`. Po publikaci instance bootstrap přímé členství znovu neobnovuje.

Repozitář zatím obsahuje jen inicializační commit GitHubu, bez workflow instance, a má vypnuté Actions. Pokud vypnutí Actions selže po vytvoření repozitáře, další běh ho zopakuje před pokračováním inicializace. Výsledek má `CredentialsConfigured: false`; příprava není dokončený bootstrap. V této fázi může chybět alias App u vybraného modulu. Plná validace a dokončení ho vyžadují. Po vzniku organizace může GitHub vyžadovat nové SSO přihlášení a obnovení `gh auth login`; skript vrátí chybu a další běh pokračuje se stejným inventory. U již dokončené instance `-ResourcesOnly` nevypíná Actions ani neodstraňuje credentials.

Platformní tým potom v **Enterprise settings → GitHub Apps** ručně registruje Apps a nainstaluje je do přesně deklarovaných organizací:

| App | Oprávnění a rozsah |
|---|---|
| Autorizační App | Jen `members: read`, pouze organizace platformy, žádné repozitáře. Samostatná identita; nesmí ji sdílet modul. |
| App fáze modulu | Přesně `permissions` a `resources` manifestu a aliasu v `instance.yaml`. Plan a apply používají odlišné identity. |
| App ruleset planu | Jen `organization_administration: write`, přesně cílové organizace. Oddělená od běžného planu i apply. |

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

Po ověření všech Apps skript vytvoří jeden commit se šablonou, konečnou konfigurací a přesnou kopií release v `platform/`. Vlastníkem v CODEOWNERS je `@{name}-platform/platform`. Ruleset chrání `main` před přímými změnami, force push a smazáním, bez bypass aktérů. Vyžaduje platformní CODEOWNER review. Pro `instance.yaml`, `platform/**` a `.github/**` navíc vyžaduje review security týmu. Pole API `required_reviewers` je beta; pokud ho GHE.com nepodporuje nebo nepotvrdí požadovaný stav, bootstrap skončí chybou a Actions nezapne. CODEOWNERS ani schválení apply tento požadavek nenahrazují.

`gh secret set --no-store` zašifruje klíč pomocí libsodium; plaintext dostane jen přes stdin. Bootstrap uloží šifrovanou hodnotu jako environment secret `PLATFORM_APP_PRIVATE_KEY`. Odmítne stejnojmenný repository nebo organization secret, aby environment bez klíče nemohl zdědit širší credential. Environment variables obsahují App metadata, veřejný fingerprint klíče, identitu Azure a adresu backendu podle [kontraktu šablony](../templates/instance/README.md).

Teprve po dokončení skript zapne Actions a vrátí `CredentialsConfigured: true`. `Repository`, `ReleaseVersion`, `InventoryPath` a `HasChanges` neobsahují credentials. První plan spusť ručně z chráněné `main`; zapnutí Actions zpětně nespustí push workflow inicializačního commitu.

### Environmenty, noční plan a teardown

Bootstrap omezí každý environment na větev `main`. `pull_request_target` používá base ref `main`; kontrola autora PR zůstává v trusted autorizačním jobu. Běžný plan, ruleset plan a jejich varianty `<environment>-drift` nemají reviewery. Schedule spouští plan denně v **02:17 UTC**, s oddělenými environmenty běžného a ruleset planu; nikdy neotevře apply gate. Reportování drift issues patří do #21.

Plan identita má federated credentials jen pro plan environmenty daného modulu včetně ruleset planu a nočních variant. Apply identita má právě vazbu na apply environment modulu. Issuer pro GHE.com je `https://token.actions.<githubHost>`, audience `api://AzureADTokenExchange` a subject `repo:<organizace>/instance:environment:<environment>`. Neočekávaná existující federated credential zastaví skript; bootstrap ji automaticky neodstraní.

`approve-apply` vyžaduje platformní tým. Apply modulu `enterprise-baseline` navíc vyžaduje security tým. GitHub v jednom environmentu vyžaduje schválení pouze jednoho z uvedených reviewerů. Teardown proto používá dva navazující gate environmenty: `approve-teardown-platform` vyžaduje platformní tým a `teardown` security tým. Oba nemají secrets, variables ani federated credentials. Workflow odstranění z #22 musí druhý gate spustit až po úspěchu prvního a credentials odstranitelských jobů čerpat mimo oba gate environmenty.

### Opakování, evidence a rotace

Bootstrap zachová `bootstrap-resources.json` mimo source release i checkout spouštěného skriptu. Inventory eviduje identifikátory potvrzených prostředků, deklarované a ověřené Apps, instalace, veřejné fingerprinty, vlastníka, termíny rotace a povinnost odstranění. Deklarace Apps uloží ještě před cloudovými změnami a ověřením klíčů; zachová i dřívější deklarace a App IDs při změně aliasu. Chyba ověření proto neztratí evidenci ruční registrace. Neobsahuje tokeny ani privátní klíče. Soubor musíš zachovat i při přerušení a předat procesu lokálního odstranění z #22. Ručně registrované Apps jsou prostředky bootstrapu, nikoli zachovávané enterprise předpoklady.

Opakovaný běh se stejným release, konfigurací a klíči neprovádí zápisy prostředků a vrátí `HasChanges: false`. Zkušební installation tokeny znovu vydá a odvolá; nejde o změnu nasazených prostředků. Inventory jiné verze release skript odmítne před cloudovými změnami. Chybějící cloudové oprávnění, nepodporované API nebo jiné oprávnění App skončí explicitní chybou. Skript nemá PAT fallback, rozšíření oprávnění ani automatický rollback. Po chybě oprav příčinu a spusť stejný příkaz se stejným inventory. Po inicializaci nesmí bootstrap přepsat konfiguraci nebo release na `main`; další obsahové změny vyžadují PR.

**Vlastník rotace je platformní tým.** `rotateBy` musí ležet nejpozději 90 dní po `createdAt` a nesmí být v minulosti. Nezměněnému klíči nesmíš posunout evidované datum vytvoření ani termín rotace. Při podezření na kompromitaci tým rotuje klíč okamžitě. Nejdřív vytvoří nový klíč stejné App, upraví lokální manifest a znovu spustí bootstrap. Pak v každém dotčeném environmentu ověří skutečné vydání tokenu workflow a teprve potom starý klíč odvolá v enterprise App settings. Inventory uchová starý fingerprint s `revocationRequired: true`; po ručním odvolání tým eviduje datum a nastaví příznak na `false`. Běžná workflow vydávají hodinové installation tokeny bez člověka.

## Prostředky a oprávnění

Bootstrap používá Primary region (primární region) a zkratky CAF: resource group `rg-<name>-bootstrap`, storage account `st<name>tfstate` a identity `id-<name>-<module>-plan` a `id-<name>-<module>-apply`. Názvy zůstávají stabilní; tyto prostředky nevyžadují Deployment identifier (identifikátor nasazení) podle ADR 0008. Kolize globálního názvu storage account způsobí chybu, ne náhodné přejmenování.

Storage account typu `StorageV2`, SKU `Standard_LRS` má HTTPS, TLS 1.2, encryption, vypnutý shared key a public blob access. Nepovoluje HNS, NFS, SFTP ani local users. Autentizace používá Entra ID. Blob service má versioning a soft delete blobů i kontejnerů po 30 dní. Lock `CanNotDelete` chrání účet, ne jednotlivé změny state; změny a lease musí Terraform provádět.

Každý vybraný modul včetně předpokladů má vlastní kontejner a dvě identity. Identity získají `Storage Blob Data Contributor` **jen** na kontejneru svého modulu. Tuto roli potřebuje i plan kvůli lease a možnému zápisu state; nejde o oprávnění měnit prostředky jiných modulů.

Manifest deklaruje Azure role názvem, absolutním ARM scope a volitelnou `phase`. Výchozí fáze je `apply`. Graph oprávnění zapsané jako řetězec patří jen apply; objekt `permission` a `phase` deklaruje fázi výslovně. Bootstrap planu nepřiděluje oprávnění apply a neodvozuje z nich širší oprávnění. Plan přijme Azure role obsahující jen `*/read` a Graph názvy s operací `Read` nebo `ReadBasic`; zápisová oprávnění odmítne.

Bootstrap před první změnou vyhodnotí oprávnění všech vybraných modulů. Odmítne neexistující role a Graph application permissions, neověřené subscriptions a scope na vlastních prostředcích bootstrapu. Zápisová role na management subscription nebo nadřazené management group by umožnila změnit state backend; bootstrap ji odmítne. Manifest musí zvolit scope mimo bootstrap. `emu-identity` nesmí dostat `AppRoleAssignment.ReadWrite.All`. Vlastní roli Entra omezenou na aplikaci GHE dodá #12 podle výsledku #3; toto pole nenahrazuje Graph application permission.

Bootstrap odmítne také read-only roli, jejíž `dataActions` umožňují čtení blobů na scope zahrnujícím state backend. Širší čtení by zpřístupnilo state ostatních modulů i bez oprávnění k zápisu. Při vyhodnocení wildcard oprávnění respektuje `notDataActions` v každém permission setu. Read-only role bez přístupu ke state a datová oprávnění na scope mimo bootstrap zůstávají povolené.

## Opakování, chyby a odstranění

Bootstrap porovnává požadovaný stav se skutečnými prostředky. Druhý běh při nezměněné konfiguraci neprovádí žádný cloudový zápis a vrátí `HasChanges: false`. Pokud Storage API vynechá vypnuté volitelné vlastnosti public blob access, HNS, NFS, SFTP a local users, porovnání je vyhodnotí jako `false`. Pro shared key, HTTPS ani TLS tuto normalizaci nepoužívá. Role assignments mají deterministické identifikátory; existující stejné přiřazení s jiným ID se neduplikuje.

Požadované Azure role musí platit bez ABAC podmínky. Bootstrap odmítne existující přiřazení s neprázdnou `condition`, i když má požadovaný scope a roli. Podmínka by mohla zablokovat čtení nebo lease `terraform.tfstate`; bootstrap ji sám neodstraňuje ani neobchází dalším grantem.

Před první změnou bootstrap zkontroluje všechny existující identity vybraných modulů. Odmítne dodatečné Azure nebo application permissions; nadbytečné oprávnění neodstraňuje bez schválené změny přístupu. Kontrola Azure zahrnuje všechny deklarované subscriptions, všechny jejich předky v management groups včetně tenant root group a scope management groups z manifestů. Subscription API nevrací přiřazení z management groups, proto bootstrap dotazuje tyto scope samostatně. Stejnou kontrolu provede i po vytvoření nové identity. Oprávnění mimo tento rozsah musí ověřit administrátor.

Bootstrap odmítne převzít prostředek se shodným názvem bez odpovídajících ownership tags. Čeká na dokončení storage account a omezeně opakuje požadavky při replikaci managed identity, HTTP 429 a 503. Ostatní chyby vrací s operací, URI a HTTP stavem. Po přerušeném běhu oprav příčinu a spusť stejný příkaz; existující identity i dokončené prostředky zůstanou zachované. Bootstrap nemá automatický rollback.

Požadavky s HTTP 429 nebo 503 bootstrap opakuje podle stavového kódu, i když odpověď obsahuje prostý text nebo HTML místo JSON. Provede nejvýše 12 pokusů s prodlevou 5 sekund. Po vyčerpání pokusů vrátí chybu s HTTP stavem a tělem poslední odpovědi. Ostatní odpovědi musí splnit původní požadavky na JSON.

Nástroj neimplementuje odstranění. Workflow teardown a lokální odstranění bootstrapu dodá #22. Musí zachovat tenant, enterprise, OIDC, SCIM, subscriptions, licence a enterprise kontroly. Před teardownem administrátor obnoví přímé přiřazení Enterprise Owner, které po prvním nasazení odebral ruční krok `emu-identity`. Lock se smí odstranit až při schváleném lokálním odstranění bootstrapu.

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
