# organization-roles

Modul přiřazuje předdefinovanou roli `security_manager` týmu organizace ve všech třech organizacích instance. Navazuje na `organizations`; organizace nevytváří ani nemaže.

## Nasazení ve dvou etapách

1. Nasaď `organizations`. Počkej na vytvoření organizací actions a workloads.
2. Připrav lokální konfiguraci druhé etapy s vybranými navazujícími moduly, zatím ji nenasazuj. Nad touto konfigurací spusť `Get-GitHubAppInstallationChecklist.ps1`; dosud nezaregistrované Apps označí `registrationRequired: true`. Vytvoř týmy a IdP linky, ručně nainstaluj Apps podle checklistu a doplň bindings. Apps `organization-roles` musí mít všechny tři organizace a žádný repozitář. Ověř bindings bootstrapem a teprve potom nasaď konfiguraci druhé etapy.

Runner spustí pro každou organizaci samostatný Terraform proces s jejím installation tokenem. State ukládá v kontejneru modulu pod `organizations/<login>/terraform.tfstate`. Plan a apply mají oddělené Apps, klíče a environments.

## Tým a SCIM link

Před prvním planem vytvoř v každé cílové organizaci tým `security` a propoj ho se skupinou Entra ID `{instance.name}-security-team`. Existující tým organizace platformy zachovej. Parametr `security_team` dovoluje jiný slug týmu, společný pro všechny organizace.

Propojení proveď v nastavení týmu podle stejného postupu jako ruční krok `link-organization-teams` modulu `emu-identity`. Po ověření všech tří propojení nastav `manualPrerequisites.organizationSecurityTeamsLinked: true`. Bez potvrzení plan selže. Modul tým ani jeho členství nespravuje. Chybějící tým ukončí plan chybou.

