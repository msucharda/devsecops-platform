# Každý modul má vlastní Terraform root a state

Každý modul je samostatný Terraform root s vlastním state. Přenos výstupů upřesňuje ADR 0014: runner předá necitlivé výstupy předpokladů z artifactů jako proměnné; modul nečte state předpokladů. Chyba v jednom modulu tak nezablokuje plan nezávislých modulů a identita modulu potřebuje oprávnění jen na své prostředky.

[ADR 0017](0017-isolated-rulesets-root.md) zavádí výjimku pro oddělení oprávnění: modul s deklarovaným ruleset planem má izolovaný root `rulesets/` a druhý state key ve vlastním kontejneru. Běžný plan tak nemusí dostat App klíč s oprávněním k zápisu.

Doplněk ([#98](https://github.com/msucharda/devsecops-platform/issues/98), [#104](https://github.com/msucharda/devsecops-platform/issues/104)): modul s `organizationScoped: true` spouští každý root samostatně pro každou organizaci instance. Root a kontejner zůstávají module-level; state keys jsou `organizations/<login>/terraform.tfstate` a případně `organizations/<login>/terraform.rulesets.tfstate`. Každý Terraform proces dostane pouze token a parametry své organizace. Starý společný state se nepřebírá ani nemigruje. Rozhodl koordinátor v autonomním mandátu uživatele, 23. 10. 2026.

Doplněk ([#128](https://github.com/msucharda/devsecops-platform/issues/128)): modul může deklarovat deployment phase (nasazovací fázi) s vlastním rootem, state a předpoklady v manifestu. Koordinátor schválil 28. 10. 2026 v nočním mandátu uživatele časnou fázi `enterprise-baseline:code-security`. Ta se nasadí před rulesety a katalogem; pozdní Actions policy až po katalogu. Jeden root by zde vytvořil cyklus předpokladů. Samostatný modul `code-security` byl zamítnut, protože by vyžadoval nový credential binding a živý krok uživatele.

Deployment phase zůstává ve stejném modulu a state kontejneru. Používá stávající credentials pro plan a apply, release preflight i schválení prostředí. Každá fáze musí výslovně deklarovat vlastní předpoklady; validátor i generátory odmítají cyklus rozšířeného DAG. Teardown probíhá v opačném pořadí. Pro organizaci má časná fáze state key `organizations/<login>/terraform.code-security.tfstate`; pozdní root zachovává původní key. Výjimka nepovoluje nové credentials ani oprávnění.

Přechod z původního baseline state je nedestruktivní: časná fáze adoptuje konfiguraci a patterns podle jména, pozdní root je uvolní ze state přes `removed` bloky s `destroy = false`. Objekty se vzdáleně nemažou ani znovu nevytvářejí. Tento přechod se liší od dřívějšího přechodu na organization-scoped state; regresní test ověřuje i opakování po přerušení mezi fázemi.

## Considered Options

- Jeden root pro celou instanci. Zamítnuto: Každý plan by načítal stav celé instance a identita pro apply by potřebovala oprávnění na enterprise GitHubu i na celou SLZ.

## Consequences

- Workflow nasazení instance musí spouštět moduly v pořadí závislostí.
- Změna výstupu modulu je změna rozhraní pro závislé moduly.
