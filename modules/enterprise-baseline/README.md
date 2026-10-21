# enterprise-baseline

Modul nastaví automatizované kontroly v organizacích instance podle ADR 0016. Název modulu zachováváme. Enterprise kontroly, které App-only automatizace nepokrývá, jsou povinné ruční předpoklady, ne Terraform prostředky modulu.

Předpoklady: `actions-catalog`. Manifest ho zatím nedeklaruje; doplní ho politika akcí ([#18](https://github.com/msucharda/devsecops-platform/issues/18)).

## Stav implementace

[#17](https://github.com/msucharda/devsecops-platform/issues/17) implementuje organizační oprávnění a ruční enterprise předpoklady. [#19](https://github.com/msucharda/devsecops-platform/issues/19) implementuje code security configuration a custom patterns. Politika akcí ([#18](https://github.com/msucharda/devsecops-platform/issues/18)) a rulesety ([#20](https://github.com/msucharda/devsecops-platform/issues/20)) zatím implementované nejsou. Ruleset root `rulesets/` je prázdný; existuje kvůli oddělenému ruleset jobu v manifestu.

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

## Organizační ruleset pro výchozí větev

Každá organizace instance má ruleset pro své repozitáře.

- Změna jen přes PR s jedním schválením. Nový commit schválení zruší.
- PR vyžaduje review od CODEOWNERS.
- Force push a smazání větve jsou zakázané.
- Výsledky code scanningu nesmí obsahovat nález úrovně high nebo vyšší.
- Bypass nemá nikdo.

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
- Apply nastaví configuration jako výchozí pro nové repozitáře (`default_for_new_repos: all`) a připojí ji ke všem repozitářům (`scope: all`). Potom čeká, dokud žádný repozitář nemá stav `attaching` nebo `updating`. Limit je 600 sekund; proměnná `CODE_SECURITY_ATTACHMENT_TIMEOUT` ho změní.
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

- Modul nepoužívá `Mastercard/restapi` ani `integrations/github`. Configuration a patterns spravují prostředky `terraform_data` s PowerShell skripty v `scripts/`. Skripty volají REST API s tokenem z `REST_API_BEARER` a pevnou hlavičkou `X-GitHub-Api-Version: 2026-03-10`.
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
- některý repozitář je připojený k jiné configuration,
- spravovaný pattern chybí, liší se, není publikovaný nebo nemá zapnutou push protection.

Oprava: operátor obnoví stav ručně, nebo spustí apply s `-replace` obsahového prostředku, který uvádí chybová zpráva.

Omezení: modul nečte seznam repozitářů organizace. Na to by potřeboval oprávnění `metadata: read`. Repozitář bez jakékoli configuration (například po ručním odpojení) proto plan nezachytí; zachytí ho až další apply s `-replace`.
## Teardown

Teardown vrátí spravované organizační politiky na výchozí hodnoty GitHubu a smaže organizační rulesety, configurations a custom patterns. Destroy configuration nejdřív zruší její výchozí roli a potom ji smaže. GitHub odpojí repozitáře a ponechá jim nastavení bez vazby na configuration. Destroy patternu vyřeší jeho alerty jako `pattern deleted` (`post_delete_action: resolve_alerts`). Ruční enterprise předpoklady nemění. Případné ruční operace uvádí manifest včetně omezení odstranění. Destroy organizačních nastavení pošle `PATCH` jen se spravovanými poli a výchozími hodnotami z tabulky výše.

## Identita

- Běžný plan používá installation token s `Organization Administration: read`; apply používá `write` pro organizace instance. Stejná oprávnění dokumentace uvádí pro čtení a změny code security configurations, custom patterns a pattern configurations.
- Seznam a detail rulesetů vyžadují `write` i pro čtení. Plan rulesetů proto běží v samostatném jobu a environmentu s vlastní App identitou. Toto oprávnění umožňuje i změny jiných organizačních nastavení; výjimku přijímáme podle ADR 0016.
- Privátní klíč ani token ruleset jobu nesmějí dostat ostatní plan joby. Stejné oddělení platí pro noční detekci driftu.
- PR platformního týmu může spustit oba plan joby automaticky, bez dalšího schválení security týmem. Forky, jiní autoři ani App-created PR credentials automaticky nedostanou.
- Apply nadále schvaluje platformní tým a navíc security tým.
- Před nasazením se musí na GHE.com ověřit potřebná API, oprávnění i úplné čtení bypass aktérů. Nepodporovaná operace není důvod přidat PAT.