SCIM link je ruční krok. OpenAPI pro `PATCH /orgs/{org}/teams/{team_slug}/external-groups` deklaruje `enabledForGitHubApps: false`, zatímco pokus C2 v [#4](https://github.com/msucharda/devsecops-platform/issues/4) zaznamenal HTTP 200 s App tokenem. Modul tento rozpor neobchází nezdokumentovaným voláním. Plan, drift ani destroy SCIM link neověřují a nemění.

## Oprávnění

| Fáze | Oprávnění | Instalace |
|---|---|---|
| plan | `members: read`, `organization_custom_org_roles: read` | platform, actions, workloads; žádné repozitáře |
| apply | `members: write`, `organization_custom_org_roles: read` | platform, actions, workloads; žádné repozitáře |

Uživatel tento rozsah schválil 23. 10. 2026. Oprávnění se nepřenášejí na ostatní moduly. Role se přiřazuje přes Organization Roles API, nikoli přes nahrazené endpointy `/security-managers`.

## Parametry

| Parametr | Význam |
|---|---|
| `target_organizations` | Úplná sada platform, actions a workloads odvozená z organizace platformy. Runner předá každému procesu právě jednu organizaci. |
| `security_team` | Slug existujícího týmu organizace. Výchozí hodnota je `security`. |

## Životní cyklus

Plan přečte předdefinovanou roli `security_manager`, identitu týmu a jeho přímé přiřazení. Nečitelná odpověď, neznámý typ nebo nesoulad identity ukončí čtení chybou. Enterprise tým ani nepřímé přiřazení nejsou důkazem přímého přiřazení týmu organizace.

Modul deklarativně vlastní přiřazení této role tomuto týmu. Nerozlišuje přiřazení vytvořené modulem a přiřazení, které existovalo předem. Ruční správa stejného přiřazení mimo modul se nepodporuje.

Apply při vytvoření prostředku přiřadí chybějící roli. Při existujícím přiřazení nic nezapisuje. Přerušení po PUT před uložením Terraform state nevyžaduje journal: další apply najde existující přiřazení a zachová ho bez dalšího PUT.

Destroy odebere přímé přiřazení security týmu uloženému ve state, **včetně dřívějšího ručního přiřazení**. Rozhoduje podle uložených `role_id` a `team_id`, nikoli podle původního slugu. Přejmenovaný tým dohledá v úplném seznamu přiřazení. Náhradní tým se stejným slugem a jiným ID nezmění za provozního předpokladu uvedeného níže. Ostatní týmy, jejich přiřazení, členství a SCIM linky zachová.

Před odebráním i po něm modul načte všechny stránky přiřazení. Bez DELETE skončí jen po úspěšně ověřené nepřítomnosti přímého přiřazení uloženému týmu. Nečitelná odpověď, chyba další stránky nebo neplatné stránkování ukončí destroy chybou. DELETE 404 je přípustné jen při ověřené nepřítomnosti po požadavku.

Smazaný tým dál zastaví běžný plan, ale neblokuje destroy prostředků ve state. Reader vrátí strukturovanou nepřítomnost pouze pro dokumentované GET 404. Terraform postcondition ji při běžném planu odmítne; při destroy refreshi dovolí cleanup podle uložené identity. Chyby oprávnění, serveru a nečitelné úspěšné odpovědi se za nepřítomnost nepovažují.

**Přiznaná mezera teardownu:** destroy pracuje jen s prostředky v Terraform state. Pokud běh skončí po PUT před uložením state, musíš před destroy obnovit apply. Bez něj může role security týmu zůstat přiřazená. Samostatný stateless cleanup modul neprovádí. Při úplném teardownu ji odstraní až smazání organizací actions a workloads v `organizations` ([#22](https://github.com/msucharda/devsecops-platform/issues/22)) a smazání organizace platformy přes `Remove-Bootstrap`.

Při apply modul porovná identitu role a týmu s planem před zápisem i po něm. Záměnu týmu za jiný tým se stejným slugem odmítne. Destroy před DELETE znovu ověří, že aktuální slug patří uloženému ID. Odebrání role deklarovanému security týmu zachytí plan i drift. Přiřazení jiným týmům modul nespravuje.

### Provozní předpoklad identity týmu

**Během apply/destroy nikdo souběžně nemaže, nepřejmenovává ani nevytváří security tým.** Slib „nikdy nezměnit náhradní tým“ platí jen za tohoto předpokladu. [Připnuté OpenAPI](https://github.com/github/rest-api-description/blob/755ee33b4a81d51f6f07a902cce26cbec3b822f2/descriptions/ghec/ghec.2026-03-10.json) definuje odebrání role pouze přes `org`, `team_slug` a `role_id`. Nedokumentuje odebrání podle neměnného ID týmu ani podmíněný DELETE vázaný na očekávané ID.

Kontrola ID těsně před DELETE souběžnou záměnu nevyloučí. Modul proto po DELETE znovu ověří identitu slugu. Pokud patří jinému ID, skončí chybou s původním a novým team ID, slugem, role ID a přesným příkazem obnovy. Novému týmu už mohla být role odebrána. Automatickou obnovu modul neprovádí.

Při této chybě nejprve zastav souběžnou správu týmu. Ověř, že nový tým má dostat `security_manager`. Nastav jeho organizační apply token do `REST_API_BEARER` a spusť příkaz z chyby: importuje knihovnu modulu a zavolá `Set-OrganizationSecurityManager` s explicitním novým team ID a uloženým role ID. Příkaz obě identity znovu ověří před přiřazením i po něm. Teprve potom opakuj přerušenou operaci.

### Ruční náprava odebrané role

**Přiznaná mezera nápravy driftu:** pokud někdo přiřazení role ručně odebere, plan, drift i běžný apply selžou. Terraform bez změny vstupů znovu nespustí create provisioner existujícího prostředku. Uživatel 23. 10. 2026 schválil explicitní náhradu prostředku `assignment` místo změny runneru.

Připrav samostatný pracovní kontext se stejným backendem, tfvars a apply tokenem jako pro postiženou organizaci. Dočasný kontext runneru po jeho dokončení neexistuje. Inicializuj backend pro state `organizations/<login>/terraform.tfstate` v kontejneru modulu. Tfvars musí obsahovat právě tuto organizaci v `target_organizations` a úplnou mapu `instance.organizations`; apply token této organizace nastav v `REST_API_BEARER`.

V pracovním adresáři modulu spusť následující příkaz. Cestu nahraď cestou k připravenému souboru parametrů; runnerův název `inputs.tfvars.json` Terraform automaticky nenačítá.

```powershell
terraform apply -var-file="<cesta k inputs.tfvars.json>" -replace=terraform_data.assignment
```

Zkontroluj a schval plan náhrady. Nahrazuj jen `assignment`, nikoli `role_guard`; neměň backend ani nevypínej state lock. Potom spusť běžný plan, který musí skončit bez změn. Pokud role chybí ve více organizacích, proveď nápravu odděleně v každé z nich.

Živý plan, apply, následný plan, drift a destroy nejsou v rámci implementace ověřené. Ověří je navazující nasazení; implementační session nemá povolené živé kroky.

## Zdroje

- [Organization Roles API](https://docs.github.com/en/enterprise-cloud@latest/rest/orgs/organization-roles?apiVersion=2026-03-10), REST API `2026-03-10`.
- [Teams API](https://docs.github.com/en/enterprise-cloud@latest/rest/teams/teams?apiVersion=2026-03-10), REST API `2026-03-10`.
- OpenAPI: `github/rest-api-description@755ee33b4a81d51f6f07a902cce26cbec3b822f2`, `descriptions/ghec/ghec.2026-03-10.json`.
- [#105](https://github.com/msucharda/devsecops-platform/issues/105), navazuje na [#13](https://github.com/msucharda/devsecops-platform/issues/13).
