# Workflow vendoringu

Jediný reusable workflow (opakovaně použitelný workflow) `templates/instance/.github/workflows/vendor.yml` připraví akci nebo Release (release) podle tagu a otevře PR v cíli. Zdrojový kód nikdy nespouští. Workflow nezakládá organizace, repozitáře ani Apps; ty musí existovat před živým importem.

## Vstupy a katalog

Bootstrap umístí workflow do `.github/workflows/vendor.yml` v Instance repository (repozitáři instance). Schválené nástroje leží v `platform/tools/`. Volající workflow musí běžet z chráněné `main` při `workflow_dispatch` nebo `push`. PR event ani větev mimo `main` import nespustí. Volající workflow, reusable workflow, katalog i změny App oprávnění musí projít review.

| Vstup | Význam |
|---|---|
| `source-repository` | Zdroj ve formátu `owner/repo`. |
| `source-tag` | Přesný tag, nikoli větev. Nástroj rozbalí annotated tag na commit SHA. |
| `source-api-url` | HTTPS API origin `https://api.github.com` nebo `https://api.<enterprise>.ghe.com`. Výchozí hodnota míří na github.com. |
| `source-asset` | Název ZIP assetu z release tohoto tagu. Pro import release platformy musí volající určit tento asset; automatický zdrojový ZIP není náhrada attestovaného release. Pro akci bez assetu nástroj stáhne zdrojový ZIP z rozlišeného commit SHA. |
| `private-source` | `true` vydá samostatný read-only installation token pro předem deklarovaný zdroj. Výchozí `false` čte zdroj bez autentizace. |
| `target-repository` | Existující cíl `owner/repo` na hostu instance, s větví `main`. |
| `kind` | `action` nebo `release`. |
| `actions-organization` | Actions organization (organizace akcí), do které musí patřit všechny katalogové kopie. |

Workflow vrátí výstup `pull-request`. Prázdná hodnota znamená, že import nenašel diff; není to cloudový plan.

Katalog `vendoring/actions.json` v repozitáři instance má verzi `1` a mapu `actions`. Prázdnou šablonu naplní platformní tým po schválení importů z #15. Klíč určuje upstream repozitář; `repository` určuje kopii `{owner}-{repo}` a `sha` její skutečný merge commit:

```json
{
  "version": 1,
  "actions": {
    "actions/checkout": {
      "repository": "example-actions/actions-checkout",
      "sha": "1111111111111111111111111111111111111111"
    }
  }
}
```

SHA v příkladu je pouze placeholder. Platformní tým musí přes API cílového repozitáře ověřit skutečný commit a jeho schválení security týmem. Offline validátor kontroluje formát a cílovou organizaci, nikoli existenci nebo schválení commitu. Katalog vybírá jednu schválenou kopii pro každý upstream repozitář; upstream reference sama nevybírá jinou verzi kopie.

## Příprava a attestace

`Get-VendoringSource.ps1` nejprve rozliší tag na immutable commit (neměnný commit). ZIP asset vybere z release stejného tagu. Asset musí obsahovat jediný kořenový adresář. Nástroj odmítne traversal, `.git`, duplicitní cesty, symbolické odkazy a rozbalený obsah nad 512 MiB.

Nástroj spočítá SHA256 stažených bajtů a dotáže API attestací pro tento digest. Úspěšná odpověď s prázdnou kolekcí znamená `not-present`. Veřejné API github.com vrací pro neregistrovaný digest také HTTP 404; nástroj tento stav přijme jen po samostatném potvrzení identity a veřejné viditelnosti zdrojového repozitáře a vypíše varování o neověřené provenance. HTTP 404 u privátního zdroje nebo na GHE.com, jiná HTTP chyba, chybějící oprávnění ani nepodporované API nejsou důkazem absence a import zastaví. Nejednoznačný stav vyžaduje deklarovaný ruční import.

Při existující attestaci `gh attestation verify` ověří podpis, digest artefaktu, zdrojový repozitář, `refs/tags/<tag>` a rozlišený source commit. Neplatná nebo neověřitelná attestace import zastaví ještě před rozbalením. Nástroj zaznamená `verified` až po úspěšném ověření. Dostupnost ověřovače, Sigstore a API na konkrétním GHE.com hostu musí potvrdit živý běh; fixture s náhradou CLI neprokazuje kryptografické ověření.

