# enterprise-baseline

Modul nastaví automatizované kontroly v organizacích instance podle ADR 0016. Název modulu zachováváme. Enterprise kontroly, které App-only automatizace nepokrývá, jsou povinné ruční předpoklady, ne Terraform prostředky modulu.

Předpoklady: `organizations` a `actions-catalog`. Manifest deklaruje oba moduly. Graf modulů proto spustí plan a apply tohoto modulu až po úspěšných modulech `organizations` a `actions-catalog`. Teardown ho odstraní před destroy obou modulů. Politika akcí tak začne platit až po importu vendorovaných akcí a při teardownu skončí dřív, než katalog zmizí. Pořadí nezávisí na názvech modulů. Modul výstupy předpokladů nečte. Výběr modulu `enterprise-baseline` vybere i `actions-catalog` včetně jeho ručních kroků.

## Stav implementace

[#17](https://github.com/msucharda/devsecops-platform/issues/17) implementuje organizační oprávnění a ruční enterprise předpoklady. [#18](https://github.com/msucharda/devsecops-platform/issues/18) implementuje politiku akcí a výchozí oprávnění `GITHUB_TOKEN`; živou akceptaci na GHE.com zatím nikdo neprovedl. [#19](https://github.com/msucharda/devsecops-platform/issues/19) implementuje code security configuration a custom patterns. Samostatný root `rulesets/` implementuje organizační rulesety podle [#20](https://github.com/msucharda/devsecops-platform/issues/20).

## Spravovaná organizační nastavení

Modul pro každou organizaci z `target_organizations` volá `PATCH /orgs/{org}` ([dokumentace](https://docs.github.com/en/enterprise-cloud@latest/rest/orgs/orgs#update-an-organization), API verze `2026-03-10`) a nastaví:

| Pole | Hodnota | Výchozí hodnota GitHubu |
|---|---|---|
| `default_repository_permission` | `none` | `read` |
| `members_can_create_repositories` | `false` | `true` |
| `members_can_create_private_repositories` | `false` | `true` |
| `members_can_create_internal_repositories` | `false` | `true` |
| `members_can_fork_private_repositories` | `false` | `false` |

- Modul nespravuje zakládání public repozitářů. EMU organizace public repozitáře nemají.
- Modul používá provider `Mastercard/restapi`, ne `github_organization_settings` providera `integrations/github`. Ten vyžaduje `billing_email`, posílá všechna pole organizace a potřebuje provider pro každou organizaci.
- Provider dostane installation token jobu z proměnné `REST_API_BEARER`. Runner ji nastaví z `GITHUB_TOKEN` a po běhu obnoví.
- Omezení: modul zatím podporuje právě jednu organizaci v `target_organizations`. Installation token platí jen pro jednu organizaci a provider `restapi` přijímá jeden bearer token na běh. Terraform 1.16 nepodporuje `for_each` na provider bloku. Runner proto pro Terraform root s providerem `Mastercard/restapi` odmítne jiný počet organizací než jednu ještě před spuštěním Terraformu. Podpora více organizací (například samostatný běh a state pro každou organizaci) je otevřené rozhodnutí.
- Create, update i destroy jsou `PATCH` existující organizace. Přerušený běh proto další apply bezpečně zopakuje.
- Postcondition po čtení `GET /orgs/{org}` ([dokumentace](https://docs.github.com/en/enterprise-cloud@latest/rest/orgs/orgs#get-an-organization)) vyžaduje spravované hodnoty. Chybějící pole je chyba, ne shoda. Plan tak zachytí drift spravovaných polí.
- Omezení: provider `Mastercard/restapi` 3.0.0 s `ignore_server_additions` drift spravovaných polí neopraví. `Read` ponechá v state konfigurovaná data, a plan proto nenaplánuje opravný `PATCH` ([Mastercard/terraform-provider-restapi#348](https://github.com/Mastercard/terraform-provider-restapi/issues/348)). Drift proto zastaví plan i apply chybou postcondition. Operátor obnoví spravované hodnoty v organizaci ručně. Automatická oprava driftu je otevřené rozhodnutí.
- Druhá postcondition odmítne odpověď, ve které `members_can_change_repo_visibility` nebo `members_can_delete_repositories` má jinou hodnotu než `false`. API organizace tato pole nenastaví; vynucuje je předpoklad `repositoryManagementPoliciesEnforced`. Ruční potvrzení předpokladu nepřebije opačný důkaz z API.
- Check `enterprise_repository_management_policies` hlásí jako varování, že GitHub některé z těchto dvou polí nevrátil. Installation token je nemusí dostat; jediným důkazem pak zůstává ručně potvrzený předpoklad.

## Ruční enterprise předpoklady

Manifest deklaruje `manualPrerequisites`. Runner před plan a apply vyžaduje `true` pro každý příznak v `instance.yaml`; chybějící nebo nepravdivá hodnota ho zastaví před Terraformem. Destroy potvrzení nevyžaduje. Souhrn jobu označí potvrzení jako ruční deklaraci, ne ověření.

| Příznak | Kontrola |
|---|---|
| `privateInternalForksDisabled` | Forky privátních a internal repozitářů jsou zakázané. |
| `repositoryManagementPoliciesEnforced` | Členové nesmí zakládat repozitáře, měnit jejich viditelnost ani je mazat nebo přenášet. |
| `emuUserNamespacesRestricted` | EMU user namespaces nesmějí obsahovat repozitáře, které obejdou organizační kontroly. |
| `fineGrainedPatApprovalRequired` | Fine-grained PAT vyžaduje schválení. |
| `patMaxLifetime90Days` | Maximální platnost PAT je 90 dní. |

Platformní tým příznaky nastaví před bootstrapem. O omezení classic PAT zatím není rozhodnuto. Teardown tyto předpoklady zachová. Jejich ruční potvrzení není důkaz automatického planu ani detekce driftu.

## Organizační oprávnění

- Základní oprávnění k repozitářům je žádné.
- Organization owners patří jen do platformního týmu.
- Workload týmy mají nejvýše repository roli `Maintain`; nemají `Admin`, organization owner ani organizační role pro změnu kontrol.
- Kontroly omezují workload týmy. Platformní tým je důvěryhodný správce; může kontroly změnit a změny mimo workflow má zachytit drift.

## GitHub Actions

- Povolené jsou jen vendorované akce z Actions organization (organizace akcí).
- Dependabot version updates a security updates běží v dynamických workflow, která [obcházejí kontroly Actions policy](https://docs.github.com/en/code-security/concepts/supply-chain-security/dependabot-on-actions) na úrovni repozitáře a organizace.
- Modul kvůli Dependabotu nesmí povolit externí action pattern ani `github/dependabot-action@*`. Log interního jobu při C4 tuto akci obsahoval, ale allowlist ji nevyžaduje.
- Pull request Dependabotu může spustit CI workflow repozitáře. Toto workflow politice akcí podléhá.
- CodeQL default setup politika akcí neblokuje.
- Výchozí oprávnění `GITHUB_TOKEN` je jen čtení.
- GitHub Actions nesmí vytvářet ani schvalovat PR.

### Politika akcí a oprávnění `GITHUB_TOKEN`

Modul v každé organizaci z `target_organizations` nastaví tato pole (API verze `2026-03-10`):

| Endpoint | Pole | Hodnota | Výchozí hodnota GitHubu |
|---|---|---|---|
| [`PUT /orgs/{org}/actions/permissions`](https://docs.github.com/en/enterprise-cloud@latest/rest/actions/permissions#set-github-actions-permissions-for-an-organization) | `enabled_repositories` | `all` | `all` |
| | `allowed_actions` | `local_only` | `all` |
| [`PUT /orgs/{org}/actions/permissions/workflow`](https://docs.github.com/en/enterprise-cloud@latest/rest/actions/permissions#set-default-workflow-permissions-for-an-organization) | `default_workflow_permissions` | `read` | `read` |
| | `can_approve_pull_request_reviews` | `false` | `false` |

- `local_only` povolí akce z repozitářů organizace a enterprise. Vendorované akce v organizaci akcí jsou dostupné celé enterprise ([`actions-catalog`](../actions-catalog/README.md)), proto workflow organizací instance smějí volat jen je a akce enterprise. Akce z GitHub.com a Marketplace politika zablokuje.
- Omezení: `local_only` nezablokuje akce z jiných organizací enterprise. Užší pravidlo „jen organizace akcí“ by vyžadovalo enterprise politiku nebo seznam `selected` s vyloučením; je to otevřená otázka.
- `can_approve_pull_request_reviews` řídí i vytváření PR z GitHub Actions (v UI „Allow GitHub Actions to create and approve pull requests“).
- Modul nespravuje `sha_pinning_required` ani seznam `selected-actions`; `sha_pinning_required` ponechá beze změny.
- Enterprise politika může nastavení organizace zakázat. Pak `PUT` vrátí HTTP 409 a apply selže se zprávou o enterprise politice. Modul enterprise politiku nemění.
- Zápis i čtení provádí skript `scripts/ActionsPolicy.psm1`. Oba `PUT` vrací `204` bez těla, proto modul nepoužívá provider `restapi`. Každý zápis je idempotentní `PUT` jen se spravovanými poli. Skript nejdřív přečte stav a zapíše jen rozdíl. Po zápisu stav znovu přečte a selže, když neodpovídá politice.
- Data source `external.actions_policy_state` čte `GET /orgs/{org}/actions/permissions` a `GET /orgs/{org}/actions/permissions/workflow` při každém planu a po apply. Chybějící pole, jiný typ nebo jiná velikost písmen je porušení, ne shoda. Drift zastaví plan; oprava je ruční obnova nebo apply s `-replace=terraform_data.actions_policy_settings["<org>"]`.
- Identitní prostředek `terraform_data.actions_policy` při destroy obnoví výchozí hodnoty GitHubu z tabulky. Obsahový prostředek `terraform_data.actions_policy_settings` politiku zapisuje; změna politiky nahradí jen jeho, takže mezi starou a novou politikou nevznikne okno s výchozími hodnotami.

## Organizační ruleset pro výchozí větev

Samostatný root `rulesets/` spravuje v každé organizaci z `target_organizations` aktivní ruleset `platform-default-branch`. Podmínka `repository_name.include: ["~ALL"]` zahrnuje všechny repozitáře; `ref_name.include: ["~DEFAULT_BRANCH"]` sleduje jejich aktuální výchozí větev. Oba seznamy `exclude` jsou prázdné.

- Změna jen přes PR s jedním schválením. Nový commit schválení zruší.
- PR vyžaduje review od CODEOWNERS.
- Force push a smazání větve jsou zakázané.
- Pravidlo `code_scanning` vyžaduje CodeQL s `security_alerts_threshold: high_or_higher`. Obecné alerty bez bezpečnostní závažnosti neblokuje (`alerts_threshold: none`).
- `bypass_actors` je explicitně prázdné pole. Bypass nemá ani platformní tým, organization owner nebo importní App.

Root používá [organizační ruleset REST API](https://docs.github.com/en/enterprise-cloud@latest/rest/orgs/rules), verzi `2026-03-10`: seznam `GET /orgs/{org}/rulesets`, detail `GET /orgs/{org}/rulesets/{ruleset_id}`, vytvoření `POST /orgs/{org}/rulesets`, změnu `PUT /orgs/{org}/rulesets/{ruleset_id}` a odstranění `DELETE /orgs/{org}/rulesets/{ruleset_id}`.

- Runner ho spouští přes `Invoke-Module.ps1 -Module enterprise-baseline -Rulesets` s akcí `plan`, `apply` nebo `destroy`. Má oddělený state `terraform.rulesets.tfstate`.
- Prostředek `restapi_object.ruleset` používá provider `Mastercard/restapi` a installation token z `REST_API_BEARER`, který nastavuje runner. Stejně jako běžný root podporuje právě jednu organizaci na běh. Podpora více organizací vyžaduje samostatné běhy a state; není součástí této změny.
- `terraform_data.ruleset_intent` uloží záměr před vzdáleným `POST`. Provider potom uchová GitHub ID ve state a mění i maže objekt podle něj, nikoli podle názvu. Přejmenování proto nezpůsobí smazání jiného rulesetu pod původním názvem.
- Po ztracené odpovědi na `POST` čtení podle rezervovaného názvu `platform-default-branch` zjistí existující objekt. Terraform `import` block ho při dalším planu převezme do state místo vytvoření duplikátu. Existující state identita má přednost před tímto vyhledáním. Ztracenou odpověď na `PUT` nebo `DELETE` řeší refresh a opakovaný běh.
- Před destroy runner spustí `Restore-RulesetState.ps1`. Skript ověří každý uložený objekt podle ID a zdrojové organizace. Pokud state obsahuje jen přerušený záměr vytvoření bez vzdáleného ID, nejprve objekt vyhledá podle názvu a přes `terraform import` uloží jeho ID. Potom cíleným apply uloží do záměru příznak `destroy_started = true`; používá interní proměnnou `ruleset_destroy_started`. Teprve potom runner vytvoří destroy plan. Záměr se maže až po nativním prostředku. Po přerušení mezi jejich odstraněním proto další destroy nepřevezme jiný objekt původního názvu. Skript podle názvu nic nemaže a existující ID nikdy nenahradí jiným objektem. Tento obnovovací krok vyžaduje runner; samostatné `terraform destroy` po přerušeném vytvoření ho nenahrazuje.
- Duplicitní název, kolize velikosti písmen názvu, neznámý typ zdroje a neshodná identita v detailu zastaví čtení i zápis. Zděděný enterprise ruleset stejného názvu skript nepřevezme ani nesmaže.
- Každý plan a ověření po apply čte úplný detail. Nezávislé čtení během planu kontroluje existující rulesety i při přidání organizace nebo jiné čekající změně; nesmí se odložit do apply. Chybějící, `null` nebo nepolové `bypass_actors` je chyba, ne důkaz prázdného bypassu. Bypass navíc, vypnutí vynucování, změna podmínek nebo pravidel zastaví plan jako drift. Pořadí pravidel a merge metod se ignoruje; prázdné serverové `required_reviewers` a vypnuté `dismissal_restriction` bez aktérů se považují za ekvivalent. `enabled` musí mít boolean typ.
- Spravovaný ruleset podporuje jen variantu podmínek `repository_name` s `ref_name`. Varianty `repository_id` a `repository_property` odmítne s chybou. Ostatní místní rulesety nespravuje. Detaily zděděných enterprise rulesetů tento root neověřuje; noční kontrola jejich počet vykazuje jako nepokrytou oblast podle ADR 0016.
- Drift spravovaných hodnot zastaví plan; provider `restapi` s `ignore_server_additions` ho automaticky neopravuje. Operátor obnoví požadované hodnoty včetně původního názvu. Smazaný ruleset refresh rozpozná a další schválený apply ho znovu vytvoří. Běžný plan nemění vzdálené prostředky.

Importní PR podléhají stejnému review i skenování. Ruleset nevyžaduje vlastní CI status check cloudového planu; jeho neprovedení u App-created PR proto není samo o sobě blokací merge. Import nesmí dostat bypass. Skutečný průchod importu akce a release, chování CodeQL pro jejich obsah a čtení `bypass_actors` installation tokenem musí potvrdit živá akceptace na GHE.com. Offline testy to nedokazují.

## Code security configuration

Modul v každé organizaci z `target_organizations` vytvoří organizační code security configuration (konfiguraci zabezpečení kódu) `platform-baseline`. Endpointy jsou v [dokumentaci](https://docs.github.com/en/enterprise-cloud@latest/rest/code-security/configurations), API verze `2026-03-10`.

| Pole | Hodnota |
|---|---|
| `advanced_security` | `enabled` (GitHub Code Security a GitHub Secret Protection) |
| `dependency_graph`, `dependabot_alerts`, `dependabot_security_updates` | `enabled` |
| `code_scanning_default_setup` | `enabled` (CodeQL default setup) |
| `secret_scanning`, `secret_scanning_push_protection`, `secret_scanning_validity_checks` | `enabled` |
| `secret_scanning_delegated_bypass` | `enabled`; reviewery určuje parametr `secret_scanning_bypass_reviewers` |
| `enforcement` | `enforced` |

- Configuration je organizační, ne `enterprise_enforced`. Installation token App enterprise configuration nevytvoří.
- Apply nastaví configuration jako výchozí pro nové repozitáře (`default_for_new_repos: all`) a připojí ji ke všem repozitářům (`scope: all`). Potom čeká, dokud žádný repozitář nemá stav `attaching` nebo `updating`. Limit je 600 sekund; proměnná `CODE_SECURITY_ATTACHMENT_TIMEOUT` ho změní. Apply selže, když některý repozitář skončí v jiném stavu než `attached` nebo `enforced`, nebo když některý repozitář instalace configuration nemá. Další apply krok zopakuje.
- Parametr `secret_scanning_bypass_reviewers` je povinný. Každá položka má `reviewer_type` (`TEAM` nebo `ROLE`) a číselné `reviewer_id` týmu nebo organizační role security týmu. `teams.security` v `instance.yaml` obsahuje jen e-maily, proto modul ID z této sekce neodvodí. Příklad:

  ```yaml
  modules:
    enterprise-baseline:
      parameters:
        target_organizations: [demo]
        secret_scanning_bypass_reviewers:
          - reviewer_type: TEAM
            reviewer_id: 42
  ```

## Custom patterns

Seznam patterns je v `customPatterns` v `instance.yaml`. Výchozí seznam je prázdný. Modul každý pattern vytvoří v každé organizaci a zapne pro něj push protection. Endpointy jsou v dokumentaci [custom patterns](https://docs.github.com/en/enterprise-cloud@latest/rest/secret-scanning/custom-patterns) a [push protection](https://docs.github.com/en/enterprise-cloud@latest/rest/secret-scanning/push-protection), API verze `2026-03-10`.

- Modul hledá pattern podle `name`. Název musí být v seznamu jedinečný.
- `secretRegex` je `pattern`. `beforeSecret` a `afterSecret` jsou `start_delimiter` a `end_delimiter`. Chybějící nebo prázdná hodnota znamená dokumentovanou výchozí hodnotu `\A|[^0-9A-Za-z]`, resp. `\z|[^0-9A-Za-z]`.
- Modul nespravuje `must_match` ani `must_not_match`. Plan vyžaduje, aby oba seznamy byly prázdné.
- Push protection modul zapne přes `PATCH /orgs/{org}/secret-scanning/pattern-configurations`. Pattern najde v `custom_pattern_overrides` podle `slug`.
- API nemá operaci pro publikování patternu. Pokud GitHub vytvoří pattern ve stavu `unpublished`, apply selže. Operátor pattern publikuje v UI a apply zopakuje.
- Patterns organizace, které nejsou v `customPatterns`, modul ignoruje a nemaže.

## Implementace a obnova po přerušení

- Code security configuration a patterns nepoužívají `Mastercard/restapi` ani `integrations/github`. Spravují je prostředky `terraform_data` s PowerShell skripty v `scripts/`. Skripty volají REST API s tokenem z `REST_API_BEARER` a pevnou hlavičkou `X-GitHub-Api-Version: 2026-03-10`.
  - `restapi` neumí převzít configuration, jejíž odpověď na `POST` se ztratila. Další apply by vytvořil duplikát, nebo selhal na kolizi názvu.
  - Mazání patternu posílá ID a verzi v těle `DELETE`; `restapi` tělo pro mazání neposílá.
- Každý objekt má dva prostředky. Identitní prostředek (`code_security_configuration`, `custom_pattern`) objekt jen maže při destroy. Obsahový prostředek (`code_security_configuration_settings`, `custom_pattern_content`) při vytvoření objekt najde podle názvu a vytvoří nebo upraví. Změna obsahu proto upraví objekt na místě.
- Každý krok je idempotentní. Selhaný provisioner označí prostředek jako tainted a další apply celý krok zopakuje. Ztracená odpověď na `POST` nevytvoří duplikát, protože skript objekt nejdřív hledá podle názvu.
- Destroy považuje chybějící objekt za smazaný. Přerušený destroy proto jde zopakovat.
- Data source `external.code_security_state` po apply a při každém planu přečte skutečný stav. Chyba čtení zastaví plan. Neznámý stav nikdy neprojde jako shoda.

## Detekce driftu

Modul drift neopravuje automaticky. Postconditions data source zastaví plan, když:

- organizační configuration `platform-baseline` chybí,
- některé spravované pole nebo seznam bypass reviewerů má jinou hodnotu,
- configuration není jediná výchozí pro nové public, private i internal repozitáře,
- některý repozitář configuration nemá ve stavu `attached` nebo `enforced`,
- některý repozitář instalace nemá úspěšně připojenou configuration, například po ručním odpojení nebo po vytvoření nového repozitáře,
- některý repozitář je připojený k jiné configuration,
- spravovaný pattern chybí, liší se, není publikovaný nebo nemá zapnutou push protection.

Oprava: operátor obnoví stav ručně, nebo spustí apply s `-replace` obsahového prostředku, který uvádí chybová zpráva.

Seznam repozitářů modul čte přes [`GET /installation/repositories`](https://docs.github.com/en/enterprise-cloud@latest/rest/apps/installations#list-repositories-accessible-to-the-app-installation). Instalace App má přístup ke všem repozitářům organizace. `GET /orgs/{org}/repos` s installation tokenem nepodporuje internal repozitáře. Plan selže, když odpověď uvádí jiný `repository_selection` než `all`, nebo když `total_count` neodpovídá počtu vypsaných repozitářů. Archivované repozitáře modul nevynechává.

Neznámý stav připojení (hodnota mimo dokumentovaný enum) a neznámý `mode` bypass reviewera plan zastaví. Chybějící `mode` znamená dokumentovanou výchozí hodnotu `ALWAYS`.
## Teardown

Teardown vrátí spravované organizační politiky na výchozí hodnoty GitHubu, včetně politiky akcí a oprávnění `GITHUB_TOKEN` (`all`, `all`, `read`, `false`), a smaže organizační rulesety, configurations a custom patterns. Destroy configuration nejdřív zruší její výchozí roli a potom ji smaže. GitHub odpojí repozitáře a ponechá jim nastavení bez vazby na configuration. Destroy patternu vyřeší jeho alerty jako `pattern deleted` (`post_delete_action: resolve_alerts`). Ruční enterprise předpoklady nemění. Případné ruční operace uvádí manifest včetně omezení odstranění. Destroy organizačních nastavení pošle `PATCH` jen se spravovanými poli a výchozími hodnotami z tabulky výše.

## Identita

- Běžný plan používá installation token s `Organization Administration: read`; apply používá `write` pro organizace instance. Stejná oprávnění dokumentace uvádí pro čtení a změny code security configurations, custom patterns, pattern configurations a politiky GitHub Actions organizace.
- Seznam a detail rulesetů vyžadují `write` i pro čtení. Plan rulesetů proto běží v samostatném jobu a environmentu s vlastní App identitou. Toto oprávnění umožňuje i změny jiných organizačních nastavení; výjimku přijímáme podle ADR 0016.
- Privátní klíč ani token ruleset jobu nesmějí dostat ostatní plan joby. Stejné oddělení platí pro noční detekci driftu.
- PR platformního týmu může spustit oba plan joby automaticky, bez dalšího schválení security týmem. Forky, jiní autoři ani App-created PR credentials automaticky nedostanou.
- Apply nadále schvaluje platformní tým a navíc security tým.
- Před nasazením se musí na GHE.com ověřit potřebná API, oprávnění i úplné čtení bypass aktérů. Nepodporovaná operace není důvod přidat PAT.
