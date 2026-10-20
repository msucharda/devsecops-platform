# emu-identity

Modul vytváří skupiny Entra ID platformního týmu, security týmu a uživatelů Copilotu. Každé skupině přiřadí app roli v enterprise aplikaci GHE. SCIM potom ze skupin zřídí uživatele a IdP skupiny v GHE.

Předpoklady: žádné. Modul potřebuje sekci `bootstrap` v `instance.yaml`. Runner z ní předá `tenantId` a `enterpriseApplicationObjectId` do `var.instance.entra`.

## Skupiny

| Skupina | App role v aplikaci GHE | Členství |
|---|---|---|
| `<instance>-platform-team` | Enterprise Owner | UPN v `teams.platform` |
| `<instance>-security-team` | User | UPN v `teams.security` |
| `<instance>-copilot-users` | User | Spravuje zákazník v Entra ID. Modul členy nečte ani nemění. |

- Skupiny jsou security groups. Modul jim nenastavuje vlastníky. Provider azuread nastaví apply identitu jako jediného vlastníka. Oprávnění `Group.Create` dovolí identitě měnit jen skupiny, které vlastní.
- Modul vybírá app roli podle zobrazovaného názvu a jen z povolených rolí. Pokud enterprise aplikace roli nemá, plan selže.
- Modul publikuje jen output `group_names`. Hodnoty jsou známé už při plánu.
- Skupiny týmů workloadů vytváří modul `workload-onboarding`.

## Ruční kroky

Modul nemá přístup do GitHubu. Kroky v GitHubu proto dělá platformní tým ručně. Manifest je uvádí v `manualSteps`.

| ID | Kdy | Krok |
|---|---|---|
| `remove-direct-enterprise-owner` | Po prvním apply a úspěšném SCIM cyklu | Odebrat prvnímu enterprise ownerovi přímé přiřazení app role Enterprise Owner. Roli pak dostává jen přes skupinu platformního týmu. |
| `link-organization-teams` | Po zřízení skupin platformního a security týmu přes SCIM | Propojit týmy `platform` a `security` v organizaci platformy s IdP skupinami. |
| `copilot-enterprise-team` | Po zřízení skupiny uživatelů Copilotu přes SCIM | Vytvořit enterprise tým, propojit ho s IdP skupinou a přiřadit mu licenci Copilot. |

Důvody ručních kroků:

- SCIM enterprise týmy nevytváří. Enterprise tým vzniká v UI nebo přes REST API s classic PAT. Propojení enterprise týmu s IdP skupinou je jen v UI.
- API pro licenci Copilot (`selected_enterprise_teams`) vyžaduje instalaci GitHub App na enterprise. Platforma ji pro tento modul nemá a PAT nepoužívá (ADR 0016).
- Propojení týmu organizace s IdP skupinou vyžaduje externí skupinu. Ta existuje až po SCIM cyklu. API vyžaduje oprávnění `members: write` i pro čtení.

Roli security manager přiřazuje modul `organizations` (#13) týmu `security`.

## Identita

| Fáze | Microsoft Graph | Vlastní role Entra se scope na service principal aplikace GHE |
|---|---|---|
| plan | `Group.Read.All`, `User.Read.All` | `appRoleAssignedTo/read`, `standard/read` |
| apply | `Group.Create`, `User.Read.All` | `appRoleAssignedTo/update`, `appRoleAssignedTo/read`, `standard/read` |

- Akce rolí mají prefix `microsoft.directory/servicePrincipals/`. Kombinaci akcí pro apply ověřil test C1 (#3). Samotná akce `update` nestačila.
- Identita nemá `AppRoleAssignment.ReadWrite.All`. Toto oprávnění dovolí přiřadit libovolnou app roli v celém tenantu.
- Bootstrap vytvoří vlastní role `platform-<instance>-emu-identity-<phase>` a přiřadí je jen se scope na enterprise aplikaci. Podrobnosti jsou v [ADR 0015](../../docs/adr/0015-least-privilege-identity-per-module.md) a v [popisu bootstrapu](../../docs/bootstrap.md).
- Modul nepoužívá GitHub API ani PAT.

## Testy

`terraform test` v adresáři modulu spustí testy s mock providerem. Testy ověří názvy skupin, členství, výběr povolené app role a přiřazení každé role vlastní skupině.
