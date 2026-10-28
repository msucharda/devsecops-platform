# Terraform mocks organizace

Testovací soubory používají společný mock v `mocks/organization.tfmock.hcl`. Mock načte tělo sdílené kontraktní fixture `orgs/get` pro `GET /orgs/{org}` (REST API `2026-03-10`) a překryje pouze sedm ověřovaných polí hodnotami z `fixtures/organization-settings.json`.

Každý negativní případ změní nebo vynechá jedno pole tohoto compliant těla. Jednoprvkový výraz `for` naváže výsledné tělo na `response`. Z něj vzniknou současně `api_response` a projekce používaných polí `api_data`. Změnu proto nezapisuj samostatně do obou atributů.

Assertions porovnávají oba atributy i při očekávaném selhání postcondition nebo checku. Kontrolují hodnoty i vynechaná pole. Jednostranná změna mocku musí způsobit selhání testu. Stringifikace odpovídá provideru `Mastercard/restapi` 3.0.0: boolean se mění na `"true"` nebo `"false"` a JSON `null` na `"<nil>"` ([implementace `GetApiData`](https://github.com/Mastercard/terraform-provider-restapi/blob/v3.0.0/internal/apiclient/object.go)).

Terraform testy ověřují také dokumentovaný `null` u fork policy a záměrně neplatný string `"false"`. Kontrolují zachování JSON typu i konzistentní `api_data`. Původní případy v `tools/tests/EnterpriseBaseline.Tests.ps1` zůstávají beze změny. Používají skutečný provider proti lokálnímu API stubu; nevyžadují GitHub credentials ani živé kroky.

Soubor `organization_patch_contract.tftest.hcl` používá stejný mock a kontroluje skutečné `data`, efektivní `update_data` (při `null` použije `data`) a `destroy_data` proti `../organization-patch-allowlist.json`. Vyžaduje explicitní neprázdné stringové zdůvodnění každého odesílaného pole i vynechaných kandidátů. Nedokazuje zapisovatelnost povolených polí pod aktuální enterprise policy.

Pester suite `tools/tests/EnterpriseBaselinePatchContract.Tests.ps1` spustí tento Terraform test nad izolovanou kopií modulu. Ověří platný kontrakt, dispozici devíti kandidátů enterprise policy, přidání nepovoleného pole do create, samostatného update i destroy payloadu a chybějící či neplatný důvod včetně array. Kopie používá stejné kontraktní fixtures z #153; nová API odpověď nevzniká. Stávající lokální API stub v `EnterpriseBaseline.Tests.ps1` navíc ověří každý skutečně odeslaný PATCH proti allow-listu. Cílený běh: `.\tools\Invoke-Tests.ps1 -Path .\tools\tests\EnterpriseBaselinePatchContract.Tests.ps1`.
