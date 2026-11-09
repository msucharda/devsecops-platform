# Instance vlastní celý enterprise a celý tenant

Jedna instance odpovídá jednomu enterprise EMU na GHE.com, jednomu tenantu Entra ID a jedné SLZ. Platforma je jediný vlastník nastavení enterprise a hierarchie SLZ. Tenant Entra ID podporuje jen jednu integraci OIDC s EMU a GitHub dokumentuje podporu Conditional Access jen pro OIDC. Dvě instance v jednom enterprise by si navíc přepisovaly nastavení.

## Consequences

- Ruční předpoklady instance jsou tenant, enterprise s nastaveným OIDC a SCIM, licence a subscriptions.
- Testovací instance potřebuje vlastní enterprise a tenant. Nesmí je sdílet s jiným prostředím.

## Organizace pro vývoj platformy ve sdíleném enterprise

Uživatel 9. 11. 2026 při řešení Q4 ve spec
[#256](https://github.com/msucharda/devsecops-platform/issues/256) schválil
umístění organizace pro vývoj platformy do stejného enterprise
jako referenční instance. Nejde o druhou instanci platformy; pravidlo
jedné instance na enterprise a tenant zůstává platné.

Organizace pro vývoj platformy zůstane mimo organizační správu a teardown reference,
ale sdílí enterprise politiky, SSO a SCIM. Uživatel toto omezení přijal;
samostatná organizace se nesmí vykazovat jako úplná izolace. Zásah
do společných nastavení vyžaduje posouzení dopadu na vývoj a ověřitelný
plán návratu. Platí to i pro oprávnění a identity, na kterých vývoj závisí.
Toto rozhodnutí nepovoluje konkrétní živý zásah.

Důvodem je zachování schváleného umístění vývoje bez požadavku
na samostatný enterprise. Platforma zůstává jediným vlastníkem
enterprise nastavení; výjimka chrání organizační prostředky vývoje,
nikoli nezávislou druhou správu enterprise.
