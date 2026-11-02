# Token broker

Stav: přijato. Rozhodnutí D1–D13 schválil uživatel při grillingu 2. 11. 2026 v [#184](https://github.com/msucharda/devsecops-platform/issues/184). Zápis sleduje [#185](https://github.com/msucharda/devsecops-platform/issues/185).

Toto ADR částečně nahrazuje [ADR 0016](0016-github-app-installation-tokens-for-instance-workflows.md). Mění uložení klíčů, vydávání tokenů, oddělení App podle modulu a fáze a autorizaci volajícího podle D3. Pravidla ADR 0016, která toto rozhodnutí nemění, zůstávají v platnosti. [ADR 0011](0011-platform-workflows-on-github-hosted-runners.md) se nemění.

## Kontext

ADR 0016 sjednocuje autentizaci workflow instance na GitHub App installation tokeny (instalační tokeny GitHub App). Privátní klíč v environment secret ale runneru umožňuje vydávat další tokeny dané App. Cílem přírůstku 2 je ponechat privátní klíče a App JWT mimo runner a vydat jobu jen installation tokeny v jeho povoleném rozsahu.

Klíče budou v Azure Key Vault Premium jako neexportovatelné HSM klíče. Broker v Azure Container Apps express ověří OIDC token jobu. Návrh nahrazuje zavřený [#41](https://github.com/msucharda/devsecops-platform/issues/41), mění stories 13 a 31 v [#1](https://github.com/msucharda/devsecops-platform/issues/1) a nemění přírůstek 1 ani jeho akceptaci [#23](https://github.com/msucharda/devsecops-platform/issues/23).

## Rozhodnutí

### D1 Bezpečnostní hranice

Klíč ani App JWT nikdy nesmějí na runner. Kompromitovaný runner smí získat nejvýš installation token, který by jeho job dostal legitimně: stejná App, instalace, permissions a scope, platnost ≤ 1 h. Tokeny jiných modulů a fází nesmí dostat. Zneužití platného workflow řeší branch protection a environment approvals, ne broker.

### D2 Typy instalací

Broker musí podporovat organizační i enterprise instalace. Enterprise token nejde zúžit. Šíři omezuje návrh App: jedna App na modul a fázi. Broker musí ověřit přesnou shodu oprávnění App s deklarací.

### D3 Identita volajícího

Broker musí ověřit přesnou shodu `repository_id`, `repository_owner_id`, `environment`, `workflow_ref` na `refs/heads/main` pro povolený soubor workflow a `event_name` z povoleného seznamu. Audience musí být URL brokeru. Broker musí ověřit podpis přes JWKS pevně nastaveného issueru GHE.com, `exp`, `nbf` a stáří `iat`.

### D4 Autorizační mapa

Deklarativní mapa se musí generovat z `instance.yaml` a nasazovat do brokeru Terraformem jako neměnná konfigurace revize. Změna vyžaduje PR a deploy brokeru. Broker za běhu nesmí číst konfiguraci z GitHubu.

### D5 Kontrakt API

Broker musí poskytovat `POST /v1/tokens` s OIDC tokenem v hlavičce `Authorization`, bez těla požadavku. Modul a fázi musí odvodit z claims a mapy. Musí provést dnešní kontroly: vlastník App, přesná oprávnění, inventář instalací a kontrola repozitářů po vydání s revokací.

Odpověď má tvar `{ tokens: { <organizace|enterprise>: { token, expires_at, installation_id, permissions } } }`. Klient musí exportovat stejné proměnné jako dnes: `PLATFORM_GITHUB_TOKENS`, `TF_VAR_github_tokens` a `GH_TOKEN`. Tokeny musí revokovat dnešním `Remove-PlatformGitHubToken.ps1`.

### D6 Replay a ztracená odpověď

Broker nebude mít trvalé úložiště. Musí auditovat intent před POST a výsledek po něm, bez tokenu. OIDC token smí být nejvýš 5 min starý. Cache `jti` bude v paměti a poskytne jen best-effort ochranu.

### D7 Runtime

Broker bude používat C# / .NET 10 LTS, ASP.NET Core minimal API a chiseled image. Pro ověření identity použije `Microsoft.IdentityModel`, pro podpis RS256 `Azure.Security.KeyVault.Keys` (`CryptographyClient.Sign`) a pro user-assigned managed identity `Azure.Identity`. Testy xUnit poběží v CI vedle Pesteru.

### D8 Síť

Key Vault musí být dostupný jen přes private endpoint. Veřejný přístup musí být vypnutý, bez výjimky pro trusted services. Broker ho musí volat přes VNet. Broker bude mít veřejný HTTPS ingress chráněný OIDC. Standardní runnery zůstávají.

### D9 Nasazení v Azure

Nasazení zajistí modul `modules/token-broker` s providery azurerm a azapi, regionem `swedencentral` a vlastní resource group v subscription Terraform state. Samostatné workflow v repozitáři instance použije Azure OIDC a pořadí plan, schválení přes environment, apply. Custom role smí mít jen `sign` na každý klíč. Subscription musí uživatel potvrdit před prvním plánem.

### D10 Výpadek brokeru

Klient nesmí použít tichý fallback. Musí mít omezený retry s backoffem; po vyčerpání pokusů musí job selhat se srozumitelnou chybou. Migrované workflow nesmí používat `PLATFORM_APP_PRIVATE_KEY`.

### D11 Zařazení

Token broker tvoří nový přírůstek 2. Toto nové ADR částečně nahrazuje ADR 0016.

### D12 První řez

První řez zahrnuje broker, Terraform modul, klienta a drift reporter. Další workflow přejdou v dalších sub-issues.

### D13 Audit

Log Analytics workspace bude v resource group brokeru. Audit musí zahrnovat AuditEvent Key Vaultu a strukturované logy brokeru s poli `run_id`, `run_attempt`, `repository`, `workflow_ref`, `environment`, `jti`, `installation_id`, výsledkem a důvodem zamítnutí. Nikdy nesmí obsahovat token, OIDC JWT ani App JWT.

## Důsledky

- Runner dostane jen installation token pro povolenou App, instalaci, oprávnění a scope. Privátní klíč a App JWT zůstanou mimo runner; broker nenahrazuje branch protection ani environment approvals.
- Autorizační změna vyžaduje novou revizi brokeru. Kompatibilita klientských proměnných a revokačního nástroje podle D5 zůstává zachovaná.
- Vydání tokenu závisí na dostupnosti brokeru a Key Vaultu. Výpadek po omezeném retry zastaví job, nikoli přepne autentizaci.
- Cache `jti` bez trvalého úložiště nezaručuje trvalou ochranu před replay. Audit intentu a výsledku neuchovává vydaný token; trvalý ledger zůstává odložený.
- Přechod workflow proběhne postupně podle D12. Tento zápis ADR sám nemigruje klíče ani workflow a nedokazuje dostupnost na referenční instanci.
- Pevný region `swedencentral` podle D9 je při jiném `regions.primary` v rozporu s definicí Primary region (primární region) v [glosáři](../../CONTEXT.md#platforma) a s [pravidly regionů](../../README.md#regiony): všechny moduly a management mají být v primárním regionu a SLZ má povolit primární a případně sekundární lokaci. **Otevřená otázka před nasazením v [#191](https://github.com/msucharda/devsecops-platform/issues/191):** jak sladit pevný region brokeru s primárním regionem instance a povolenými lokacemi SLZ? Uživatel musí před nasazením vyjasnit regionální politiku a případnou výjimku. D9 se tímto zápisem nemění.

## Ověřené podklady

Ověřeno proti veřejné dokumentaci 2. 11. 2026, bez živého PoC. Zdroje dokazují dokumentovaný kontrakt, nikoli funkčnost nasazení na konkrétní instanci.

| Podklad | Primární zdroj |
|---|---|
| Key Vault podporuje import PEM a ochranu `hsm`; RSA-HSM podporuje podpis RS256. | [Import klíče](https://learn.microsoft.com/en-us/cli/azure/keyvault/key?view=azure-cli-latest#az-keyvault-key-import), [typy a operace klíčů](https://learn.microsoft.com/en-us/azure/key-vault/keys/about-keys-details) a [HSM klíče v Premium](https://learn.microsoft.com/en-us/azure/key-vault/keys/hsm-protected-keys-byok). |
| Azure RBAC dovoluje vlastní role a scope jednotlivého klíče. Data action pro podpis je `Microsoft.KeyVault/vaults/keys/sign/action`. | [RBAC Key Vaultu](https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-guide) a [seznam oprávnění](https://learn.microsoft.com/en-us/azure/role-based-access-control/permissions/security#microsoftkeyvault). |
| Release policy souvisí s exportem klíče; broker ji nesmí používat pro neexportovatelné klíče. | [Import klíče: `--exportable` a `--policy`](https://learn.microsoft.com/en-us/cli/azure/keyvault/key?view=azure-cli-latest#az-keyvault-key-import) a [operace Release](https://learn.microsoft.com/en-us/azure/key-vault/keys/about-keys-details#key-operations). |
| Container Apps express podporuje environment private endpoint, outbound přes VNet, user-assigned managed identity a Log Analytics. Nepodporuje Easy Auth, klientské certifikáty ani zónovou redundanci. | [Přehled express a podporované funkce](https://learn.microsoft.com/en-us/azure/container-apps/express-overview#supported-features) a [FAQ sítí](https://learn.microsoft.com/en-us/azure/container-apps/express-faq#can-i-use-private-virtual-network-inbound-or-outbound-networking-with-express). |
| ARM API `Microsoft.App/managedEnvironments@2026-07-01` obsahuje `environmentMode=Express`; reference uvádí i zápis přes Terraform AzAPI. | [Schéma managedEnvironments, API `2026-07-01`](https://learn.microsoft.com/en-us/azure/templates/microsoft.app/2026-07-01/managedenvironments). |
| Enterprise installation token nejde zúžit a installation token expiruje po 1 h. | [Vydání installation tokenu](https://docs.github.com/en/enterprise-cloud@latest/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app). |
| `job_workflow_ref` a `job_workflow_sha` jsou claims pro joby používající reusable workflow. | [Reference OIDC claims](https://docs.github.com/en/actions/reference/security/oidc#custom-claims-provided-by-github). |

## Neověřeno a rozpory podkladů

- **Neověřeno:** `workflow_ref` a `event_name` u `pull_request` (`refs/pull/N/merge`) vůči D3. Ověření při implementaci nesmí tiše rozšířit povolené refs nebo events.
- **Neověřeno:** `workflow_ref` a `event_name` u `pull_request_target`, který spouští PR plan ve [workflow nasazení](../../templates/instance/.github/workflows/deploy.yml). Při implementaci je nutné ověřit claims, rozlišení base a head ref při plánu nad head SHA PR a soulad s povoleným seznamem events podle D3. D3 se tímto zápisem nemění; ověření nesmí tiše rozšířit povolené refs nebo events.
- **Neověřeno:** GA status Container Apps express, image podle digestu a `minReplicas`. Tyto body z #184 zůstávají k ověření při implementaci.
- **Rozpor dokumentace s podkladem #184:** výzkum v #184 uvádí repliky 0–1. [Aktuální přehled](https://learn.microsoft.com/en-us/azure/container-apps/express-overview#supported-features) uvádí podporu více replik; [FAQ](https://learn.microsoft.com/en-us/azure/container-apps/express-faq#how-do-i-create-an-express-app) současně ukazuje příklad s `min-replicas 0` a `max-replicas 1`. Limit 0–1 proto není ověřený fakt. Rozpor zůstává k ověření při implementaci a nemění D1–D13.
- **Nahlášeno výzkumem v #184, zde neověřeno:** express umí z Terraform providerů jen azapi. Výše uvedené ARM schéma potvrzuje AzAPI kontrakt, nikoli výlučnost podpory mezi providery.

## Odložené body a živé ověření

- Ceremonii importu klíčů, rotaci, break-glass, migraci Apps a první živé nasazení řeší [#191](https://github.com/msucharda/devsecops-platform/issues/191).
- Trvalý ledger vydání je odložený kandidát bez vlastního issue; souvisí s [#161](https://github.com/msucharda/devsecops-platform/issues/161).
- Reusable workflow s `job_workflow_sha`, privátní runnery a private endpoint brokeru zůstávají odloženými kandidáty bez issue. Privátní runnery a private endpoint brokeru by vyžadovaly změnu ADR 0011.
- Alerting na zamítnuté požadavky zůstává odloženým kandidátem bez issue.

Toto ADR ani #185 nepovolují živé kroky. Živé ověření přírůstku zůstává otevřené podle #191; živé kroky v něm povoluje uživatel.
