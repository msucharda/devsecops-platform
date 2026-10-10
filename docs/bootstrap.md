# Lokální bootstrap Azure

`tools/Invoke-Bootstrap.ps1` vytvoří state backend a identity vybraných modulů včetně jejich předpokladů. Spouští ho člen platformního týmu z vendorovaného release. Nástroj nevyžaduje PAT, nemění konfiguraci instance a nevytváří prostředky GitHubu.

## Konfigurace a přihlášení

Platformní tým nahradí nulové identifikátory v `templates/instance/instance.yaml` skutečnými hodnotami:

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

Delegovaný token Microsoft Graph musí umožnit čtení uživatele, enterprise aplikace a jejích app role assignments, synchronization jobs, subscribed SKUs, Graph application permissions a oprávnění managed identities. Přidělení application permissions vyžaduje administrátorský souhlas a oprávnění pro app role assignment; pro Microsoft Graph ho typicky provádí Privileged Role Administrator nebo Global Administrator. Tato pravomoc patří člověku pro bootstrap, **nikoli** identitě `emu-identity`. Pokud token Azure CLI nebo role uživatele nestačí, API vrátí konkrétní chybu; bootstrap nevytváří další credential ani nepřechází na PAT.

## Manual prerequisites (ruční předpoklady)

Platformní tým nastaví `true` až po ověření každé položky. Chybějící nebo nepravdivé potvrzení zastaví bootstrap před přihlášením a před první změnou.

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

Bootstrap navíc přes API ověří tenant tokenů, členství uživatele v konfiguraci platformního týmu, OIDC režim aplikace, přímé přiřazení Enterprise Owner, aktivní SCIM job bez quarantine, aktivní licenci Entra ID P1/P2, tenant a stav všech subscriptions a roli ownera pro účet OAuth v GitHubu. Enterprise politiky, správnost cíle a mapování SCIM a ostatní licence ověří člověk. Potvrzení není automatická detekce driftu.

## Spuštění a výstup

Z repozitáře instance spusť:

```powershell
$bootstrap = .\platform\tools\Invoke-Bootstrap.ps1 -InstancePath .\instance.yaml
$bootstrap | ConvertTo-Json -Depth 10
```

Při práci ve zdrojovém repozitáři použij `.\tools\Invoke-Bootstrap.ps1`. Parametr `-ModulesPath` může určit jiný adresář manifestů.

Výsledek obsahuje `TenantId`, `SubscriptionId`, `ResourceGroupName`, `StorageAccountName`, `Modules` a `HasChanges`. Každý modul má `Name`, `ContainerName` a záznamy `Plan` a `Apply` s `ResourceId`, `PrincipalId` a `ClientId`. Výstup neobsahuje tokeny. Navazující bootstrap GitHubu z #11 použije tyto identity pro federated credentials environmentů.

Runner modulu používá stejný název kontejneru a key `terraform.tfstate`. Název backendu mu můžeš předat přímo:

```powershell
$env:PLATFORM_STATE_STORAGE_ACCOUNT = $bootstrap.StorageAccountName
$env:PLATFORM_STATE_RESOURCE_GROUP = $bootstrap.ResourceGroupName
```

Přihlášení runneru přes OIDC a chráněné environmenty dodá #11. Lokální bootstrap nevytváří federated credentials ani workflow a sám moduly nenasazuje.

## Prostředky a oprávnění

Bootstrap používá primární region a zkratky CAF: resource group `rg-<name>-bootstrap`, storage account `st<name>tfstate` a identity `id-<name>-<module>-plan` a `id-<name>-<module>-apply`. Názvy zůstávají stabilní; tyto prostředky nevyžadují identifikátor nasazení podle ADR 0008. Kolize globálního názvu storage account způsobí chybu, ne náhodné přejmenování.

Storage account typu `StorageV2`, SKU `Standard_LRS` má HTTPS, TLS 1.2, encryption, vypnutý shared key a public blob access. Nepovoluje HNS, NFS, SFTP ani local users. Autentizace používá Entra ID. Blob service má versioning a soft delete blobů i kontejnerů po 30 dní. Lock `CanNotDelete` chrání účet, ne jednotlivé změny state; změny a lease musí Terraform provádět.

Každý vybraný modul včetně předpokladů má vlastní kontejner a dvě identity. Identity získají `Storage Blob Data Contributor` **jen** na kontejneru svého modulu. Tuto roli potřebuje i plan kvůli lease a možnému zápisu state; nejde o oprávnění měnit prostředky jiných modulů.

