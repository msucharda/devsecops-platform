# enterprise-baseline

Modul nastaví automatizované kontroly v organizacích instance podle ADR 0016. Název modulu zachováváme. Enterprise kontroly, které App-only automatizace nepokrývá, jsou povinné ruční předpoklady, ne Terraform prostředky modulu.

Předpoklady: `actions-catalog`. Manifest ho zatím nedeklaruje; doplní ho politika akcí ([#18](https://github.com/msucharda/devsecops-platform/issues/18)).

## Stav implementace

[#17](https://github.com/msucharda/devsecops-platform/issues/17) implementuje organizační oprávnění a ruční enterprise předpoklady. Politika akcí ([#18](https://github.com/msucharda/devsecops-platform/issues/18)), code security ([#19](https://github.com/msucharda/devsecops-platform/issues/19)) a rulesety ([#20](https://github.com/msucharda/devsecops-platform/issues/20)) zatím implementované nejsou. Ruleset root `rulesets/` je prázdný; existuje kvůli oddělenému ruleset jobu v manifestu.

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
- Check `enterprise_repository_management_policies` čte `members_can_change_repo_visibility` a `members_can_delete_repositories`. API organizace tato pole nenastaví; vynucuje je předpoklad `repositoryManagementPoliciesEnforced`. Nesoulad nebo chybějící pole check hlásí jako varování, ne chybu.

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

- Zapnuté: dependency graph, Dependabot alerts, Dependabot security updates, CodeQL default setup.
- Secret scanning s push protection a validity checks. Delegovaný bypass push protection schvaluje security tým.
- Configuration je v každé organizaci vynucená a výchozí pro nové repozitáře. Nejde o `enterprise_enforced` konfiguraci.

## Custom patterns

Seznam patterns je v `instance.yaml`. Výchozí seznam je prázdný.

## Teardown

Teardown vrátí spravované organizační politiky na výchozí hodnoty GitHubu a smaže organizační rulesety, configurations a custom patterns. Ruční enterprise předpoklady nemění. Případné ruční operace uvádí manifest včetně omezení odstranění. Destroy organizačních nastavení pošle `PATCH` jen se spravovanými poli a výchozími hodnotami z tabulky výše.

## Identita

- Běžný plan používá installation token s `Organization Administration: read`; apply používá `write` pro organizace instance.
- Seznam a detail rulesetů vyžadují `write` i pro čtení. Plan rulesetů proto běží v samostatném jobu a environmentu s vlastní App identitou. Toto oprávnění umožňuje i změny jiných organizačních nastavení; výjimku přijímáme podle ADR 0016.
- Privátní klíč ani token ruleset jobu nesmějí dostat ostatní plan joby. Stejné oddělení platí pro noční detekci driftu.
- PR platformního týmu může spustit oba plan joby automaticky, bez dalšího schválení security týmem. Forky, jiní autoři ani App-created PR credentials automaticky nedostanou.
- Apply nadále schvaluje platformní tým a navíc security tým.
- Před nasazením se musí na GHE.com ověřit potřebná API, oprávnění i úplné čtení bypass aktérů. Nepodporovaná operace není důvod přidat PAT.
