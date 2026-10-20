# Runbook C3: živé ověření enterprise App pro organizace

Runbook ověřuje public preview API v části 5.1 analýzy issue #13. Běh provede člověk na referenční enterprise. Žádný agent nesmí tento runbook spustit automaticky.

## Předpoklady

- Enterprise-owned GitHub App je už registrovaná a je instalovaná na enterprise.
- Human uživatel má oprávnění k vytvoření a smazání organizace a k instalaci App.
- Platformní tým určí jednorázové testovací jméno organizace podle ADR 0008. Jméno nesmí být stabilní.
- Human má k dispozici ochranné okolí referenčního enterprise bez workloadů nebo citlivých dat.
- App private key je dostupný jen bezpečně přidělenému runbook jobu. Nepoužívejte PAT ani OAuth token.

## Varianty oprávnění k vytvoření organizace

Začněte nejmenší bezpečnou variantou: enterprise App s oprávněním
`enterprise_organization_installations: write` a bez dalšího write oprávnění.
Pokud API odmítne vytvoření, nepotvrzujte další oprávnění automaticky.

Nezvěřejněné nebo výsledek-mapou nepřiřazené oprávnění požadujte výslovně v ruční evaluaci.
Minimální potvrzené oprávnění je zápis do:

- `enterprise_organization_installations`
- další oprávnění pouze podle explicitního a potvrzeného výsledku živého ověření

Tento zápis není potvrzení skutečnosti na GHE.com. Živý výsledek níže rozhoduje.

## Kroky

1. Zaznamenejte App ID, enterprise installation ID, enterprise slug, API hostname, API version
   `2026-03-10`, používající token typu a čas spuštění.
2. Vydáním installation tokenu ověřte exact App permissions. Ověřte `enterprise_organization_installations`
   pro enterprise installation. Oprávnění App nesmí obsahovat nevyžádané write scope mimo potvrzený experiment.
3. Zavolejte `GET /enterprises/{enterprise}/apps/installable_organizations` nebo ekvivalentní endpoint.
   Zaznamenejte HTTP status, neomezeně jen jednorázový výsledek.
4. Přejděte přes nejmenší variantu vytváření organizace:

   ```graphql
   mutation {
     createEnterpriseOrganization(
       input: {
         enterpriseId: "ENTERPRISE_NODE_ID"
         login: "TEST_ORGANIZATION_LOGIN"
         profileName: "C3 live verification"
         billingEmail: "BILLING_EMAIL"
         adminLogins: ["PLATFORM_OWNER_LOGIN"]
       }
     ) {
       organization { id login }
     }
   }
   ```

   `adminLogins` musí být explicitní seznam platformního ownera. Do `adminLogins` nepřidávejte security nebo workload týmy.
5. Zaznamenejte HTTP nebo GraphQL status, výsledek, použitá oprávnění, chybějící oprávnění a to,
   zda organizace skutečně přišla o ownera.
6. Pokud vytvoření vzniklo, ověřte organizaci a vlastníka před další akcí:

   - `GET /orgs/{org}`
   - `GET /orgs/{org}/members?role=admin&per_page=100`

   Potvrďte pouze platformního ownera jako ownera. Nepokračujte, pokud vlastníka nelze ověřit.
7. Instalujte testovanou App do nové organizace:

   ```text
   POST /enterprises/{enterprise}/apps/organizations/{org}/installations
   Content-Type: application/json

   {"client_id":"APP_CLIENT_ID","repository_selection":"none"}
   ```

   Zaznamenejte HTTP 201 nebo 200 a installation ID.
8. Vydáním installation tokenu ověřte organizační instalaci, `repository_selection: none`
   a skutečné permissions. Nevydávajte token mimo ověřený job a token odvolejte po ověření.
9. Odvolejte organizační token. Po ověření smažte organizaci pomocí
   `DELETE /orgs/{org}` s organizačním installation tokenem nebo ruční akcí dle live acceptance.
   Zaznamenejte HTTP 202/204 podle endpointu nebo srozumitelný error.
10. Ověřte, že existuje-li REST GET `/orgs/{org}`, vrací 404. Neovlivňujte jiný existující account.

## Očekávání výsledku

Výsledek runbooku musí obsahovat:

- úspěšnost či odmítnutí vytvoření,
- skutečné minimální oprávnění,
- ownera vytvořené organizace,
- skutečnou schopnost a idempotenci instalace App,
- skutečný způsob a výsledek smazání,
- stav testu enterprise installation tokenu,
- API version a čas běhu,
- App/installation ID a enterprise, nikoliv private key nebo token.

Do PR nevkládejte live výsledek jako fakt, dokud člověk runbook nedokončí.

## Bezpečnostní omezení

- Žádný PAT, OAuth user token ani admin personal credential není povolený fallback.
- Nepoužívejte `removeEnterpriseOrganization`, dokud není ověřeno, zda jen odebere organizaci z enterprise.
- V app tokenu nebudete omylem získávat write oprávnění k organizačnímu plánu.
- V plánovací fázi token nevyžaduje neexistující organizaci; apply může vydat enterprise token a
  organization tokeny jen pro skutečně existující instalace.
- Q1–Q8 nejsou rozhodnuty tímto runbookem. `enterprise_organization_installations` je pouze
  potvrzený scope pro instalaci App; exact create permission musí být doložen živě.