Attestace platí pro stažený artefakt, nikoli pro všechny soubory libovolného release. Volající importu platformy proto musí uvést attestovaný ZIP asset vydaný v #16. Bezattestační release musí tuto absenci přiznat podle ADR 0012. Automatický zdrojový ZIP akce může mít stav `not-present`; tento stav nikdy neznamená ověřenou provenance (provenienci).

`ConvertTo-VendoredSource.ps1` přepíše skutečné YAML hodnoty `uses` v composite akcích, včetně vnořených `action.yml` a `action.yaml`. Pro release přepíše kroky a reusable job references v `templates/instance/.github/workflows/`. Nepřepisuje text ve skriptech, komentáře, testovací fixtures ani zdrojové CI, které pod `platform/` neběží jako workflow instance. Subpath akce zachová a upstream ref nahradí katalogovým SHA. Chybějící katalogová akce způsobí chybu s jejím názvem ještě před vytvořením výstupu.

Lokální `./` odkazy a `docker://` references zůstávají beze změny; nejsou to vzdálené GitHub akce. Docker images musí security tým posoudit zvlášť. Dynamické `uses` a YAML anchors nebo aliases nástroj odmítne místo neúplného přepisu. Import zachová binární soubory a na Linuxu executable bits (příznaky spustitelnosti).

## Diff, oprávnění a hranice cloudového planu

Příprava a publikace běží v oddělených jobech a předávají jen připravená data a receipt (záznam původu) přes artifact stejného běhu. Publikace spouští pouze nástroje z důvěryhodné `main`, nikoli skripty kandidáta.

| Environment | App a scope (rozsah) |
|---|---|
| `vendoring-source` | Jen pro privátní zdroj: samostatná enterprise-owned App s přesně `contents: read` a `attestations: read`. Installation token pokrývá jen deklarovaný zdroj. Veřejný import žádný zdrojový klíč nepoužije. |
| `vendoring-import` | Samostatná enterprise-owned App s přesně `contents: write` a `pull_requests: write`. Installation token pokrývá jen cílový repozitář. Žádné `workflows: write`, organization administration, Azure nebo Microsoft Graph credentials. |

Oba environmenty musí povolit jen chráněnou `main`. `vendoring-import` musí vyžadovat schválení platformním týmem. Privátní klíče patří jen do příslušných environment secrets, ne do repository nebo organization secrets dostupných běžným jobům. Správu, rotaci po nejvýše 90 dnech a odstranění Apps určuje ADR 0016. Workflow neprovisionuje environmenty ani identity; platformní tým je připraví jako řízený krok.

Každý environment s App deklaruje `PLATFORM_APP_ID`, `PLATFORM_APP_INSTALLATION_ID`, `PLATFORM_APP_ENTERPRISE` a secret `PLATFORM_APP_PRIVATE_KEY` podle stávajícího tokenového interface. `vendoring-source` navíc deklaruje `SOURCE_REPOSITORY` a `SOURCE_API_URL`; privátní vstupy se s nimi musí shodovat před použitím klíče. `New-PlatformGitHubToken.ps1 -VendoringRepository owner/repo` kontroluje skutečného enterprise vlastníka, přesná oprávnění App a instalací, cílovou organizaci a active selected installation. Token vydá s explicitním omezením na jméno cílového repozitáře a zkontroluje jeho skutečný rozsah. `-ReadOnlySource` zvolí oddělený zdrojový kontrakt. Širší oprávnění způsobí chybu.

`Publish-VendoringPullRequest.ps1` vyžaduje čistý checkout cílové `main` a ověřený installation token. Akce vlastní obsah kořene cílového repozitáře kromě `.github/`; upstream `.github/` se neimportuje, aby nepřepsal governance ani nespustil cizí workflow. Release vlastní jen `platform/`. Nástroj odstraní staré tracked soubory uvnitř příslušné hranice a přidá nové; zachová konfiguraci instance i živé workflow. Do `.vendoring.json`, pro release do `platform/.vendoring.json`, zapíše tag, source commit, digest a stav attestace. Licence a ostatní soubory zdroje zůstávají součástí diffu.

PR otevře installation token, nikoli `GITHUB_TOKEN`. GITHUB_TOKEN workflow má pouze `contents: read` pro checkout důvěryhodných nástrojů. Tokeny se po použití odvolají i při chybě. Chyba push nebo vytvoření PR se nesmí vykázat jako úspěšný import. Nástroj nevynucuje merge ani nevytváří upstream tag v cíli; tagování schválené kopie řeší #15 po review.

