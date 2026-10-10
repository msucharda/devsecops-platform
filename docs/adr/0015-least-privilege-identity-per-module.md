# Každý modul má vlastní identity Azure a Microsoft Graph s nejmenším oprávněním

Každý modul má dvě user-assigned managed identity: jednu pro plan a jednu pro apply. Jejich federated credentials jsou vázané na environmenty modulu. Manifest modulu deklaruje potřebné role Azure a oprávnění Microsoft Graph a bootstrap podle něj identity vytvoří. Kompromitace jednoho modulu tak nedává oprávnění ostatních modulů.

Modul `emu-identity` nepoužívá `AppRoleAssignment.ReadWrite.All`, protože s ním si identita může přidělit libovolné oprávnění v tenantu. Skupiny spravuje přes `Group.Create`, takže mění jen skupiny, které vytvořila. App role v enterprise aplikaci GHE přiřazuje přes vlastní roli Entra s oprávněním `microsoft.directory/servicePrincipals/appRoleAssignedTo/update`, omezenou na tuto aplikaci.

## Considered Options

- Jedna dvojice identit pro všechny moduly, jako v ALZ acceleratoru. Zamítnuto: Identita pro apply by měla oprávnění Graph i roli Owner na management group.
- `AppRoleAssignment.ReadWrite.All` pro `emu-identity`. Zamítnuto: Umožňuje převzít celý tenant.

## Consequences

- Vlastní role Entra vyžaduje licenci Entra ID P1.
- Přírůstek 1 ověří, že Microsoft Graph uzná vlastní roli i pro app-only token.
- Toto rozhodnutí se týká managed identity pro Azure a Microsoft Graph. Sdílení GitHub App identit a výjimku ruleset planu určuje ADR 0016.
