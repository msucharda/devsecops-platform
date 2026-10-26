# Každý modul má vlastní identity Azure a Microsoft Graph s nejmenším oprávněním

Každý modul má dvě user-assigned managed identity: jednu pro plan a jednu pro apply. Jejich federated credentials jsou vázané na environmenty modulu. Manifest modulu deklaruje potřebné role Azure a oprávnění Microsoft Graph a bootstrap podle něj identity vytvoří. Kompromitace jednoho modulu tak nedává oprávnění ostatních modulů.

Modul `emu-identity` nepoužívá `AppRoleAssignment.ReadWrite.All`, protože s ním si identita může přidělit libovolné oprávnění v tenantu. Skupiny spravuje přes `Group.Create`, takže mění jen skupiny, které vytvořila. App role v enterprise aplikaci GHE přiřazuje přes vlastní roli Entra se scope na service principal této aplikace. Role obsahuje tři akce:

- `microsoft.directory/servicePrincipals/appRoleAssignedTo/update`
- `microsoft.directory/servicePrincipals/appRoleAssignedTo/read`
- `microsoft.directory/servicePrincipals/standard/read`

Identita apply má navíc `User.Read.All` pro vyhledání členů podle UPN a `GroupMember.Read.All` pro čtení vlastníků a členství. Identita planu má `Group.Read.All`, `User.Read.All` a vlastní roli jen s oběma read akcemi. Bootstrap vytvoří obě vlastní role a přiřadí je se scope na service principal aplikace GHE.

Rozhodnutí D-119-1 z 24. 10. 2026 přidává apply identitě `GroupMember.Read.All`, nikoli `Group.Read.All`. Provider azuread 3.10.0 po vytvoření i při refresh čte `owners`, `members` a `memberOf` přes Graph beta. `Group.Create` s vlastnictvím skupiny nepokrylo v běhu #119 čtení `owners`; skupiny podle následného beta ověření koordinátora vlastníka měly. Microsoft Learn uvádí `GroupMember.Read.All` jako nejmenší oprávnění pro [owners](https://learn.microsoft.com/en-us/graph/api/group-list-owners?view=graph-rest-beta) a podporuje je i pro [members](https://learn.microsoft.com/en-us/graph/api/group-list-members?view=graph-rest-beta) a [memberOf](https://learn.microsoft.com/en-us/graph/api/group-list-memberof?view=graph-rest-beta). Jde o nejmenší společné oprávnění pro tyto vztahy, ne o rozšíření zápisu do cizích skupin.

## Considered Options

- Jedna dvojice identit pro všechny moduly, jako v ALZ acceleratoru. Zamítnuto: Identita pro apply by měla oprávnění Graph i roli Owner na management group.
- `AppRoleAssignment.ReadWrite.All` pro `emu-identity`. Zamítnuto: Umožňuje převzít celý tenant.
- `Group.Read.All` pro apply identitu. Zamítnuto v D-119-1: Je širší než potřebné čtení vlastníků a členství. Pouhé explicitní `owners` ani `azuread_group_without_members` neodstraní owner read provideru.

## Consequences

- Vlastní role Entra vyžaduje licenci Entra ID P1.
- `GroupMember.Read.All` zpřístupňuje členství a základní vlastnosti všech skupin tenantu, nejen vlastních skupin instance. Graph toto oprávnění neomezuje na konkrétní skupiny. Rozsah je podle D-119-1 přijatý; úspěšný apply a následný plan bez změn se musí ověřit živě.
- První běh C1 s jedinou akcí `appRoleAssignedTo/update` skončil HTTP 403 `Authorization_RequestDenied` při přiřazení app role v aplikaci GHE i v druhé testovací aplikaci.
- Opakovaný běh C1 s oběma doplněnými read akcemi po 10 minutách propagace vrátil HTTP 201 v aplikaci GHE a HTTP 403 `Authorization_RequestDenied` v druhé testovací aplikaci. Čtení aplikace GHE i jejích přiřazení vrátilo HTTP 200; čtení druhé aplikace vrátilo HTTP 403. Oba zápisy použily tentýž app-only token a identita měla právě jednu scoped roli.
- Testovací identita měla před zápisy i po nich `0` application permissions a před zápisy `0` delegated grants. Test tedy nepotřeboval `AppRoleAssignment.ReadWrite.All`. Ověření potvrzuje kombinaci všech tří akcí; neurčuje, zda by stačila jen jedna z read akcí. Všechny dočasné prostředky obou běhů byly odstraněny.
- Toto rozhodnutí se týká managed identity pro Azure a Microsoft Graph. Sdílení GitHub App identit a výjimku ruleset planu určuje ADR 0016.
