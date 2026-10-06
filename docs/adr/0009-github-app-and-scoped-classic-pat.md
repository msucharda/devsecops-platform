# GitHub API volá GitHub App, classic PAT jen tam, kde App nestačí

Platforma volá API GitHubu přes dvě GitHub App, které vlastní organizace platformy a které jsou nainstalované na enterprise a v organizacích instance. App pro plan má jen oprávnění ke čtení, App pro apply má oprávnění k zápisu. GitHub App nepodporuje endpointy enterprise rulesetů, code security configurations, politiky akcí a streamování audit logu. Pro tyto endpointy platforma používá classic PAT s `admin:enterprise`. PAT patří dedikovanému managed uživateli s rolí enterprise owner a má expiraci 90 dní.

## Considered Options

- Jen classic PAT. Zamítnuto: PAT má oprávnění enterprise ownera i tam, kde stačí užší oprávnění GitHub App.
- Jen GitHub App a zbytek ručně. Zamítnuto: Klíčové kontroly (rulesety, code security configurations) by nebyly v kódu.
- Jedna GitHub App pro plan i apply. Zamítnuto: Plan běží pro každý PR, takže by workflow v PR mělo oprávnění k zápisu.

## Consequences

- Manifest modulu uvádí prostředky, které vyžadují PAT. Až GitHub App doplní podporu, modul PAT přestane potřebovat.
- GET politiky akcí vyžaduje `admin:enterprise`, takže plan modulu `enterprise-baseline` potřebuje PAT. PAT je jen ve dvou environmentech modulu `enterprise-baseline`. V prvním běží plan z PR a apply a security tým schvaluje každé spuštění. Druhé slouží jen pro noční detekci driftu, povoluje jen větev `main` a schválení nevyžaduje.
- PAT vytvoří servisní uživatel, který je ruční předpoklad (ADR 0015). Modul `emu-identity` mu přiřadí roli Enterprise Owner. Rotace PAT je ruční krok každých 90 dní: člen platformního týmu se jako servisní uživatel přihlásí přes Temporary Access Pass. Workflow varuje 14 dní před expirací.
- Conditional Access s podmínkou na IP adresu zablokuje PAT z GitHub-hosted runnerů. Servisní uživatel nesmí mít v Conditional Access podmínku na IP adresu.
- Enterprise politika omezení classic PAT podle dokumentace GitHubu blokuje přístup k organizacím enterprise. Admin PAT volá jen enterprise endpointy. Přírůstek 1 ověří, jestli `enterprise-baseline` smí classic PAT omezit bez dopadu na admin PAT.
- Privátní klíče GitHub App a PAT jsou environment secrets v repozitáři instance. Key Vault s privátním endpointem by vyžadoval runner v síti Azure, což je v rozporu s ADR 0011. Do Azure se workflow přihlašuje přes OIDC bez secretu.
