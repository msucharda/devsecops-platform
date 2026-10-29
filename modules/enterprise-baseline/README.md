# enterprise-baseline

Modul nastaví automatizované kontroly v organizacích instance podle ADR 0016. Název modulu zachováváme. Enterprise kontroly, které App-only automatizace nepokrývá, jsou povinné ruční předpoklady, ne Terraform prostředky modulu.

Manifest dělí modul na časnou fázi `code-security` a pozdní hlavní root. Časná fáze vyžaduje pouze `organizations` a používá stávající plan/apply credentials modulu. Nepožaduje `liveWorkflowsPromoted` ani preflight katalogových workflow. Hlavní root stále vyžaduje `organizations` a `actions-catalog` a zachovává jejich ruční předpoklady. Graf spustí časnou fázi před `organization-rulesets`, katalog po rulesetech a hlavní root po katalogu. Teardown probíhá v opačném pořadí. Každý root má vlastní state a výstupní artifact; výstupy předpokladů pocházejí z odpovídajícího planu nebo apply stejného běhu.

Na čerstvé instanci ruleset plan před prvním apply správně odmítne chybějící vzdálenou výchozí konfiguraci. Schválený první živý krok proto samostatně aplikuje časnou fázi po `organizations`; [postup bootstrapu](../../docs/bootstrap.md#nový-živý-krok-časná-code-security-fáze-před-prvním-úplným-deploy) určuje kontrolu release, prostředí a výstupů. Celý deploy následuje až po tomto kroku.

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
- Každá organizace má v kontejneru `enterprise-baseline` vlastní state `organizations/<login>/terraform.tfstate` pro pozdní root a `organizations/<login>/terraform.code-security.tfstate` pro časnou fázi. Login je lowercase. Výstupní artifact vznikne až po úspěchu všech organizací. Obsahuje úplný seznam `organizations` a veřejné výstupy v mapě `organization_outputs`.
- Přechod z dřívějšího pozdního state, který vlastní Code Security, je výslovná výjimka z nepodporované obecné migrace RC release. Nejdřív časná fáze převezme existující konfiguraci a patterns podle názvu idempotentními skripty; nepřidává vzdálené duplikáty. Pozdní root deklaruje pro čtyři původní adresy `terraform_data.code_security_configuration`, `terraform_data.code_security_configuration_settings`, `terraform_data.custom_pattern` a `terraform_data.custom_pattern_content` bloky `removed` s `destroy = false`. Runner před zapomenutím každé staré identity ověří odpovídající identitu v časném state; starý pattern musí být stále v `customPatterns` pod původním názvem. Při chybějícím, přejmenovaném nebo nepřevzatém patternu runner odmítne pozdní plan i apply a starý state zachová. Nejprve obnov původní název v `customPatterns`, opakuj `deployment: code-security`, potom dokonči `deployment: full`. Teprve poté změň `customPatterns`; běžný destroy časného rootu odstraní původní pattern. První úspěšný pozdní apply pouze zapomene původní state; nespustí staré destroy provisionery. Pokud běh skončí mezi převzetím časnou fází a dokončením pozdního apply, zopakuj staged běh a potom úplný deploy. Žádný ruční `terraform state mv` není potřeba. Ostatní migrace RC state podporované nejsou.
- Create, update i destroy jsou `PATCH` existující organizace. Přerušený běh proto další apply bezpečně zopakuje.
- Postcondition po čtení `GET /orgs/{org}` ([dokumentace](https://docs.github.com/en/enterprise-cloud@latest/rest/orgs/orgs#get-an-organization)) vyžaduje spravované hodnoty. Chybějící pole je chyba, ne shoda. Plan tak zachytí drift spravovaných polí.
- `members_can_fork_private_repositories` řídí enterprise politika, ne modul. Create, update ani destroy toto pole neposílají. Samostatná postcondition vyžaduje přesně boolean `false` z API; `true`, `null`, chybějící pole nebo neplatná hodnota je chyba s odkazem na předpoklad `privateInternalForksDisabled`. U existujícího prostředku s nezměněnými `data` kontrola zastaví plan po refreshi. Při prvním nasazení nebo změně `data` není `api_response` během planu známá; kontrola proběhne až při apply po PATCH. Apply proto může selhat až po zápisu ostatních spravovaných polí. Teardown enterprise politiku zachová.
- Plan čte stav, ale neposílá zkušební `PATCH`. Dokumentace tohoto endpointu neuvádí dry-run; úspěšný plan proto nedokazuje, že API přijme zápis. Enterprise politika forků odmítá i zápis nezměněné hodnoty (`422`, [#147](https://github.com/msucharda/devsecops-platform/issues/147)).
- Omezení: provider `Mastercard/restapi` 3.0.0 s `ignore_server_additions` drift spravovaných polí neopraví. `Read` ponechá v state konfigurovaná data, a plan proto nenaplánuje opravný `PATCH` ([Mastercard/terraform-provider-restapi#348](https://github.com/Mastercard/terraform-provider-restapi/issues/348)). Drift proto zastaví plan i apply chybou postcondition. Operátor obnoví spravované hodnoty v organizaci ručně. Automatická oprava driftu je otevřené rozhodnutí.
- Další postcondition odmítne odpověď, ve které `members_can_change_repo_visibility` nebo `members_can_delete_repositories` má jinou hodnotu než `false`. API organizace tato pole nenastaví; vynucuje je předpoklad `repositoryManagementPoliciesEnforced`. Ruční potvrzení předpokladu nepřebije opačný důkaz z API.
- Check `enterprise_repository_management_policies` hlásí jako varování, že GitHub některé z těchto dvou polí nevrátil. Installation token je nemusí dostat; jediným důkazem pak zůstává ručně potvrzený předpoklad.

### Offline kontrakt zapisovaných polí

Soubor [`organization-patch-allowlist.json`](organization-patch-allowlist.json) obsahuje explicitní allow-list polí `PATCH /orgs/{org}` a důvod zápisu každého pole. Zachovává čtyři spravovaná pole uvedená výše. U každého uvádí omezení: enterprise musí správu delegovat organizaci. Soubor také zaznamenává pět vynechaných kandidátů enterprise policy: public creation, private forks, organization Projects, repository Projects a deploy keys.

Terraform test [`organization_patch_contract.tftest.hcl`](tests/organization_patch_contract.tftest.hcl) porovná skutečné `data`, efektivní update payload a `destroy_data` každého organizačního prostředku s allow-listem. Provider [`Mastercard/restapi` 3.0.0](https://github.com/Mastercard/terraform-provider-restapi/blob/v3.0.0/docs/resources/object.md) při update použije `update_data`, pokud je nastavené; jinak použije `data`. Neznámé pole, prázdný payload, chybějící důvod, prázdný důvod, `null` nebo jiný typ důvodu než string zastaví test. Stringové důvody musí mít i vynechaní kandidáti. Pester ověřuje dokumentovaná pole a dispozici všech devíti kandidátů z [#148](https://github.com/msucharda/devsecops-platform/issues/148). Mutační případy přidají dokumentované, ale nepovolené pole zvlášť do create, update a destroy payloadu v izolované kopii modulu; stejný Terraform test musí selhat. Existující integrační test navíc ověřuje allow-list nad každým skutečným PATCH tělem zachyceným lokálním API stubem.

Jde o offline kontrolu v Source CI, nikoli o preflight zapisovatelnosti při nasazení. Kontrola nemění payload, manifest permissions ani postconditions efektivních hodnot z #147. Neschválený nový zápis odhalí před vydáním, ale nezjistí aktuální enterprise policy. I povolené pole může při apply vrátit `422`. Varianta A z #148, read-only čtení GraphQL `ownerInfo`, zůstává otevřeným živým kritériem a vyžaduje samostatné rozhodnutí uživatele. Tato změna nepovoluje živé kroky ani obnovení kroku 6.23.

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
| | `sha_pinning_required` | `true` | `false` |
| [`PUT /orgs/{org}/actions/permissions/workflow`](https://docs.github.com/en/enterprise-cloud@latest/rest/actions/permissions#set-default-workflow-permissions-for-an-organization) | `default_workflow_permissions` | `read` | `read` |
| | `can_approve_pull_request_reviews` | `false` | `false` |

- `local_only` povolí akce z repozitářů organizace a enterprise. Vendorované akce v organizaci akcí jsou dostupné celé enterprise ([`actions-catalog`](../actions-catalog/README.md)), proto workflow organizací instance smějí volat jen je a akce enterprise. Akce z GitHub.com a Marketplace politika zablokuje.
- Omezení: `local_only` nezablokuje akce z jiných organizací enterprise. Přírůstek 1 `local_only` ponechá (rozhodnutí uživatele z 22. 10. 2026). Užší pravidlo `selected` se vzorem pro organizaci akcí a jeho živé ověření řeší [#81](https://github.com/msucharda/devsecops-platform/issues/81).
- Pořadí nasazení: úspěšný apply `actions-catalog` nedokazuje, že živá workflow v `.github/workflows` repozitáře instance už používají katalogové akce. Povýšení šablon z `platform/` je samostatný ruční krok ([vendoring](../../docs/vendoring.md#ruční-povýšení-živých-workflow-v-16)). Platformní tým musí povýšení mergnout před prvním apply tohoto modulu. Jinak politika zablokuje deploy, drift i teardown workflow, které upstream akce stále volají. Runner před plan i apply nadále vyžaduje `manualPrerequisites.liveWorkflowsPromoted: true`. Automatický preflight tuto deklaraci doplňuje, nenahrazuje ji. Obnova po chybném pořadí: organization owner v UI dočasně povolí všechny akce, povýší workflow a apply zopakuje.
- `can_approve_pull_request_reviews` řídí i vytváření PR z GitHub Actions (v UI „Allow GitHub Actions to create and approve pull requests“).
- Modul pevně nastaví `sha_pinning_required: true`, bez nového parametru. Rozhodnutí uživatele z 29. 10. 2026 v [#82](https://github.com/msucharda/devsecops-platform/issues/82) nahrazuje rozhodnutí pole nespravovat z 22. 10. 2026. Seznam `selected-actions` modul nadále nespravuje.
- GitHub [vyžaduje plný commit SHA pro vzdálené akce](https://docs.github.com/en/organizations/managing-organization-settings/disabling-or-limiting-github-actions-for-your-organization#managing-github-actions-permissions-for-your-organization), včetně akcí enterprise. Reusable workflow mohou podle GitHubu dál používat tag; preflight modulu je záměrně přísnější a pro vzdálené reference vyžaduje SHA. Lokální `./…` reference nemají `@SHA`: [step-level akce používá workspace](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idstepsuses), job-level reusable workflow používá commit volajícího workflow. Plan a apply na referenční instanci, včetně ověření lokálních referencí při zapnuté politice, zůstávají živými kritérii #82.
- Enterprise politika může nastavení organizace zakázat. Pak `PUT` vrátí HTTP 409 a apply selže se zprávou o enterprise politice. Modul enterprise politiku nemění.
- Zápis i čtení provádí skript `scripts/ActionsPolicy.psm1`. Oba `PUT` vrací `204` bez těla, proto modul nepoužívá provider `restapi`. Každý zápis je idempotentní `PUT` jen se spravovanými poli. Skript nejdřív přečte stav a zapíše jen rozdíl. Po zápisu stav znovu přečte a selže, když neodpovídá politice.
- Data source `external.actions_policy_state` čte `GET /orgs/{org}/actions/permissions` a `GET /orgs/{org}/actions/permissions/workflow` při každém planu a po apply. Chybějící pole, jiný typ nebo jiná velikost písmen je porušení, ne shoda. Drift zastaví plan; oprava je ruční obnova nebo apply s `-replace=terraform_data.actions_policy_settings["<org>"]`.
- Identitní prostředek `terraform_data.actions_policy` při destroy obnoví výchozí hodnoty GitHubu z tabulky. Obsahový prostředek `terraform_data.actions_policy_settings` politiku zapisuje; změna politiky nahradí jen jeho, takže mezi starou a novou politikou nevznikne okno s výchozími hodnotami.
- Reset nastaví `sha_pinning_required: false`, protože obnovuje výchozí politiku GitHubu, nikoli původní stav organizace. Starší Terraform state pole neobsahuje; pouze `ResetPolicy` tento uložený vstup doplní o `false`. Přímý destroy ani opakování přerušeného destroy proto nevyžaduje předchozí apply nové verze. `SetPolicy` a kontrola readbacku chybějící pole dál odmítají.

### Preflight živých workflow

Runner před plan i apply čte Git objekty na pevném HEAD SHA checkoutu repozitáře instance, nikoli pracovní kopii nebo šablony v `platform/`. Kořen odvodí z umístění `instance.yaml`. Kontrola nevolá API a nepotřebuje další token ani oprávnění. Před Terraform plan a apply runner znovu ověří HEAD; po změně revize musíš běh zopakovat.

Preflight projde všechna živá `.github/workflows/*.yml` a `*.yaml`, job-level reusable workflow references a step-level `uses:`. Z lokálních odkazů rekurzivně projde dosažitelné workflow a composite akce. Navštívená množina ukončí cykly. Nedosažitelné testovací fixtures ani nepovýšené šablony nepovažuje za živé akce.

Povolí jen lokální reference `./…` v témže Git stromu a reference z odvozené Actions organization (organizace akcí) s plným 40znakovým commit SHA. Množina výjimek je prázdná. Tag, větev, krátké SHA, jiný owner, výraz nebo `docker://` kontrolu zastaví. Lokální akce musí mít právě jeden `action.yml` nebo `action.yaml`; chybějící objekt, symbolický odkaz, cesta mimo kořen, nečitelný YAML a neznámý tvar jsou chyby. YAML anchors a aliases musíš před povýšením rozbalit. Lokální JavaScript akce podporují `node20` a `node24`. Docker akce musí odkazovat na lokální Dockerfile ve stejném adresáři, uložený jako běžný soubor na daném SHA; kontrola neověřuje instrukce Dockerfile ani jeho základní image. Nepodporovaný runtime nebo externí image kontrola odmítne.

Úspěch dokazuje jen tvar referencí v Git stromu na ověřeném HEAD SHA. Netvrdí nic o původu souborů v runtime workspace (pracovním prostoru běhu). Step-level `./…` GitHub [načítá z workspace](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idstepsuses), které může změnit checkout jiného repozitáře či refu nebo krok `run`. Lokální job-level reusable workflow se naopak váže na commit volajícího workflow. Toto omezení přijal koordinátor 28. 10. 2026: preflight hlídá pořadí nasazení, runtime hranici vynucuje politika akcí na GitHubu.

Preflight nedokazuje dostupnost vzdálené akce, její obsah ani živou konfiguraci GitHubu. Nastavení `sha_pinning_required` modul ověřuje samostatným čtením API.

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

- Code security configuration a patterns spravuje samostatný Terraform root `code-security/`; nepoužívají `Mastercard/restapi` ani `integrations/github`. Prostředky `terraform_data` volají původní PowerShell skripty v `scripts/` s tokenem z `REST_API_BEARER` a pevnou hlavičkou `X-GitHub-Api-Version: 2026-03-10`.
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
