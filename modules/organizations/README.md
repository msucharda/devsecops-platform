# organizations

Modul vytvoří v enterprise organizace akcí (actions) a workloadů (workloads) instance a nainstaluje do nich enterprise-owned Apps bez přístupu k repozitářům.

Předpoklady: manifest žádné nedeklaruje. Owneři z `admin_logins` musí být existující EMU uživatelé, například členové platformního týmu zřízení přes SCIM z `emu-identity`. Modul je nezakládá.

## Stav implementace

[#13](https://github.com/msucharda/devsecops-platform/issues/13) PR 2 implementuje tvorbu organizací, instalaci Apps a kontrolu stavu. Tým security, IdP link, roli security manager a navazující Apps doplní PR 3. **Živé ověření neproběhlo.** Tvorbu organizace a instalaci App enterprise installation tokenem ověří člověk podle [runbooku C3](../../docs/runbooks/organizations-c3.md) a při apply [#12](https://github.com/msucharda/devsecops-platform/issues/12).

## Názvy organizací

Runner odvodí názvy z názvu organizace platformy (`-PlatformOrganization`). Workflow předá `GITHUB_REPOSITORY_OWNER` instance repozitáře; lokální běh předá název explicitně. Funkce `Get-PlatformInstanceOrganization` v `tools/PlatformTools.psm1` název striktně validuje a porovná s `instance.name`.

| Organizace platformy | Deployment identifier (identifikátor nasazení) | actions | workloads |
|---|---|---|---|
| `{name}-{deployment}-platform` | `{deployment}`, 6 znaků `a-z0-9` | `{name}-{deployment}-actions` | `{name}-{deployment}-workloads` |
| `{name}-platform` (legacy) | žádný | `{name}-actions` | `{name}-workloads` |

GHE.com název smazané organizace neuvolní ([ADR 0008](../../docs/adr/0008-deployment-identifier-in-retained-names.md)). Modul nemá vlastní generování suffixu. Nové nasazení po teardownu vyžaduje nový bootstrap s novým identifikátorem.

## Parametry

| Parametr | Povinný | Význam |
|---|---|---|
| `admin_logins` | ano | Neprázdný seznam EMU loginů ownerů nové organizace (`alice_demo`). Jedinečné bez ohledu na velikost písmen. |
| `billing_email` | ano | Billing email nové organizace. |
| `app_client_ids` | ne | Client ID enterprise-owned Apps, které modul nainstaluje do obou organizací. Výchozí hodnota je prázdný seznam. |

- `admin_logins` a `billing_email` platí jen při tvorbě organizace. Jejich pozdější změna nic nezmění; modul ownery ani billing existující organizace nespravuje.
- Instance schéma validuje parametry před spuštěním Terraformu. Terraform validace opakuje.

## Životní cyklus

### Tvorba

1. Modul přečte organizace enterprise přes `GET /enterprises/{enterprise}/apps/installable_organizations` (stránkovaně) a hledá název bez ohledu na velikost písmen.
2. Pokud organizace neexistuje, zjistí node ID enterprise (`enterprise(slug)`) a zavolá GraphQL mutaci `createEnterpriseOrganization` s `login`, `profileName`, `billingEmail` a `adminLogins`. Potom čeká, než se organizace objeví v enterprise seznamu.
3. Pokud organizace existuje, modul ji převezme jen tehdy, když název obsahuje identifikátor nasazení. Náhodný identifikátor dokazuje, že organizace patří tomuto nasazení. Legacy název bez identifikátoru (`{name}-actions`, `{name}-workloads`) nic nedokazuje, proto existující legacy organizace ukončí běh chybou (fail-closed). Modul nemá výjimku pro převzetí legacy organizace.

GraphQL odpověď HTTP 200 s `errors` je chyba. Odpověď bez `id` nebo s jiným `login` je chyba.

### Instalace Apps

Pro každou dvojici organizace a `app_client_ids` modul zavolá `POST /enterprises/{enterprise}/apps/organizations/{org}/installations` s `repository_selection: none`. U existující instalace s `repository_selection` `selected` nebo `none` modul přečte seznam repozitářů instalace (`GET .../installations/{installation_id}/repositories`, všechny stránky) a instalaci převezme, jen když je seznam prázdný. Dokumentovaný enum odpovědi obsahuje jen `all` a `selected`; hodnotu `none` modul proto neověřuje podle názvu, ale podle prázdného seznamu repozitářů. Instalaci s přístupem ke všem repozitářům nebo k aspoň jednomu repozitáři odmítne. Stejnou kontrolu provede po vytvoření nové instalace. Destroy instalace volá `DELETE .../installations/{installation_id}`; chybějící instalace nebo organizace je no-op.

### Kontrola stavu

Data source `organization_state` po změnách přečte skutečný stav a vrátí seznam porušení. Postcondition vyžaduje prázdný seznam. Porušení jsou:

- organizace neexistuje,
- App z `app_client_ids` není nainstalovaná (client ID se porovnává s rozlišením velikosti písmen),
- App z `app_client_ids` má přístup ke všem repozitářům,
- App z `app_client_ids` s `repository_selection` `selected` nebo `none` má přístup k aspoň jednomu repozitáři. Apps mimo modul modul nekontroluje; jejich přístup k repozitářům není součástí kontraktu modulu.

Nečitelná odpověď API ukončí čtení chybou; neznámý stav neprojde jako shoda. Plan i drift proto hlásí smazanou organizaci nebo odebranou App jako chybu.

### Obnova po přerušení

- Přerušení po mutaci a před uložením state: Terraform označí prostředek jako tainted a další apply ho nahradí. Destroy provisioner u tainted prostředku neběží, proto absenci organizace při destroy ověřuje i prostředek `removal_guard` (viz Destroy a teardown). Tvorba organizaci najde. S identifikátorem nasazení ji převezme. U legacy názvu běh skončí chybou; operátor organizaci smaže (je nová a prázdná) a spustí apply znovu.
- Přerušení po instalaci App: Terraform označí instalaci jako tainted a další apply ji nahradí; instalace se najde a převezme. Destroy provisioner u tainted instalace neběží, proto App odinstaluje i prostředek `installation_guard` bez create provisioneru. Odebrání client ID z `app_client_ids` po přerušené instalaci proto App neponechá nainstalovanou.
- Změna identity organizace (host, enterprise, název) nahradí guard, organizaci i její instalace (`triggers_replace`). Destroy původních prostředků ověří, že původní organizace neexistuje; jinak apply skončí chybou dřív, než vytvoří novou organizaci stejného druhu. `terraform_data` mění `input` bez nahrazení, proto identita musí být i v `triggers_replace`.

### Destroy a teardown

GitHub nenabízí smazání organizace enterprise installation tokenem. Organizace smaže člověk (ruční krok `delete-instance-organizations`). Destroy jen ověří, že obě organizace v enterprise chybí, a jinak selže.

Ověření provádí destroy provisioner prostředku `organization` a znovu prostředek `removal_guard`. Guard nemá create provisioner, proto nikdy není tainted. Organizace na něm závisí, proto Terraform guard vytvoří před organizací a odstraní ho až po ní. Kontrola proto proběhne i po přerušené tvorbě organizace, kdy je `organization` tainted. Zbytkové riziko: po ztrátě celého state runner modul s prázdným state přeskočí a nic neověří.

Teardown odstraňuje moduly v obráceném pořadí předpokladů. Postup:

1. Spusť teardown. Zastaví se na destroy modulu `organizations` s chybou, že organizace existuje.
2. Enterprise owner smaže organizace actions a workloads v nastavení enterprise.
3. Spusť teardown znovu. Moduly s prázdným state přeskočí; destroy `organizations` projde.

Destroy zachová enterprise, organizaci platformy a ruční enterprise předpoklady. Apps založené pro instanci odstraní až lokální odstranění bootstrapu.

## Identita

Modul používá installation tokeny enterprise-owned Apps podle [ADR 0016](../../docs/adr/0016-github-app-installation-tokens-for-instance-workflows.md) s `resources: { enterprise: true }`. Plan a apply mají oddělené Apps a environments.

| Fáze | Oprávnění |
|---|---|
| plan | `enterprise_organization_installations: read` |
| apply | `enterprise_organization_installations: write`, `enterprise_administration: write` |

- `enterprise_administration: write` je neověřený kandidát pro `createEnterpriseOrganization`. Minimum potvrdí runbook C3.
- `enterprise_organization_installations: write` dovoluje instalovat Apps do všech organizací enterprise. Riziko je přijaté s mitigací (Q7): samostatná App jen pro tento modul, token jen v apply environmentu s required reviewers, minimální oprávnění a krátká platnost.
- Enterprise token nemá přístup k organizačním členům. Modul proto neověří, že owneři z `admin_logins` mají aktivní členství. GraphQL dokumentace uvádí, že chyba pozvánky ownera tvorbu organizace nevrátí zpět. Ověření ownerů je živé kritérium runbooku C3.

## Neověřené živě

- Oprávnění pro `createEnterpriseOrganization` (preview) s enterprise installation tokenem.
- Čtení `enterprise(slug) { id }` enterprise installation tokenem.
- Instalace App do organizace enterprise tokenem a hodnota `none` v seznamu instalací.
- Povinnost `billingEmail` v EMU.
- Aktivní členství ownerů z `admin_logins`.

## Zdroje

- [Enterprise App installations](https://docs.github.com/en/enterprise-cloud@latest/rest/enterprise-admin/organization-installations?apiVersion=2026-03-10), API verze `2026-03-10`, OpenAPI `github/rest-api-description@755ee33b4a81d51f6f07a902cce26cbec3b822f2` (`descriptions/ghec/ghec.2026-03-10.json`).
- [GraphQL createEnterpriseOrganization](https://docs.github.com/en/enterprise-cloud@latest/graphql/reference/mutations#createenterpriseorganization), schéma `github/docs@3a444c04d005e5d91e29ee0658fd5c9bbeaecf24` (`src/graphql/data/ghec/schema.docs.graphql`).
- Kontraktní fixtures jsou v `tools/tests/fixtures/github-api/enterprise-apps/` a `tools/tests/fixtures/github-api/graphql/`.