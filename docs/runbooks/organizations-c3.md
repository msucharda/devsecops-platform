# C3: Organizace přes enterprise installation token (#13)

**Stav: živé ověření proběhlo 2026-10-21.** Výsledek je v sekci [Záznam výsledku](#záznam-výsledku). Tento runbook provede člověk na referenční instanci GHE.com. Lokální testy issueru nenahrazují důkaz dostupnosti API. Výsledek opakovaného běhu zapiš do tabulky na konci tohoto souboru přes PR; nezavírej tím automaticky #13.

Původní [C3 pro blokaci názvu](../reference-instance.md#c3-nové-použití-názvu-smazané-organizace-5) už proběhlo. Jeho výsledek v [ADR 0008](../adr/0008-deployment-identifier-in-retained-names.md) platí dál. Toto rozšíření ověřuje autentizaci, oprávnění, vlastníka, instalaci App a odstranění organizace.

## Hranice a předpoklady

- Použij PowerShell 7.4+ a proměnné `$api`, `$enterprise`, `$work` z [konvence relace](../reference-instance.md#konvence-relace). Zkontroluj cílový host před prvním požadavkem. Azure ani Microsoft Graph nejsou potřeba.
- Enterprise owner z platformního týmu schválí konkrétní testovací organizaci a její nevratné smazání. Security tým schválí každou testovanou sadu oprávnění. `enterprise_organization_installations: write` dovoluje instalace Apps napříč enterprise, ne jen v probe organizaci. Schválení tohoto pokusu není přijetí rizika Q7 pro produkční modul.
- Použij vyhrazené enterprise-owned Apps a klíče mimo checkout. Enterprise App má právě jednu aktivní enterprise installation a žádnou organizační instalaci. Oddělená organizační App pro kontrolu vlastníka a smazání má `members: read` a `organization_administration: write`, žádný přístup k repozitářům a instalaci jen do probe organizace.
- Apps ani klíče nesdílej s existujícími plan/apply workflow. Žádný PAT, uživatelský OAuth token ani automatické rozšíření oprávnění. Enterprise-installed Apps jsou public preview.
- Zvol nový testovací Deployment identifier (identifikátor nasazení) pro každý úspěšný pokus. Po smazání jméno znovu nepoužívej. Produkční organizace, organizaci platformy, zdrojové skupiny ani ruční enterprise předpoklady neměň.
- Vypni transcript a HTTP debug logování. Tokeny, JWT a privátní klíče neukládej do souborů, issue ani PR. Do veřejného výsledku nepatří ani skutečný enterprise slug, loginy a interní ID.

## 1. Ověření issueru bez změny organizací

Pro každou sadu oprávnění vytvoř samostatnou App, nebo změnu existující testovací App výslovně schval a znovu ověř. Nezaměňuj oddělení Apps s pouhým zúžením tokenu. Při změně App odvolej předchozí tokeny.

```powershell
$c3KeyPath = Read-Host 'Private key path outside checkout'
$c3App = @{
    appId = Read-Host 'Enterprise App ID'
    installationId = Read-Host 'Enterprise installation ID'
    enterprise = $enterprise
    permissions = @{ enterprise_organization_installations = 'read' }
    resources = @{ enterprise = $true }
}
$c3Key = Get-Content -LiteralPath $c3KeyPath -Raw
try {
    $c3Verification = .\tools\New-PlatformGitHubToken.ps1 -BootstrapApp $c3App -Phase apply `
        -PrivateKey $c3Key -ApiUrl $api -ValidateOnly -VerifyRevocation
    if (-not $c3Verification.Verified -or $c3Verification.RevocationsVerified -ne 1) {
        throw 'Enterprise issuer verification did not complete.'
    }
} finally { Remove-Variable c3Key }
```

`-Phase apply` zde označuje izolovaný ověřovací pokus, nikoli produkční plan. Issuer ověří enterprise vlastníka, App ID, přesná oprávnění App i instalace, enterprise slug a ID, installation ID a aktivní stav. Vydá token bez těla `permissions`. U kontraktu s `enterprise_organization_installations` musí aktivním tokenem úspěšně přečíst `GET /enterprises/{enterprise}/apps/installable_organizations`; při chybě token odvolá a vrátí chybu. Potom token odvolá přes `DELETE /installation/token` a musí dostat právě HTTP 401 při následném čtení enterprise endpointu. HTTP 403 ani 404 nejsou důkaz revokace. Kontrakt bez tohoto oprávnění neprokazuje aktivní čtení tímto endpointem. Issuer nic nezapíše do `GITHUB_ENV`.

GitHub pro enterprise installation nepodporuje zúžení přes `permissions` a token nemá přístup k repozitářům. Běh 2026-10-21 prokázal, že `createEnterpriseOrganization` vyžaduje `enterprise_organizations: write` a že toto oprávnění stačí. Pokud API vrátí jiný tvar vlastníka nebo instalace, zastav se a zaznamenej anonymizovaný tvar; kontrolu identity nevypínej.

## 2. Pomocné funkce pro ruční požadavky

Funkce samy nic nespouštějí. Každé vydání tokenu proveď až po úspěšném kroku 1 pro aktuální App a oprávnění. Organizační App ověř stejným issuerem s kontraktem `resources = @{ organizations = @($c3Org); repositories = @{} }` a vlastními ID a oprávněními.

```powershell
Import-Module .\tools\PlatformTools.psm1
$c3Headers = @{ Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2026-03-10' }
function ConvertTo-C3Base64Url([byte[]] $Bytes) {
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}
function New-C3Token {
    param([hashtable] $App, [string] $KeyPath, [switch] $Organization)
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $header = ConvertTo-C3Base64Url ([Text.Encoding]::UTF8.GetBytes('{"alg":"RS256","typ":"JWT"}'))
    $payload = ConvertTo-C3Base64Url ([Text.Encoding]::UTF8.GetBytes((@{
        iat = $now - 60; exp = $now + 540; iss = $App.appId
    } | ConvertTo-Json -Compress)))
    $rsa = [Security.Cryptography.RSA]::Create()
    try {
        $rsa.ImportFromPem((Get-Content -LiteralPath $KeyPath -Raw))
        $signature = $rsa.SignData([Text.Encoding]::UTF8.GetBytes("$header.$payload"),
            [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    } finally { $rsa.Dispose() }
    $jwt = ConvertTo-SecureString "$header.$payload.$(ConvertTo-C3Base64Url $signature)" -AsPlainText -Force
    try {
        $request = @{
            Uri = "$api/app/installations/$($App.installationId)/access_tokens"
            Method = 'POST'; Headers = $c3Headers; Authentication = 'Bearer'; Token = $jwt
            MaximumRedirection = 0; MaximumRetryCount = 0; TimeoutSec = 60
        }
        if ($Organization) {
            $request.Body = @{ permissions = $App.permissions } | ConvertTo-Json -Compress
            $request.ContentType = 'application/json'
        }
        $issued = Invoke-RestMethod @request
        if (-not $issued.token) { throw 'Installation token was not issued.' }
        $token = ConvertTo-SecureString $issued.token -AsPlainText -Force
        try {
            $actualPermissions = ConvertTo-Json -InputObject $issued.permissions -Depth 10 |
                ConvertFrom-Json -AsHashtable
            if ($actualPermissions -isnot [System.Collections.IDictionary]) {
                throw 'Installation token permissions were not returned as a map.'
            }
            $comparison = @{} + $actualPermissions
            if (-not $App.permissions.Contains('metadata') -and $comparison['metadata'] -ceq 'read') {
                $comparison.Remove('metadata')
            }
            if ((ConvertTo-PlatformCanonicalJson $comparison) -cne (ConvertTo-PlatformCanonicalJson $App.permissions)) {
                throw "Installation token permissions differ from the current contract. Actual permissions: $(ConvertTo-PlatformCanonicalJson $actualPermissions)"
            }
            [pscustomobject]@{ Token = $token; Permissions = $actualPermissions }
        } catch {
            $failure = $_
            try {
                $revocation = Invoke-C3Request -Path '/installation/token' -Token $token -Method DELETE
                if ($revocation.StatusCode -ne 204) {
                    throw "Token revocation returned HTTP $($revocation.StatusCode); stop and wait for expiration."
                }
            } catch {
                throw "Token permission validation failed and revocation was not confirmed; stop and wait for expiration. $($_.Exception.Message)"
            } finally { $token.Dispose() }
            throw $failure
        }
    } finally { $jwt.Dispose(); Remove-Variable issued -ErrorAction SilentlyContinue }
}
function Invoke-C3Request {
    param([string] $Path, [securestring] $Token, [string] $Method = 'GET', [object] $Body)
    $request = @{
        Uri = "$api$Path"; Method = $Method; Headers = $c3Headers
        Authentication = 'Bearer'; Token = $Token; SkipHttpErrorCheck = $true
        MaximumRedirection = 0; MaximumRetryCount = 0; TimeoutSec = 60
    }
    if ($null -ne $Body) {
        $request.Body = $Body | ConvertTo-Json -Depth 10 -Compress
        $request.ContentType = 'application/json'
    }
    Invoke-WebRequest @request
}
```

Po timeoutu mutace nic automaticky neopakuj. Nejprve ověř skutečný stav přes UI a čtecí API. HTTP 200 GraphQL není důkaz úspěchu: vždy kontroluj `errors` i `data`. HTTP 401/403/404 samo nerozliší nedostupné preview od chybějícího oprávnění.

`New-C3Token` vrací objekt `Token` (`SecureString`) a `Permissions` (skutečnou mapu oprávnění bez tokenu). Před vrácením porovná oprávnění s aktuálním kontraktem; implicitní `metadata: read` přijme stejně jako issuer. Při neshodě token odvolá a vrátí chybu. Do sanitizovaného záznamu ulož jen `Permissions`, nikdy celý návratový objekt. Při nepotvrzené revokaci se zastav a vyčkej expirace.

## 3. Nejmenší oprávnění a vytvoření organizace

Nejdřív enterprise owner přes UI zjistí GraphQL node ID enterprise. Ulož ho lokálně jako `$c3EnterpriseNodeId`. Urči existujícího enterprise člena platformního týmu jako `$c3OwnerLogin` a schválený billing email jako `$c3BillingEmail`. `adminLogins` bude explicitní; tím se nerozhoduje o produkčním zdroji ownerů (Q2).

| Pokus | Oprávnění enterprise App | Očekávání a vyhodnocení |
|---|---|---|
| A | `enterprise_organization_installations: read` | Čtení `GET /enterprises/{enterprise}/apps/installable_organizations` vrátí 200. Tvorba by měla selhat bez nové organizace. Pokud uspěje, zaznamenej porušení předpokladu read-only planu a zastav návrh produkčního planu. |
| B | `enterprise_organizations: write` | Oprávnění, které pro tvorbu vyžaduje dokumentace GitHubu. Běh 2026-10-21 tvorbu potvrdil. Ověř tvorbu se stejnými vstupy a novým názvem. |
| C | B + `enterprise_organization_installations: write` | Jen po schválení, pokud B neuspěje. Pokud uspěje, jednotlivě odeber každé oprávnění a opakuj s novými tokeny i názvy. |

Úspěšná širší sada bez negativního pokusu s odebraným oprávněním není důkaz minima. Pokud B ani C neuspějí, nepřidávej další práva pokusem naslepo; ulož důkaz a označ API/oprávnění za blokátor. Pokud UI nepovolí požadovanou sadu, zaznamenej tuto hranici místo předstíraného API pokusu.

Pro každý pokus uprav `$c3App.permissions`, proveď krok 1 a pak:

```powershell
$c3Org = "probe13-$([guid]::NewGuid().ToString('N').Substring(0, 12))-actions"
$c3Issued = New-C3Token -App $c3App -KeyPath $c3KeyPath
$c3Token = $c3Issued.Token
$c3PermissionEvidence = $c3Issued.Permissions | ConvertTo-Json -Compress
$c3CreateBody = @{
    query = @'
mutation($input: CreateEnterpriseOrganizationInput!) {
  createEnterpriseOrganization(input: $input) { organization { id login } }
}
'@
    variables = @{ input = @{
        enterpriseId = $c3EnterpriseNodeId; login = $c3Org; profileName = $c3Org
        billingEmail = $c3BillingEmail; adminLogins = @($c3OwnerLogin)
    } }
}
$c3Reply = Invoke-C3Request -Path '/graphql' -Token $c3Token -Method POST -Body $c3CreateBody
$c3Result = $c3Reply.Content | ConvertFrom-Json -AsHashtable
$c3Created = $c3Result['data']['createEnterpriseOrganization']['organization']
if ($c3Reply.StatusCode -ne 200 -or $c3Result['errors'] -or $c3Created['login'] -cne $c3Org -or -not $c3Created['id']) {
    throw 'Creation was not confirmed. Inspect errors and actual state before another attempt.'
}
```

U negativního pokusu místo pokračování zaznamenej HTTP, GraphQL error type/message bez interních hodnot a potvrď v UI, že organizace nevznikla. U úspěchu ulož node ID jen do lokálního inventáře. `billingEmail` je ve schématu povinný: pokus bez něj skončil 2026-10-21 GraphQL validační chybou proměnné a organizace nevznikla. Pokus bez `billingEmail` opakuj jen se schválením a novým názvem.

## 4. Instalace organizační App a vlastník

S tokenem App, která má schválené `enterprise_organization_installations: write`, zavolej:

```powershell
$c3InstallReply = Invoke-C3Request -Path "/enterprises/$enterprise/apps/organizations/$c3Org/installations" `
    -Token $c3Token -Method POST -Body @{ client_id = $c3OrganizationAppClientId; repository_selection = 'none' }
if ($c3InstallReply.StatusCode -notin @(200, 201)) { throw 'Organization App installation was not confirmed.' }
```

Pokud sada pro tvorbu toto oprávnění nemá, použij samostatnou schválenou enterprise App nebo App nainstaluj ručně přes UI. Úspěch ruční instalace není důkaz podpory enterprise instalačního API. Před API pokusem znovu proveď krok 1 pro použitou App. Nepřidávej organizační instalaci do enterprise-only App; tento PR takovou kombinaci úmyslně odmítá.

Odpověď na požadavek s `repository_selection: none` může obsahovat `repository_selection: "selected"`; běh 2026-10-21 vrátil HTTP 201 a `selected`. Hodnotu proto nevyhodnocuj podle názvu. Prázdný přístup k repozitářům ověř přes `GET /installation/repositories` tokenem organizační App (`total_count: 0`).

Z odpovědi instalace zjisti installation ID organizační App. Vytvoř `$c3OrganizationApp` s jejími `appId`, `installationId`, `enterprise`, přesnými `permissions` a `resources` podle kroku 2. Ověř kontrakt issuerem. Potom vydej `$c3OrgIssued = New-C3Token -App $c3OrganizationApp -KeyPath $c3OrganizationKeyPath -Organization` a přiřaď `$c3OrgToken = $c3OrgIssued.Token`. Do sanitizovaného záznamu zahrň i `$c3OrgIssued.Permissions`, ne celý objekt.

Přes `GET /orgs/{org}/memberships/{login}` s `$c3OrgToken` musí mít explicitní `$c3OwnerLogin` `state: active` a `role: admin`. Potvrď stav také přihlášením tohoto vlastníka do UI. Existující enterprise člen se má přidat přímo; pozvánka se nesmí vykázat jako aktivní vlastnictví. Přes `GET /orgs/{org}/members?role=admin` projdi všechny stránky a zaznamenej všechny skutečné ownery v soukromém inventáři. Ve veřejném výsledku uveď jen počet a zda všichni patří do platformního týmu.

Variantu bez `adminLogins` nespouštěj jako výchozí test. Vyžaduje samostatný souhlas a předem ověřenou cestu obnovy přes enterprise ownera. Pokud ji člověk neprovede, zapiš „bez adminLogins neověřeno“. Není to rozhodnutí Q2.

## 5. Smazání, revokace a úklid

Před smazáním porovnej `$c3Org` a `$c3Created.id` s lokálním inventářem a s živým `GET /orgs/{org}` (`node_id`). Organizace musí být prázdná a musí jít o právě vytvořený probe. Člověk znovu potvrdí přesné jméno a nevratné smazání. Token organizační App ponech aktivní až do dokončení DELETE; App předem neodinstaluj.

```powershell
if ($c3Org -cnotmatch '^probe13-[a-f0-9]{12}-actions$') { throw 'Not an allowed C3 probe name.' }
$c3Confirmation = Read-Host 'Type the exact probe organization name to approve permanent deletion'
if ($c3Confirmation -cne $c3Org) { throw 'Deletion was not approved.' }
$c3DeleteReply = Invoke-C3Request -Path "/orgs/$c3Org" -Token $c3OrgToken -Method DELETE
if ($c3DeleteReply.StatusCode -notin @(202, 204)) { throw 'Deletion was not accepted; inspect actual state before retry.' }
```

GitHub smaže organizaci asynchronně: běh 2026-10-21 dostal HTTP 202 s tělem `{}`, ne 204. Kód proto přijme 202 i 204. Ani jeden kód není důkaz smazání. Organizace chyběla v enterprise seznamu přibližně 20 s po DELETE.

Potvrď nepřítomnost v enterprise UI a přes enterprise seznam organizací; seznam stránkuj. Samotné HTTP 404 s původním organizačním tokenem není důkaz smazání, protože instalace mohla zaniknout. `removeEnterpriseOrganization` nepoužívej jako náhradu DELETE: nemusí organizaci smazat.

Po každém pokusu včetně chyby odvolej všechny vydané tokeny přes `DELETE /installation/token`. Očekávej 204 a následné 401 pro původní token na odpovídajícím čtecím endpointu. U organizačního tokenu po zániku instalace zaznamenej skutečný stav, i když už revokace vrátí 401. Při nejasném výsledku revokace token nepoužívej a vyčkej expirace; slepé opakování není důkaz. Vyvolej `Dispose()` na všech `SecureString` tokenech.

Pokud DELETE selže, enterprise owner odstraní pouze schválený probe přes UI a ověří výsledek. Odstraň vyhrazené testovací Apps a jejich lokální klíče až po úklidu organizací a revokaci tokenů. Neodstraňuj Apps bootstrapu ani ruční předpoklady. Zaznamenej zbylé prostředky, vlastníka úklidu a termín; nedokončený úklid znamená nedokončené ověření.

## Záznam výsledku

Výsledek smí změnit člověk až po běhu. PR s výsledkem musí oddělit doložený stav od hypotézy a obsahovat anonymizované chyby. Tabulka obsahuje sanitizovaný výsledek běhu 2026-10-21; neobsahuje enterprise slug, loginy, interní ID ani email.

| Oblast | Požadovaný důkaz | Výsledek |
|---|---|---|
| Relace | Datum UTC, operátor, commit nástrojů, API verze, GHE.com a stav preview | 2026-10-21, přibližně 18:00–18:41 UTC. Operátor: enterprise owner z platformního týmu; příkazy spouštěl koordinátor ve viditelném terminálu. Commit nástrojů `4afd252`, API verze `2026-03-10`, GHE.com, enterprise-installed Apps v public preview. Apps vznikly přes předvyplněné URL parametry registrace (`/enterprises/{enterprise}/settings/apps/new?...&enterprise_organizations=write`); UI oprávnění z URL přijalo. Testovací Apps: 3 enterprise-owned Apps (A, B, I), každá s jednou enterprise instalací, a 1 organizační App (O) s `members: read` a `organization_administration: write`, bez repozitářů a před testem bez instalace. |
| Issuer | Přesná oprávnění a scope, vlastník App, Enterprise target, vydání bez permissions, revokace 204 → 401 | Prošlo. `New-PlatformGitHubToken.ps1 -ValidateOnly -VerifyRevocation` ověřil pro A, B a I enterprise vlastníka, přesná oprávnění App i instalace, cíl Enterprise, vydání bez `permissions` a revokaci 204 → 401. Pro O prošel issuer s `resources = @{ organizations = @(<probe>); repositories = @{} }` včetně čtení `actions/permissions` a endpointů `code-security`. |
| Minimum pro tvorbu | Deklarovaná i skutečně vrácená mapa oprávnění každého tokenu (`Permissions`), HTTP, GraphQL errors/data, negativní pokus bez každého požadovaného práva | Minimum je `enterprise_organizations: write`; toto jediné oprávnění stačí. Pokus A (`{"enterprise_organization_installations":"read"}`): HTTP 200, GraphQL error `FORBIDDEN` „Resource not accessible by integration“, `data.createEnterpriseOrganization = null`. Pokus B (`{"enterprise_organizations":"write"}`): HTTP 200 bez `errors`, vrácený `login` odpovídá, `id` je vyplněné. Pokus A je negativní důkaz bez požadovaného oprávnění. Pokus C nebyl potřeba. Manifest modulu je potvrzený. Dva dřívější běhy pokusu A selhaly na chybě pomocného skriptu operátora (chybný název GraphQL proměnné); neměly vedlejší efekt a nejsou důkazem. |
| Read-only | Pokus A, tvorba zamítnutá bez vedlejšího efektu; jiný výsledek blokuje návrh planu | Prošlo. Token s `enterprise_organization_installations: read` organizaci nevytvořil. Organizace nevznikla a enterprise seznam organizací se nezměnil. |
| Vlastník | Explicitní adminLogins, aktivní admin členství, počet ownerů, platformní tým; stav varianty bez adminLogins | Explicitní `adminLogins` s 1 členem platformního týmu. `GET /orgs/{org}/memberships/{login}`: HTTP 200, `state: active`, `role: admin`. `GET /orgs/{org}/members?role=admin` (všechny stránky): 1 owner, člen platformního týmu. Potvrzení přihlášením vlastníka do UI neproběhlo. Varianta bez `adminLogins`: neověřeno. |
| Billing email | Povinnost/volitelnost v EMU, nebo výslovně neověřeno | Povinný. Pokus B bez `billingEmail`: HTTP 200 a GraphQL validační chyba proměnné, `billingEmail` „Expected value to not be null“. Organizace nevznikla. Vytvořená organizace měla billing email uložený (`GET /orgs/{org}` tokenem organizační App). |
| Instalace App | Enterprise endpoint, 200/201, repository_selection none, organizační token bez repozitářů | Prošlo s odchylkou. `POST /enterprises/{enterprise}/apps/organizations/{org}/installations` s `client_id` a `repository_selection: none` tokenem App I: HTTP 201. Odpověď obsahovala `repository_selection: "selected"`, ne `none`. Oprávnění instalace odpovídala deklaraci. Token organizační App: `{"members":"read","organization_administration":"write"}`, `GET /installation/repositories` vrátil `total_count: 0`. |
| Odstranění | Organizační App token, DELETE 202/204, nezávislé potvrzení nepřítomnosti, nový identifikátor pro další pokus | Prošlo s odchylkou. Před smazáním se ověřil formát názvu a shoda živého `node_id` s vytvořenou organizací; člověk opsal přesný název. `DELETE /orgs/{org}` tokenem organizační App s `organization_administration: write`: HTTP 202 s tělem `{}`, ne 204. Přibližně 20 s potom organizace chyběla ve stránkovaném enterprise seznamu (GraphQL `enterprise.organizations`) a `GET /orgs/{org}` uživatelským tokenem vrátil 404. Smazání enterprise installation tokenem se netestovalo. Název probe zůstává rezervovaný; další pokus musí použít nový název. |
| Úklid | Revokace všech tokenů, odstranění probe a testovacích Apps/klíčů, případné zbytky | Dokončeno. Všechny vydané tokeny jsou odvolané (204 → 401), včetně tokenu organizační App po smazání. Vznikla 1 probe organizace a je smazaná. Názvy z pokusů A a z pokusu bez billing emailu nevznikly. Owner smazal všechny 4 testovací Apps v UI; `GET /app` s JWT vrací 404. Lokální klíče jsou smazané. Zbytky: žádné. |
Rozhodnutí Q1–Q8 jsou v [komentáři #13](https://github.com/msucharda/devsecops-platform/issues/13#issuecomment-6312972204). Modul `organizations` je implementuje podle [specifikace modulu](../../modules/organizations/README.md). Manifest deklaruje pro apply `enterprise_organizations: write`, které pro `createEnterpriseOrganization` vyžaduje [dokumentace GitHubu](https://github.com/github/docs/blob/3a444c04d005e5d91e29ee0658fd5c9bbeaecf24/content/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation.md). Běh 2026-10-21 potvrdil, že je toto oprávnění minimum. Jiný výsledek opakovaného běhu vyžaduje změnu manifestu.

## Zdroje a hranice důkazu

- [REST Apps: vydání tokenu a schéma instalací](https://docs.github.com/en/enterprise-cloud@latest/rest/apps/apps?apiVersion=2026-03-10#create-an-installation-access-token-for-an-app): enterprise token nelze zúžit parametrem permissions a nemá přístup k repozitářům.
- [Enterprise App installations](https://docs.github.com/en/enterprise-cloud@latest/rest/enterprise-admin/organization-installations?apiVersion=2026-03-10): instalace Apps do organizací enterprise a oprávnění `enterprise_organization_installations`.
- [GraphQL createEnterpriseOrganization](https://docs.github.com/en/enterprise-cloud@latest/graphql/reference/mutations#createenterpriseorganization): vstupy a chování `adminLogins`; přesné App oprávnění musí potvrdit tento běh.
- [ADR 0016](../adr/0016-github-app-installation-tokens-for-instance-workflows.md): enterprise-owned Apps, oddělené identity, read-only plan a zákaz PAT fallbacku.
