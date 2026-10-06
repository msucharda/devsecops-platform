# GitHub API volá GitHub App, classic PAT jen tam, kde App nestačí

Platforma volá API GitHubu přes GitHub App nainstalovanou na enterprise a v organizacích instance. GitHub App nepodporuje endpointy enterprise rulesetů, code security configurations, politiky akcí a streamování audit logu. Pro tyto endpointy platforma používá classic PAT s `admin:enterprise`. PAT patří dedikovanému managed uživateli s rolí enterprise owner a má expiraci 90 dní.

## Considered Options

- Jen classic PAT. Zamítnuto: PAT má oprávnění enterprise ownera i tam, kde stačí užší oprávnění GitHub App.
- Jen GitHub App a zbytek ručně. Zamítnuto: Klíčové kontroly (rulesety, code security configurations) by nebyly v kódu.

## Consequences

- Manifest modulu uvádí prostředky, které vyžadují PAT. Až GitHub App doplní podporu, modul PAT přestane potřebovat.
- GET politiky akcí vyžaduje `admin:enterprise`. Plan modulu `enterprise-baseline` proto potřebuje stejný PAT jako apply.
- Conditional Access s podmínkou na IP adresu zablokuje PAT z GitHub-hosted runnerů. Servisní uživatel nesmí mít v Conditional Access podmínku na IP adresu.
