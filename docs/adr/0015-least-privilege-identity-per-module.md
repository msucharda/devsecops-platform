# Každý modul má vlastní identity Azure a Microsoft Graph s nejmenším oprávněním

Každý modul má dvě user-assigned managed identity: jednu pro plan a jednu pro apply. Jejich federated credentials jsou vázané na environmenty modulu. Manifest modulu deklaruje potřebné role Azure a oprávnění Microsoft Graph a bootstrap podle něj identity vytvoří. Kompromitace jednoho modulu tak nedává oprávnění ostatních modulů.

Modul `emu-identity` nepoužívá `AppRoleAssignment.ReadWrite.All`, protože s ním si identita může přidělit libovolné oprávnění v tenantu. Skupiny spravuje přes `Group.Create`, takže mění jen skupiny, které vytvořila. App role v enterprise aplikaci GHE přiřazuje přes vlastní roli Entra se scope na service principal této aplikace. Role obsahuje tři akce:

- `microsoft.directory/servicePrincipals/appRoleAssignedTo/update`
- `microsoft.directory/servicePrincipals/appRoleAssignedTo/read`
- `microsoft.directory/servicePrincipals/standard/read`

## Considered Options

- Jedna dvojice identit pro všechny moduly, jako v ALZ acceleratoru. Zamítnuto: Identita pro apply by měla oprávnění Graph i roli Owner na management group.
- `AppRoleAssignment.ReadWrite.All` pro `emu-identity`. Zamítnuto: Umožňuje převzít celý tenant.

## Consequences

- Vlastní role Entra vyžaduje licenci Entra ID P1.
- První běh C1 s jedinou akcí `appRoleAssignedTo/update` skončil HTTP 403 `Authorization_RequestDenied` při přiřazení app role v aplikaci GHE i v druhé testovací aplikaci.
- Opakovaný běh C1 s oběma doplněnými read akcemi po 10 minutách propagace vrátil HTTP 201 v aplikaci GHE a HTTP 403 `Authorization_RequestDenied` v druhé testovací aplikaci. Čtení aplikace GHE i jejích přiřazení vrátilo HTTP 200; čtení druhé aplikace vrátilo HTTP 403. Oba zápisy použily tentýž app-only token a identita měla právě jednu scoped roli.
- Testovací identita měla před zápisy i po nich `0` application permissions a před zápisy `0` delegated grants. Test tedy nepotřeboval `AppRoleAssignment.ReadWrite.All`. Ověření potvrzuje kombinaci všech tří akcí; neurčuje, zda by stačila jen jedna z read akcí. Všechny dočasné prostředky obou běhů byly odstraněny.
- Toto rozhodnutí se týká managed identity pro Azure a Microsoft Graph. Sdílení GitHub App identit a výjimku ruleset planu určuje ADR 0016.
