# Instance repository (repozitář instance)

Bootstrap zkopíruje tuto šablonu do organizace platformy a umístí schválený Release (release) do `platform/`. Soubor `instance.yaml` projde validací, ale prázdný výběr modulů nic nenasadí. Ruční předpoklady zůstávají `false`, dokud je platformní tým skutečně nepotvrdí. Šablona neobsahuje klíče ani tokeny.

Bootstrap musí nahradit `@example-platform/platform` v `.github/CODEOWNERS` skutečným platformním týmem s write přístupem. Chráněná `main` musí vyžadovat jeho review; změna workflow, vendorovaného release, App oprávnění i konfigurace musí projít PR. CODEOWNERS sám pravidla ochrany nevynucuje.

Změnu App oprávnění musí navíc schválit security tým podle ADR 0016. Bootstrap musí zajistit toto pravidlo review samostatně; jediný platformní vlastník v CODEOWNERS ani další security schválení apply jobu nejsou náhradou za review změny App oprávnění.

## Environmenty a identity

| Environment | Schválení a přihlašovací údaje |
|---|---|
| `pr-authorization` | Bez schválení. Pouze samostatná enterprise-owned App s `members: read`, instalovaná jen v organizaci platformy, bez přístupu k repozitářům. Nikdy App klíč modulu ani Azure identita. |
| `<module>-plan` | Bez schválení. Vlastní read-only Azure/Microsoft Graph identita a případně read-only enterprise-owned App. |
| `<module>-ruleset-plan` | Bez schválení. Vlastní App s právě `organization_administration: write` pro cílové organizace a identita pro čtení state modulu. Žádný běžný plan tento klíč nedostane. |
| `approve-apply` | Jedno schválení platformním týmem pro celý běh. Žádné secrets. |
| `<module>-apply` | Vlastní apply identity a App. Po společném gate bez dalšího schválení, kromě `enterprise-baseline-apply`, který vyžaduje security tým. |

Explicitní názvy z `credentials` nahrazují výchozí názvy environmentů. Každý environment patří jen jednomu modulu a fázi. Bootstrap musí všechny environmenty omezit na deployment ref `main`, protože `pull_request_target` používá base ref. Nesmí přidat další schválení k PR planu ani ruleset planu. Doporučené pravidlo zabrání obejití schválení administrátorem.

Bootstrap nastaví tyto environment variables:

| Proměnná | Environment |
|---|---|
| `PLATFORM_TEAM_SLUG` | `pr-authorization`; GitHub team slug, nikoli UPN z konfigurace. |
| `PLATFORM_APP_ID`, `PLATFORM_APP_INSTALLATION_ID`, `PLATFORM_APP_ENTERPRISE` | Autorizační environment a každá fáze s App. Hodnoty modulů musí odpovídat aliasu v `instance.yaml`. |
| `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` | Každá fáze modulu; federated credential odpovídá jeho environmentu. |
| `PLATFORM_STATE_STORAGE_ACCOUNT`, `PLATFORM_STATE_RESOURCE_GROUP` | Každá fáze modulu. |

Jediný App secret je `PLATFORM_APP_PRIVATE_KEY` v příslušném environmentu. Nesmí existovat repository nebo organization secret téhož názvu dostupný běžným jobům: environment bez správného secretu musí selhat, ne zdědit širší klíč. Azure používá OIDC bez secretu. Konfigurační proměnné a secrets nesmějí mít rezervovaný prefix `GITHUB_`.

Ještě před vložením klíče musí bootstrap ověřit **skutečná** oprávnění celé App, enterprise vlastníka a všechny její instalace. Read-only plan nesmí dostat klíč write-capable App ani při zúžení vydávaného tokenu. Dva klíče jedné App izolaci nevytvoří. Job tato fakta znovu ověří přes API před zveřejněním tokenu; tato kontrola nenahrazuje správné rozdělení klíčů při bootstrapu.

## Plan a apply

Trusted autorizační job nejprve odmítne forky, App autory a draft PR. Ostatní PR musí mít aktivního autora z platformního týmu. Kontrola běží jen z base commitu, před checkoutem PR kódu do jobu s credentials. Samostatný validační job nemá environment, OIDC ani cloudové credentials.

PR nesmí měnit credential vazby ani App metadata a použít je už před merge. Po review a merge takového PR, včetně importu vytvořeného App, poběží nový plan z chráněné `main`. Summary PR výslovně rozlišuje neprovedený cloudový plan od validace konfigurace.

Joby předávají jen necitlivé výstupy přímých předpokladů přes artifacty stejného běhu a fáze. Úspěch všech vybraných běžných i ruleset planů odemkne společný apply gate. Apply job modulu s rulesety provede běžný root i celý `rulesets/` root; příští modul čeká na úspěch obou.

Workflow používá SHA-pinované upstream akce, dokud platformní tým v #16 ručně nepovýší importované šablony s odkazy na schválené katalogové kopie. Automatický import mění jen `platform/`; App má pouze Contents a Pull requests, ne `workflows: write`. Ruční povýšení vyžaduje PR a review security týmem a není automaticky ověřený cloudový plan.

Reusable workflow `.github/workflows/vendor.yml` volá důvěryhodný workflow z chráněné `main`. Katalog `vendoring/actions.json` naplní platformní tým po schválení akcí v #15; prázdný katalog import vzdálených akcí zastaví. Import vyžaduje samostatné environmenty `vendoring-source`, `vendoring-action-import` a `vendoring-release-import` bez Azure nebo Microsoft Graph identit. Každá cílová organizace má vlastní writer App. Jejich příprava, vstupy workflow, App permissions a ruční import nedostupného zdroje mají kontrakt v `platform/docs/vendoring.md`.

Workflow běží na GitHub-hosted runnerech. Dostupnost enterprise-owned Apps, API a oprávnění na konkrétní instanci GHE.com musí být potvrzená před nasazením. Selhání skončí chybou, nikdy PAT fallbackem nebo širšími plan oprávněními.

Pravidla environmentů implementuje bootstrap v [msucharda/devsecops-platform#11](https://github.com/msucharda/devsecops-platform/issues/11). První cloudový běh a skutečné čtení ruleset bypassu ověří [msucharda/devsecops-platform#12](https://github.com/msucharda/devsecops-platform/issues/12); offline fixture toto ověření nenahrazuje.
