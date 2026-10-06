# GitHub API volá GitHub App, classic PAT jen tam, kde App nestačí

Platforma volá API GitHubu přes dvě GitHub App nainstalované na enterprise a v organizacích instance. App pro plan má jen oprávnění ke čtení, App pro apply má oprávnění k zápisu. GitHub App nepodporuje endpointy enterprise rulesetů, code security configurations, politiky akcí a streamování audit logu. Pro tyto endpointy platforma používá classic PAT s `admin:enterprise`. PAT patří dedikovanému managed uživateli s rolí enterprise owner a má expiraci 90 dní.

## Considered Options

- Jen classic PAT. Zamítnuto: PAT má oprávnění enterprise ownera i tam, kde stačí užší oprávnění GitHub App.
- Jen GitHub App a zbytek ručně. Zamítnuto: Klíčové kontroly (rulesety, code security configurations) by nebyly v kódu.
- Jedna GitHub App pro plan i apply. Zamítnuto: Plan běží pro každý PR, takže by workflow v PR mělo oprávnění k zápisu.

## Consequences

- Manifest modulu uvádí prostředky, které vyžadují PAT. Až GitHub App doplní podporu, modul PAT přestane potřebovat.
- GET politiky akcí vyžaduje `admin:enterprise`, takže plan modulu `enterprise-baseline` potřebuje PAT. PAT je jen v environmentu modulu `enterprise-baseline`. Security tým schvaluje každé spuštění v tomto environmentu, i plan.
- Conditional Access s podmínkou na IP adresu zablokuje PAT z GitHub-hosted runnerů. Servisní uživatel nesmí mít v Conditional Access podmínku na IP adresu.
- Privátní klíče GitHub App a PAT jsou environment secrets v repozitáři instance. Key Vault s privátním endpointem by vyžadoval runner v síti Azure, což je v rozporu s ADR 0011. Do Azure se workflow přihlašuje přes OIDC bez secretu.
