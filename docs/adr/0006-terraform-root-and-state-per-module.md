# Každý modul má vlastní Terraform root a state

Každý modul je samostatný Terraform root s vlastním state. Přenos výstupů upřesňuje ADR 0014: runner předá necitlivé výstupy předpokladů z artifactů jako proměnné; modul nečte state předpokladů. Chyba v jednom modulu tak nezablokuje plan nezávislých modulů a identita modulu potřebuje oprávnění jen na své prostředky.

[ADR 0017](0017-isolated-rulesets-root.md) zavádí jedinou výjimku: modul s deklarovaným ruleset planem má izolovaný root `rulesets/` a druhý state key ve vlastním kontejneru. Běžný plan tak nemusí dostat App klíč s oprávněním k zápisu.

## Considered Options

- Jeden root pro celou instanci. Zamítnuto: Každý plan by načítal stav celé instance a identita pro apply by potřebovala oprávnění na enterprise GitHubu i na celou SLZ.

## Consequences

- Workflow nasazení instance musí spouštět moduly v pořadí závislostí.
- Změna výstupu modulu je změna rozhraní pro závislé moduly.
