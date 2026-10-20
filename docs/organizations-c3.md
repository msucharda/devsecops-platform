# C3: Organizace přes enterprise installation token (#13)

**Stav: NEPROVEDENO.** Tento runbook připravuje živé ověření. Lokální testy s mock API nedokazují dostupnost na GHE.com ani oprávnění potřebné pro vytvoření organizace. Živý běh provede člověk a výsledek doplní do tabulky na konci tohoto souboru nebo do ADR 0016. Issue ani labely tento postup nemění.

Původní [C3 pro blokování názvu](reference-instance.md#c3-nové-použití-názvu-smazané-organizace-5) zůstává platné. Tento postup neopakuje #5. Každý pokus o vytvoření organizace musí použít nový Deployment identifier (identifikátor nasazení) podle [ADR 0008](adr/0008-deployment-identifier-in-retained-names.md).

## Rozsah a podmínky

Ověříš enterprise installation token, minimální oprávnění pro GraphQL `createEnterpriseOrganization`, přiřazení explicitního ownera, instalaci úklidové App a smazání testovací organizace. Podle [ADR 0016](adr/0016-github-app-installation-tokens-for-instance-workflows.md) nesmíš použít PAT, uživatelský token pro zkoušené operace ani privátní klíč apply App v planu.

- Běh musí schválit enterprise owner a security tým. Schválení musí určit testovací enterprise, Apps, kandidátní oprávnění, ownery a jednorázové testovací organizace. Instalace App s `enterprise_organization_installations: write` smí zasáhnout všechny organizace enterprise; nejde o oprávnění omezené seznamem v konfiguraci. Schválení testu není přijetí Q7 pro produkční modul.
- Použij PowerShell 7.4+, důvěryhodný checkout této změny a samostatnou relaci bez transcriptu, debug logu nebo HTTP proxy zaznamenávající Authorization. Klíče ulož mimo repozitář. Do výsledku nepatří tokeny, PEM, billing email, loginy, název ani ID skutečného enterprise.
- Vyhraď existujícího člena enterprise z platformního týmu jako explicitního testovacího ownera. Nesmí jím být člen workload týmu. Ověř, že se tento člověk umí přihlásit a organizaci v případě selhání API ručně odstranit.
- Před prvním vytvořením musí být připravená úklidová App a ruční cesta k odstranění organizace. Žádná testovací organizace nesmí obsahovat repozitáře ani produkční data.
- Enterprise-installed Apps jsou public preview. Při chybě dostupnosti, neznámém tvaru odpovědi nebo nejasném výsledku mutace zastav běh. Automaticky nerozšiřuj oprávnění a neopakuj mutaci po timeoutu; nejdřív ověř skutečný stav v UI.

## Kontrakt issueru v PR 1

Module manifest může pro fázi deklarovat `resources: {enterprise: target_enterprise}`. `target_enterprise` je název parametru modulu, ne pevný slug. V konfiguraci instance mu odpovídá například:

```yaml
modules:
  example:
    parameters: {target_enterprise: example}
githubApps:
  enterprise-reader:
    appId: '101'
    installationId: '201'
    enterprise: example
    permissions: {enterprise_organization_installations: read}
    resources: {enterprise: example}
credentials:
  example:
    plan: {environment: example-plan, githubApp: enterprise-reader}
    apply: {environment: example-apply}
```

Jde o fragment kontraktu, ne o spustitelný modul `organizations`. Manifest musí deklarovat plan i apply. Jejich skutečná oprávnění se musí přesně shodovat s příslušnými Apps. Plan používá samostatnou read-only App.

Issuer ověří enterprise vlastníka App, přesná oprávnění App i instalace, jedinou aktivní instalaci s `target_type: Enterprise`, `account.slug` a přesné `installationId`. Slug v `resources.enterprise` se musí shodovat s vlastníkem App i parametrem modulu. Enterprise token nelze zúžit; issuer proto neposílá tělo s `permissions` ani repozitáři a ověří oprávnění vráceného tokenu. Workflow dostane mapu `{"enterprise":"<token>"}` přes `PLATFORM_GITHUB_TOKENS` a `TF_VAR_github_tokens`; jediný token dostane také přes `GH_TOKEN`. Závěrečné odvolání používá stávající `Remove-PlatformGitHubToken.ps1`.

PR 1 záměrně nepovoluje kombinaci enterprise a organizačních scope v jedné fázi nebo App, další instalace ani chybějící deklarované organizace. Organizační režim zachovává přesnou shodu. Výjimka `rulesetPlan` zůstává pouze organizační. Toto omezení odkládá volbu jedné či více Apps a bootstrap budoucích organizací do navazujících PR.

## 1. Připrav oddělené Apps

V UI registruj tři enterprise-owned Apps bez webhooků a bez user authorization. Klíče a ID poznamenej jen do místního neveřejného záznamu.

| App | Instalace | Počáteční oprávnění | Účel |
|---|---|---|---|
| C3 reader | pouze enterprise | `enterprise_organization_installations: read` | Read-only kontrola issueru a seznamu instalovatelných organizací. |
| C3 creator | pouze enterprise | `enterprise_organization_installations: write` | Instalace úklidové App a první kandidát pro vytvoření organizace. |
| C3 cleanup | pouze nová testovací organizace; předem jen registrace | `organization_administration: write` | Smazání organizace organizačním tokenem. |

Přesné oprávnění `createEnterpriseOrganization` není doložené mapou oprávnění. `enterprise_administration: write` je **hypotéza pro další schválený pokus**, ne požadavek ani ověřený název dostupný na konkrétní instanci. Pokud ho UI nenabízí, zapiš to a zastav eskalaci. Nedávej do Apps SCIM, členství, repozitářová ani jiná nesouvisející oprávnění.

V nastavení obou enterprise instalací ověř přijetí oprávnění. C3 cleanup zatím neinstaluj do žádné existující organizace. Zachovej její Client ID pro krok 5.

## 2. Ověř issuer a odvolání

Vyplň místní proměnné. `$enterpriseId` je GraphQL node ID z důvěryhodného UI nebo předchozího inventáře, nikoli číselné REST ID. `$ownerLogins` obsahuje jen schválené existující členy platformního týmu.

```powershell
$ErrorActionPreference = 'Stop'
$api = 'https://api.<subdomain>.ghe.com'
$enterprise = '<enterprise-slug>'
$enterpriseId = '<enterprise-node-id>'
$ownerLogins = @('<platform-owner-login>')
$billingEmail = '<approved-billing-email>'
$readerKeyPath = '<absolute-path-to-reader.pem>'
$creatorKeyPath = '<absolute-path-to-creator.pem>'
$cleanupKeyPath = '<absolute-path-to-cleanup.pem>'
$cleanupAppId = '<cleanup-app-id>'
$cleanupClientId = '<cleanup-client-id>'
$reader = @{
    appId = '<reader-app-id>'; installationId = '<reader-installation-id>'
    enterprise = $enterprise
    permissions = @{ enterprise_organization_installations = 'read' }
    resources = @{ enterprise = $enterprise }
}
$creator = @{
    appId = '<creator-app-id>'; installationId = '<creator-installation-id>'
    enterprise = $enterprise
    permissions = @{ enterprise_organization_installations = 'write' }
    resources = @{ enterprise = $enterprise }
}
.\tools\New-PlatformGitHubToken.ps1 -BootstrapApp $reader -Phase plan `
    -PrivateKey (Get-Content -LiteralPath $readerKeyPath -Raw) -ApiUrl $api -ValidateOnly -VerifyRevocation
.\tools\New-PlatformGitHubToken.ps1 -BootstrapApp $creator -Phase apply `
    -PrivateKey (Get-Content -LiteralPath $creatorKeyPath -Raw) -ApiUrl $api -ValidateOnly -VerifyRevocation
```

Očekávej `Verified: true`, jedinou správnou instalaci a `RevocationsVerified: 1` pro každou App. Issuer musí přečíst `GET /enterprises/{enterprise}/apps/installable_organizations?per_page=1`, odvolat zkušební token s HTTP 204 a týmž tokenem dostat HTTP 401. Tyto tokeny pak nelze použít pro mutaci. Výsledek nedokazuje oprávnění k vytvoření organizace.

Záporný pokus: předej kontrakt creator App s `-Phase plan`. Issuer ho musí odmítnout před voláním API jako write-capable klíč. Neřeš chybu zúžením tokenu z téže App.

## 3. Připrav pomocné funkce pro jednorázové pokusy

Funkce drží tokeny v paměti jako `SecureString`. Nevyvolávají retry a nesledují redirect. Každé volání přiřaď do proměnné; nevypisuj celou odpověď vydání tokenu.

```powershell
$c3Tokens = [Collections.Generic.List[securestring]]::new()
function Invoke-C3Api {
    param([string] $Path, [securestring] $Token, [string] $Method = 'GET', [object] $Body)
    $request = @{
        Uri = "$api$Path"; Method = $Method
        Authentication = 'Bearer'; Token = $Token
        Headers = @{ Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2026-03-10' }
        SkipHttpErrorCheck = $true; MaximumRedirection = 0; MaximumRetryCount = 0; TimeoutSec = 60
    }
    if ($null -ne $Body) {
        $request.ContentType = 'application/json'
        $request.Body = ConvertTo-Json -InputObject $Body -Depth 20 -Compress
    }
    $response = Invoke-WebRequest @request
    @{
        Status = [int] $response.StatusCode
        RequestId = $response.Headers['X-GitHub-Request-Id']
        Body = $(if ($response.Content) { ConvertFrom-Json -InputObject $response.Content -AsHashtable } else { $null })
    }
}
function New-C3Token {
    param([hashtable] $App, [string] $KeyPath)
    $encode = { param([byte[]] $Bytes) [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $header = & $encode ([Text.Encoding]::UTF8.GetBytes('{"alg":"RS256","typ":"JWT"}'))
    $payload = & $encode ([Text.Encoding]::UTF8.GetBytes(
        (ConvertTo-Json -InputObject @{ iat = $now - 60; exp = $now + 540; iss = $App.appId } -Compress)))
    $rsa = [Security.Cryptography.RSA]::Create()
    try {
        $rsa.ImportFromPem((Get-Content -LiteralPath $KeyPath -Raw))
        $signature = $rsa.SignData([Text.Encoding]::UTF8.GetBytes("$header.$payload"),
            [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    }
    finally { $rsa.Dispose() }
    $jwt = ConvertTo-SecureString "$header.$payload.$(& $encode $signature)" -AsPlainText -Force
    $body = if ($App.resources.Contains('enterprise')) { $null } else { @{ permissions = $App.permissions } }
    $reply = Invoke-C3Api -Path "/app/installations/$($App.installationId)/access_tokens" -Token $jwt -Method POST -Body $body
    if ($reply.Status -ne 201 -or -not $reply.Body.token) { throw 'Token issuance failed; stop and inspect the sanitized response.' }
    $token = ConvertTo-SecureString $reply.Body.token -AsPlainText -Force
    $c3Tokens.Add($token)
    $actual = $reply.Body.permissions
    if (-not $App.permissions.Contains('metadata') -and $actual['metadata'] -ceq 'read') { $actual.Remove('metadata') }
    $expectedPairs = @($App.permissions.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })
    $actualPairs = @($actual.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })
    if (Compare-Object $expectedPairs $actualPairs -CaseSensitive) { throw 'Issued permissions differ; revoke tokens in step 7 and stop.' }
    $token
}
```

## 4. Najdi minimální oprávnění a ověř ownera

Pro každý pokus vyber nový název `probe13-<6 náhodných znaků>-actions`, do 39 znaků. Název po smazání znovu nepoužívej. Neodvozuj ho od legacy instance a neměň její konfiguraci; tento pokus nerozhoduje Q1, Q3 ani Q8.

```powershell
$probeOrg = 'probe13-<new-deployment-id>-actions'
$createMutation = @'
mutation($input: CreateEnterpriseOrganizationInput!) {
  createEnterpriseOrganization(input: $input) {
    organization { id login }
  }
}
'@
$createInput = @{
    enterpriseId = $enterpriseId; login = $probeOrg; profileName = $probeOrg
    billingEmail = $billingEmail; adminLogins = $ownerLogins
}
$enterpriseToken = New-C3Token -App $creator -KeyPath $creatorKeyPath
$created = Invoke-C3Api -Path '/graphql' -Token $enterpriseToken -Method POST `
    -Body @{ query = $createMutation; variables = @{ input = $createInput } }
```

Úspěch znamená HTTP 200 **bez `errors`** a neprázdné `data.createEnterpriseOrganization.organization.id` se shodným `login`. HTTP 200 s GraphQL `errors` není úspěch. Zaznamenej HTTP status, GraphQL error `type` a sanitizovanou zprávu, request ID, přesná skutečná oprávnění App a tokenu. Při timeoutu nejdřív v UI zjisti, zda organizace vznikla.

Postupuj po jednom schváleném kandidátu:

1. Vyzkoušej creator App jen s `enterprise_organization_installations: write`.
2. Pokud vytvoření selže pro nedostatečné oprávnění, odvolej tokeny a vyžádej schválení konkrétního dalšího oprávnění. Pokud UI nabízí hypotézu `enterprise_administration: write`, může ji člověk po schválení přidat. Aktualizuj přesný kontrakt `$creator.permissions`, přijmi změnu instalace a zopakuj krok 2 před vydáním nového tokenu.
3. Po úspěchu odeber každé kandidátní oprávnění zvlášť a ověř, zda je pro vytvoření opravdu nutné. Pokud by odebrání `enterprise_organization_installations: write` znemožnilo úklidovou instalaci, proveď tento pokus samostatnou creator App a původní installer zachovej. Výsledek pak dokazuje minimum vytvoření, ne minimum celého lifecycle.
4. Záporný pokus proveď read-only App jen po schválení stejného testovacího rozsahu a s novým názvem. Očekávej odmítnutí vytvoření. Pokud se organizace přesto vytvoří, ihned zastav další pokusy, proveď úklid a zapiš, že read-only plan není pro tento endpoint prokázaný.

Po každém úspěchu přihlas schváleného ownera do UI: organizace musí být v očekávaném enterprise, owner musí mít aktivní roli `Owner`, nikoli čekající pozvánku. Ověř všechny explicitní `adminLogins` a absenci ownerů z workload týmů. Pokud je k dokončení nutné přijmout pozvánku, zapiš to jako ruční krok; nevydávej to za přímé přiřazení.

`adminLogins` vždy vyplň. Variantu bez ownera tento runbook z bezpečnostních důvodů nespouští. Chování bez `adminLogins`, zdroj produkčních loginů a Q2 zůstávají otevřené. Zda `billingEmail` lze v EMU vynechat, ověř jen dalším schváleným pokusem; povinný údaj z neúspěchu nehádej.

## 5. Ověř instalaci organizační App

Použij enterprise token installeru s přesným `enterprise_organization_installations: write`. Pokud jsi creator App v kroku 4 zúžil, použij zachovanou installer App a její odpovídající kontrakt.

```powershell
$installed = Invoke-C3Api -Path "/enterprises/$enterprise/apps/organizations/$probeOrg/installations" `
    -Token $enterpriseToken -Method POST -Body @{ client_id = $cleanupClientId; repository_selection = 'none' }
if ($installed.Status -notin @(200, 201) -or -not $installed.Body.id) { throw 'Cleanup App installation failed; stop.' }
$cleanup = @{
    appId = $cleanupAppId; installationId = [string] $installed.Body.id; enterprise = $enterprise
    permissions = @{ organization_administration = 'write' }
    resources = @{ organizations = @($probeOrg); repositories = @{} }
}
.\tools\New-PlatformGitHubToken.ps1 -BootstrapApp $cleanup -Phase apply `
    -PrivateKey (Get-Content -LiteralPath $cleanupKeyPath -Raw) -ApiUrl $api -ValidateOnly -VerifyRevocation
$organizationToken = New-C3Token -App $cleanup -KeyPath $cleanupKeyPath
```

Očekávej správnou organizační instalaci bez přístupu k repozitářům a úspěšnou validaci issuerem. Pokud endpoint odmítne `repository_selection: none`, zapiš chybu a nerozšiřuj scope na `all`. Úklid dokončí schválený owner ručně.

Tato dvojice testovacích Apps není rozhodnutí o produkční topologii Apps ani o instalacích downstream modulů (Q6). Issuer PR 1 záměrně odmítá jednu App instalovanou zároveň na enterprise a organizaci.

## 6. Smaž pouze testovací organizaci

Před každým DELETE musí člověk ověřit přesný login, node ID z vytvoření, enterprise, ownera a prázdný seznam repozitářů v UI. Potvrdí nevratné smazání této konkrétní organizace. Při jakémkoli nesouladu nesmí příkaz spustit. Nikdy nepoužij organizaci platformy, akce nebo workloady existující instance.

```powershell
$deleted = Invoke-C3Api -Path "/orgs/$probeOrg" -Token $organizationToken -Method DELETE
if ($deleted.Status -ne 204) { throw 'Organization deletion did not return HTTP 204; verify actual state before any retry.' }
```

Owner následně v enterprise UI ověří odstranění organizace. Enterprise installerem přečti seznam instalovatelných organizací, projdi **všechny stránky** a ověř její nepřítomnost. REST `GET /orgs/{org}` s již zneplatněným organizačním tokenem ani samotné HTTP 404 není dostatečný důkaz smazání. Token se smazáním instalace může zneplatnit.

Nepoužívej GraphQL `removeEnterpriseOrganization`: není zde ověřené, že organizaci smaže místo odpojení od enterprise. Neměň ani znovu nepoužívej smazaný název. Zaznamenej, zda DELETE skutečně podporuje organizační installation token a zda App či enterprise instalace po úklidu zůstaly zachované.

## 7. Odvolej tokeny a ukliď Apps

Po každém pokusu i při chybě projdi všechny tokeny z `$c3Tokens`:

```powershell
foreach ($token in $c3Tokens) {
    $revoked = Invoke-C3Api -Path '/installation/token' -Token $token -Method DELETE
    if ($revoked.Status -notin @(204, 401)) { throw 'Token cleanup is unconfirmed; stop and record the failure.' }
    $proof = Invoke-C3Api -Path "/enterprises/$enterprise/apps/installable_organizations?per_page=1" -Token $token
    if ($proof.Status -ne 401) { throw 'Revoked token was not rejected with HTTP 401.' }
}
$c3Tokens.Clear()
```

HTTP 401 při odvolání přijmi jen jako již neplatný token; nezapisuj ho jako potvrzené HTTP 204. Při nejasném odvolání postup neopakuj naslepo; zaznamenej neověřený úklid a použij schválenou ruční cestu odebrání testovací instalace.

Ověř odstranění **každé** úspěšně vytvořené organizace včetně neočekávaných úspěchů záporných pokusů. Pak v UI odinstaluj a smaž jen C3 Apps a zneplatni jejich klíče; odstraň jejich místní PEM soubory a zavři relaci. Zachovej existující bootstrap Apps, enterprise, organizace instance, Entra ID i SCIM. Úklid testu nenahrazuje teardown instance.

## Záznam výsledku

Dokud člověk tabulku nevyplní, stav zůstává **NEPROVEDENO**. Při částečném výsledku použij **BLOKOVÁNO**, ne „ověřeno“. Přilož jen sanitizované důkazy; skutečné identifikátory zůstanou v neveřejném záznamu operátora.

| Kontrola | Výsledek / důkaz |
|---|---|
| Datum UTC, operátor, schvalovatelé, commit | NEPROVEDENO |
| GHE.com, API verze `2026-03-10`, dostupnost public preview | NEPROVEDENO |
| Enterprise owner App; `target_type`, `account.slug`, installation ID | NEPROVEDENO |
| Reader: skutečná oprávnění, GET seznamu, issuer, HTTP 204 → 401 | NEPROVEDENO |
| Creator: skutečná oprávnění App i tokenu, jednotlivé pokusy a request ID | NEPROVEDENO |
| Nejmenší ověřená sada pro vytvoření; odebrané permission a záporné pokusy | NEPROVEDENO |
| HTTP a GraphQL výsledek `createEnterpriseOrganization` | NEPROVEDENO |
| Explicitní owners: přímé členství vs. pozvánka; bez workload ownera | NEPROVEDENO |
| Bez `adminLogins`; povinnost `billingEmail` | NEPROVEDENO; bez `adminLogins` se z bezpečnostních důvodů netestuje |
| Enterprise instalace cleanup App, scope `none`, organizační token | NEPROVEDENO |
| DELETE organizačním tokenem, HTTP 204 a nezávislé potvrzení smazání | NEPROVEDENO |
| Úklid všech organizací, tokenů, instalací, Apps a klíčů | NEPROVEDENO |
| Závěr pro PR 2: podporováno / blokováno; zbývající omezení | NEPROVEDENO |

Q1–Q8 tato změna neuzavírá. Zejména neurčuje zdroj názvů a ownerů, nové nasazení po teardownu, výjimku pro IdP čtení, roli v organizaci platformy, downstream instalace, přijetí enterprise-wide oprávnění ani legacy názvy.

## Primární zdroje

- [Enterprise instalace, public preview a podporované operace](https://docs.github.com/en/enterprise-cloud@latest/apps/using-github-apps/installing-a-github-app-on-your-enterprise).
- [Vydání tokenu; enterprise token nelze zúžit](https://docs.github.com/en/enterprise-cloud@latest/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app).
- [Instalace Apps do organizací enterprise](https://docs.github.com/en/enterprise-cloud@latest/admin/managing-github-apps-for-your-enterprise/automate-installations).
- [GraphQL `createEnterpriseOrganization`](https://docs.github.com/en/enterprise-cloud@latest/graphql/reference/enterprise-admin#mutation-createenterpriseorganization) a [mapa oprávnění Apps](https://docs.github.com/en/enterprise-cloud@latest/rest/authentication/permissions-required-for-github-apps). Dokumentace nenahrazuje živý důkaz minimálního oprávnění.