PR body a summary uvádějí **Cloud PR plan: NOT PERFORMED**. Stávající deployment authorization odmítne App autora před předáním cloudových credentials. Po review a merge do chráněné `main` proběhne nový plan před schváleným apply. Úspěšná příprava, validace YAML, vytvoření PR ani ruční krok nejsou cloudový plan.

### Ruční povýšení živých workflow v #16

Uživatel schválil zachování omezených App oprávnění: automatický import uloží přepsané šablony jen pod `platform/`. Zápis do živých `.github/workflows` by vyžadoval další `workflows: write`; App ho nesmí získat kvůli vendoringu.

Po review release platformní tým připraví samostatný PR s povýšením schválených šablon do `.github/workflows`. Security tým schválí diff a platformní tým zajistí, že workflow používají katalogové SHA a zachovávají authorization gates (autorizační podmínky), environmenty a pořadí plan → approval → apply. Tento ruční krok z #16 se nesmí vykázat jako automaticky ověřený běh. Rozhodnutí upřesňuje acceptance criteria (akceptační kritéria) v [#16](https://github.com/msucharda/devsecops-platform/issues/16#issuecomment-6148995640).

## Nedostupný privátní zdroj: Manual step (ruční krok)

Pokud enterprise-owned App nemůže zdroj číst, automatický import skončí konkrétní chybou. Workflow nesmí použít osobní PAT, OAuth token ani širší App scope. Platformní tým provede deklarovaný ruční import do zpřístupnění zdroje:

1. Oprávněný člověk stáhne přesný tag nebo release asset mimo workflow. Zapíše zdroj, tag, rozlišený commit, SHA256 a původ získaných bajtů. Credential nepřenese do repozitáře ani workflow.
2. Pokud zdroj poskytuje attestaci, člověk ji ověří pro stejné bajty, zdroj a tag. Neplatná attestace import zastaví. Chybějící nebo nedostupné ověření výslovně zaznamená; nesmí použít stav `verified`.
3. Člověk bezpečně rozbalí zdroj a spustí `ConvertTo-VendoredSource.ps1` nad lokálními daty a schváleným katalogem. Výsledek vloží do PR v hranici daného importu. Security tým schválí diff včetně licencí a přiznaných omezení.

Ruční PR musí uvést **Manual import; source access was not verified by the workflow; cloud plan NOT PERFORMED**. Stav `manual-not-verified` v receipt přiznává neověřený původ; nezaměňuje ho za absenci attestace ani úspěšné ověření. Po review a merge do chráněné `main` následuje plan před schváleným apply. Drift ani opakovatelnost ručně získaného zdroje nejsou automaticky ověřené.

## Offline a živé ověření

Pester testy volají veřejné skripty. Fixtures ověřují přepis composite akcí, zachování lokálních odkazů a script textu, missing catalog error (chybu chybějící katalogové akce), release hranici, tag resolution (rozlišení tagu), attestation failure (selhání attestace), bezpečnost ZIP a omezení installation tokenu. PR test používá skutečný lokální Git a nahrazuje jen push a HTTP API.

```powershell
Invoke-Pester -Path .\tools\tests\Vendoring*.Tests.ps1 -Output Detailed
.\tools\Test-PowerShell.ps1
```

Před uzavřením #14 musí platformní tým na Reference instance (referenční instanci) doložit cílový repozitář, dostupnost App installation a API, omezená oprávnění, PR s diffem, skutečné kryptografické ověření dostupné attestace a odmítnutí neplatné attestace. Musí doložit, že App PR nedostal cloudové credentials a po review a merge proběhl plan před schváleným apply. Dosavadní offline fixtures tento živý běh nenahrazují. Výsledek nesmí zveřejnit identifikátory ani credentials instance.

## Zdroje

- [ADR 0002](adr/0002-customers-vendor-releases.md), [ADR 0012](adr/0012-public-source-repository.md) a [ADR 0016](adr/0016-github-app-installation-tokens-for-instance-workflows.md).
- [REST API attestací](https://docs.github.com/en/rest/repos/attestations), [GitHub CLI attestation verify](https://cli.github.com/manual/gh_attestation_verify) a [installation token scope](https://docs.github.com/en/rest/apps/apps#create-an-installation-access-token-for-an-app).
