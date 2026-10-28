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
| `<plan-environment>-drift`, `<ruleset-plan-environment>-drift` | Noční varianty bez schválení, jen z `main`. Zachovají oddělené App klíče; používají plan identitu stejného modulu. |
| `drift-report` | Bez schválení, jen z `main`. Samostatná App s právě `issues: write` jen pro repozitář instance. Žádná Azure identita. Job `report_drift` v `drift.yml` jí otevře nebo aktualizuje issue driftu. |
| `vendoring-action-import`, `vendoring-release-import` | Jen z `main`, schválení platformním týmem, bez bypassu. Dvě oddělené Apps s `contents: write` a `pull_requests: write`, selected scope pouze v příslušné cílové organizaci. Žádné Azure nebo Microsoft Graph credentials. |
| `vendoring-source` | Jen z `main`. Pro veřejný import prázdný; volitelná samostatná App s `contents: read` a `attestations: read` na jediný deklarovaný privátní zdroj. |
| `approve-apply` | Jedno schválení platformním týmem pro celý běh. Žádné secrets. |
| `<module>-apply` | Vlastní apply identity a App. Po společném gate bez dalšího schválení, kromě `enterprise-baseline-apply` a `organization-rulesets-apply`, které vyžadují security tým. |
| `approve-teardown-platform`, `teardown` | Navazující schválení platformním a potom security týmem. Žádné secrets, variables ani OIDC vazby. Používá je workflow `teardown`. |

Explicitní názvy z `credentials` nahrazují výchozí názvy environmentů. Každý environment patří jen jednomu modulu a fázi. Bootstrap musí všechny environmenty omezit na deployment ref `main`, protože `pull_request_target` používá base ref. Nesmí přidat další schválení k PR planu ani ruleset planu. Doporučené pravidlo zabrání obejití schválení administrátorem.

Bootstrap nastaví tyto environment variables:

| Proměnná | Environment |
|---|---|
| `PLATFORM_TEAM_SLUG` | `pr-authorization`; GitHub team slug, nikoli UPN z konfigurace. |
| `PLATFORM_APP_ID`, `PLATFORM_APP_INSTALLATION_ID`, `PLATFORM_APP_ENTERPRISE` | Autorizační environment a každá fáze s App. Hodnoty modulů musí odpovídat aliasu v `instance.yaml`. |
| `PLATFORM_APP_KEY_FINGERPRINT` | Environment s App; veřejný fingerprint umožní idempotentní vložení a rotaci klíče. |
| `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` | Každá fáze modulu; federated credential odpovídá jeho environmentu. |
| `PLATFORM_STATE_STORAGE_ACCOUNT`, `PLATFORM_STATE_RESOURCE_GROUP` | Každá fáze modulu. |

Jediný App secret je `PLATFORM_APP_PRIVATE_KEY` v příslušném environmentu. Nesmí existovat repository nebo organization secret téhož názvu dostupný běžným jobům: environment bez správného secretu musí selhat, ne zdědit širší klíč. Azure používá OIDC bez secretu. Konfigurační proměnné a secrets nesmějí mít rezervovaný prefix `GITHUB_`.

Ještě před vložením klíče musí bootstrap ověřit **skutečná** oprávnění celé App, enterprise vlastníka a všechny její instalace. Read-only plan nesmí dostat klíč write-capable App ani při zúžení vydávaného tokenu. Dva klíče jedné App izolaci nevytvoří. Job tato fakta znovu ověří přes API před zveřejněním tokenu; tato kontrola nenahrazuje správné rozdělení klíčů při bootstrapu.

## Plan a apply

Trusted autorizační job nejprve odmítne forky, App autory a draft PR. Ostatní PR musí mít aktivního autora z platformního týmu. Kontrola běží jen z base commitu, před checkoutem PR kódu do jobu s credentials. Samostatný validační job nemá environment, OIDC ani cloudové credentials.

