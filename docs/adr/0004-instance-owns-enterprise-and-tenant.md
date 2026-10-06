# Instance vlastní celý enterprise a celý tenant

Jedna instance odpovídá jednomu enterprise EMU na GHE.com, jednomu tenantu Entra ID a jedné SLZ. Platforma je jediný vlastník nastavení enterprise a hierarchie SLZ. Tenant Entra ID podporuje jen jednu integraci OIDC s EMU a GitHub dokumentuje podporu Conditional Access jen pro OIDC. Dvě instance v jednom enterprise by si navíc přepisovaly nastavení.

## Consequences

- Ruční předpoklady instance jsou tenant, enterprise s nastaveným OIDC a SCIM, licence a subscriptions.
- Testovací instance potřebuje vlastní enterprise a tenant. Nesmí je sdílet s jiným prostředím.
