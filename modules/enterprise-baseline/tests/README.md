# Terraform mocks organizace

Všechny tři testovací soubory používají společný mock v `mocks/organization.tfmock.hcl`. Mock načte tělo sdílené kontraktní fixture `orgs/get` pro `GET /orgs/{org}` (REST API `2026-03-10`) a překryje pouze sedm ověřovaných polí hodnotami z `fixtures/organization-settings.json`.

Každý negativní případ změní nebo vynechá jedno pole tohoto compliant těla. Jednoprvkový výraz `for` naváže výsledné tělo na `response`. Z něj vzniknou současně `api_response` a projekce používaných polí `api_data`. Změnu proto nezapisuj samostatně do obou atributů.

Assertions porovnávají oba atributy i při očekávaném selhání postcondition nebo checku. Kontrolují hodnoty i vynechaná pole. Jednostranná změna mocku musí způsobit selhání testu. Stringifikace odpovídá provideru `Mastercard/restapi` 3.0.0: boolean se mění na `"true"` nebo `"false"` a JSON `null` na `"<nil>"` ([implementace `GetApiData`](https://github.com/Mastercard/terraform-provider-restapi/blob/v3.0.0/internal/apiclient/object.go)).

Terraform testy ověřují také dokumentovaný `null` u fork policy a záměrně neplatný string `"false"`. Kontrolují zachování JSON typu i konzistentní `api_data`. Původní případy v `tools/tests/EnterpriseBaseline.Tests.ps1` zůstávají beze změny. Používají skutečný provider proti lokálnímu API stubu; nevyžadují GitHub credentials ani živé kroky.
