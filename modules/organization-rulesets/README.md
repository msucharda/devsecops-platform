# organization-rulesets

Modul spravuje organizační ruleset `platform-default-branch` v organizaci z `target_organizations`. Ruleset vyžaduje review od CODEOWNERS na výchozí větvi všech repozitářů organizace a nemá bypass. Modul vznikl vyčleněním rootu `rulesets/` z modulu `enterprise-baseline` ([#73](https://github.com/msucharda/devsecops-platform/issues/73)).

Předpoklad: `organizations`. Na modulu závisí `actions-catalog`: katalog akcí vyžaduje schvalovací pravidlo v organizaci akcí ještě před prvním apply. Pořadí nasazení je `organizations` → `organization-rulesets` → `actions-catalog` → `enterprise-baseline`. Modul `enterprise-baseline` závisí na `actions-catalog` kvůli politice akcí ([#18](https://github.com/msucharda/devsecops-platform/issues/18)). Ruleset by proto v `enterprise-baseline` vytvořil cyklus.

## Konfigurace

`target_organizations` musí obsahovat právě jednu organizaci: organizaci akcí (Actions organization). Runner pro root s providerem `Mastercard/restapi` jiný počet organizací odmítne. Oba rooty navíc odmítnou jinou organizaci než `instance.organizations.actions` (bez ohledu na velikost písmen) a chybějící `instance.organizations`. Rulesety platformní a workload organizace proto modul zatím nespravuje. Podpora více organizací je otevřené rozhodnutí.

```yaml
modules:
  organization-rulesets:
    parameters:
      target_organizations: [demo-a1b2c3-actions]
```

## Hlavní root a výstupy

Hlavní root nemá prostředky. Zveřejní výstup `organizations`: seřazený seznam `target_organizations`. Deploy job nahraje výstupy modulu až po úspěšném apply rootu `rulesets/`. Závislé moduly proto výstup dostanou, jen když ruleset existuje v požadovaném tvaru.

`actions-catalog` v planu ověří, že výstup `organizations` obsahuje organizaci akcí (bez rozlišení velikosti písmen). Chybějící výstup, prázdný seznam, jiný typ nebo jiná organizace plan zastaví.

## Organizační ruleset pro výchozí větev

Root `rulesets/` spravuje v organizaci z `target_organizations` aktivní ruleset `platform-default-branch`. Podmínka `repository_name.include: ["~ALL"]` zahrnuje všechny repozitáře; `ref_name.include: ["~DEFAULT_BRANCH"]` sleduje jejich aktuální výchozí větev. Oba seznamy `exclude` jsou prázdné.

- Změna jen přes PR s jedním schválením. Nový commit schválení zruší.
- PR vyžaduje review od CODEOWNERS.
- Force push a smazání větve jsou zakázané.
- Pravidlo `code_scanning` vyžaduje CodeQL s `security_alerts_threshold: high_or_higher`. Obecné alerty bez bezpečnostní závažnosti neblokuje (`alerts_threshold: none`).
- `bypass_actors` je explicitně prázdné pole. Bypass nemá ani platformní tým, organization owner nebo importní App.

Root používá [organizační ruleset REST API](https://docs.github.com/en/enterprise-cloud@latest/rest/orgs/rules), verzi `2026-03-10`: seznam `GET /orgs/{org}/rulesets`, detail `GET /orgs/{org}/rulesets/{ruleset_id}`, vytvoření `POST /orgs/{org}/rulesets`, změnu `PUT /orgs/{org}/rulesets/{ruleset_id}` a odstranění `DELETE /orgs/{org}/rulesets/{ruleset_id}`.

- Runner ho spouští přes `Invoke-Module.ps1 -Module organization-rulesets -Rulesets` s akcí `plan`, `apply` nebo `destroy`. Má oddělený state `terraform.rulesets.tfstate`.
- Prostředek `restapi_object.ruleset` používá provider `Mastercard/restapi` a installation token z `REST_API_BEARER`, který nastavuje runner. Root podporuje právě jednu organizaci na běh.
- Skripty v `scripts/` volají REST API s tokenem z `REST_API_BEARER` a pevnou hlavičkou `X-GitHub-Api-Version: 2026-03-10`. Modul má vlastní kopii transportu; na skriptech jiného modulu nezávisí.
- `terraform_data.ruleset_intent` uloží záměr před vzdáleným `POST`. Provider potom uchová GitHub ID ve state a mění i maže objekt podle něj, nikoli podle názvu. Přejmenování proto nezpůsobí smazání jiného rulesetu pod původním názvem.
- Po ztracené odpovědi na `POST` čtení podle rezervovaného názvu `platform-default-branch` zjistí existující objekt. Terraform `import` block ho při dalším planu převezme do state místo vytvoření duplikátu. Existující state identita má přednost před tímto vyhledáním. Ztracenou odpověď na `PUT` nebo `DELETE` řeší refresh a opakovaný běh.
- Před destroy runner spustí `Restore-RulesetState.ps1`. Skript ověří každý uložený objekt podle ID a zdrojové organizace. Pokud state obsahuje jen přerušený záměr vytvoření bez vzdáleného ID, nejprve objekt vyhledá podle názvu a přes `terraform import` uloží jeho ID. Potom cíleným apply uloží do záměru příznak `destroy_started = true`; používá interní proměnnou `ruleset_destroy_started`. Teprve potom runner vytvoří destroy plan. Záměr se maže až po nativním prostředku. Po přerušení mezi jejich odstraněním proto další destroy nepřevezme jiný objekt původního názvu. Skript podle názvu nic nemaže a existující ID nikdy nenahradí jiným objektem. Tento obnovovací krok vyžaduje runner; samostatné `terraform destroy` po přerušeném vytvoření ho nenahrazuje.
- Duplicitní název, kolize velikosti písmen názvu, neznámý typ zdroje a neshodná identita v detailu zastaví čtení i zápis. Zděděný enterprise ruleset stejného názvu skript nepřevezme ani nesmaže.
- Každý plan a ověření po apply čte úplný detail. Nezávislé čtení během planu kontroluje existující rulesety i při přidání organizace nebo jiné čekající změně; nesmí se odložit do apply. Chybějící, `null` nebo nepolové `bypass_actors` je chyba, ne důkaz prázdného bypassu. Pořadí pravidel a merge metod se ignoruje; prázdné serverové `required_reviewers` a vypnuté `dismissal_restriction` bez aktérů se považují za ekvivalent. `enabled` musí mít boolean typ.
- Spravovaný ruleset podporuje jen variantu podmínek `repository_name` s `ref_name`. Varianty `repository_id` a `repository_property` odmítne s chybou. Ostatní místní rulesety nespravuje. Detaily zděděných enterprise rulesetů tento root neověřuje; noční kontrola jejich počet vykazuje jako nepokrytou oblast podle ADR 0016.

Importní PR podléhají stejnému review i skenování. Ruleset nevyžaduje vlastní CI status check cloudového planu; jeho neprovedení u App-created PR proto není samo o sobě blokací merge. Import nesmí dostat bypass. Skutečný průchod importu akce a release, chování CodeQL pro jejich obsah a čtení `bypass_actors` installation tokenem musí potvrdit živá akceptace na GHE.com. Offline testy to nedokazují.

## Detekce driftu

Modul drift neopravuje automaticky; provider `restapi` s `ignore_server_additions` ho neopraví.

| Drift | Výsledek planu |
|---|---|
| Ruleset smazaný mimo Terraform | Postcondition plan zastaví chybou; plan nic nevytvoří ani nezapíše. Automatická obnova chybí. Operátor odebere `restapi_object.ruleset["<org>"]` ze state rootu `rulesets/` a další schválený apply ruleset vytvoří znovu. |
| Bypass navíc, nižší počet schválení, vypnuté vynucování, změna podmínek nebo pravidel | Postcondition plan zastaví chybou. Operátor obnoví požadované hodnoty včetně původního názvu. |

Běžný plan vzdálené prostředky nemění.

## Teardown

Teardown nejdřív odstraní root `rulesets/` a smaže ruleset. Teprve potom odstraní hlavní root. `actions-catalog` se odstraní před tímto modulem.

## Identita

- Seznam a detail rulesetů vyžadují `Organization Administration: write` i pro čtení. Plan rulesetů proto běží v samostatném jobu a environmentu s vlastní App identitou (výjimka `rulesetPlan`, účel `organization-rulesets-full-read`). Toto oprávnění umožňuje i změny jiných organizačních nastavení; výjimku přijímáme podle ADR 0016.
- Běžný plan hlavního rootu používá `Organization Administration: read`. Hlavní root API nevolá; oprávnění drží plan job jen pro běžný kontrakt.
- Apply používá `Organization Administration: write` a aplikuje hlavní root i root `rulesets/`.
- Privátní klíč ani token ruleset jobu nesmějí dostat ostatní plan joby. Stejné oddělení platí pro noční detekci driftu.
- PR platformního týmu může spustit oba plan joby automaticky, bez dalšího schválení security týmem. Forky, jiní autoři ani App-created PR credentials automaticky nedostanou.
- Apply schvaluje platformní tým a navíc security tým, protože ruleset určuje schvalovací pravidlo kódu.
- Před nasazením se musí na GHE.com ověřit potřebná API, oprávnění i úplné čtení bypass aktérů. Nepodporovaná operace není důvod přidat PAT.
