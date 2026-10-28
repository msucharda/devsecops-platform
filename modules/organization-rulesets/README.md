# organization-rulesets

Modul spravuje organizační ruleset `platform-default-branch` ve všech organizacích instance: platformní, akcí a workloadů. Ruleset vyžaduje review od CODEOWNERS na výchozí větvi všech repozitářů organizace a nemá bypass. Modul vznikl vyčleněním rootu `rulesets/` z modulu `enterprise-baseline` ([#73](https://github.com/msucharda/devsecops-platform/issues/73)).

Předpoklady: `organizations` a časná fáze `enterprise-baseline:code-security`. Katalog akcí vyžaduje schvalovací pravidlo v organizaci akcí před svým prvním apply. Pořadí je `organizations` → časná Code Security fáze → `organization-rulesets` → `actions-catalog` → pozdní `enterprise-baseline`. Pozdní root čeká na katalog kvůli politice akcí ([#18](https://github.com/msucharda/devsecops-platform/issues/18)). Samostatná časná fáze proto odstraňuje dřívější cyklus. Ruleset plan na první instanci selže, dokud vzdálená výchozí Code Security konfigurace neexistuje; postup po etapách popisuje [šablona instance](../../templates/instance/README.md#plan-a-apply).

## Konfigurace

Manifest deklaruje `organizationScoped: true`. `target_organizations` musí obsahovat přesně všechny organizace instance odvozené z vlastníka repozitáře přes `-PlatformOrganization`. Podmnožina, nadmnožina nebo jiná velikost písmen plan zastaví. Runner spustí pro každou organizaci samostatný Terraform proces se singleton seznamem a pouze jejím installation tokenem. Oba Terraform rooty odmítnou organizaci mimo deklarované organizace instance.

```yaml
modules:
  organization-rulesets:
    parameters:
      target_organizations:
        - demo-a1b2c3-platform
        - demo-a1b2c3-actions
        - demo-a1b2c3-workloads
```

## Hlavní root a výstupy

Hlavní root nemá prostředky. Každý proces zveřejní singleton výstup `organizations`. Runner vytvoří společný artifact s úplným seznamem `organizations` a mapou `organization_outputs`, která obsahuje veřejné výstupy jednotlivých organizací. Artifact vznikne až po úspěchu všech organizací. Deploy job ho nahraje až po úspěšném apply rootu `rulesets/` ve všech organizacích. Závislé moduly proto výstup dostanou, jen když rulesety existují v požadovaném tvaru.

`actions-catalog` v planu ověří, že výstup `organizations` obsahuje organizaci akcí (bez rozlišení velikosti písmen). Chybějící výstup, prázdný seznam, jiný typ nebo jiná organizace plan zastaví.

## Organizační ruleset pro výchozí větev

Root `rulesets/` spravuje v organizaci z `target_organizations` aktivní ruleset `platform-default-branch`. Podmínka `repository_name.include: ["~ALL"]` zahrnuje všechny repozitáře; `ref_name.include: ["~DEFAULT_BRANCH"]` sleduje jejich aktuální výchozí větev. Oba seznamy `exclude` jsou prázdné.

- Změna jen přes PR s jedním schválením. Nový commit schválení zruší.
- PR vyžaduje review od CODEOWNERS.
- Force push a smazání větve jsou zakázané.
- Pravidlo `code_scanning` vyžaduje CodeQL s `security_alerts_threshold: high_or_higher`. Obecné alerty bez bezpečnostní závažnosti neblokuje (`alerts_threshold: none`).
- `bypass_actors` je explicitně prázdné pole. Bypass nemá ani platformní tým, organization owner nebo importní App.

Root používá [organizační ruleset REST API](https://docs.github.com/en/enterprise-cloud@latest/rest/orgs/rules), verzi `2026-03-10`: seznam `GET /orgs/{org}/rulesets`, detail `GET /orgs/{org}/rulesets/{ruleset_id}`, vytvoření `POST /orgs/{org}/rulesets`, změnu `PUT /orgs/{org}/rulesets/{ruleset_id}` a odstranění `DELETE /orgs/{org}/rulesets/{ruleset_id}`.

- Runner ho spouští přes `Invoke-Module.ps1 -Module organization-rulesets -Rulesets` s akcí `plan`, `apply` nebo `destroy`. Každá organizace má v kontejneru modulu vlastní state `organizations/<login>/terraform.rulesets.tfstate`; hlavní root má `organizations/<login>/terraform.tfstate`. Login je lowercase. Starý state runner nehledá ani nemigruje; upgrade mezi RC release není podporovaný.
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

Teardown nejdřív odstraní root `rulesets/` ve všech organizacích a smaže jejich rulesety. Teprve potom odstraní hlavní root ve všech organizacích. `actions-catalog` se odstraní před tímto modulem. Kontrola prázdného state čte každý root každé organizace ještě před vydáním tokenů. Po přerušení další běh naváže na stejný state; úspěšná první organizace se nezaloží znovu kvůli chybě druhé.

## Identita

- Seznam a detail rulesetů vyžadují `Organization Administration: write` i pro čtení. Plan rulesetů proto běží v samostatném jobu a environmentu s vlastní App identitou (výjimka `rulesetPlan`, účel `organization-rulesets-full-read`). Toto oprávnění umožňuje i změny jiných organizačních nastavení; výjimku přijímáme podle ADR 0016.
- Běžný plan hlavního rootu používá `Organization Administration: read`. Hlavní root API nevolá; oprávnění drží plan job jen pro běžný kontrakt.
- Apply používá `Organization Administration: write` a aplikuje hlavní root i root `rulesets/`.
- Privátní klíč ani token ruleset jobu nesmějí dostat ostatní plan joby. Stejné oddělení platí pro noční detekci driftu.
- PR platformního týmu může spustit oba plan joby automaticky, bez dalšího schválení security týmem. Forky, jiní autoři ani App-created PR credentials automaticky nedostanou.
- Apply schvaluje platformní tým a navíc security tým, protože ruleset určuje schvalovací pravidlo kódu.
- Před nasazením se musí na GHE.com ověřit potřebná API, oprávnění i úplné čtení bypass aktérů. Nepodporovaná operace není důvod přidat PAT.
- Plan, apply a ruleset plan Apps musí mít instalace přesně ve všech třech organizacích podle manifestu. Instalace jsou ruční; token issuer je ověří a cizí nebo chybějící organizaci odmítne.
