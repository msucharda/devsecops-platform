# Platforma má vlastní bootstrap místo ALZ acceleratoru

Platformní tým spustí bootstrap jednou lokálně. Bootstrap vytvoří state backend, identity pro plan a apply a repozitář s konfigurací instance v organizaci platformy. Ostatní moduly nasazuje GitHub Actions přes chráněná environmenty pro plan a apply. Modul SLZ volá `avm-ptn-alz` s knihovnou `platform/slz` přímo, bez bootstrapu ALZ acceleratoru.

## Considered Options

- Bootstrap ALZ acceleratoru. Zamítnuto: Accelerator vyžaduje dva PAT, generuje vlastní repozitář a workflow ze šablony a pokrývá jen landing zone. Platforma nasazuje i enterprise GitHubu a zákazník přebírá moduly z release, ne z vygenerované šablony.
- Nasazení všech modulů lokálně. Zamítnuto: Změna instance by neprošla PR a schválením.
