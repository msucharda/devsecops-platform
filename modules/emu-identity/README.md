# emu-identity

Modul spravuje skupiny Entra ID a jejich přiřazení v enterprise aplikaci GHE. SCIM ze skupin vytvoří enterprise týmy.

Předpoklady: `bootstrap`.

## Skupiny

| Skupina | App role v aplikaci GHE | Role v GitHubu | Členství |
|---|---|---|---|
| Platformní tým | Enterprise Owner | – | UPN v `instance.yaml` |
| Security tým | User | Security manager ve všech organizacích instance | UPN v `instance.yaml` |
| Uživatelé Copilotu | User | Licence Copilot | Spravuje zákazník v Entra ID |

Skupiny týmů workloadů vytváří modul `workload-onboarding`.

## Ruční kroky

- Po prvním nasazení odebere platformní tým prvnímu enterprise ownerovi přímé přiřazení app role. Roli Enterprise Owner pak dostává jen přes skupinu platformního týmu.

## Identita

- Microsoft Graph: `Group.Create`.
- Vlastní role Entra se scope na service principal enterprise aplikace GHE. Obsahuje akce `microsoft.directory/servicePrincipals/appRoleAssignedTo/update`, `microsoft.directory/servicePrincipals/appRoleAssignedTo/read` a `microsoft.directory/servicePrincipals/standard/read`. Kombinaci pro app-only token ověřil test C1; samotná update akce nestačila. Podrobnosti jsou v [ADR 0015](../../docs/adr/0015-least-privilege-identity-per-module.md).
- GitHub API používá installation tokeny podle ADR 0016. Modul propojí týmy organizace platformy se skupinami Entra ID.
- Roli security manager přiřazuje modul `organizations`, protože organizace akcí a workloadů vzniknou až v něm. Přírůstek 1 ověří toto přiřazení přes installation token.
