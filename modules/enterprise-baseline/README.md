# enterprise-baseline

Modul nastaví automatizované kontroly v organizacích instance podle ADR 0016. Název modulu zachováváme. Enterprise kontroly, které App-only automatizace nepokrývá, jsou povinné ruční předpoklady, ne Terraform prostředky modulu.

Předpoklady: `actions-catalog`.

## Ruční enterprise předpoklady

Platformní tým před bootstrapem nastaví a potvrdí:

- Repozitáře zakládá jen platforma. Členové nesmí zakládat repozitáře, měnit jejich viditelnost ani je mazat.
- Forky privátních a internal repozitářů jsou zakázané.
- EMU user namespaces nesmějí obsahovat repozitáře, které obejdou organizační kontroly.
- Fine-grained PAT vyžaduje schválení. Maximální platnost PAT je 90 dní.
- O omezení classic PAT zatím není rozhodnuto.

Teardown tyto předpoklady zachová. Jejich ruční potvrzení není důkaz automatického planu ani detekce driftu.

## Organizační oprávnění

- Základní oprávnění k repozitářům je žádné.
- Organization owners patří jen do platformního týmu.
- Workload týmy mají nejvýše repository roli `Maintain`; nemají `Admin`, organization owner ani organizační role pro změnu kontrol.
- Kontroly omezují workload týmy. Platformní tým je důvěryhodný správce; může kontroly změnit a změny mimo workflow má zachytit drift.

## GitHub Actions

- Povolené jsou jen akce z organizace akcí a akce, které potřebuje Dependabot. Dependabot na Actions jinak nepoběží. CodeQL default setup politika akcí neblokuje.
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

Teardown vrátí spravované organizační politiky na výchozí hodnoty GitHubu a smaže organizační rulesety, configurations a custom patterns. Ruční enterprise předpoklady nemění. Případné ruční operace uvádí manifest včetně omezení odstranění.

## Identita

- Běžný plan používá installation token s `Organization Administration: read`; apply používá `write` pro organizace instance.
- Seznam a detail rulesetů vyžadují `write` i pro čtení. Plan rulesetů proto běží v samostatném jobu a environmentu s vlastní App identitou. Toto oprávnění umožňuje i změny jiných organizačních nastavení; výjimku přijímáme podle ADR 0016.
- Privátní klíč ani token ruleset jobu nesmějí dostat ostatní plan joby. Stejné oddělení platí pro noční detekci driftu.
- PR platformního týmu může spustit oba plan joby automaticky, bez dalšího schválení security týmem. Forky, jiní autoři ani App-created PR credentials automaticky nedostanou.
- Apply nadále schvaluje platformní tým a navíc security tým.
- Před nasazením se musí na GHE.com ověřit potřebná API, oprávnění i úplné čtení bypass aktérů. Nepodporovaná operace není důvod přidat PAT.
