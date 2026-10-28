# enterprise-baseline

Modul nastaví automatizované kontroly v organizacích instance podle ADR 0016. Název modulu zachováváme. Enterprise kontroly, které App-only automatizace nepokrývá, jsou povinné ruční předpoklady, ne Terraform prostředky modulu.

Předpoklady: `organizations` a `actions-catalog`. Manifest deklaruje oba moduly. Graf modulů proto spustí plan a apply tohoto modulu až po úspěšných modulech `organizations` a `actions-catalog`. Teardown ho odstraní před destroy obou modulů. Politika akcí tak začne platit až po importu vendorovaných akcí a při teardownu skončí dřív, než katalog zmizí. Pořadí nezávisí na názvech modulů. Modul výstupy předpokladů nečte. Výběr modulu `enterprise-baseline` vybere i `actions-catalog` včetně jeho ručních kroků.

## Stav implementace

[#17](https://github.com/msucharda/devsecops-platform/issues/17) implementuje organizační oprávnění a ruční enterprise předpoklady. [#18](https://github.com/msucharda/devsecops-platform/issues/18) implementuje politiku akcí a výchozí oprávnění `GITHUB_TOKEN`; živou akceptaci na GHE.com zatím nikdo neprovedl. [#19](https://github.com/msucharda/devsecops-platform/issues/19) implementuje code security configuration a custom patterns. Organizační rulesety podle [#20](https://github.com/msucharda/devsecops-platform/issues/20) spravuje modul `organization-rulesets`.

## Spravovaná organizační nastavení

Modul pro každou organizaci z `target_organizations` volá `PATCH /orgs/{org}` ([dokumentace](https://docs.github.com/en/enterprise-cloud@latest/rest/orgs/orgs#update-an-organization), API verze `2026-03-10`) a nastaví:

| Pole | Hodnota | Výchozí hodnota GitHubu |
|---|---|---|
| `default_repository_permission` | `none` | `read` |
| `members_can_create_repositories` | `false` | `true` |
| `members_can_create_private_repositories` | `false` | `true` |
| `members_can_create_internal_repositories` | `false` | `true` |

- Modul nespravuje zakládání public repozitářů. EMU organizace public repozitáře nemají.
- Modul používá provider `Mastercard/restapi`, ne `github_organization_settings` providera `integrations/github`. Ten vyžaduje `billing_email`, posílá všechna pole organizace a potřebuje provider pro každou organizaci.
- Manifest deklaruje `organizationScoped: true`. `target_organizations` musí obsahovat přesně všechny organizace instance: platformní, akcí a workloadů, odvozené přes `-PlatformOrganization`. Runner podmnožinu i nadmnožinu odmítne.
- Provider přijímá jeden bearer token na proces. Společný runner proto pro každou organizaci spustí samostatný Terraform proces se singleton `target_organizations` a tokenem dané organizace v `REST_API_BEARER`, `GITHUB_TOKEN` a tokenových mapách. Původní environment po běhu obnoví.
- Každá organizace má v kontejneru `enterprise-baseline` vlastní state `organizations/<login>/terraform.tfstate`. Login je lowercase. Runner nepoužije starý společný state ani ho nemigruje; upgrade mezi RC release není podporovaný. Výstupní artifact vznikne až po úspěchu všech organizací. Obsahuje úplný seznam `organizations` a veřejné výstupy v mapě `organization_outputs`.
- Create, update i destroy jsou `PATCH` existující organizace. Přerušený běh proto další apply bezpečně zopakuje.
- Postcondition po čtení `GET /orgs/{org}` ([dokumentace](https://docs.github.com/en/enterprise-cloud@latest/rest/orgs/orgs#get-an-organization)) vyžaduje spravované hodnoty. Chybějící pole je chyba, ne shoda. Plan tak zachytí drift spravovaných polí.
- `members_can_fork_private_repositories` řídí enterprise politika, ne modul. Create, update ani destroy toto pole neposílají. Samostatná postcondition vyžaduje přesně `false` z API; `true`, `null`, chybějící pole nebo neplatná hodnota zastaví plan i apply s odkazem na předpoklad `privateInternalForksDisabled`. Teardown enterprise politiku zachová.
- Plan čte stav, ale neposílá zkušební `PATCH`. Dokumentace tohoto endpointu neuvádí dry-run; úspěšný plan proto nedokazuje, že API přijme zápis. Enterprise politika forků odmítá i zápis nezměněné hodnoty (`422`, [#147](https://github.com/msucharda/devsecops-platform/issues/147)).
- Omezení: provider `Mastercard/restapi` 3.0.0 s `ignore_server_additions` drift spravovaných polí neopraví. `Read` ponechá v state konfigurovaná data, a plan proto nenaplánuje opravný `PATCH` ([Mastercard/terraform-provider-restapi#348](https://github.com/Mastercard/terraform-provider-restapi/issues/348)). Drift proto zastaví plan i apply chybou postcondition. Operátor obnoví spravované hodnoty v organizaci ručně. Automatická oprava driftu je otevřené rozhodnutí.
- Další postcondition odmítne odpověď, ve které `members_can_change_repo_visibility` nebo `members_can_delete_repositories` má jinou hodnotu než `false`. API organizace tato pole nenastaví; vynucuje je předpoklad `repositoryManagementPoliciesEnforced`. Ruční potvrzení předpokladu nepřebije opačný důkaz z API.
- Check `enterprise_repository_management_policies` hlásí jako varování, že GitHub některé z těchto dvou polí nevrátil. Installation token je nemusí dostat; jediným důkazem pak zůstává ručně potvrzený předpoklad.

## Ruční enterprise předpoklady

Manifest deklaruje `manualPrerequisites`. Runner před plan a apply vyžaduje `true` pro každý příznak v `instance.yaml`; chybějící nebo nepravdivá hodnota ho zastaví před Terraformem. Destroy potvrzení nevyžaduje. Souhrn jobu označí potvrzení jako ruční deklaraci, ne ověření.

| Příznak | Kontrola |
|---|---|
| `privateInternalForksDisabled` | Enterprise politika zakazuje forky privátních a internal repozitářů. Modul ji nemění; přes `GET /orgs/{org}` navíc vyžaduje `members_can_fork_private_repositories = false`. Ruční potvrzení nenahradí chybějící nebo nevyhovující hodnotu z API. |
| `repositoryManagementPoliciesEnforced` | Členové nesmí zakládat repozitáře, měnit jejich viditelnost ani je mazat nebo přenášet. |
| `emuUserNamespacesRestricted` | EMU user namespaces nesmějí obsahovat repozitáře, které obejdou organizační kontroly. |
| `fineGrainedPatApprovalRequired` | Fine-grained PAT vyžaduje schválení. |
| `patMaxLifetime90Days` | Maximální platnost PAT je 90 dní. |
| `liveWorkflowsPromoted` | Živá workflow v `.github/workflows` repozitáře instance jsou povýšená z `platform/` a volají jen katalogové akce. Viz [Politika akcí](#politika-akcí-a-oprávnění-github_token). |

Platformní tým nastaví enterprise příznaky před bootstrapem. Příznak `liveWorkflowsPromoted` nastaví až po mergi PR s povýšením workflow; bootstrap ani průvodce ho nevyžadují a průvodce zachová jeho hodnotu. O omezení classic PAT zatím není rozhodnuto. Teardown tyto předpoklady zachová. Jejich ruční potvrzení není důkaz automatického planu ani detekce driftu.

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
- Omezení: `local_only` nezablokuje akce z jiných organizací enterprise. Přírůstek 1 `local_only` ponechá (rozhodnutí uživatele z 22. 10. 2026). Užší pravidlo `selected` se vzorem pro organizaci akcí a jeho živé ověření řeší [#81](https://github.com/msucharda/devsecops-platform/issues/81).
- Pořadí nasazení: úspěšný apply `actions-catalog` nedokazuje, že živá workflow v `.github/workflows` repozitáře instance už používají katalogové akce. Povýšení šablon z `platform/` je samostatný ruční krok ([vendoring](../../docs/vendoring.md#ruční-povýšení-živých-workflow-v-16)). Platformní tým musí povýšení mergnout před prvním apply tohoto modulu. Jinak politika zablokuje deploy, drift i teardown workflow, které upstream akce stále volají. Runner před plan i apply nadále vyžaduje `manualPrerequisites.liveWorkflowsPromoted: true`. Automatický preflight tuto deklaraci doplňuje, nenahrazuje ji. Obnova po chybném pořadí: organization owner v UI dočasně povolí všechny akce, povýší workflow a apply zopakuje.
- `can_approve_pull_request_reviews` řídí i vytváření PR z GitHub Actions (v UI „Allow GitHub Actions to create and approve pull requests“).
- Modul nespravuje `sha_pinning_required` ani seznam `selected-actions`; `sha_pinning_required` ponechá beze změny (rozhodnutí uživatele z 22. 10. 2026). Ověření SHA pinningu workflow a rozhodnutí o poli řeší [#82](https://github.com/msucharda/devsecops-platform/issues/82).
- Enterprise politika může nastavení organizace zakázat. Pak `PUT` vrátí HTTP 409 a apply selže se zprávou o enterprise politice. Modul enterprise politiku nemění.
- Zápis i čtení provádí skript `scripts/ActionsPolicy.psm1`. Oba `PUT` vrací `204` bez těla, proto modul nepoužívá provider `restapi`. Každý zápis je idempotentní `PUT` jen se spravovanými poli. Skript nejdřív přečte stav a zapíše jen rozdíl. Po zápisu stav znovu přečte a selže, když neodpovídá politice.
- Data source `external.actions_policy_state` čte `GET /orgs/{org}/actions/permissions` a `GET /orgs/{org}/actions/permissions/workflow` při každém planu a po apply. Chybějící pole, jiný typ nebo jiná velikost písmen je porušení, ne shoda. Drift zastaví plan; oprava je ruční obnova nebo apply s `-replace=terraform_data.actions_policy_settings["<org>"]`.
- Identitní prostředek `terraform_data.actions_policy` při destroy obnoví výchozí hodnoty GitHubu z tabulky. Obsahový prostředek `terraform_data.actions_policy_settings` politiku zapisuje; změna politiky nahradí jen jeho, takže mezi starou a novou politikou nevznikne okno s výchozími hodnotami.

### Preflight živých workflow

Runner před plan i apply čte Git objekty na pevném HEAD SHA checkoutu repozitáře instance, nikoli pracovní kopii nebo šablony v `platform/`. Kořen odvodí z umístění `instance.yaml`. Kontrola nevolá API a nepotřebuje další token ani oprávnění. Před Terraform plan a apply runner znovu ověří HEAD; po změně revize musíš běh zopakovat.

Preflight projde všechna živá `.github/workflows/*.yml` a `*.yaml`, job-level reusable workflow references a step-level `uses:`. Z lokálních odkazů rekurzivně projde dosažitelné workflow a composite akce. Navštívená množina ukončí cykly. Nedosažitelné testovací fixtures ani nepovýšené šablony nepovažuje za živé akce.

Povolí jen lokální reference `./…` v témže Git stromu a reference z odvozené Actions organization (organizace akcí) s plným 40znakovým commit SHA. Množina výjimek je prázdná. Tag, větev, krátké SHA, jiný owner, výraz nebo `docker://` kontrolu zastaví. Lokální akce musí mít právě jeden `action.yml` nebo `action.yaml`; chybějící objekt, symbolický odkaz, cesta mimo kořen, nečitelný YAML a neznámý tvar jsou chyby. YAML anchors a aliases musíš před povýšením rozbalit. Lokální JavaScript akce podporují `node20` a `node24`. Docker akce musí odkazovat na lokální Dockerfile ve stejném adresáři, uložený jako běžný soubor na daném SHA; kontrola neověřuje instrukce Dockerfile ani jeho základní image. Nepodporovaný runtime nebo externí image kontrola odmítne.

Úspěch dokazuje jen tvar referencí v Git stromu na ověřeném HEAD SHA. Netvrdí nic o původu souborů v runtime workspace (pracovním prostoru běhu). Step-level `./…` GitHub [načítá z workspace](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idstepsuses), které může změnit checkout jiného repozitáře či refu nebo krok `run`. Lokální job-level reusable workflow se naopak váže na commit volajícího workflow. Toto omezení přijal koordinátor 28. 10. 2026: preflight hlídá pořadí nasazení, runtime hranici vynucuje politika akcí na GitHubu.

Preflight nedokazuje dostupnost vzdálené akce, její obsah ani živou konfiguraci GitHubu. Modul nespravuje `sha_pinning_required`.

## Organizační rulesety

Organizační ruleset `platform-default-branch` spravuje modul [`organization-rulesets`](../organization-rulesets/README.md). Root `rulesets/` patřil do tohoto modulu do [#73](https://github.com/msucharda/devsecops-platform/issues/73). Modul `actions-catalog` ruleset vyžaduje před svým apply a tento modul závisí na `actions-catalog`. Ruleset v tomto modulu by proto vytvořil cyklus.

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
- Parametr `secret_scanning_bypass_reviewers` je povinná mapa podle loginu organizace. Každý klíč obsahuje vlastní neprázdný seznam reviewerů: `reviewer_type` (`TEAM` nebo `ROLE`) a číselné `reviewer_id` týmu nebo organizační role security týmu. IDs platí v dané organizaci; runner společný seznam nesmí kopírovat do ostatních organizací. Mapa musí obsahovat přesně stejné organizace jako `target_organizations`. Manifest tento parametr uvádí v `organizationParameters`; Terraform proces dostane jen seznam své organizace. `teams.security` v `instance.yaml` obsahuje jen e-maily, proto modul ID z této sekce neodvodí. Příklad:

  ```yaml
  modules:
    enterprise-baseline:
      parameters:
        target_organizations: [demo-a1b2c3-platform, demo-a1b2c3-actions, demo-a1b2c3-workloads]
        secret_scanning_bypass_reviewers:
          demo-a1b2c3-platform:
            - reviewer_type: TEAM
              reviewer_id: 42
          demo-a1b2c3-actions:
            - reviewer_type: TEAM
              reviewer_id: 43
          demo-a1b2c3-workloads:
            - reviewer_type: TEAM
              reviewer_id: 44
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

Teardown vrátí spravované organizační politiky na výchozí hodnoty GitHubu, včetně politiky akcí a oprávnění `GITHUB_TOKEN` (`all`, `all`, `read`, `false`), a smaže configurations a custom patterns. Destroy configuration nejdřív zruší její výchozí roli a potom ji smaže. GitHub odpojí repozitáře a ponechá jim nastavení bez vazby na configuration. Destroy patternu vyřeší jeho alerty jako `pattern deleted` (`post_delete_action: resolve_alerts`). Ruční enterprise předpoklady nemění. Případné ruční operace uvádí manifest včetně omezení odstranění. Destroy organizačních nastavení pošle `PATCH` jen se spravovanými poli a výchozími hodnotami z tabulky výše.

## Identita

- Běžný plan používá installation token s `Organization Administration: read`; apply používá `write` pro organizace instance. Stejná oprávnění dokumentace uvádí pro čtení a změny code security configurations, custom patterns, pattern configurations a politiky GitHub Actions organizace.
- Při registraci obou Apps zahrň i `metadata: read`. Manifest deklaruje `installationSelection: all`; ruční instalace musí zahrnout všechny repozitáře cílových organizací, ne `No repositories`. Plan jiný výběr odmítne.
- PR platformního týmu může spustit plan job automaticky, bez dalšího schválení security týmem. Forky, jiní autoři ani App-created PR credentials automaticky nedostanou.
- Apply nadále schvaluje platformní tým a navíc security tým.
- Před nasazením se musí na GHE.com ověřit potřebná API a oprávnění. Nepodporovaná operace není důvod přidat PAT.
- Plan a apply Apps musí být ručně nainstalované přesně do všech organizací z manifestu a na všechny jejich repozitáře. Token issuer zkontroluje všechny instalace; neočekávaná organizace nebo chybný výběr repozitářů běh zastaví.
