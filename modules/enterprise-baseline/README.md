# enterprise-baseline

Modul nastaví kontroly na úrovni enterprise. Organizace nastavují jen rozdíly, například runner groups.

Předpoklady: `actions-catalog`.

## Politiky enterprise

- Základní oprávnění k repozitářům je žádné.
- Repozitáře zakládá jen platforma. Členové nesmí zakládat repozitáře, měnit jejich viditelnost ani je mazat.
- Forky privátních a internal repozitářů jsou zakázané.
- Fine-grained PAT vyžaduje schválení. Maximální platnost PAT je 90 dní.
- Omezení classic PAT závisí na testu v přírůstku 1 (ADR 0009).

## GitHub Actions

- Povolené jsou jen akce z organizace akcí a akce, které potřebuje Dependabot. Dependabot na Actions jinak nepoběží. CodeQL default setup politika akcí neblokuje.
- Výchozí oprávnění `GITHUB_TOKEN` je jen čtení.
- GitHub Actions nesmí vytvářet ani schvalovat PR.

## Enterprise ruleset pro výchozí větev

- Změna jen přes PR s jedním schválením. Nový commit schválení zruší.
- PR vyžaduje review od CODEOWNERS.
- Force push a smazání větve jsou zakázané.
- Výsledky code scanningu nesmí obsahovat nález úrovně high nebo vyšší.
- Bypass nemá nikdo.

## Code security configuration

- Zapnuté: dependency graph, Dependabot alerts, Dependabot security updates, CodeQL default setup.
- Secret scanning s push protection a validity checks. Delegovaný bypass push protection schvaluje security tým.
- Configuration je vynucená a výchozí pro nové repozitáře.

## Custom patterns

Seznam patterns je v `instance.yaml`. Výchozí seznam je prázdný.

## Teardown

Teardown vrátí politiky na výchozí hodnoty GitHubu a smaže ruleset, configuration a custom patterns.

## Identita

Enterprise rulesety, code security configurations a politika akcí vyžadují admin PAT (ADR 0009). Ostatní nastavení používá GitHub App.
