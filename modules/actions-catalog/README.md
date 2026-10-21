# actions-catalog

Modul spravuje repozitáře vendorovaných akcí v organizaci akcí (actions). Workflow v instanci smí používat jen akce z tohoto katalogu, pinované na SHA commitu.

Předpoklady: `organizations`. Ruční kroky: `create-actions-security-team` a `require-catalog-code-owner-review` (viz [Ruční kroky](#ruční-kroky)).

## Stav implementace

[#15](https://github.com/msucharda/devsecops-platform/issues/15) implementuje tvorbu repozitářů, přístup enterprise, CODEOWNERS, tagy schválených importů a kontrolu stavu. Kód a testy běží offline proti stubu podle dokumentovaného API. **Živý apply na referenční instanci neproběhl.** Živá kritéria #15 zůstávají otevřená.

## Pravidla vendoringu

- Každá akce má v organizaci akcí repozitář `{owner}-{repo}`, například `actions-checkout`.
- Repozitář je internal a jeho akce smí používat repozitáře z enterprise (`access_level: enterprise`).
- Security tým má do repozitáře `push` a `.github/CODEOWNERS` obsahuje jen `* @{organizace}/{security tým}`.
- Import ([vendoring](../../docs/vendoring.md)) otevře PR s diffem. Merge do `main` vyžaduje schválení code ownera, tedy security týmu.
- Tag ve vendorované kopii se rovná tagu upstreamu. Modul tag vytvoří až po ověření schváleného importu a existující tag nikdy nepřesune.
- Workflow pinují akci na SHA commitu z výstupu `releases`, ne na tag.

## Počáteční katalog

| Upstream | Repozitář | Použití |
|---|---|---|
| `actions/checkout` | `actions-checkout` | Checkout repozitáře. |
| `actions/upload-artifact` | `actions-upload-artifact` | Výstupy modulů mezi joby (ADR 0014). |
| `actions/download-artifact` | `actions-download-artifact` | Výstupy modulů mezi joby. |
| `actions/create-github-app-token` | `actions-create-github-app-token` | Vydání installation tokenu (ADR 0016), viz [Tokenová akce](#tokenová-akce). |
| `azure/login` | `azure-login` | Přihlášení do Azure přes OIDC. |
| `hashicorp/setup-terraform` | `hashicorp-setup-terraform` | Instalace Terraformu. |

## Parametry

| Parametr | Povinný | Význam |
|---|---|---|
| `target_organizations` | ano | Rozsah GitHub App: přesně organizace akcí instance, například `["demo-a1b2c3-actions"]`. Velikost písmen se při porovnání ignoruje. |
| `security_team` | ano | Slug týmu v organizaci akcí, který vlastní katalog přes CODEOWNERS a schvaluje importy. Malá písmena, číslice a `-`, nejvýše 100 znaků. |
| `catalog` | ne | Seznam upstreamů `owner/repo` malými písmeny. Výchozí hodnota je počáteční katalog. Názvy repozitářů `{owner}-{repo}` se nesmí shodovat. |
| `releases` | ne | Mapa upstream → `{ tag, commit }` schválených importů. `commit` je plné SHA (40 znaků hex, malá písmena) commitu importu na `main`. Výchozí hodnota je prázdná mapa. |

Terraform validuje parametry před spuštěním provisionerů.

## Výstupy

| Výstup | Obsah |
|---|---|
| `organization` | Login organizace akcí. |
| `repositories` | Upstream → `organizace/repozitář` vendorované kopie. |
| `releases` | Upstream → `{ tag, commit }` ověřeného releasu. Workflow použije `uses: {repozitář}@{commit}`. |

Výstupy `repositories` a `releases` závisí na kontrole stavu. Terraform je vrátí jen po kontrole bez porušení.

## Životní cyklus

### Repozitář

Prostředek `terraform_data.repository` pro každou akci katalogu spustí `Invoke-CatalogChange.ps1 -Action InitializeRepository`. Každý krok nejdřív čte stav:

1. Modul přečte repozitář (`GET /repos/{org}/{repo}`). Pokud chybí, vytvoří ho (`POST /orgs/{org}/repos`, `visibility: internal`, `auto_init: false`). Odpověď HTTP 422 po ztracené odpovědi předchozího běhu vede k opakovanému čtení.
2. Modul převezme jen repozitář organizace akcí s přesným názvem, viditelností `internal`, bez archivace, který není fork a má výchozí větev `main`. Jiný repozitář ukončí běh chybou (fail-closed).
3. Pokud security tým nemá `push`, modul ho přidá (`PUT /orgs/{org}/teams/{team}/repos/{org}/{repo}`). Chybějící tým nebo tým s jinou viditelností než `closed` ukončí běh chybou. CODEOWNERS tajný (`secret`) tým ignoruje.
4. Prázdný repozitář dostane první commit `.github/CODEOWNERS` (`PUT /repos/{org}/{repo}/contents/.github/CODEOWNERS`). Pokud `main` existuje a CODEOWNERS se liší, modul soubor nepřepíše a skončí chybou. Změna musí projít PR se schválením.
5. Pokud `access_level` není `enterprise`, modul ho nastaví (`PUT /repos/{org}/{repo}/actions/permissions/access`). Krok je poslední, proto repozitář, který neprošel převzetím, zůstane pro enterprise uzavřený.

### Tag releasu

Prostředek `terraform_data.release_tag` pro každou položku `releases` spustí `-Action CreateReleaseTag`:

1. Pokud tag existuje a ukazuje přímo na `commit`, modul nic nemění. Tag na jiný objekt, včetně anotovaného tagu, ukončí běh chybou. Modul tag nikdy nepřesune.
2. Modul přečte stav repozitáře jako [kontrola stavu](#kontrola-stavu) bez tagu. Každé porušení ukončí běh chybou před tvorbou tagu. Schvalovací pravidlo, CODEOWNERS a push security týmu zajišťují, že `main` obsahuje jen schválené změny.
3. Modul ověří, že SHA `main` z kroku 2 obsahuje `commit` (`GET /repos/{org}/{repo}/compare/{commit}...{main_sha}`, stav `identical` nebo `ahead`). Commit mimo `main` neprošel schváleným PR.
4. Modul přečte receipt `.vendoring.json` v daném commitu. Receipt musí mít `version: 1`, `kind: action`, `source` rovné upstreamu katalogu a `tag` rovné tagu releasu. Hodnoty musí být řetězce a porovnání rozlišuje velikost písmen.
5. Modul znovu přečte SHA `main`. Pokud se od kroku 2 změnilo, běh skončí chybou a tag nevznikne.
6. Modul vytvoří lightweight tag (`POST /repos/{org}/{repo}/git/refs`). Odpověď HTTP 422 vede k opakovanému čtení tagu podle kroku 1.

Nový release je nová položka `releases` s novým tagem. Starý tag zůstává.

Omezení: krok 3 ověřuje dosažitelnost z `main`, ne schválení přesné revize. Mezilehlý commit importního PR s platným receiptem proto projde. Commit releasu volí člověk v parametru `releases` přes reviewovaný PR konfigurace instance. Vazbu na důkaz schválení řeší [#72](https://github.com/msucharda/devsecops-platform/issues/72).

### Kontrola stavu

Data source `catalog_state` po změnách přečte stav každého repozitáře jen čtecími požadavky. Postcondition vyžaduje prázdný seznam porušení. Porušení jsou:

- repozitář neexistuje nebo nesplňuje podmínky převzetí z kroku 2,
- `access_level` není přesně `enterprise`,
- security tým nemá `push`,
- `main` neexistuje nebo CODEOWNERS na `main` se liší od `* @{organizace}/{security tým}`,
- na `main` není aktivní pravidlo `pull_request` z rulesetu organizace akcí (`ruleset_source_type: Organization`, `ruleset_source` rovné organizaci) s `require_code_owner_review: true`, `dismiss_stale_reviews_on_push: true` a `required_approving_review_count` ≥ 1 (`GET /repos/{org}/{repo}/rules/branches/main`, všechny stránky). Pravidlo z rulesetu repozitáře se nepočítá, protože apply credential s `administration: write` ho může změnit,
- tag releasu chybí, neukazuje přímo na `commit` nebo `commit` nesplňuje podmínky z kroků 3 a 4.

Chyba čtení nebo nečitelná odpověď API ukončí program chybou. Neznámý stav neprojde jako shoda. Plan i drift proto hlásí každý rozdíl jako chybu, ne jako plánovanou změnu.

### Obnova po přerušení

Každý krok apply nejdřív čte stav. Opakovaný apply po přerušení proto pokračuje bez druhé tvorby objektu. Harness přerušení (`tools/tests/ActionsCatalog.Interruption.Tests.ps1`) ověřuje každý zapisující krok tvorby, převzetí repozitáře a tvorby tagu ve variantách `BeforeApply` a `LoseResponse`.

### Destroy a teardown

Destroy nic nemaže. Repozitáře, tagy a CODEOWNERS zůstanou, dokud člověk nesmaže organizaci akcí (ruční krok modulu `organizations`). Odebrání akce z `catalog` ani položky z `releases` repozitář ani tag nesmaže.

## Ruční kroky

- `create-actions-security-team`: owner organizace akcí vytvoří viditelný (`closed`) security tým před prvním apply a přidá do něj reviewery. Modul tým ani členy nespravuje.
- `require-catalog-code-owner-review`: owner organizace akcí vytvoří ruleset organizace pro výchozí větev repozitářů katalogu. Ruleset vyžaduje PR s aspoň 1 schválením a review code ownera bez bypassu. Nový push do PR schválení zruší (`dismiss_stale_reviews_on_push`). Modul nesmí mít credential pro zápis rulesetů (ADR 0016), proto ruleset jen čte.

Omezení: endpoint `rules/branches` vrací jen aktivní pravidla. Bypass actory nevrací, proto modul bypass neověří.

## Identita

Modul používá installation tokeny organizačních Apps podle [ADR 0016](../../docs/adr/0016-github-app-installation-tokens-for-instance-workflows.md) s `resources: { organizations: target_organizations }`. Instalace App musí mít přístup ke všem repozitářům organizace akcí, protože modul repozitáře vytváří.

| Fáze | Oprávnění |
|---|---|
| plan | `administration: read`, `contents: read`, `members: read`, `metadata: read` |
| apply | `administration: write`, `contents: write`, `members: read`, `metadata: read` |

- `administration: write` je potřeba pro tvorbu repozitáře, `access_level` a přístup týmu.
- `contents: write` je potřeba pro commit CODEOWNERS a tvorbu tagu.
- `members: read` je potřeba pro čtení týmu a jeho oprávnění.
- Plan je read-only. Žádná fáze nemá oprávnění k zápisu rulesetů.

### Tokenová akce

Návrh: `actions/create-github-app-token` verze `v3.3.0` (commit `64ab729a6294000f5aa4a4bc0b73d1f32bc45510`). Akce má vstupy `owner`, `repositories` a `github-api-url` a vstupy `permission-*` pro oprávnění repozitáře a organizace. Vstupy pro enterprise permissions nemá. Moduly s `resources: { enterprise: true }` proto tokeny touto akcí nevydají. Volba verze je otevřená otázka [#15](https://github.com/msucharda/devsecops-platform/issues/15); živě neověřeno.

## Neověřené živě

- Apply a druhý plan bez změny na referenční instanci.
- Výchozí větev nového prázdného repozitáře a tvorba `main` prvním `PUT contents`.
- Oprávnění, které vyžaduje `GET rules/branches` (předpoklad: `metadata: read`).
- Workflow v organizaci workloadů s akcí pinovanou na SHA.

## Zdroje

Všechna volání posílají `X-GitHub-Api-Version: 2026-03-10`. Kontraktní fixtures jsou v `tools/tests/fixtures/github-api/` a vychází z OpenAPI `github/rest-api-description@bb754941722779d8a5b3a2f25a5fbb7ce794e1ea` (`descriptions/ghec/ghec.2026-03-10.json`).

- [Create an organization repository](https://docs.github.com/en/enterprise-cloud@latest/rest/repos/repos?apiVersion=2026-03-10#create-an-organization-repository), [Get a repository](https://docs.github.com/en/enterprise-cloud@latest/rest/repos/repos?apiVersion=2026-03-10#get-a-repository)
- [Get](https://docs.github.com/en/enterprise-cloud@latest/rest/actions/permissions?apiVersion=2026-03-10#get-the-level-of-access-for-workflows-outside-of-the-repository) a [set the level of access for workflows outside of the repository](https://docs.github.com/en/enterprise-cloud@latest/rest/actions/permissions?apiVersion=2026-03-10#set-the-level-of-access-for-workflows-outside-of-the-repository)
- [Get a team by name](https://docs.github.com/en/enterprise-cloud@latest/rest/teams/teams?apiVersion=2026-03-10#get-a-team-by-name), [Check team permissions for a repository](https://docs.github.com/en/enterprise-cloud@latest/rest/teams/teams?apiVersion=2026-03-10#check-team-permissions-for-a-repository) (s `Accept: application/vnd.github.v3.repository+json`), [Add or update team repository permissions](https://docs.github.com/en/enterprise-cloud@latest/rest/teams/teams?apiVersion=2026-03-10#add-or-update-team-repository-permissions)
- [Get repository content](https://docs.github.com/en/enterprise-cloud@latest/rest/repos/contents?apiVersion=2026-03-10#get-repository-content) (varianty file, directory, symlink, submodule), [Create or update file contents](https://docs.github.com/en/enterprise-cloud@latest/rest/repos/contents?apiVersion=2026-03-10#create-or-update-file-contents)
- [Get a reference](https://docs.github.com/en/enterprise-cloud@latest/rest/git/refs?apiVersion=2026-03-10#get-a-reference), [Create a reference](https://docs.github.com/en/enterprise-cloud@latest/rest/git/refs?apiVersion=2026-03-10#create-a-reference)
- [Compare two commits](https://docs.github.com/en/enterprise-cloud@latest/rest/commits/commits?apiVersion=2026-03-10#compare-two-commits)
- [Get rules for a branch](https://docs.github.com/en/enterprise-cloud@latest/rest/repos/rules?apiVersion=2026-03-10#get-rules-for-a-branch)