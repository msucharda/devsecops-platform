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

## Servisní uživatel

Servisní uživatel pro admin PAT je ruční předpoklad (ADR 0015). Modul mu přiřadí app roli Enterprise Owner. UPN servisního uživatele je v `instance.yaml`.

## Ruční kroky

- Po prvním nasazení odebere platformní tým prvnímu enterprise ownerovi přímé přiřazení app role. Roli Enterprise Owner pak dostává jen přes skupinu platformního týmu.

## Identita

- Microsoft Graph: `Group.Create`.
- Vlastní role Entra s oprávněním `microsoft.directory/servicePrincipals/appRoleAssignedTo/update`, omezená na enterprise aplikaci GHE.
- GitHub App: přiřazení role security manager enterprise týmu v organizacích. Přírůstek 1 ověří, že GitHub dovolí přiřadit org roli enterprise týmu.
