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
- Vlastní role Entra s oprávněním `microsoft.directory/servicePrincipals/appRoleAssignedTo/update`, omezená na enterprise aplikaci GHE.
- GitHub API používá installation tokeny podle ADR 0016. Modul propojí týmy organizace platformy se skupinami Entra ID.
- Roli security manager přiřazuje modul `organizations`, protože organizace akcí a workloadů vzniknou až v něm. Přírůstek 1 ověří toto přiřazení přes installation token.
