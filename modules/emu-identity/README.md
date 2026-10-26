# emu-identity

Modul vytváří skupiny Entra ID platformního týmu, security týmu a uživatelů Copilotu. Každé skupině přiřadí app roli v enterprise aplikaci GHE. SCIM potom ze skupin zřídí uživatele a IdP skupiny v GHE.

Předpoklady: žádné. Modul potřebuje sekci `bootstrap` v `instance.yaml`. Runner z ní předá `tenantId` a `enterpriseApplicationObjectId` do `var.instance.entra`.

## Skupiny

| Skupina | App role v aplikaci GHE | Členství |
|---|---|---|
| `<instance>-platform-team` | Enterprise Owner | UPN v `teams.platform` |
| `<instance>-security-team` | User | UPN v `teams.security` |
| `<instance>-copilot-users` | User | Spravuje zákazník v Entra ID. Modul členství nemění; provider je při refresh čte. |

- Skupiny jsou security groups. Atribut `owners` není deklarovaný: provider azuread 3.10.0 při vytvoření doplní apply identitu jako vlastníka. Oddělená plan identita tak nenavrhuje změnu vlastníka. Oprávnění `Group.Create` dovolí apply identitě měnit vlastní skupiny, ale nepokrývá čtení vztahu `owners`.
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
| apply | `Group.Create`, `GroupMember.Read.All`, `User.Read.All` | `appRoleAssignedTo/update`, `appRoleAssignedTo/read`, `standard/read` |

- `GroupMember.Read.All` je nejmenší společné aplikační oprávnění pro čtení `owners`, `members` a `memberOf`, které provider provádí přes Microsoft Graph beta. Dovolí číst členství a základní vlastnosti **všech skupin tenantu**, nejen skupin instance. Neumožňuje zápis do cizích skupin. Apply identita nedostává širší `Group.Read.All` ani `Group.ReadWrite.All`.
- Akce rolí mají prefix `microsoft.directory/servicePrincipals/`. Kombinaci akcí pro apply ověřil test C1 (#3). Samotná akce `update` nestačila.
- Identita nemá `AppRoleAssignment.ReadWrite.All`. Toto oprávnění dovolí přiřadit libovolnou app roli v celém tenantu.
- Bootstrap vytvoří vlastní role `platform-<instance>-emu-identity-<phase>` a přiřadí je jen se scope na enterprise aplikaci. Podrobnosti jsou v [ADR 0015](../../docs/adr/0015-least-privilege-identity-per-module.md) a v [popisu bootstrapu](../../docs/bootstrap.md).
- Modul nepoužívá GitHub API ani PAT.

### Proč apply potřebuje čtení skupin

Zdroj [provideru azuread 3.10.0](https://github.com/hashicorp/terraform-provider-azuread/blob/v3.10.0/internal/services/groups/group_resource.go#L537-L592) potvrzuje doplnění vlastníka do počátečního POST. Po vytvoření provider spustí read, který načte skupinu a samostatně [owners, members a memberOf](https://github.com/hashicorp/terraform-provider-azuread/blob/v3.10.0/internal/services/groups/group_resource.go#L1315-L1345). `memberOf` čte i bez nakonfigurovaných administrative units. `owners` nelze vypnout; také resource `azuread_group_without_members` je čte.

Microsoft Graph beta dokumentuje `GroupMember.Read.All` pro [GET owners](https://learn.microsoft.com/en-us/graph/api/group-list-owners?view=graph-rest-beta), [GET members](https://learn.microsoft.com/en-us/graph/api/group-list-members?view=graph-rest-beta), [GET memberOf](https://learn.microsoft.com/en-us/graph/api/group-list-memberof?view=graph-rest-beta) i [GET group](https://learn.microsoft.com/en-us/graph/api/group-get?view=graph-rest-beta). `owners` vyžaduje nejméně `GroupMember.Read.All`; samotné členství lze číst i s užším oprávněním, které ale nepokryje `owners`.

V #119 koordinátor nahlásil 403 při čtení vlastníků po vytvoření skupin s `Group.Create` a `User.Read.All`. Přes Graph beta pak ověřil, že skupiny apply identitu jako vlastníka mají. Prázdný seznam z [Graph v1.0 owners](https://learn.microsoft.com/en-us/graph/api/group-list-owners?view=graph-rest-1.0) není důkazem chybějícího vlastníka: dokumentace upozorňuje, že endpoint nevrací service principal vlastníky. Explicitní `owners = [caller]` proto tuto autorizační chybu neřeší. Tvrzení dokumentace provideru, že stačí `Group.Create` s doplňkovým čtením typů objektů, v tomto běhu nepokrylo owner read.

### Návrh obnovy po částečně úspěšném apply (#119)

Tento postup je návrh pro platformní tým, ne pokyn k automatickému úklidu. Stav Terraform state původního běhu není ověřený. Skupiny nesmíš mazat jen podle prázdné odpovědi v1.0.

1. Zastav souběžné deploy, drift a teardown běhy. Zálohuj aktuální state a zaznamenej jeho verzi. Použij backend kontejneru `emu-identity` dané instance, ne lokální prázdný state. Ověř přes Graph beta ID skupin, vlastníka a členy; při rozdílu proti očekávané instanci zastav obnovu.
2. Po schválené aktualizaci release a oprávnění bootstrapem ověř, že apply identita má právě `Group.Create`, `GroupMember.Read.All` a `User.Read.All`. Zachovej scoped roli aplikace GHE. Počkej na propagaci oprávnění a nové přihlášení identity.
3. Zkontroluj `terraform state list`, `terraform state show` pro `azuread_group.platform`, `azuread_group.security` a `azuread_group.copilot` a nový plan. Pokud state obsahuje správná ID a plan nepožaduje nahrazení, pokračuj apply; existující skupiny znovu nevytvářej.
4. Pokud skupina existuje, ale ve state chybí, po ověření ID ji importuj na odpovídající adresu podle [formátu provideru](https://github.com/hashicorp/terraform-provider-azuread/blob/v3.10.0/docs/resources/group.md#import). Před opakováním importu po přerušení znovu načti state. Pokud je prostředek tainted, zvaž `terraform untaint` pouze po kontrole skutečného stavu a následného planu; jinak může Terraform navrhnout smazání a vytvoření.
5. Recreate použij jen tehdy, když resume nebo import nejsou vhodné, a až po výslovném schválení smazání konkrétních skupin uživatelem. Zkontroluj app role assignments, členy a vazby SCIM. Po potvrzeném vzdáleném smazání nech refresh odstranit chybějící objekt ze state; případné `terraform state rm` použij jen pro ověřený zbylý záznam a se zálohou. Po přerušení nejdřív ověř vzdálený objekt i state, neopakuj naslepo smazání ani vytvoření.
6. Ověř dokončené app role assignments, úspěšný apply a následný plan bez změn. Release a živé ověření pro #119 provádí koordinátor; do té doby zůstávají tato kritéria otevřená.

## Testy

`terraform test` v adresáři modulu spustí testy s mock providerem. Testy ověří názvy skupin, členství, výběr povolené app role a přiřazení každé role vlastní skupině. Regrese bootstrapu ověřuje přesné sady Graph application permissions z reálného manifestu pro plan a apply. Offline testy neprokazují živou autorizaci Graph ani úspěch apply.