Manifest deklaruje Azure role názvem, absolutním ARM scope a volitelnou `phase`. Výchozí fáze je `apply`. Graph oprávnění zapsané jako řetězec patří jen apply; objekt `permission` a `phase` deklaruje fázi výslovně. Bootstrap planu nepřiděluje oprávnění apply a neodvozuje z nich širší oprávnění. Plan přijme Azure role obsahující jen `*/read` a Graph názvy s operací `Read` nebo `ReadBasic`; zápisová oprávnění odmítne.

Bootstrap před první změnou vyhodnotí oprávnění všech vybraných modulů. Odmítne neexistující role a Graph application permissions, neověřené subscriptions a scope na vlastních prostředcích bootstrapu. Zápisová role na management subscription nebo nadřazené management group by umožnila změnit state backend; bootstrap ji odmítne. Manifest musí zvolit scope mimo bootstrap. `emu-identity` nesmí dostat `AppRoleAssignment.ReadWrite.All`. Vlastní roli Entra omezenou na aplikaci GHE dodá #12 podle výsledku #3; toto pole nenahrazuje Graph application permission.

## Opakování, chyby a odstranění

Bootstrap porovnává požadovaný stav se skutečnými prostředky. Druhý běh při nezměněné konfiguraci neprovádí žádný cloudový zápis a vrátí `HasChanges: false`. Role assignments mají deterministické identifikátory; existující stejné přiřazení s jiným ID se neduplikuje. Identitám s dodatečnými Azure nebo application permissions bootstrap odmítne pokračovat; nadbytečné oprávnění neodstraňuje bez schválené změny přístupu. Kontrola Azure zahrnuje všechny subscriptions uvedené v konfiguraci a zděděná přiřazení vrácená API; oprávnění mimo tento rozsah musí ověřit administrátor.

Bootstrap odmítne převzít prostředek se shodným názvem bez odpovídajících ownership tags. Čeká na dokončení storage account a omezeně opakuje požadavky při replikaci managed identity, HTTP 429 a 503. Ostatní chyby vrací s operací, URI a HTTP stavem. Po přerušeném běhu oprav příčinu a spusť stejný příkaz; existující identity i dokončené prostředky zůstanou zachované. Bootstrap nemá automatický rollback.

Nástroj neimplementuje odstranění. Workflow teardown a lokální odstranění bootstrapu dodá #22. Musí zachovat tenant, enterprise, OIDC, SCIM, subscriptions, licence a enterprise kontroly. Před teardownem administrátor obnoví přímé přiřazení Enterprise Owner, které po prvním nasazení odebral ruční krok `emu-identity`. Lock se smí odstranit až při schváleném lokálním odstranění bootstrapu.

## Ověření na Reference instance (referenční instanci)

Offline testy Pester ověřují veřejný skript proti náhradám cloudových API. Neprokazují přístup ani dostupnost API na skutečné instanci.

Platformní tým musí před uzavřením #10 spustit bootstrap na určené referenční instanci, zkontrolovat ochrany backendu, dvě identity každého vybraného modulu a jejich scope. Musí ověřit, že identita přečte a zamkne vlastní state a dostane HTTP 403 pro state jiného modulu. Druhý běh musí vrátit `HasChanges: false`. Přerušený běh musí další spuštění dokončit bez výměny identit. Výsledek včetně data a necitlivých identifikátorů patří do #10. Ověření není součástí dosud provedených offline testů.

## Zdroje

- [ADR 0005](adr/0005-own-bootstrap-instead-of-alz-accelerator.md), [ADR 0008](adr/0008-deployment-identifier-in-retained-names.md), [ADR 0015](adr/0015-least-privilege-identity-per-module.md) a [ADR 0016](adr/0016-github-app-installation-tokens-for-instance-workflows.md).
- [EMU OIDC provisioning](https://learn.microsoft.com/en-us/entra/identity/saas-apps/github-enterprise-managed-user-oidc-provisioning-tutorial) a [synchronization API](https://learn.microsoft.com/en-us/graph/api/resources/synchronization-overview).
- [Storage account REST API](https://learn.microsoft.com/en-us/rest/api/storagerp/storage-accounts/create?view=rest-storagerp-2023-05-01) a [role assignments](https://learn.microsoft.com/en-us/rest/api/authorization/role-assignments/list-for-subscription?view=rest-authorization-2022-04-01).