PR nesmí měnit credential vazby ani App metadata a použít je už před merge. Po review a merge takového PR, včetně importu vytvořeného App, poběží nový plan z chráněné `main`. Summary PR výslovně rozlišuje neprovedený cloudový plan od validace konfigurace.

U autorizovaného PR se změnou `githubApps` nebo `credentials` záměrně zčervenají checky výběru modulů a souhrnu planu, i když validace konfigurace prošla. Přesné názvy checků, texty chyb a podmínky review a merge uvádí [postup pro chráněné vazby](../../docs/bootstrap.md#pr-se-změnou-githubapps-nebo-credentials) (v repozitáři instance `platform/docs/bootstrap.md`). Tento výsledek není provedený cloudový plan.

Joby předávají jen necitlivé výstupy přímých předpokladů přes artifacty stejného běhu a fáze. Výběr v `instance.yaml` zahrne všechny fáze výslovně zvoleného modulu a skutečné předpoklady jednotlivých fází; předpoklad `enterprise-baseline:code-security` sám nevybere pozdní root ani jeho ruleset plan. Stejné uzly určují joby deploy, drift a teardown. Úspěch všech vybraných běžných, časných i ruleset planů odemkne společný apply gate. Apply job modulu s rulesety provede běžný root i celý `rulesets/` root; příští modul čeká na úspěch obou.

Manifest `enterprise-baseline` deklaruje časnou fázi `code-security`. Ta používá stejná oprávnění App, identity a environmenty `enterprise-baseline` pro plan a apply, ale samostatný Terraform root a state `organizations/<login>/terraform.code-security.tfstate`. Nevyžaduje `liveWorkflowsPromoted` ani preflight katalogových workflow. Nejdřív se dokončí `organizations`, pak časná Code Security fáze připojí konfiguraci ke všem existujícím repozitářům včetně repozitáře instance a nastaví ji jako výchozí pro nové repozitáře. Až potom běží `organization-rulesets`, `actions-catalog` a pozdní `enterprise-baseline`. Pozdní fáze zachovává `liveWorkflowsPromoted`, preflight workflow a politiku Actions. Teardown probíhá v obráceném pořadí a odstraní časnou konfiguraci až po rulesetech. Každá fáze předává vlastní výstupní artifacty; runner načte výstupy předpokladů ze stejného běhu.

Na čerstvé instanci ruleset plan musí odmítnout organizaci bez existující výchozí Code Security konfigurace. Výstup dosud nenapsaného planu časné fáze není důkaz vzdáleného stavu. Rozhodnutí koordinátora schválilo **dva nové živé uživatelské kroky**: spusť `Deploy instance` přes `workflow_dispatch` na chráněné `main` nejdřív s volbou `deployment: code-security`, potom s volbou `deployment: catalog`. První běh vybere jen časnou fázi a její předpoklady; druhý přidá `organization-rulesets` a `actions-catalog`, ale ne pozdní root `enterprise-baseline`. Oba běhy použijí vlastní plan a výstupy předpokladů ze stejného běhu. Autorizační preflight, společná validace konfigurace, schválení `approve_apply` a původní plan/apply environmenty zůstávají. Konfigurace `enterprise-baseline` potřebuje své `target_organizations`, hodnoty `secret_scanning_bypass_reviewers` pro jednotlivé organizace a stávající App bindings. Po úspěchu `catalog` proveď import a povýšení živých workflow. Až pak spusť `deployment: full`; tato výchozí volba zahrne pozdní politiku Actions a nadále vyžaduje `liveWorkflowsPromoted` i katalogový workflow preflight. Neplatný dispatch vstup musí první job odmítnout před autorizací a vydáním tokenů. Ruleset nesmí převzít navržený Terraform state jako důkaz vzdáleného stavu. Podrobnosti jsou v [runbooku bootstrapu](../../docs/bootstrap.md#nový-živý-krok-časná-code-security-fáze-před-prvním-úplným-deploy). Časná fáze převezme existující Code Security objekty podle názvu; pozdní root je zapomene přes `removed` s `destroy = false`, aniž by je smazal. Jiná migrace RC state není podporovaná.

Release hranice všech tří voleb zůstává stejná jako u dosavadního `full`. Kontrola release při bootstrapu se nemění; samostatnou kontrolu markeru a provenance při deploy řeší [#157](https://github.com/msucharda/devsecops-platform/issues/157). Omezený výběr nepřidává novou záruku původu release.

Root `organization-rulesets/rulesets` spravuje aktivní organizační ruleset pro výchozí větve všech repozitářů organizace akcí bez bypassu. Vyžaduje jedno nové schválení po změně PR, review od CODEOWNERS a CodeQL bez bezpečnostních nálezů high nebo vyšších; zakazuje force push a smazání výchozí větve. Pro změny bez připsaného autora explicitně vyžaduje dodatečné schválení (`require_extra_approval_for_unattributed_changes = true`). Úplný detail včetně explicitního prázdného `bypass_actors` ověřuje oddělený ruleset plan i noční drift. Chybějící pole běh zastaví. Ruleset plan credential má širší `organization_administration: write`, nikoli read-only přístup. Importní App ruleset neobchází; importní PR musí získat review i požadované výsledky skenování.

Workflow používá SHA-pinované upstream akce, dokud platformní tým v #16 ručně nepovýší importované šablony s odkazy na schválené katalogové kopie. Automatický import mění jen `platform/`; App má pouze Contents a Pull requests, ne `workflows: write`. Ruční povýšení vyžaduje PR a review security týmem a není automaticky ověřený cloudový plan.

Reusable workflow `.github/workflows/vendor.yml` volá důvěryhodný workflow z chráněné `main`. Workflow `import-action.yml` importuje veřejnou akci podle vstupů `repository` a `tag`; cíl odvodí v organizaci akcí a nepřijímá jeho přepsání. Workflow `import-release.yml` importuje attestovaný release platformy podle tagu (`workflow_dispatch`, vstup `tag`); zdroj určuje proměnná `PLATFORM_SOURCE_REPOSITORY`, výchozí hodnota je `msucharda/devsecops-platform`. Katalog `vendoring/actions.json` naplní platformní tým po schválení akcí v #15; prázdný katalog import vzdálených akcí zastaví. Bootstrap vždy vytvoří environmenty `vendoring-source`, `vendoring-action-import` a `vendoring-release-import` bez Azure nebo Microsoft Graph identit. Writer aliasy zapojí parametry `-VendoringActionApp` a `-VendoringReleaseApp`; bez nich varuje a import skončí před prvním tokenem. Action writer zapoj opakovaným bootstrapem po apply `actions-catalog`. Každá cílová organizace má vlastní writer App. Jejich příprava, vstupy workflow, App permissions a ruční import nedostupného zdroje mají kontrakt v `platform/docs/vendoring.md`.

Workflow běží na GitHub-hosted runnerech. Dostupnost enterprise-owned Apps, API a oprávnění na konkrétní instanci GHE.com musí být potvrzená před nasazením. Selhání skončí chybou, nikdy PAT fallbackem nebo širšími plan oprávněními.

Pravidla environmentů implementuje `tools/Invoke-GitHubBootstrap.ps1`; postup a rotaci klíčů popisuje [runbook bootstrapu](../../docs/bootstrap.md#github-část-bootstrapu). Workflow `drift.yml` spouští oddělené plan joby denně v 02:17 UTC, bez apply. Drift nebo neúplný běh zapíše do jednoho issue; report uvádí i oblasti mimo automatickou detekci. První cloudový běh a skutečné čtení ruleset bypassu ověří [msucharda/devsecops-platform#12](https://github.com/msucharda/devsecops-platform/issues/12); offline fixture toto ověření nenahrazuje.
